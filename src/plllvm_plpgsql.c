/*-------------------------------------------------------------------------
 *
 * plllvm_plpgsql.c
 *
 *			  the PL/pgSQL plugin: trampolines on the simple expressions
 *			  of PL/pgSQL functions (plllvm.expr_jit)
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The plugin takes the PLpgSQL_plugin slot when the library is loaded
 *    and chains the previous occupant: its callbacks are forwarded, and
 *    PL/pgSQL's helper pointers, which PL/pgSQL writes into the slot
 *    owner's struct only (plpgsql_estate_setup), are copied into it.  A
 *    plugin loaded later that overwrites the slot without chaining removes
 *    us without notice; plllvm_expr_stats() then shows not_in_slot.
 *
 * 2) func_setup replaces paramLI->paramCompile with a wrapper, which runs
 *    inside ExecInitExprWithParams().  On the ExprState of a simple
 *    expression, built once per transaction, the wrapper puts a trampoline
 *    on the first PARAM_CALLBACK step.  The ExprState does not exist yet
 *    when func_setup runs, and ExecReadyExpr() sets evalfunc after the
 *    wrapper, so the step is the first place where its evaluations can be
 *    seen.
 *
 * 3) The trampoline re-arms itself at the first evaluation and fires at the
 *    second, after restoring the original paramfunc.  By then
 *    ExecInterpExprStillValid() has set evalfunc to evalfunc_private, so
 *    evalfunc may be replaced.  An ExprState evaluated once per
 *    transaction pays for nothing more.  plllvm.expr_eager fires at the
 *    first evaluation, which is safe for the same reason.
 *
 * 4) A fired trampoline hands the ExprState to plllvm_exprjit.c, with
 *    param_check() and param_emit() for its Params.  The compiled code
 *    reads a variable as plpgsql_param_eval_var() does, from the estate
 *    that is running the expression: an ExprState may serve several
 *    estates of one function.  The offsets are those of this library's
 *    own compile of plpgsql.h.
 *
 */
#include "postgres.h"

#include "access/parallel.h"
#include "catalog/pg_type.h"
#include "executor/execExpr.h"
#include "fmgr.h"
#include "plpgsql.h"

#include "plllvm.h"
#include "plllvm_expr.h"
#include "plllvm_ir.h"

/* plpgsql_param_compile chooses one of six paramfuncs */
#define MAX_PARAMFUNCS	6

int64		plllvm_expr_fired = 0;
int64		plllvm_expr_declined = 0;

static PLpgSQL_plugin **plugin_ptr = NULL;
static PLpgSQL_plugin *prev_plugin = NULL;

/* the slot owner at the last func_setup that reached us */
static PLpgSQL_plugin *seen_owner = NULL;

/* plpgsql_param_compile and plpgsql_param_eval_var, both static */
static ParamCompileHook orig_compile = NULL;
static ExecEvalSubroutine eval_var = NULL;
static bool paramfunc_conflict = false; /* true, when a second paramfunc was
										 * seen for eval_var */

static ExecEvalSubroutine orig_paramfunc[MAX_PARAMFUNCS];
static int	norig = 0;

static void plugin_func_setup(PLpgSQL_execstate *estate,
							  PLpgSQL_function *func);
static void param_compile(ParamListInfo params, Param *param,
						  ExprState *state, Datum *resv, bool *resnull);
static void fire(ExprState *state, ExprContext *econtext);
static bool param_check(plllvm_expr_env *env, const Param *p,
						StringInfo facts);
static void param_emit(plllvm_expr_env *env, plllvm_ir *ir, const Param *p,
					   plllvm_value *out);
static const char *field_load(plllvm_ir *ir, const char *type,
							  const char *base, size_t offset);

/* writable: PL/pgSQL stores its helper pointers in it */
static PLpgSQL_plugin plugin = {plugin_func_setup};

/*
 * Trampolines, one pair per original paramfunc
 */
#define TRAMPOLINE(i) \
static void \
fire_##i(ExprState *state, ExprEvalStep *op, ExprContext *econtext) \
{ \
	op->d.cparam.paramfunc = orig_paramfunc[i]; \
	fire(state, econtext); \
	orig_paramfunc[i] (state, op, econtext); \
} \
static void \
arm_##i(ExprState *state, ExprEvalStep *op, ExprContext *econtext) \
{ \
	if (plllvm_expr_eager) \
		fire_##i(state, op, econtext); \
	else \
	{ \
		/* before the call: plpgsql_param_eval_var_check may rewrite it */ \
		op->d.cparam.paramfunc = fire_##i; \
		orig_paramfunc[i] (state, op, econtext); \
	} \
}

TRAMPOLINE(0)
TRAMPOLINE(1)
TRAMPOLINE(2)
TRAMPOLINE(3)
TRAMPOLINE(4)
TRAMPOLINE(5)

static const ExecEvalSubroutine trampolines[MAX_PARAMFUNCS] = {
	arm_0, arm_1, arm_2, arm_3, arm_4, arm_5
};

/*
 * Take the slot
 *
 * The forwarders are set only for callbacks the previous plugin has, as
 * PL/pgSQL skips a NULL callback.  A plugin that sets its callbacks after
 * it has been chained is not seen.
 */
#define FORWARD(name, type) \
static void \
forward_##name(PLpgSQL_execstate *estate, type *arg) \
{ \
	if (prev_plugin->name) \
		prev_plugin->name(estate, arg); \
}

FORWARD(func_beg, PLpgSQL_function)
FORWARD(func_end, PLpgSQL_function)
FORWARD(stmt_beg, PLpgSQL_stmt)
FORWARD(stmt_end, PLpgSQL_stmt)

void
plllvm_plpgsql_init(void)
{
	plugin_ptr = (PLpgSQL_plugin **) find_rendezvous_variable("PLpgSQL_plugin");
	prev_plugin = *plugin_ptr;

	if (prev_plugin != NULL)
	{
		if (prev_plugin->func_beg)
			plugin.func_beg = forward_func_beg;
		if (prev_plugin->func_end)
			plugin.func_end = forward_func_end;
		if (prev_plugin->stmt_beg)
			plugin.stmt_beg = forward_stmt_beg;
		if (prev_plugin->stmt_end)
			plugin.stmt_end = forward_stmt_end;
	}

	*plugin_ptr = &plugin;
}

/*
 * State for plllvm_expr_stats()
 *
 * A plugin loaded after us that chains is the slot owner but still calls
 * us; we know that only once a PL/pgSQL function has started.
 */
const char *
plllvm_plpgsql_state(void)
{
	PLpgSQL_plugin *owner = *plugin_ptr;

	if (owner == NULL || (owner != &plugin && owner != seen_owner))
		return "not_in_slot";
	if (paramfunc_conflict)
		return "declined:paramfunc";
	return plllvm_expr_jit ? "active" : "off";
}

static void
plugin_func_setup(PLpgSQL_execstate *estate, PLpgSQL_function *func)
{
	PLpgSQL_plugin *owner = *plugin_ptr;
	ParamListInfo params = estate->paramLI;

	seen_owner = owner;

	if (prev_plugin != NULL)
	{
		if (owner->error_callback)
			prev_plugin->error_callback = owner->error_callback;
		if (owner->assign_expr)
			prev_plugin->assign_expr = owner->assign_expr;
		if (owner->assign_value)
			prev_plugin->assign_value = owner->assign_value;
		if (owner->eval_datum)
			prev_plugin->eval_datum = owner->eval_datum;
		if (owner->cast_value)
			prev_plugin->cast_value = owner->cast_value;

		if (prev_plugin->func_setup)
			prev_plugin->func_setup(estate, func);
	}

	/* a worker gets its own ExprStates, for one query */
	if (!plllvm_expr_jit || paramfunc_conflict || IsParallelWorker())
		return;

	/* the first hook we see is PL/pgSQL's; leave any other alone */
	if (orig_compile == NULL && params->paramCompile != param_compile)
		orig_compile = params->paramCompile;
	if (params->paramCompile != NULL &&
		params->paramCompile == orig_compile)
		params->paramCompile = param_compile;
}

/*
 * paramCompile wrapper
 */
static void
param_compile(ParamListInfo params, Param *param, ExprState *state,
			  Datum *resv, bool *resnull)
{
	PLpgSQL_execstate *estate = (PLpgSQL_execstate *) params->paramFetchArg;
	PLpgSQL_expr *expr = (PLpgSQL_expr *) params->parserSetupArg;
	PLpgSQL_datum *datum;
	ExprEvalStep *step;
	ExecEvalSubroutine orig;
	int			i;

	orig_compile(params, param, state, resv, resnull);

	/*
	 * Only the ExprState of a simple expression.  Partition pruning also
	 * builds one with no parent from our paramLI, but not of this tree.  The
	 * paramLI was wrapped when the function started, so the GUC may be off by
	 * now.
	 */
	if (!plllvm_expr_jit || paramfunc_conflict ||
		state->parent != NULL || expr == NULL ||
		state->expr != expr->expr_simple_expr)
		return;

	step = &state->steps[state->steps_len - 1];
	if (step->opcode != EEOP_PARAM_CALLBACK)
		return;

	/* learn plpgsql_param_eval_var: the paramfunc of a non-varlena variable */
	datum = estate->datums[param->paramid - 1];
	if (datum->dtype == PLPGSQL_DTYPE_VAR &&
		((PLpgSQL_var *) datum)->datatype->typlen != -1)
	{
		if (eval_var == NULL)
			eval_var = step->d.cparam.paramfunc;
		else if (step->d.cparam.paramfunc != eval_var)
		{
			paramfunc_conflict = true;
			return;
		}
	}

	/* one trampoline per ExprState, on its first Param */
	for (i = 0; i < state->steps_len - 1; i++)
		if (state->steps[i].opcode == EEOP_PARAM_CALLBACK)
			return;

	orig = step->d.cparam.paramfunc;
	for (i = 0; i < norig; i++)
		if (orig_paramfunc[i] == orig)
			break;
	if (i == norig)
	{
		if (norig == MAX_PARAMFUNCS)
			return;
		orig_paramfunc[norig++] = orig;
	}
	step->d.cparam.paramfunc = trampolines[i];
}

/*
 * The trampoline of a simple expression fired
 *
 * SET plllvm.expr_jit = off stops new installs at once; code installed in
 * this transaction runs until its ExprState goes at transaction end.  The
 * paramLI is that of the estate running the expression.
 */
static void
fire(ExprState *state, ExprContext *econtext)
{
	plllvm_expr_env env;

	if (!plllvm_expr_jit || paramfunc_conflict)
		return;

	plllvm_expr_fired++;

	/* someone else replaced the evalfunc */
	if (state->evalfunc != (ExprStateEvalFunc) state->evalfunc_private)
	{
		plllvm_expr_declined++;
		return;
	}

	env.param_check = param_check;
	env.param_emit = param_emit;
	env.arg = econtext->ecxt_param_list_info->paramFetchArg;
	plllvm_exprjit_install(state, &env);
}

/*
 * A Param can be compiled if plpgsql_param_eval_var() would read it: a
 * variable of a type passed by value.  The paramfunc of a varlena variable
 * may depend on the assignment target (plpgsql_param_eval_var_check); one
 * passed by value is read the same way also when it is the target, as in
 * "i := i + 1".  The check has taken only PARAM_EXTERN Params of bool,
 * int4, int8 and float8.
 */
static bool
param_check(plllvm_expr_env *env, const Param *p, StringInfo facts)
{
	PLpgSQL_execstate *estate = (PLpgSQL_execstate *) env->arg;
	int			dno = p->paramid - 1;
	PLpgSQL_var *var;

	if (dno < 0 || dno >= estate->ndatums)
		return false;

	var = (PLpgSQL_var *) estate->datums[dno];
	if (var->dtype != PLPGSQL_DTYPE_VAR ||
		var->datatype->typoid != p->paramtype ||
		!var->datatype->typbyval)
		return false;

	appendStringInfo(facts, "%d:%u:%d:%d ", p->paramid, p->paramtype,
					 (int) var->dtype, (int) var->datatype->typlen);
	return true;
}

/*
 * Load the variable of a Param, as plpgsql_param_eval_var() does:
 * econtext->ecxt_param_list_info->paramFetchArg is the estate, and the
 * variable is its datums[paramid - 1]
 */
static void
param_emit(plllvm_expr_env *env, plllvm_ir *ir, const Param *p,
		   plllvm_value *out)
{
	const char *params;
	const char *estate;
	const char *datums;
	const char *var;
	const char *value;
	const char *isnull;
	const char *v;
	const char *n;

	StaticAssertStmt(sizeof(Datum) == 8, "Datum is not i64");
	StaticAssertStmt(sizeof(bool) == 1, "bool is not i8");

	params = field_load(ir, "ptr", "%econtext",
						offsetof(ExprContext, ecxt_param_list_info));
	estate = field_load(ir, "ptr", params,
						offsetof(ParamListInfoData, paramFetchArg));
	datums = field_load(ir, "ptr", estate,
						offsetof(PLpgSQL_execstate, datums));
	var = field_load(ir, "ptr", datums,
					 (p->paramid - 1) * sizeof(PLpgSQL_datum *));
	value = field_load(ir, "i64", var, offsetof(PLpgSQL_var, value));
	isnull = field_load(ir, "i8", var, offsetof(PLpgSQL_var, isnull));

	n = plllvm_ir_tmp(ir);
	plllvm_ir_emit(ir, "%s = icmp ne i8 %s, 0", n, isnull);

	v = value;
	switch (p->paramtype)
	{
		case BOOLOID:
			/* DatumGetBool */
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
	out->isnull = n;
	out->type = p->paramtype;
}

/*
 * The field at offset of the struct at base
 */
static const char *
field_load(plllvm_ir *ir, const char *type, const char *base, size_t offset)
{
	const char *addr = plllvm_ir_tmp(ir);
	const char *val = plllvm_ir_tmp(ir);

	plllvm_ir_emit(ir, "%s = getelementptr inbounds i8, ptr %s, i64 %zu",
				   addr, base, offset);
	plllvm_ir_emit(ir, "%s = load %s, ptr %s", val, type, addr);

	return val;
}
