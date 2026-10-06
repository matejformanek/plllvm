/*-------------------------------------------------------------------------
 *
 * plllvm_exprjit.c
 *
 *			  compiled PL/pgSQL expressions: cache, compile, install
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) A program is found by a hash of a cheap key (the opt level, the
 *    eager flag, the node tags, functions and types of the tree), but it is
 *    taken only when its stored copy of the tree is equal() to the
 *    ExprState's and the Param facts match.  Two trees with the same key,
 *    e.g. "x + 1" and "x + 2", get two programs.  equal() runs once per
 *    ExprState and transaction, on at most PLLLVM_EXPR_MAX_NODES nodes.
 *
 * 2) Programs are never freed.  The only pointer to one is the evalfunc of
 *    a simple-expression ExprState, which PL/pgSQL builds anew in every
 *    transaction; so there is no point at which a program could be known
 *    to be unused.  plllvm.expr_max_programs bounds the memory: at the cap
 *    a new expression stays interpreted.  A build that failed is kept as
 *    a program without code, so that it is not tried again; it counts
 *    toward the cap.
 *
 * 3) Under plllvm.expr_eager the program also counts its evaluations
 *    (compiled_evals of plllvm_expr_stats()), so that the tests can see
 *    that compiled code ran.  The eager flag is in the key.
 *
 */
#include "postgres.h"

#include "common/hashfn.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "nodes/execnodes.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

#include "plllvm.h"
#include "plllvm_expr.h"
#include "plllvm_ir.h"
#include "plllvm_jit.h"

/* one compiled tree */
typedef struct ExprProgram
{
	char	   *key;
	Expr	   *tree;			/* copy of the planned tree */
	char	   *facts;
	ExprStateEvalFunc addr;		/* NULL, when the build failed */
	struct ExprProgram *next;
} ExprProgram;

/* the programs of one hash value */
typedef struct ExprBucket
{
	uint32		hash;			/* hash key */
	ExprProgram *programs;
} ExprBucket;

int64		plllvm_expr_compiled = 0;
int64		plllvm_expr_hits = 0;
int64		plllvm_expr_failures = 0;
int64		plllvm_expr_capped = 0;
int64		plllvm_expr_programs = 0;
int64		plllvm_expr_compiled_evals = 0;

static MemoryContext expr_cxt = NULL;
static HTAB *programs = NULL;

static ExprStateEvalFunc program_build(const Expr *expr, plllvm_expr_env *env);
static const char *datum_box(plllvm_ir *ir, const plllvm_value *val);

/*
 * Give a simple-expression ExprState compiled code, if it can have it
 *
 * Called at its second evaluation (or the first, under plllvm.expr_eager),
 * with evalfunc still the interpreter's.  Anything that cannot be compiled
 * stays interpreted; only the LLVM session setup may raise an ERROR.
 */
void
plllvm_exprjit_install(ExprState *state, plllvm_expr_env *env)
{
	StringInfoData key;
	StringInfoData facts;
	const char *why = NULL;
	uint32		hash;
	ExprBucket *bucket;
	bool		found;
	ExprProgram *prog;
	ExprStateEvalFunc addr;
	MemoryContext oldcxt;

	/* the check and the emitter recurse over the tree */
	if (stack_is_too_deep())
	{
		plllvm_expr_declined++;
		return;
	}

	initStringInfo(&key);
	initStringInfo(&facts);
	appendStringInfo(&key, "O%d%s ", plllvm_expr_opt_level,
					 plllvm_expr_eager ? "e" : "");

	if (!plllvm_expr_check(state->expr, env, &key, &facts, &why))
	{
		plllvm_expr_declined++;
		ereport(DEBUG1,
				(errmsg_internal("plllvm: expression not compiled: %s",
								 why ? why : "unknown"),
				 errhidestmt(true)));
		return;
	}

	if (programs == NULL)
	{
		HASHCTL		ctl;

		expr_cxt = AllocSetContextCreate(TopMemoryContext,
										 "plllvm - expression context",
										 ALLOCSET_DEFAULT_SIZES);
		memset(&ctl, 0, sizeof(ctl));
		ctl.keysize = sizeof(uint32);
		ctl.entrysize = sizeof(ExprBucket);
		ctl.hcxt = expr_cxt;
		programs = hash_create("plllvm expression programs", 256, &ctl,
							   HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	hash = hash_bytes((const unsigned char *) key.data, key.len);
	bucket = hash_search(programs, &hash, HASH_FIND, NULL);
	for (prog = bucket ? bucket->programs : NULL; prog; prog = prog->next)
	{
		if (strcmp(prog->key, key.data) == 0 &&
			strcmp(prog->facts, facts.data) == 0 &&
			equal(prog->tree, state->expr))
			break;
	}

	if (prog != NULL)
	{
		if (prog->addr == NULL)
			plllvm_expr_declined++;
		else
		{
			state->evalfunc = prog->addr;
			plllvm_expr_hits++;
		}
		return;
	}

	if (plllvm_expr_programs >= plllvm_expr_max_programs)
	{
		plllvm_expr_capped++;
		return;
	}

	addr = program_build(state->expr, env);

	/* not before: a build that raised an ERROR leaves no program */
	oldcxt = MemoryContextSwitchTo(expr_cxt);
	prog = palloc_object(ExprProgram);
	prog->key = pstrdup(key.data);
	prog->tree = copyObject(state->expr);
	prog->facts = pstrdup(facts.data);
	prog->addr = addr;
	MemoryContextSwitchTo(oldcxt);

	bucket = hash_search(programs, &hash, HASH_ENTER, &found);
	if (!found)
		bucket->programs = NULL;
	prog->next = bucket->programs;
	bucket->programs = prog;
	plllvm_expr_programs++;

	if (addr == NULL)
		plllvm_expr_failures++;
	else
	{
		state->evalfunc = addr;
		plllvm_expr_compiled++;
	}
}

/*
 * Compile the tree as an ExprStateEvalFunc; NULL if the build failed
 *
 * The Params are read through %econtext (env->param_emit).
 */
static ExprStateEvalFunc
program_build(const Expr *expr, plllvm_expr_env *env)
{
	MemoryContext cxt;
	MemoryContext oldcxt;
	plllvm_ir  *ir;
	plllvm_value val;
	const char *datum;
	const char *isnull;
	plllvm_jit_result result;
	ExprStateEvalFunc addr = NULL;

	/* the IR text and LLVM's messages; the code lives in plllvm_jit.c */
	cxt = AllocSetContextCreate(CurrentMemoryContext,
								"plllvm - expression compile",
								ALLOCSET_DEFAULT_SIZES);
	oldcxt = MemoryContextSwitchTo(cxt);

	ir = plllvm_ir_begin();
	plllvm_ir_emit(ir, "define i64 @f(ptr %%state, ptr %%econtext, ptr %%isnull) {");
	plllvm_ir_block(ir, plllvm_ir_label(ir));

	plllvm_expr_emit(ir, expr, env, &val);
	datum = datum_box(ir, &val);

	if (plllvm_expr_eager)
	{
		const char *counter = plllvm_ir_tmp(ir);
		const char *old = plllvm_ir_tmp(ir);
		const char *sum = plllvm_ir_tmp(ir);

		plllvm_ir_emit(ir, "%s = inttoptr i64 %llu to ptr", counter,
					   (unsigned long long) (uintptr_t) &plllvm_expr_compiled_evals);
		plllvm_ir_emit(ir, "%s = load i64, ptr %s", old, counter);
		plllvm_ir_emit(ir, "%s = add i64 %s, 1", sum, old);
		plllvm_ir_emit(ir, "store i64 %s, ptr %s", sum, counter);
	}

	isnull = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = zext i1 %s to i8", isnull, val.isnull);
	plllvm_ir_emit(ir, "store i8 %s, ptr %%isnull", isnull);
	plllvm_ir_emit(ir, "ret i64 %s", datum);
	plllvm_ir_emit(ir, "}");

	if (plllvm_jit_compile_expr(plllvm_ir_end(ir), plllvm_expr_opt_level,
								&result))
		addr = (ExprStateEvalFunc) result.mod->addr;
	else
		ereport(DEBUG1,
				(errmsg_internal("plllvm: expression not compiled: %s",
								 result.errmsg),
				 errhidestmt(true)));

	MemoryContextSwitchTo(oldcxt);
	MemoryContextDelete(cxt);

	return addr;
}

/*
 * The value as a Datum, 0 when it is NULL
 */
static const char *
datum_box(plllvm_ir *ir, const plllvm_value *val)
{
	const char *datum;
	const char *result = plllvm_ir_tmp(ir);

	switch (val->repr)
	{
		case PLLLVM_I1:
			datum = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = zext i1 %s to i64", datum, val->v);
			break;
		case PLLLVM_I32:
			/* Int32GetDatum sign extends */
			datum = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = sext i32 %s to i64", datum, val->v);
			break;
		case PLLLVM_I64:
			datum = val->v;
			break;
		case PLLLVM_F64:
			datum = plllvm_ir_tmp(ir);
			plllvm_ir_emit(ir, "%s = bitcast double %s to i64", datum, val->v);
			break;
		default:
			elog(ERROR, "unrecognized plllvm_repr: %d", (int) val->repr);
			datum = NULL;		/* keep compiler quiet */
	}

	plllvm_ir_emit(ir, "%s = select i1 %s, i64 0, i64 %s", result, val->isnull,
				   datum);

	return result;
}
