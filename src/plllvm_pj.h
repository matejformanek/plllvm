/*-------------------------------------------------------------------------
 *
 * plllvm_pj.h
 *
 *			  declarations of LANGUAGE plpgsql_jit (plllvm_pj.c,
 *			  plllvm_pj_translate.c)
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_PJ_H
#define PLLLVM_PJ_H

#include "fmgr.h"
#include "nodes/pg_list.h"
#include "nodes/primnodes.h"
#include "utils/plancache.h"

struct plllvm_path;

#include "plllvm_jit.h"

struct PLpgSQL_function;
struct PLpgSQL_expr;
struct PLpgSQL_stmt_return;

/* per backend; plllvm_pj_stats() */
typedef struct plllvm_pj_counters
{
	int64		calls;
	int64		compiled_calls;
	int64		deopts;
	int64		interpreted_calls;
	int64		declines;
	int64		guard_misses;
	int64		null_args;
	int64		plugin_fallbacks;
	int64		capped;
	int64		translations;
	int64		attempts;
	int64		failures;
	int64		boxed_evals;
	int64		resident;
	int64		peak_tuple_bytes;
} plllvm_pj_counters;

/* one side entry of a function, for plllvm_pj_status() */
typedef struct plllvm_pj_info
{
	char	   *signature;
	Oid			collation;
	const char *state;
	const char *reason;			/* NULL unless declined */
	int64		calls;
	int64		compiled_calls;
	int64		deopts;
	int64		guard_misses;
	int64		translations;
	const char *last_path;		/* NULL before the first call */
	bool		has_harvest;	/* the rest is meaningful */
	int			exprs;
	int			unplanned;
	int			variants;
	bool		has_variant;	/* a variant for the session's GUCs exists */
	bool		native;
	bool		boxed;
	bool		restartable;
	double		translate_ms;
} plllvm_pj_info;

/* the per-call state compiled code shares with the handler; pos is first */
typedef struct PjCtx
{
	int32		pos;			/* index into the harvest's position table */
	int32		deopt;			/* 1 + the expression to re-run interpreted */
} PjCtx;

typedef Datum (*PjCode) (FunctionCallInfo fcinfo, PjCtx *ctx);

/* what plpgsql_exec_error_callback() reads from the estate */
typedef struct PjPos
{
	int			lineno;			/* 0: none */
	const char *stmt;			/* statement type name, or NULL */
	const char *text;			/* err_text, or NULL */
} PjPos;

/* positions of every function: none, the RETURN, the cast of its value */
#define PJ_POS_NONE		0
#define PJ_POS_RETURN	1
#define PJ_POS_CAST		2

typedef enum PjH1
{
	PJ_H1_UNPLANNED,
	PJ_H1_NOT_SIMPLE,
	PJ_H1_READY
} PjH1;

/* K3: how to cast one type to another, as PL/pgSQL's cast_expr_hash */
typedef struct PjCast
{
	CachedExpression *cexpr;
	uint64		gen;			/* changes with cexpr */
} PjCast;

typedef enum PjPath
{
	PJ_PATH_MOVE,				/* copy the Datum of a variable or constant */
	PJ_PATH_NATIVE				/* the Stage 1 compiler */
} PjPath;

typedef struct PjExpr
{
	struct PLpgSQL_expr *expr;
	PjH1		h1;
	/* READY only, copies in the harvest context */
	Expr	   *tree;
	Oid			type;
	int32		typmod;
	bool		mutable;
	CachedPlanSource *plansource;
	CachedPlan *plan;
	int			generation;
} PjExpr;

/* what the translator found in a function, once per pre-check */
typedef struct PjScope
{
	const char *reason;			/* NULL when the function is in scope */
	List	   *exprs;			/* PjExpr, in walker order */
	struct PLpgSQL_stmt_return *ret;	/* the RETURN that ends it, or NULL */
	int			nready;
	int			nunplanned;
	int			nnotsimple;
} PjScope;

typedef struct PjVariant
{
	struct PjVariant *next;
	int			opt_level;
	int			codegen;
	plllvm_jit_module *mod;
	PjCode		code;
	bool		failed;
	bool		native;
	bool		boxed;
	bool		restartable;
	double		translate_ms;
	char	   *ir;
} PjVariant;

/* one generation of a function's expressions, with the variants built on it */
typedef struct PjHarvest
{
	MemoryContext cxt;
	List	   *exprs;			/* PjExpr */
	struct PLpgSQL_stmt_return *ret;
	int			nunplanned;
	PjPath		path;			/* of the RETURN's value */
	Oid			srctype;		/* of that value; InvalidOid: no value */
	Expr	   *cast_tree;		/* K1, or NULL */
	PjCast	   *cast;
	uint64		cast_gen;
	List	   *funcids;		/* to check EXECUTE on */
	PjPos		pos[3];
	PjVariant  *variants;
} PjHarvest;

extern plllvm_pj_counters plllvm_pj_count;
extern int	plllvm_pj_infos(Oid fn, plllvm_pj_info **infos);
extern char *plllvm_pj_ir_text(Oid fn);

/* plllvm_pj_translate.c */
extern void plllvm_pj_scope(struct PLpgSQL_function *func, PjScope *scope);
extern void plllvm_pj_classify(PjScope *scope);
extern const char *plllvm_pj_harvest(struct PLpgSQL_function *func,
									 const PjScope *scope, PjHarvest *h);
extern bool plllvm_pj_emit(struct PLpgSQL_function *func, PjHarvest *h,
						   PjVariant *v);
extern const char *plllvm_pj_stmt_typename(void *stmt);

#endif							/* PLLLVM_PJ_H */
