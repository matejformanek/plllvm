/*-------------------------------------------------------------------------
 *
 * plllvm_expr.c
 *
 *			  planned expression trees to LLVM IR
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The supported functions are a table keyed by the function's OID, so
 *    the check needs no catalog access and raises no error.  An operator
 *    calls its helper of plllvm_ops.h (docs/host-api.ll), so the semantics
 *    are written once.  Only what cannot fail is plain IR: the integer
 *    comparisons and the casts to int8 and to float8.
 *
 * 2) A helper that can raise an error is called only when no argument is
 *    NULL, the interpreter does not call a strict function either.  The
 *    rest is computed also on the values of NULLs, which are never used.
 *
 * 3) The hash key is the tree in prefix order: OpExpr and FuncExpr with
 *    the function's OID and the number of arguments, Param ids and types,
 *    Const types and values, and the other nodes with their kind (AND or
 *    OR, IS NULL or IS NOT NULL, ...), type and number of arguments.  The
 *    caller confirms a match with equal().
 *
 * 4) AND, OR, CASE and COALESCE branch to a join block with phis, so that
 *    an argument the interpreter skips is not evaluated here either; it
 *    might raise an error.
 *
 */
#include "postgres.h"

#include "catalog/pg_type_d.h"
#include "fmgr.h"
#include "utils/fmgroids.h"

#include "plllvm_expr.h"

typedef enum OpKind
{
	OP_CALL,					/* helper that may raise an error */
	OP_CALL_PURE,				/* helper that never raises; NULLIF calls it
								 * also on NULLs */
	OP_ICMP,					/* icmp with the predicate in name */
	OP_SEXT,					/* int4 -> int8 */
	OP_SITOFP,					/* int4, int8 -> float8 */
} OpKind;

typedef struct OpInfo
{
	Oid			funcid;
	OpKind		kind;
	const char *name;			/* helper or icmp predicate */
	int			nargs;
	plllvm_repr args[2];
	plllvm_repr result;
} OpInfo;

#define I1		PLLLVM_I1
#define I32		PLLLVM_I32
#define I64		PLLLVM_I64
#define F64		PLLLVM_F64

static const OpInfo ops[] = {
	{F_INT4PL, OP_CALL, "plllvm_int4_pl", 2, {I32, I32}, I32},
	{F_INT4MI, OP_CALL, "plllvm_int4_mi", 2, {I32, I32}, I32},
	{F_INT4MUL, OP_CALL, "plllvm_int4_mul", 2, {I32, I32}, I32},
	{F_INT4DIV, OP_CALL, "plllvm_int4_div", 2, {I32, I32}, I32},
	{F_INT4MOD, OP_CALL, "plllvm_int4_mod", 2, {I32, I32}, I32},
	{F_MOD_INT4_INT4, OP_CALL, "plllvm_int4_mod", 2, {I32, I32}, I32},
	{F_INT4UM, OP_CALL, "plllvm_int4_um", 1, {I32}, I32},
	{F_INT8PL, OP_CALL, "plllvm_int8_pl", 2, {I64, I64}, I64},
	{F_INT8MI, OP_CALL, "plllvm_int8_mi", 2, {I64, I64}, I64},
	{F_INT8MUL, OP_CALL, "plllvm_int8_mul", 2, {I64, I64}, I64},
	{F_INT8DIV, OP_CALL, "plllvm_int8_div", 2, {I64, I64}, I64},
	{F_INT8MOD, OP_CALL, "plllvm_int8_mod", 2, {I64, I64}, I64},
	{F_MOD_INT8_INT8, OP_CALL, "plllvm_int8_mod", 2, {I64, I64}, I64},
	{F_INT8UM, OP_CALL, "plllvm_int8_um", 1, {I64}, I64},
	{F_INT48PL, OP_CALL, "plllvm_int48_pl", 2, {I32, I64}, I64},
	{F_INT48MI, OP_CALL, "plllvm_int48_mi", 2, {I32, I64}, I64},
	{F_INT48MUL, OP_CALL, "plllvm_int48_mul", 2, {I32, I64}, I64},
	{F_INT48DIV, OP_CALL, "plllvm_int48_div", 2, {I32, I64}, I64},
	{F_INT84PL, OP_CALL, "plllvm_int84_pl", 2, {I64, I32}, I64},
	{F_INT84MI, OP_CALL, "plllvm_int84_mi", 2, {I64, I32}, I64},
	{F_INT84MUL, OP_CALL, "plllvm_int84_mul", 2, {I64, I32}, I64},
	{F_INT84DIV, OP_CALL, "plllvm_int84_div", 2, {I64, I32}, I64},

	{F_INT4EQ, OP_ICMP, "eq", 2, {I32, I32}, I1},
	{F_INT4NE, OP_ICMP, "ne", 2, {I32, I32}, I1},
	{F_INT4LT, OP_ICMP, "slt", 2, {I32, I32}, I1},
	{F_INT4LE, OP_ICMP, "sle", 2, {I32, I32}, I1},
	{F_INT4GT, OP_ICMP, "sgt", 2, {I32, I32}, I1},
	{F_INT4GE, OP_ICMP, "sge", 2, {I32, I32}, I1},
	{F_INT8EQ, OP_ICMP, "eq", 2, {I64, I64}, I1},
	{F_INT8NE, OP_ICMP, "ne", 2, {I64, I64}, I1},
	{F_INT8LT, OP_ICMP, "slt", 2, {I64, I64}, I1},
	{F_INT8LE, OP_ICMP, "sle", 2, {I64, I64}, I1},
	{F_INT8GT, OP_ICMP, "sgt", 2, {I64, I64}, I1},
	{F_INT8GE, OP_ICMP, "sge", 2, {I64, I64}, I1},
	{F_INT48EQ, OP_ICMP, "eq", 2, {I32, I64}, I1},
	{F_INT48NE, OP_ICMP, "ne", 2, {I32, I64}, I1},
	{F_INT48LT, OP_ICMP, "slt", 2, {I32, I64}, I1},
	{F_INT48LE, OP_ICMP, "sle", 2, {I32, I64}, I1},
	{F_INT48GT, OP_ICMP, "sgt", 2, {I32, I64}, I1},
	{F_INT48GE, OP_ICMP, "sge", 2, {I32, I64}, I1},
	{F_INT84EQ, OP_ICMP, "eq", 2, {I64, I32}, I1},
	{F_INT84NE, OP_ICMP, "ne", 2, {I64, I32}, I1},
	{F_INT84LT, OP_ICMP, "slt", 2, {I64, I32}, I1},
	{F_INT84LE, OP_ICMP, "sle", 2, {I64, I32}, I1},
	{F_INT84GT, OP_ICMP, "sgt", 2, {I64, I32}, I1},
	{F_INT84GE, OP_ICMP, "sge", 2, {I64, I32}, I1},
	{F_BOOLEQ, OP_ICMP, "eq", 2, {I1, I1}, I1},
	{F_BOOLNE, OP_ICMP, "ne", 2, {I1, I1}, I1},

	{F_FLOAT8PL, OP_CALL, "plllvm_float8_pl", 2, {F64, F64}, F64},
	{F_FLOAT8MI, OP_CALL, "plllvm_float8_mi", 2, {F64, F64}, F64},
	{F_FLOAT8MUL, OP_CALL, "plllvm_float8_mul", 2, {F64, F64}, F64},
	{F_FLOAT8DIV, OP_CALL, "plllvm_float8_div", 2, {F64, F64}, F64},
	{F_FLOAT8UM, OP_CALL_PURE, "plllvm_float8_um", 1, {F64}, F64},
	/* NaN is equal to NaN and above everything, so no fcmp */
	{F_FLOAT8EQ, OP_CALL_PURE, "plllvm_float8_eq", 2, {F64, F64}, I1},
	{F_FLOAT8NE, OP_CALL_PURE, "plllvm_float8_ne", 2, {F64, F64}, I1},
	{F_FLOAT8LT, OP_CALL_PURE, "plllvm_float8_lt", 2, {F64, F64}, I1},
	{F_FLOAT8LE, OP_CALL_PURE, "plllvm_float8_le", 2, {F64, F64}, I1},
	{F_FLOAT8GT, OP_CALL_PURE, "plllvm_float8_gt", 2, {F64, F64}, I1},
	{F_FLOAT8GE, OP_CALL_PURE, "plllvm_float8_ge", 2, {F64, F64}, I1},

	{F_INT4ABS, OP_CALL, "plllvm_int4_abs", 1, {I32}, I32},
	{F_ABS_INT4, OP_CALL, "plllvm_int4_abs", 1, {I32}, I32},
	{F_INT8ABS, OP_CALL, "plllvm_int8_abs", 1, {I64}, I64},
	{F_ABS_INT8, OP_CALL, "plllvm_int8_abs", 1, {I64}, I64},
	{F_FLOAT8ABS, OP_CALL_PURE, "plllvm_float8_abs", 1, {F64}, F64},
	{F_ABS_FLOAT8, OP_CALL_PURE, "plllvm_float8_abs", 1, {F64}, F64},
	{F_DSQRT, OP_CALL, "plllvm_float8_sqrt", 1, {F64}, F64},
	{F_SQRT_FLOAT8, OP_CALL, "plllvm_float8_sqrt", 1, {F64}, F64},

	{F_INT8_INT4, OP_SEXT, NULL, 1, {I32}, I64},
	{F_INT4_INT8, OP_CALL, "plllvm_int4_from_int8", 1, {I64}, I32},
	{F_FLOAT8_INT4, OP_SITOFP, NULL, 1, {I32}, F64},
	{F_FLOAT8_INT8, OP_SITOFP, NULL, 1, {I64}, F64},
	{F_INT4_FLOAT8, OP_CALL, "plllvm_int4_from_float8", 1, {F64}, I32},
	{F_INT8_FLOAT8, OP_CALL, "plllvm_int8_from_float8", 1, {F64}, I64},
};

typedef struct CheckState
{
	plllvm_expr_env *env;
	StringInfo	hash_key;
	StringInfo	facts;
	const char *why;
	int			nnodes;
	int			nops;
	bool		has_caseval;	/* a CaseTestExpr may appear here */
	plllvm_repr caseval_repr;
} CheckState;

typedef struct EmitState
{
	plllvm_expr_env *env;
	const plllvm_value *caseval;	/* what a CaseTestExpr reads, or NULL */
} EmitState;

/* the incoming edges of the phis that join the branches of a node */
typedef struct PhiJoin
{
	StringInfoData v;
	StringInfoData isnull;
} PhiJoin;

static bool check_node(const Expr *e, CheckState *cs, plllvm_repr *repr);
static bool check_arg(const Expr *e, CheckState *cs, plllvm_repr repr);
static bool check_args(List *args, CheckState *cs, plllvm_repr repr);
static bool check_func(Oid funcid, CheckState *cs, const OpInfo **op);
static void emit_node(plllvm_ir *ir, const Expr *e, EmitState *es,
					  plllvm_value *out);
static void emit_op(plllvm_ir *ir, const OpInfo *op, List *args,
					EmitState *es, plllvm_value *out);
static const char *emit_compute(plllvm_ir *ir, const OpInfo *op,
								plllvm_value *av);
static void emit_bool(plllvm_ir *ir, const BoolExpr *b, EmitState *es,
					  plllvm_value *out);
static void emit_case(plllvm_ir *ir, const CaseExpr *c, EmitState *es,
					  plllvm_value *out);
static void emit_coalesce(plllvm_ir *ir, const CoalesceExpr *c,
						  EmitState *es, plllvm_value *out);
static void emit_nullif(plllvm_ir *ir, const NullIfExpr *n, EmitState *es,
						plllvm_value *out);
static void emit_booltest(plllvm_ir *ir, const BooleanTest *b,
						  EmitState *es, plllvm_value *out);
static const char *emit_not(plllvm_ir *ir, const char *v);
static const char *emit_logic(plllvm_ir *ir, const char *op, const char *a,
							  const char *b);
static void join_init(PhiJoin *j);
static void join_edge(PhiJoin *j, const char *v, const char *isnull,
					  const char *from);
static void join_end(plllvm_ir *ir, PhiJoin *j, const char *label,
					 plllvm_repr repr, plllvm_value *out);


static const OpInfo *
find_op(Oid funcid)
{
	for (int i = 0; i < lengthof(ops); i++)
	{
		if (ops[i].funcid == funcid)
			return &ops[i];
	}
	return NULL;
}

static bool
type_repr(Oid type, plllvm_repr *repr)
{
	switch (type)
	{
		case BOOLOID:
			*repr = PLLLVM_I1;
			return true;
		case INT4OID:
			*repr = PLLLVM_I32;
			return true;
		case INT8OID:
			*repr = PLLLVM_I64;
			return true;
		case FLOAT8OID:
			*repr = PLLLVM_F64;
			return true;
		default:
			return false;
	}
}

static Oid
repr_sql_type(plllvm_repr repr)
{
	static const Oid types[] = {BOOLOID, INT4OID, INT8OID, FLOAT8OID};

	return types[repr];
}

static const char *
repr_zero(plllvm_repr repr)
{
	static const char *const zeros[] = {"false", "0", "0", "0.0"};

	return zeros[repr];
}

/*
 * The IR type of a representation
 */
const char *
plllvm_repr_type(plllvm_repr repr)
{
	static const char *const types[] = {"i1", "i32", "i64", "double"};

	return types[repr];
}

/*
 * Can the whole tree be compiled?
 *
 * On success, hash_key has the tree's key appended and facts what
 * param_check added.  Otherwise *why says what was refused, and both
 * buffers hold garbage.
 */
bool
plllvm_expr_check(const Expr *e, plllvm_expr_env *env, StringInfo hash_key,
				  StringInfo facts, const char **why)
{
	CheckState	cs;
	plllvm_repr repr;

	cs.env = env;
	cs.hash_key = hash_key;
	cs.facts = facts;
	cs.why = NULL;
	cs.nnodes = 0;
	cs.nops = 0;
	cs.has_caseval = false;

	if (!check_node(e, &cs, &repr))
	{
		*why = cs.why;
		return false;
	}
	if (cs.nops == 0)
	{
		/* a bare variable or constant is cheaper interpreted */
		*why = "no operator";
		return false;
	}
	return true;
}

static bool
check_node(const Expr *e, CheckState *cs, plllvm_repr *repr)
{
	char		tag;
	Oid			funcid;
	Oid			restype;
	List	   *args;
	const OpInfo *op;
	int			i;

	if (++cs->nnodes > PLLLVM_EXPR_MAX_NODES)
	{
		cs->why = "too many nodes";
		return false;
	}

	switch (nodeTag(e))
	{
		case T_Const:
			{
				const Const *c = (const Const *) e;

				if (!type_repr(c->consttype, repr))
				{
					cs->why = "type";
					return false;
				}
				if (c->constisnull)
					appendStringInfo(cs->hash_key, "C%u:null ", c->consttype);
				else
					appendStringInfo(cs->hash_key, "C%u:" UINT64_FORMAT " ",
									 c->consttype,
									 DatumGetUInt64(c->constvalue));
				return true;
			}
		case T_Param:
			{
				const Param *p = (const Param *) e;

				if (p->paramkind != PARAM_EXTERN)
				{
					cs->why = "Param kind";
					return false;
				}
				if (!type_repr(p->paramtype, repr))
				{
					cs->why = "type";
					return false;
				}
				if (!cs->env->param_check(cs->env, p, cs->facts))
				{
					cs->why = "Param";
					return false;
				}
				appendStringInfo(cs->hash_key, "P%d:%u ", p->paramid,
								 p->paramtype);
				return true;
			}
		case T_OpExpr:
			{
				const OpExpr *o = (const OpExpr *) e;

				tag = 'O';
				funcid = o->opfuncid;
				restype = o->opresulttype;
				args = o->args;
				break;
			}
		case T_FuncExpr:
			{
				const FuncExpr *f = (const FuncExpr *) e;

				if (f->funcretset)
				{
					cs->why = "function";
					return false;
				}
				tag = 'F';
				funcid = f->funcid;
				restype = f->funcresulttype;
				args = f->args;
				break;
			}
		case T_BoolExpr:
			{
				const BoolExpr *b = (const BoolExpr *) e;

				cs->nops++;
				appendStringInfo(cs->hash_key, "B%d/%d ", (int) b->boolop,
								 list_length(b->args));
				*repr = PLLLVM_I1;
				return check_args(b->args, cs, PLLLVM_I1);
			}
		case T_NullTest:
			{
				const NullTest *n = (const NullTest *) e;
				plllvm_repr arepr;

				if (n->argisrow)
				{
					cs->why = "node";
					return false;
				}
				cs->nops++;
				appendStringInfo(cs->hash_key, "N%d ", (int) n->nulltesttype);
				*repr = PLLLVM_I1;
				return check_node(n->arg, cs, &arepr);
			}
		case T_BooleanTest:
			{
				const BooleanTest *b = (const BooleanTest *) e;

				cs->nops++;
				appendStringInfo(cs->hash_key, "b%d ", (int) b->booltesttype);
				*repr = PLLLVM_I1;
				return check_arg(b->arg, cs, PLLLVM_I1);
			}
		case T_CaseExpr:
			{
				const CaseExpr *c = (const CaseExpr *) e;
				plllvm_repr arepr = PLLLVM_I1;

				/* transformCaseExpr always adds a default */
				Assert(c->defresult != NULL);
				if (!type_repr(c->casetype, repr))
				{
					cs->why = "type";
					return false;
				}
				cs->nops++;
				appendStringInfo(cs->hash_key, "K%u/%d%s ", c->casetype,
								 list_length(c->args), c->arg ? "a" : "");
				if (c->arg && !check_node(c->arg, cs, &arepr))
					return false;
				foreach_node(CaseWhen, w, c->args)
				{
					bool		save_has = cs->has_caseval;
					plllvm_repr save_repr = cs->caseval_repr;
					bool		ok;

					/* as ExecInitExprRec: only the WHEN sees this arg */
					cs->has_caseval = (c->arg != NULL);
					cs->caseval_repr = arepr;
					ok = check_arg(w->expr, cs, PLLLVM_I1);
					cs->has_caseval = save_has;
					cs->caseval_repr = save_repr;
					if (!ok || !check_arg(w->result, cs, *repr))
						return false;
				}
				return check_arg(c->defresult, cs, *repr);
			}
		case T_CaseTestExpr:
			{
				const CaseTestExpr *t = (const CaseTestExpr *) e;

				if (!cs->has_caseval)
				{
					cs->why = "node";
					return false;
				}
				if (!type_repr(t->typeId, repr) || *repr != cs->caseval_repr)
				{
					cs->why = "type";
					return false;
				}
				appendStringInfo(cs->hash_key, "T%u ", t->typeId);
				return true;
			}
		case T_CoalesceExpr:
			{
				const CoalesceExpr *c = (const CoalesceExpr *) e;

				if (!type_repr(c->coalescetype, repr))
				{
					cs->why = "type";
					return false;
				}
				cs->nops++;
				appendStringInfo(cs->hash_key, "Z%u/%d ", c->coalescetype,
								 list_length(c->args));
				return check_args(c->args, cs, *repr);
			}
		case T_NullIfExpr:
			{
				const NullIfExpr *n = (const NullIfExpr *) e;

				/*
				 * The comparison runs also on the values of NULLs, whose
				 * result is masked, so it must not be able to raise.
				 */
				if (!check_func(n->opfuncid, cs, &op))
					return false;
				if (op->kind == OP_CALL || op->result != PLLLVM_I1 ||
					op->nargs != 2 || list_length(n->args) != 2 ||
					!type_repr(n->opresulttype, repr) || *repr != op->args[0])
				{
					cs->why = "function";
					return false;
				}
				appendStringInfo(cs->hash_key, "I%u/%u ", n->opfuncid,
								 n->opresulttype);
				i = 0;
				foreach_ptr(Expr, arg, n->args)
				{
					if (!check_arg(arg, cs, op->args[i++]))
						return false;
				}
				return true;
			}
		default:
			cs->why = "node";
			return false;
	}

	if (!check_func(funcid, cs, &op))
		return false;
	if (list_length(args) != op->nargs || restype != repr_sql_type(op->result))
	{
		cs->why = "function";
		return false;
	}
	appendStringInfo(cs->hash_key, "%c%u/%d ", tag, funcid, op->nargs);

	i = 0;
	foreach_ptr(Expr, arg, args)
	{
		if (!check_arg(arg, cs, op->args[i++]))
			return false;
	}
	*repr = op->result;
	return true;
}

/*
 * Check an argument, which must be of repr
 */
static bool
check_arg(const Expr *e, CheckState *cs, plllvm_repr repr)
{
	plllvm_repr arepr;

	if (!check_node(e, cs, &arepr))
		return false;
	if (arepr != repr)
	{
		cs->why = "type";
		return false;
	}
	return true;
}

static bool
check_args(List *args, CheckState *cs, plllvm_repr repr)
{
	foreach_ptr(Expr, arg, args)
	{
		if (!check_arg(arg, cs, repr))
			return false;
	}
	return true;
}

/*
 * Is funcid one of ops[], and may it be called without fmgr?
 */
static bool
check_func(Oid funcid, CheckState *cs, const OpInfo **op)
{
	*op = find_op(funcid);
	if (*op == NULL)
	{
		cs->why = "function";
		return false;
	}
	/* sepgsql and the like must see the call */
	if (FmgrHookIsNeeded(funcid))
	{
		cs->why = "fmgr hook";
		return false;
	}
	cs->nops++;
	return true;
}

/*
 * Emit the code of a tree accepted by plllvm_expr_check()
 */
void
plllvm_expr_emit(plllvm_ir *ir, const Expr *e, plllvm_expr_env *env,
				 plllvm_value *out)
{
	EmitState	es;

	es.env = env;
	es.caseval = NULL;
	emit_node(ir, e, &es, out);
}

static void
emit_node(plllvm_ir *ir, const Expr *e, EmitState *es, plllvm_value *out)
{
	switch (nodeTag(e))
	{
		case T_Const:
			{
				const Const *c = (const Const *) e;

				if (!type_repr(c->consttype, &out->repr))
					elog(ERROR, "unsupported type %u", c->consttype);
				out->type = c->consttype;
				if (c->constisnull)
				{
					out->v = repr_zero(out->repr);
					out->isnull = "true";
					return;
				}
				out->isnull = "false";
				switch (out->repr)
				{
					case PLLLVM_I1:
						out->v = DatumGetBool(c->constvalue) ? "true" : "false";
						break;
					case PLLLVM_I32:
						out->v = psprintf("%d", DatumGetInt32(c->constvalue));
						break;
					case PLLLVM_I64:
						out->v = psprintf(INT64_FORMAT,
										  DatumGetInt64(c->constvalue));
						break;
					case PLLLVM_F64:
						/* the bits, so that NaN, infinities and -0 survive */
						out->v = psprintf("0x%016" PRIX64,
										  DatumGetUInt64(c->constvalue));
						break;
				}
				return;
			}
		case T_Param:
			{
				const Param *p = (const Param *) e;

				es->env->param_emit(es->env, ir, p, out);
				Assert(out->type == p->paramtype);
				return;
			}
		case T_OpExpr:
			{
				const OpExpr *o = (const OpExpr *) e;

				emit_op(ir, find_op(o->opfuncid), o->args, es, out);
				return;
			}
		case T_FuncExpr:
			{
				const FuncExpr *f = (const FuncExpr *) e;

				emit_op(ir, find_op(f->funcid), f->args, es, out);
				return;
			}
		case T_BoolExpr:
			emit_bool(ir, (const BoolExpr *) e, es, out);
			return;
		case T_NullTest:
			{
				const NullTest *n = (const NullTest *) e;
				plllvm_value arg;

				emit_node(ir, n->arg, es, &arg);
				if (n->nulltesttype == IS_NULL)
					out->v = arg.isnull;
				else
					out->v = emit_not(ir, arg.isnull);
				out->isnull = "false";
				out->repr = PLLLVM_I1;
				out->type = BOOLOID;
				return;
			}
		case T_BooleanTest:
			emit_booltest(ir, (const BooleanTest *) e, es, out);
			return;
		case T_CaseExpr:
			emit_case(ir, (const CaseExpr *) e, es, out);
			return;
		case T_CaseTestExpr:
			Assert(es->caseval != NULL);
			*out = *es->caseval;
			return;
		case T_CoalesceExpr:
			emit_coalesce(ir, (const CoalesceExpr *) e, es, out);
			return;
		case T_NullIfExpr:
			emit_nullif(ir, (const NullIfExpr *) e, es, out);
			return;
		default:
			elog(ERROR, "unrecognized node type: %d", (int) nodeTag(e));
	}
}

static void
emit_op(plllvm_ir *ir, const OpInfo *op, List *args, EmitState *es,
		plllvm_value *out)
{
	plllvm_value av[2];
	const char *isnull = "false";
	int			i;

	Assert(op != NULL && list_length(args) == op->nargs);

	/* all arguments first, also when one of them is NULL */
	i = 0;
	foreach_ptr(Expr, arg, args)
		emit_node(ir, arg, es, &av[i++]);

	out->repr = op->result;
	out->type = repr_sql_type(op->result);

	for (i = 0; i < op->nargs; i++)
	{
		if (strcmp(av[i].isnull, "true") == 0)
		{
			out->v = repr_zero(out->repr);
			out->isnull = "true";
			return;
		}
	}
	for (i = 0; i < op->nargs; i++)
	{
		if (strcmp(av[i].isnull, "false") == 0)
			continue;
		if (strcmp(isnull, "false") == 0)
			isnull = av[i].isnull;
		else
		{
			const char *t = plllvm_ir_tmp(ir);

			plllvm_ir_emit(ir, "%s = or i1 %s, %s", t, isnull, av[i].isnull);
			isnull = t;
		}
	}
	out->isnull = isnull;

	if (op->kind != OP_CALL || strcmp(isnull, "false") == 0)
		out->v = emit_compute(ir, op, av);
	else
	{
		const char *lcall = plllvm_ir_label(ir);
		const char *lnull = plllvm_ir_label(ir);
		const char *ljoin = plllvm_ir_label(ir);
		const char *r;
		const char *from;
		const char *t;

		plllvm_ir_emit(ir, "br i1 %s, label %%%s, label %%%s",
					   isnull, lnull, lcall);
		plllvm_ir_block(ir, lcall);
		r = emit_compute(ir, op, av);
		from = plllvm_ir_current(ir);
		plllvm_ir_emit(ir, "br label %%%s", ljoin);
		plllvm_ir_block(ir, lnull);
		plllvm_ir_emit(ir, "br label %%%s", ljoin);
		plllvm_ir_block(ir, ljoin);
		t = plllvm_ir_tmp(ir);
		plllvm_ir_emit(ir, "%s = phi %s [ %s, %%%s ], [ %s, %%%s ]",
					   t, plllvm_repr_type(op->result), r, from,
					   repr_zero(op->result), lnull);
		out->v = t;
	}
}

/*
 * The operation itself, on arguments known not to be NULL
 */
static const char *
emit_compute(plllvm_ir *ir, const OpInfo *op, plllvm_value *av)
{
	const char *t;
	const char *a = av[0].v;
	const char *b = op->nargs > 1 ? av[1].v : NULL;

	switch (op->kind)
	{
		case OP_CALL:
		case OP_CALL_PURE:
			{
				const char *rtype = plllvm_repr_type(op->result);
				const char *t0 = plllvm_repr_type(op->args[0]);

				t = plllvm_ir_tmp(ir);
				if (op->nargs == 1)
				{
					plllvm_ir_declare(ir, psprintf("declare %s @%s(%s)",
												   rtype, op->name, t0));
					plllvm_ir_emit(ir, "%s = call %s @%s(%s %s)",
								   t, rtype, op->name, t0, a);
				}
				else
				{
					const char *t1 = plllvm_repr_type(op->args[1]);

					plllvm_ir_declare(ir, psprintf("declare %s @%s(%s, %s)",
												   rtype, op->name, t0, t1));
					plllvm_ir_emit(ir, "%s = call %s @%s(%s %s, %s %s)",
								   t, rtype, op->name, t0, a, t1, b);
				}
				return t;
			}
		case OP_ICMP:
			{
				plllvm_repr r = op->args[0];

				/* int48 and int84 compare as int8 */
				if (op->args[0] != op->args[1])
				{
					const char *w = plllvm_ir_tmp(ir);

					if (op->args[0] == PLLLVM_I32)
					{
						plllvm_ir_emit(ir, "%s = sext i32 %s to i64", w, a);
						a = w;
					}
					else
					{
						plllvm_ir_emit(ir, "%s = sext i32 %s to i64", w, b);
						b = w;
					}
					r = PLLLVM_I64;
				}
				t = plllvm_ir_tmp(ir);
				plllvm_ir_emit(ir, "%s = icmp %s %s %s, %s",
							   t, op->name, plllvm_repr_type(r), a, b);
				return t;
			}
		case OP_SEXT:
			t = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = sext i32 %s to i64", t, a);
			return t;
		case OP_SITOFP:
			t = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = sitofp %s %s to double",
						   t, plllvm_repr_type(op->args[0]), a);
			return t;
	}
	pg_unreachable();
}

/*
 * AND, OR and NOT
 *
 * AND stops at the first FALSE argument and OR at the first TRUE one,
 * without evaluating the rest.  Otherwise the result is NULL if an
 * argument was NULL (EEOP_BOOL_AND_STEP, execExprInterp.c:1057-1095).
 */
static void
emit_bool(plllvm_ir *ir, const BoolExpr *b, EmitState *es, plllvm_value *out)
{
	const char *stop = b->boolop == OR_EXPR ? "true" : "false";
	const char *ldone;
	const char *anynull = "false";
	PhiJoin		j;

	out->repr = PLLLVM_I1;
	out->type = BOOLOID;

	if (b->boolop == NOT_EXPR)
	{
		plllvm_value arg;

		/* NULL stays NULL */
		emit_node(ir, linitial(b->args), es, &arg);
		out->v = emit_not(ir, arg.v);
		out->isnull = arg.isnull;
		return;
	}

	ldone = plllvm_ir_label(ir);
	join_init(&j);
	foreach_ptr(Expr, e, b->args)
	{
		plllvm_value arg;
		const char *lnext = plllvm_ir_label(ir);
		const char *v;
		const char *stops;

		emit_node(ir, e, es, &arg);
		v = b->boolop == OR_EXPR ? arg.v : emit_not(ir, arg.v);
		stops = emit_logic(ir, "and", emit_not(ir, arg.isnull), v);
		plllvm_ir_emit(ir, "br i1 %s, label %%%s, label %%%s",
					   stops, ldone, lnext);
		join_edge(&j, stop, "false", plllvm_ir_current(ir));
		plllvm_ir_block(ir, lnext);
		anynull = emit_logic(ir, "or", anynull, arg.isnull);
	}
	join_edge(&j, b->boolop == OR_EXPR ? "false" : "true", anynull,
			  plllvm_ir_current(ir));
	plllvm_ir_emit(ir, "br label %%%s", ldone);
	join_end(ir, &j, ldone, PLLLVM_I1, out);
}

/*
 * IS [NOT] TRUE, IS [NOT] FALSE, IS [NOT] UNKNOWN, never NULL
 */
static void
emit_booltest(plllvm_ir *ir, const BooleanTest *b, EmitState *es,
			  plllvm_value *out)
{
	plllvm_value arg;
	const char *notnull;

	emit_node(ir, b->arg, es, &arg);
	notnull = emit_not(ir, arg.isnull);

	switch (b->booltesttype)
	{
		case IS_TRUE:
			out->v = emit_logic(ir, "and", notnull, arg.v);
			break;
		case IS_NOT_TRUE:
			out->v = emit_logic(ir, "or", arg.isnull, emit_not(ir, arg.v));
			break;
		case IS_FALSE:
			out->v = emit_logic(ir, "and", notnull, emit_not(ir, arg.v));
			break;
		case IS_NOT_FALSE:
			out->v = emit_logic(ir, "or", arg.isnull, arg.v);
			break;
		case IS_UNKNOWN:
			out->v = arg.isnull;
			break;
		case IS_NOT_UNKNOWN:
			out->v = notnull;
			break;
		default:
			elog(ERROR, "unrecognized booltesttype: %d",
				 (int) b->booltesttype);
	}
	out->isnull = "false";
	out->repr = PLLLVM_I1;
	out->type = BOOLOID;
}

/*
 * CASE: the WHEN conditions in turn, then the THEN of the first that is
 * true, else the ELSE; the other arms are not evaluated.  With an argument,
 * it is evaluated once, and the CaseTestExprs of the WHEN conditions (not
 * of the results) read it (execExpr.c:1769-1880).
 */
static void
emit_case(plllvm_ir *ir, const CaseExpr *c, EmitState *es, plllvm_value *out)
{
	plllvm_value caseval;
	plllvm_repr repr;
	const char *ldone = plllvm_ir_label(ir);
	PhiJoin		j;
	plllvm_value r;

	if (c->arg)
		emit_node(ir, c->arg, es, &caseval);

	join_init(&j);
	foreach_node(CaseWhen, w, c->args)
	{
		const plllvm_value *save = es->caseval;
		const char *lthen = plllvm_ir_label(ir);
		const char *lnext = plllvm_ir_label(ir);
		plllvm_value cond;

		es->caseval = c->arg ? &caseval : NULL;
		emit_node(ir, w->expr, es, &cond);
		es->caseval = save;

		/* NULL is not true */
		plllvm_ir_emit(ir, "br i1 %s, label %%%s, label %%%s",
					   emit_logic(ir, "and", emit_not(ir, cond.isnull), cond.v),
					   lthen, lnext);
		plllvm_ir_block(ir, lthen);
		emit_node(ir, w->result, es, &r);
		join_edge(&j, r.v, r.isnull, plllvm_ir_current(ir));
		plllvm_ir_emit(ir, "br label %%%s", ldone);
		plllvm_ir_block(ir, lnext);
	}
	emit_node(ir, c->defresult, es, &r);
	join_edge(&j, r.v, r.isnull, plllvm_ir_current(ir));
	plllvm_ir_emit(ir, "br label %%%s", ldone);

	if (!type_repr(c->casetype, &repr))
		elog(ERROR, "unsupported type %u", c->casetype);
	join_end(ir, &j, ldone, repr, out);
	out->type = c->casetype;
}

/*
 * COALESCE: the arguments in turn up to the first that is not NULL
 */
static void
emit_coalesce(plllvm_ir *ir, const CoalesceExpr *c, EmitState *es,
			  plllvm_value *out)
{
	const char *ldone = plllvm_ir_label(ir);
	PhiJoin		j;
	plllvm_repr repr;

	join_init(&j);
	foreach_ptr(Expr, e, c->args)
	{
		plllvm_value arg;

		emit_node(ir, e, es, &arg);
		if (foreach_current_index(e) == list_length(c->args) - 1)
		{
			join_edge(&j, arg.v, arg.isnull, plllvm_ir_current(ir));
			plllvm_ir_emit(ir, "br label %%%s", ldone);
		}
		else
		{
			const char *lnext = plllvm_ir_label(ir);

			plllvm_ir_emit(ir, "br i1 %s, label %%%s, label %%%s",
						   arg.isnull, lnext, ldone);
			join_edge(&j, arg.v, "false", plllvm_ir_current(ir));
			plllvm_ir_block(ir, lnext);
		}
	}

	if (!type_repr(c->coalescetype, &repr))
		elog(ERROR, "unsupported type %u", c->coalescetype);
	join_end(ir, &j, ldone, repr, out);
	out->type = c->coalescetype;
}

/*
 * NULLIF(a, b): both arguments, then NULL when neither is NULL and they
 * are equal, else a (EEOP_NULLIF).  The comparison cannot fail, so it is
 * computed also on NULLs.
 */
static void
emit_nullif(plllvm_ir *ir, const NullIfExpr *n, EmitState *es,
			plllvm_value *out)
{
	const OpInfo *op = find_op(n->opfuncid);
	plllvm_value av[2];
	const char *eq;

	Assert(op != NULL && op->kind != OP_CALL);
	emit_node(ir, linitial(n->args), es, &av[0]);
	emit_node(ir, lsecond(n->args), es, &av[1]);
	eq = emit_compute(ir, op, av);

	*out = av[0];
	out->isnull = emit_logic(ir, "or", av[0].isnull,
							 emit_logic(ir, "and",
										emit_not(ir, av[1].isnull), eq));
	out->type = n->opresulttype;
}

static const char *
emit_not(plllvm_ir *ir, const char *v)
{
	return emit_logic(ir, "xor", v, "true");
}

/* and, or, xor of two i1 */
static const char *
emit_logic(plllvm_ir *ir, const char *op, const char *a, const char *b)
{
	const char *t = plllvm_ir_tmp(ir);

	plllvm_ir_emit(ir, "%s = %s i1 %s, %s", t, op, a, b);
	return t;
}

static void
join_init(PhiJoin *j)
{
	initStringInfo(&j->v);
	initStringInfo(&j->isnull);
}

/*
 * A branch from block "from" to the join will carry v and isnull
 */
static void
join_edge(PhiJoin *j, const char *v, const char *isnull, const char *from)
{
	appendStringInfo(&j->v, "%s[ %s, %%%s ]", j->v.len ? ", " : "", v, from);
	appendStringInfo(&j->isnull, "%s[ %s, %%%s ]", j->isnull.len ? ", " : "",
					 isnull, from);
}

/*
 * Start the join block; out gets the phis of the edges
 */
static void
join_end(plllvm_ir *ir, PhiJoin *j, const char *label, plllvm_repr repr,
		 plllvm_value *out)
{
	const char *v = plllvm_ir_tmp(ir);
	const char *isnull = plllvm_ir_tmp(ir);

	plllvm_ir_block(ir, label);
	plllvm_ir_emit(ir, "%s = phi %s %s", v, plllvm_repr_type(repr), j->v.data);
	plllvm_ir_emit(ir, "%s = phi i1 %s", isnull, j->isnull.data);
	out->v = v;
	out->isnull = isnull;
	out->repr = repr;
	out->type = repr_sql_type(repr);
}
