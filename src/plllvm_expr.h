/*-------------------------------------------------------------------------
 *
 * plllvm_expr.h
 *
 *			  planned expression trees to LLVM IR
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) plllvm_expr_check() says whether the whole tree can be compiled, and
 *    plllvm_expr_emit() emits it into the current block of the caller's
 *    function.  The caller supplies the Params through the env callbacks,
 *    and turns the value into a Datum.
 *
 * 2) The emitted code evaluates as the interpreter does: the arguments
 *    first, left to right, then the strict NULL test (execExpr.c:2752-2801).
 *    So "x + y / z" with x NULL and z = 0 raises the division error.
 *
 * 3) A Datum of an int4 is sign extended (Int32GetDatum), a bool Datum is
 *    true when it is nonzero (DatumGetBool).
 *
 * 4) Every field the emitter reads is covered by the key, by equal() or by
 *    the facts param_check adds (opfuncid is in the key, as equal() ignores
 *    it when it is 0), so a program may be reused for any tree with its key
 *    that is equal() to its own and has the same facts.
 *
 */
#ifndef PLLLVM_EXPR_H
#define PLLLVM_EXPR_H

#include "lib/stringinfo.h"
#include "nodes/primnodes.h"

#include "plllvm_ir.h"

typedef enum plllvm_repr
{
	PLLLVM_I1,
	PLLLVM_I32,
	PLLLVM_I64,
	PLLLVM_F64,
} plllvm_repr;

typedef struct plllvm_value
{
	const char *v;				/* SSA name or constant, IR type of repr */
	const char *isnull;			/* i1 SSA name, or "false" / "true" */
	plllvm_repr repr;			/* IR type of v */
	Oid			type;			/* SQL type */
} plllvm_value;

typedef struct plllvm_expr_env plllvm_expr_env;

struct plllvm_expr_env
{
	/* may this Param be compiled; append what the code depends on to facts */
	bool		(*param_check) (plllvm_expr_env *env, const Param *p, StringInfo facts);
	void		(*param_emit) (plllvm_expr_env *env, plllvm_ir *ir, const Param *p, plllvm_value *out);
	void	   *arg;			/* caller's state */
};

/* the largest tree compiled, in nodes */
#define PLLLVM_EXPR_MAX_NODES	64

extern bool plllvm_expr_check(const Expr *e, plllvm_expr_env *env, StringInfo hash_key,
							  StringInfo facts, const char **why);
extern void plllvm_expr_emit(plllvm_ir *ir, const Expr *e, plllvm_expr_env *env, plllvm_value *out);
extern const char *plllvm_repr_type(plllvm_repr repr);

#endif							/* PLLLVM_EXPR_H */
