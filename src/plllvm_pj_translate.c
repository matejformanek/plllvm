/*-------------------------------------------------------------------------
 *
 * plllvm_pj_translate.c
 *
 *			  plpgsql_jit: from the planned expressions of a PL/pgSQL
 *			  function to LLVM IR
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The trees are those PL/pgSQL left in expr_simple_expr after its first
 *    run of the function.  We copy them and never point into the plan,
 *    which the next invalidation frees.
 *
 * 2) The value of a RETURN converts to the result type as exec_cast_value()
 *    does, by a tree over a CaseTestExpr bound to the value.  It is the tree
 *    PL/pgSQL would build, so that casts and errors are the same.
 *
 * The rest is in docs/architecture.md.
 *
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "access/transam.h"
#include "catalog/pg_cast.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "lib/stringinfo.h"
#include "nodes/makefuncs.h"
#include "nodes/nodeFuncs.h"
#include "optimizer/optimizer.h"
#include "parser/parse_coerce.h"
#include "plpgsql.h"
#include "utils/builtins.h"
#include "utils/hsearch.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/plancache.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_expr.h"
#include "plllvm_ir.h"
#include "plllvm_pj.h"

typedef struct PjEnv
{
	plllvm_expr_env base;
	PLpgSQL_function *func;
} PjEnv;

typedef struct PjCastKey
{
	Oid			srctype;
	int32		srctypmod;
	Oid			dsttype;
} PjCastKey;

typedef struct PjCastEntry
{
	PjCastKey	key;
	PjCast		cast;
} PjCastEntry;

static HTAB *casts = NULL;

static const char *walk_stmts(List *stmts, PjScope *scope, bool *returned);
static bool signature_polymorphic(PLpgSQL_function *func);
static void env_init(PjEnv *env, PLpgSQL_function *func);
static bool param_check(plllvm_expr_env *env, const Param *p,
						StringInfo facts);
static void param_emit(plllvm_expr_env *env, plllvm_ir *ir, const Param *p,
					   plllvm_value *out);
static PjCast *cast_get(Oid srctype, int32 srctypmod, Oid dsttype,
						Expr **tree);
static bool cast_pinned(Oid srctype, Oid dsttype);
static bool funcs_walker(Node *node, List **funcs);
static bool funcs_callback(Oid funcid, void *context);
static const char *harvest_return(PLpgSQL_function *func, PjHarvest *h);
static PLpgSQL_var *arg_var(PLpgSQL_function *func, int dno);
static void emit_return(plllvm_ir *ir, PLpgSQL_function *func, PjHarvest *h,
						PjEnv *env);
static void emit_source(plllvm_ir *ir, PjEnv *env, PjHarvest *h,
						const Expr *tree, plllvm_value *val);
static const char *field_ptr(plllvm_ir *ir, const char *base, size_t offset);

/*
 * What the function does, as far as this translator goes
 *
 * scope->reason says why a function is out of scope.  exprs are those the
 * run can reach; their planned state is read by plllvm_pj_classify().
 */
void
plllvm_pj_scope(PLpgSQL_function *func, PjScope *scope)
{
	bool		returned = false;

	memset(scope, 0, sizeof(PjScope));

	if (func->fn_is_trigger != PLPGSQL_NOT_TRIGGER ||
		func->fn_prokind != PROKIND_FUNCTION ||
		func->fn_retset || func->fn_retistuple ||
		func->out_param_varno >= 0 ||
		signature_polymorphic(func))
	{
		scope->reason = "signature";
		return;
	}

	if (!func->fn_retbyval)
	{
		scope->reason = psprintf("datum:%s", format_type_be(func->fn_rettype));
		return;
	}

	for (int i = 0; i < func->fn_nargs; i++)
	{
		PLpgSQL_datum *datum = func->datums[func->fn_argvarnos[i]];

		if (datum->dtype != PLPGSQL_DTYPE_VAR)
		{
			scope->reason = "datum:record";
			return;
		}
		if (!((PLpgSQL_var *) datum)->datatype->typbyval)
		{
			scope->reason = psprintf("datum:%s",
									 ((PLpgSQL_var *) datum)->datatype->typname);
			return;
		}
	}

	scope->reason = walk_stmts(list_make1(func->action), scope, &returned);
}

static const char *
walk_stmts(List *stmts, PjScope *scope, bool *returned)
{
	foreach_ptr(PLpgSQL_stmt, stmt, stmts)
	{
		if (*returned)
			break;

		switch (stmt->cmd_type)
		{
			case PLPGSQL_STMT_BLOCK:
				{
					PLpgSQL_stmt_block *block = (PLpgSQL_stmt_block *) stmt;
					const char *reason;

					if (block->exceptions != NULL)
						return "exception block";
					if (block->n_initvars > 0)
						return "declare";
					reason = walk_stmts(block->body, scope, returned);
					if (reason != NULL)
						return reason;
					break;
				}
			case PLPGSQL_STMT_RETURN:
				{
					PLpgSQL_stmt_return *ret = (PLpgSQL_stmt_return *) stmt;

					scope->ret = ret;
					if (ret->expr != NULL)
					{
						PjExpr	   *pe = palloc0_object(PjExpr);

						pe->expr = ret->expr;
						scope->exprs = lappend(scope->exprs, pe);
					}
					*returned = true;
					break;
				}
			default:
				return psprintf("statement:%s", plllvm_pj_stmt_typename(stmt));
		}
	}

	return NULL;
}

/*
 * Is a type of the signature polymorphic?  plpgsql_compile() keeps one
 * struct per signature, so the actual types of a call would be fixed
 */
static bool
signature_polymorphic(PLpgSQL_function *func)
{
	Oid		   *argtypes;
	int			nargs;
	Oid			rettype = get_func_signature(func->fn_oid, &argtypes, &nargs);

	if (IsPolymorphicType(rettype))
		return true;
	for (int i = 0; i < nargs; i++)
	{
		if (IsPolymorphicType(argtypes[i]))
			return true;
	}
	return false;
}

/*
 * An expression whose cached plan is stale counts as not planned: no tree is
 * read, and the interpreter replans it at its next evaluation.
 */
void
plllvm_pj_classify(PjScope *scope)
{
	foreach_ptr(PjExpr, pe, scope->exprs)
	{
		PLpgSQL_expr *expr = pe->expr;

		if (expr->plan == NULL)
			pe->h1 = PJ_H1_UNPLANNED;
		else if (expr->expr_simple_expr == NULL)
			pe->h1 = PJ_H1_NOT_SIMPLE;
		else if (expr->expr_simple_plan == NULL ||
				 !CachedPlanIsSimplyValid(expr->expr_simple_plansource,
										  expr->expr_simple_plan, NULL))
			pe->h1 = PJ_H1_UNPLANNED;
		else
			pe->h1 = PJ_H1_READY;

		switch (pe->h1)
		{
			case PJ_H1_READY:
				scope->nready++;
				break;
			case PJ_H1_UNPLANNED:
				scope->nunplanned++;
				break;
			case PJ_H1_NOT_SIMPLE:
				scope->nnotsimple++;
				break;
		}
	}
}

/*
 * Copy what the code depends on into h, and decide how the value of the
 * RETURN is computed.  Returns the reason to decline the function, or NULL.
 * The caller is in a temporary context; h->cxt takes the copies.
 */
const char *
plllvm_pj_harvest(PLpgSQL_function *func, const PjScope *scope, PjHarvest *h)
{
	MemoryContext oldcxt;
	const char *reason;
	List	   *funcs = NIL;

	h->ret = scope->ret;
	if (scope->ret != NULL)
	{
		h->pos[PJ_POS_RETURN].lineno = scope->ret->lineno;
		h->pos[PJ_POS_RETURN].stmt = plllvm_pj_stmt_typename(scope->ret);
	}
	h->pos[PJ_POS_CAST].text =
		gettext_noop("while casting return value to function's return type");

	foreach_ptr(PjExpr, pe, scope->exprs)
	{
		PjExpr	   *copy = MemoryContextAlloc(h->cxt, sizeof(PjExpr));

		*copy = *pe;
		if (pe->h1 == PJ_H1_READY)
		{
			PLpgSQL_expr *expr = pe->expr;

			oldcxt = MemoryContextSwitchTo(h->cxt);
			copy->tree = copyObject(expr->expr_simple_expr);
			MemoryContextSwitchTo(oldcxt);
			copy->type = expr->expr_simple_type;
			copy->typmod = expr->expr_simple_typmod;
			copy->mutable = expr->expr_simple_mutable;
			copy->plansource = expr->expr_simple_plansource;
			copy->plan = expr->expr_simple_plan;
			copy->generation = expr->expr_simple_plan->generation;
		}
		else
			h->nunplanned++;
		oldcxt = MemoryContextSwitchTo(h->cxt);
		h->exprs = lappend(h->exprs, copy);
		MemoryContextSwitchTo(oldcxt);
	}

	reason = harvest_return(func, h);

	foreach_ptr(PjExpr, pe, h->exprs)
	{
		if (pe->h1 == PJ_H1_READY)
			funcs_walker((Node *) pe->tree, &funcs);
	}
	if (h->cast_tree != NULL)
		funcs_walker((Node *) h->cast_tree, &funcs);
	oldcxt = MemoryContextSwitchTo(h->cxt);
	h->funcids = list_copy(funcs);
	MemoryContextSwitchTo(oldcxt);
	return reason;
}

static const char *
harvest_return(PLpgSQL_function *func, PjHarvest *h)
{
	PLpgSQL_stmt_return *ret = h->ret;
	PjExpr	   *pe = NULL;
	Expr	   *tree = NULL;
	bool		null_const = false;
	bool		move = false;
	MemoryContext oldcxt;
	PjEnv		env;
	plllvm_repr repr;
	int32		srctypmod = -1;

	if (ret == NULL)
		return NULL;

	h->srctype = InvalidOid;
	env_init(&env, func);

	if (ret->retvarno >= 0)
	{
		PLpgSQL_var *var = arg_var(func, ret->retvarno);

		if (var == NULL)
			return "datum:record";
		h->path = PJ_PATH_MOVE;
		h->srctype = var->datatype->typoid;
	}
	else if (ret->expr != NULL)
	{
		StringInfoData key;
		StringInfoData facts;
		const char *why = NULL;

		pe = linitial(h->exprs);
		if (pe->h1 != PJ_H1_READY)
			return NULL;

		tree = pe->tree;
		h->srctype = pe->type;
		srctypmod = pe->typmod;

		if (IsA(tree, Param))
		{
			Param	   *p = (Param *) tree;
			PLpgSQL_var *var = p->paramkind == PARAM_EXTERN ?
				arg_var(func, p->paramid - 1) : NULL;

			move = var != NULL && var->datatype->typoid == p->paramtype;
		}
		else if (IsA(tree, Const))
		{
			Const	   *c = (Const *) tree;

			/* a cast, if there is one, is what declines it */
			move = true;
			null_const = c->constisnull;
		}

		if (move)
			h->path = PJ_PATH_MOVE;
		else
		{
			initStringInfo(&key);
			initStringInfo(&facts);
			if (!plllvm_expr_check(tree, &env.base, &key, &facts, &why))
			{
				if (contain_volatile_functions((Node *) tree))
					return "volatile callee";
				return "node";
			}
			h->path = PJ_PATH_NATIVE;
		}
	}
	else
		return NULL;

	/* decided against the type of the value as exec_cast_value() is */
	if (h->srctype == func->fn_rettype ||
		(null_const && !func->fn_retisdomain))
		return NULL;

	/* domain targets are out of scope */
	if (func->fn_retisdomain)
		return "cast";

	if (!plllvm_expr_type_repr(h->srctype, &repr) ||
		!cast_pinned(h->srctype, func->fn_rettype))
		return "cast";
	/* for the tests: a value of another representation than the placeholder's */
	if (plllvm_debug_inject == PLLLVM_INJECT_PJ_BAD_CAST_REPR)
		repr = repr == PLLLVM_F64 ? PLLLVM_I64 : PLLLVM_F64;

	{
		Expr	   *cast_tree;
		PjCast	   *cast = cast_get(h->srctype, srctypmod, func->fn_rettype,
									&cast_tree);
		StringInfoData key;
		StringInfoData facts;
		const char *why = NULL;

		/* the guard must see the cast even if the code does not */
		h->cast = cast;
		h->cast_gen = cast->gen;

		/* a mere relabeling needs no code: the value is the same Datum */
		if (cast_tree == NULL)
			return NULL;

		initStringInfo(&key);
		initStringInfo(&facts);
		if (!plllvm_expr_check_cast(cast_tree, &env.base, repr, &key, &facts,
									&why))
			return "cast";

		oldcxt = MemoryContextSwitchTo(h->cxt);
		h->cast_tree = copyObject(cast_tree);
		MemoryContextSwitchTo(oldcxt);
	}

	return NULL;
}

/*
 * The variable of a datum, if its Datum is one we can read: a variable of a
 * type passed by value
 */
static PLpgSQL_var *
arg_var(PLpgSQL_function *func, int dno)
{
	PLpgSQL_var *var;

	if (dno < 0 || dno >= func->ndatums)
		return NULL;
	var = (PLpgSQL_var *) func->datums[dno];
	if (var->dtype != PLPGSQL_DTYPE_VAR || !var->datatype->typbyval)
		return NULL;
	return var;
}

static void
env_init(PjEnv *env, PLpgSQL_function *func)
{
	env->base.param_check = param_check;
	env->base.param_emit = param_emit;
	env->base.arg = env;
	env->func = func;
}

/*
 * A Param is compilable when the interpreter would read one of our slots:
 * a variable of the type of the Param, passed by value
 */
static bool
param_check(plllvm_expr_env *base, const Param *p, StringInfo facts)
{
	PjEnv	   *env = (PjEnv *) base->arg;
	PLpgSQL_var *var;

	if (p->paramkind != PARAM_EXTERN)
		return false;
	var = arg_var(env->func, p->paramid - 1);
	if (var == NULL || var->datatype->typoid != p->paramtype)
		return false;
	appendStringInfo(facts, "%d:%u ", p->paramid, p->paramtype);
	return true;
}

static void
param_emit(plllvm_expr_env *base, plllvm_ir *ir, const Param *p,
		   plllvm_value *out)
{
	const char *value = plllvm_ir_tmp(ir);
	const char *isnull = plllvm_ir_tmp(ir);
	const char *v = value;

	plllvm_ir_emit(ir, "%s = load i64, ptr %%v%d", value, p->paramid - 1);
	plllvm_ir_emit(ir, "%s = load i1, ptr %%n%d", isnull, p->paramid - 1);

	switch (p->paramtype)
	{
		case BOOLOID:
			out->repr = PLLLVM_I1;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = icmp ne i64 %s, 0", v, value);
			break;
		case INT4OID:
			out->repr = PLLLVM_I32;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = trunc i64 %s to i32", v, value);
			break;
		case INT8OID:
			out->repr = PLLLVM_I64;
			break;
		case FLOAT8OID:
			out->repr = PLLLVM_F64;
			v = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = bitcast i64 %s to double", v, value);
			break;
		default:
			elog(ERROR, "unexpected type of Param: %u", p->paramtype);
	}

	out->v = v;
	out->isnull = isnull;
	out->type = p->paramtype;
}

/*
 * Is there a pg_cast row for the pair that cannot be created or dropped?  A
 * cast made later than PL/pgSQL cached its own could differ from it, and
 * that cache cannot be read.
 */
static bool
cast_pinned(Oid srctype, Oid dsttype)
{
	HeapTuple	tup = SearchSysCache2(CASTSOURCETARGET,
									  ObjectIdGetDatum(srctype),
									  ObjectIdGetDatum(dsttype));
	bool		pinned = false;

	if (HeapTupleIsValid(tup))
	{
		pinned = ((Form_pg_cast) GETSTRUCT(tup))->oid < FirstUnpinnedObjectId;
		ReleaseSysCache(tup);
	}
	return pinned;
}

/*
 * The cast tree for (srctype, srctypmod) -> dsttype, built as
 * get_cast_hashentry() does (pl_exec.c) and rebuilt only when invalidated.
 * *tree is NULL for a relabeling.  May raise an ERROR, as the interpreter
 * would at the cast.
 */
static PjCast *
cast_get(Oid srctype, int32 srctypmod, Oid dsttype, Expr **tree)
{
	PjCastKey	key = {srctype, srctypmod, dsttype};
	PjCastEntry *entry;
	bool		found;

	if (casts == NULL)
	{
		HASHCTL		ctl = {0};

		ctl.keysize = sizeof(PjCastKey);
		ctl.entrysize = sizeof(PjCastEntry);
		ctl.hcxt = AllocSetContextCreate(TopMemoryContext,
										 "plllvm - pj casts context",
										 ALLOCSET_DEFAULT_SIZES);
		casts = hash_create("plllvm plpgsql_jit casts", 16, &ctl,
							HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	entry = hash_search(casts, &key, HASH_ENTER, &found);
	if (!found)
		memset(&entry->cast, 0, sizeof(PjCast));

	if (entry->cast.cexpr == NULL || !entry->cast.cexpr->is_valid)
	{
		Node	   *cast_expr;
		CaseTestExpr *placeholder = makeNode(CaseTestExpr);

		placeholder->typeId = srctype;
		placeholder->typeMod = srctypmod;
		placeholder->collation = get_typcollation(srctype);

		if (srctype == UNKNOWNOID || srctype == RECORDOID)
			cast_expr = NULL;
		else
			cast_expr = coerce_to_target_type(NULL, (Node *) placeholder,
											  srctype, dsttype, -1,
											  COERCION_PLPGSQL,
											  COERCE_IMPLICIT_CAST, -1);

		/* the interpreter's fallback, which also takes UNKNOWN literals */
		if (cast_expr == NULL)
		{
			CoerceViaIO *iocoerce = makeNode(CoerceViaIO);

			if (srctype == INTERNALOID || dsttype == INTERNALOID)
				ereport(ERROR,
						(errcode(ERRCODE_CANNOT_COERCE),
						 errmsg("cannot cast type %s to %s",
								format_type_be(srctype),
								format_type_be(dsttype))));
			iocoerce->arg = (Expr *) placeholder;
			iocoerce->resulttype = dsttype;
			iocoerce->resultcollid = InvalidOid;
			iocoerce->coerceformat = COERCE_IMPLICIT_CAST;
			iocoerce->location = -1;
			cast_expr = (Node *) iocoerce;
		}

		/* only now: the old one stays if building raised an ERROR */
		if (entry->cast.cexpr != NULL)
			FreeCachedExpression(entry->cast.cexpr);
		entry->cast.cexpr = GetCachedExpression(cast_expr);
		entry->cast.gen++;
	}

	*tree = (Expr *) entry->cast.cexpr->expr;
	if (IsA(*tree, RelabelType) &&
		IsA(((RelabelType *) *tree)->arg, CaseTestExpr))
		*tree = NULL;

	return &entry->cast;
}

static bool
funcs_callback(Oid funcid, void *context)
{
	*(List **) context = list_append_unique_oid(*(List **) context, funcid);
	return false;
}

static bool
funcs_walker(Node *node, List **funcs)
{
	if (node == NULL)
		return false;
	if (check_functions_in_node(node, funcs_callback, funcs))
		return true;
	return expression_tree_walker(node, funcs_walker, funcs);
}

/*
 * Emit the code of a variant for the harvest, and compile it
 *
 * Returns false when plllvm.max_resident_compiles is reached; any other
 * failure raises an ERROR.
 */
bool
plllvm_pj_emit(PLpgSQL_function *func, PjHarvest *h, PjVariant *v)
{
	MemoryContext cxt;
	MemoryContext oldcxt;
	plllvm_ir  *ir;
	PjEnv		env;
	const char *entry;
	char	   *text;
	plllvm_jit_result result;
	bool		ok;

	plllvm_jit_session_ensure();

	cxt = AllocSetContextCreate(CurrentMemoryContext,
								"plllvm - pj emit",
								ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(cxt);

	env_init(&env, func);
	ir = plllvm_ir_begin();
	plllvm_ir_declare(ir, "declare void @plllvm_cfi()");
	if (plllvm_debug_inject == PLLLVM_INJECT_PJ_BAD_SIGNATURE)
		plllvm_ir_emit(ir, "define i64 @f(ptr %%fcinfo, ptr %%ctx, ptr %%extra) {");
	else
		plllvm_ir_emit(ir, "define i64 @f(ptr %%fcinfo, ptr %%ctx) {");
	entry = plllvm_ir_label(ir);
	plllvm_ir_block(ir, entry);

	for (int dno = 0; dno < func->ndatums; dno++)
	{
		if (arg_var(func, dno) == NULL)
			continue;
		plllvm_ir_emit(ir, "%%v%d = alloca i64", dno);
		plllvm_ir_emit(ir, "%%n%d = alloca i1", dno);
	}

	for (int dno = 0; dno < func->ndatums; dno++)
	{
		if (arg_var(func, dno) == NULL)
			continue;
		/* FOUND is false, other variables NULL, arguments are stored below */
		plllvm_ir_emit(ir, "store i64 0, ptr %%v%d", dno);
		plllvm_ir_emit(ir, "store i1 %s, ptr %%n%d",
					   dno == func->found_varno ? "false" : "true", dno);

		for (int i = 0; i < func->fn_nargs; i++)
		{
			const char *slot;
			const char *value;

			if (func->fn_argvarnos[i] != dno)
				continue;

			slot = field_ptr(ir, "%fcinfo",
							 offsetof(FunctionCallInfoBaseData, args) +
							 i * sizeof(NullableDatum) +
							 offsetof(NullableDatum, value));
			value = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = load i64, ptr %s", value, slot);
			plllvm_ir_emit(ir, "store i64 %s, ptr %%v%d", value, dno);
			/* the handler dispatched NULL arguments to the interpreter */
			plllvm_ir_emit(ir, "store i1 false, ptr %%n%d", dno);
		}
	}

	plllvm_ir_emit(ir, "call void @plllvm_cfi()");

	if (h->ret == NULL)
	{
		plllvm_ir_declare(ir, "declare void @plllvm_pj_no_return()");
		plllvm_ir_emit(ir, "call void @plllvm_pj_no_return()");
		plllvm_ir_emit(ir, "unreachable");
	}
	else
		emit_return(ir, func, h, &env);

	plllvm_ir_emit(ir, "}");
	text = plllvm_ir_end(ir);

	ok = plllvm_jit_compile_pj(text, v->opt_level, &result);

	MemoryContextSwitchTo(h->cxt);
	v->ir = pstrdup(text);
	MemoryContextSwitchTo(oldcxt);

	if (!ok)
	{
		if (result.capped)
		{
			MemoryContextDelete(cxt);
			return false;
		}
		ereport(ERROR,
				(errcode(result.sqlerrcode),
				 errmsg_internal("%s", result.errmsg)));
	}

	MemoryContextDelete(cxt);

	v->mod = result.mod;
	v->code = (PjCode) result.mod->addr;
	v->native = true;
	v->boxed = false;
	v->restartable = true;
	return true;
}

static void
emit_return(plllvm_ir *ir, PLpgSQL_function *func, PjHarvest *h, PjEnv *env)
{
	PLpgSQL_stmt_return *ret = h->ret;
	const char *datum = "0";
	const char *isnull = "false";
	plllvm_value val;
	const Expr *tree = NULL;

	plllvm_ir_emit(ir, "store i32 %d, ptr %%ctx", PJ_POS_RETURN);

	if (ret->retvarno >= 0)
	{
		Param	   *p = makeNode(Param);
		PLpgSQL_var *var = (PLpgSQL_var *) func->datums[ret->retvarno];

		p->paramkind = PARAM_EXTERN;
		p->paramid = ret->retvarno + 1;
		p->paramtype = var->datatype->typoid;
		p->paramtypmod = -1;
		tree = (Expr *) p;
	}
	else if (ret->expr != NULL)
	{
		PjExpr	   *pe = linitial(h->exprs);

		if (pe->h1 != PJ_H1_READY)
		{
			const char *at = field_ptr(ir, "%ctx", offsetof(PjCtx, deopt));

			plllvm_ir_emit(ir, "store i32 1, ptr %s", at);
			plllvm_ir_emit(ir, "ret i64 0");
			return;
		}
		tree = pe->tree;
	}
	else if (func->fn_rettype == VOIDOID)
	{
		/* a non-null VOID, not NULL (exec_stmt_return) */
		datum = "0";
	}
	else
		isnull = "true";

	if (tree != NULL)
	{
		if (h->cast_tree == NULL && h->path == PJ_PATH_MOVE)
		{
			/* the Datum as it is, of any type passed by value */
			if (IsA(tree, Const))
			{
				const Const *c = (const Const *) tree;

				datum = psprintf(INT64_FORMAT, (int64) c->constvalue);
				isnull = c->constisnull ? "true" : "false";
			}
			else
			{
				int			dno = ((const Param *) tree)->paramid - 1;
				const char *d = plllvm_ir_tmp(ir);
				const char *n = plllvm_ir_tmp(ir);

				plllvm_ir_emit(ir, "%s = load i64, ptr %%v%d", d, dno);
				plllvm_ir_emit(ir, "%s = load i1, ptr %%n%d", n, dno);
				datum = d;
				isnull = n;
			}
		}
		else
		{
			emit_source(ir, env, h, tree, &val);
			datum = plllvm_expr_box(ir, &val);
			isnull = val.isnull;
		}
	}

	{
		const char *at = field_ptr(ir, "%fcinfo",
								   offsetof(FunctionCallInfoBaseData, isnull));
		const char *z = plllvm_ir_tmp(ir);

		plllvm_ir_emit(ir, "%s = zext i1 %s to i8", z, isnull);
		plllvm_ir_emit(ir, "store i8 %s, ptr %s", z, at);
	}
	plllvm_ir_emit(ir, "ret i64 %s", datum);
}

static void
emit_source(plllvm_ir *ir, PjEnv *env, PjHarvest *h, const Expr *tree,
			plllvm_value *val)
{
	plllvm_expr_emit(ir, tree, &env->base, val);

	if (h->cast_tree != NULL)
	{
		plllvm_value src = *val;

		plllvm_ir_emit(ir, "store i32 %d, ptr %%ctx", PJ_POS_CAST);
		plllvm_expr_emit_cast(ir, h->cast_tree, &env->base, &src, val);
	}
}

static const char *
field_ptr(plllvm_ir *ir, const char *base, size_t offset)
{
	const char *addr = plllvm_ir_tmp(ir);

	plllvm_ir_emit(ir, "%s = getelementptr inbounds i8, ptr %s, i64 %zu",
				   addr, base, offset);
	return addr;
}
