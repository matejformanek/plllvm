/*-------------------------------------------------------------------------
 *
 * plllvm_pj_sql.c
 *
 *			  plpgsql_jit: the SQL statements of a function, run by SPI on
 *			  the plans of PL/pgSQL
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) PL/pgSQL's statement runners are static, and the plugin hooks only
 *    observe, so compiled code cannot hand a statement to the interpreter.
 *    It runs the statement as exec_stmt_execsql() and exec_stmt_perform() do,
 *    by SPI_execute_plan_with_paramlist() on expr->plan, the plan the
 *    interpreter prepared.  We never prepare and never write a PLpgSQL_expr:
 *    both runs use one CachedPlanSource, so the custom plans they build count
 *    towards the same five.  That holds only if the parameter list is NULL
 *    exactly when expr->paramnos is empty, as setup_param_list() has it.
 *
 * 2) A plan that needs analysing again runs the parser hooks of PL/pgSQL,
 *    which read func->cur_estate.  Compiled code has none: the handler left
 *    whatever was there, NULL at top level.  A shadow estate stands in for it
 *    while SPI runs.  It has copies of the variables (copy_plpgsql_datums()),
 *    for a hook reads only what a datum is, not its value.
 *
 * 3) A statement's parameter list holds the variables the statement names and
 *    "no such parameter" in every other slot, as plpgsql_param_fetch() answers.
 *    It has no hooks, so it can be serialized for a parallel worker.
 *
 * The rest is in docs/architecture.md.
 *
 */
#include "postgres.h"

#include "executor/spi.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "nodes/params.h"
#include "plpgsql.h"
#include "utils/memutils.h"
#include "utils/plancache.h"

#include "plllvm.h"
#include "plllvm_pj.h"

/* the estate the parser hooks of PL/pgSQL read, and the records in it */
typedef struct PjShadow
{
	PLpgSQL_execstate *estate;
	int			nrecs;
	int		   *recs;			/* dno of each copy of a record */
} PjShadow;

static PjShadow *shadow_build(PLpgSQL_function *func, MemoryContext cxt);
static void sql_connect(PjCtx *ctx);
static bool sql_writes_walker(Node *node, void *context);

/*
 * The datums of a function as copy_plpgsql_datums() makes them for a call:
 * variables and records are copies, the rows and fields of a record are the
 * function's own.  The function's datums themselves must not be given out: a
 * hook that instantiates a record would write into them.
 */
static PjShadow *
shadow_build(PLpgSQL_function *func, MemoryContext cxt)
{
	MemoryContext oldcxt = MemoryContextSwitchTo(cxt);
	PjShadow   *shadow = palloc0_object(PjShadow);
	PLpgSQL_execstate *estate = palloc0_object(PLpgSQL_execstate);

	estate->func = func;
	estate->ndatums = func->ndatums;
	estate->readonly_func = func->fn_readonly;
	estate->datums = palloc_array(PLpgSQL_datum *, func->ndatums);
	shadow->recs = palloc_array(int, func->ndatums);

	for (int i = 0; i < func->ndatums; i++)
	{
		PLpgSQL_datum *in = func->datums[i];
		PLpgSQL_datum *out;

		switch (in->dtype)
		{
			case PLPGSQL_DTYPE_VAR:
			case PLPGSQL_DTYPE_PROMISE:
				out = palloc(sizeof(PLpgSQL_var));
				memcpy(out, in, sizeof(PLpgSQL_var));
				break;
			case PLPGSQL_DTYPE_REC:
				out = palloc(sizeof(PLpgSQL_rec));
				memcpy(out, in, sizeof(PLpgSQL_rec));
				((PLpgSQL_rec *) out)->erh = NULL;
				shadow->recs[shadow->nrecs++] = i;
				break;
			default:
				out = in;
				break;
		}
		estate->datums[i] = out;
	}

	shadow->estate = estate;
	MemoryContextSwitchTo(oldcxt);
	return shadow;
}

/*
 * What a statement for SPI may be: a query with no writes.  Any command that
 * is not a SELECT, and a data-modifying CTE under a SELECT, is the
 * interpreter's.
 */
static bool
sql_writes_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;

		if (query->commandType != CMD_SELECT || query->hasModifyingCTE)
			return true;
		return query_tree_walker(query, sql_writes_walker, context, 0);
	}
	return expression_tree_walker(node, sql_writes_walker, context);
}

/*
 * The facts of an SQL statement the code depends on, copied into the harvest.
 * Returns the reason to decline the function, or NULL.  The plan of the
 * statement is valid: classify() counts one that is not as unplanned, since
 * no tree of a plan that is stale is safe to read.
 */
const char *
plllvm_pj_sql_harvest(PLpgSQL_function *func, PjHarvest *h, PjExpr *pe)
{
	PLpgSQL_expr *expr = pe->expr;
	CachedPlanSource *psrc;
	PjSql	   *sql;
	MemoryContext oldcxt;

	Assert(expr->plan != NULL);
	psrc = (CachedPlanSource *) linitial(SPI_plan_get_plan_sources(expr->plan));
	Assert(psrc->is_valid);

	if (sql_writes_walker((Node *) psrc->query_list, NULL))
		return "statement:SQL statement";

	oldcxt = MemoryContextSwitchTo(h->cxt);
	sql = palloc0_object(PjSql);
	sql->expr = expr;
	sql->kind = pe->sql_kind;
	sql->paramnos = bms_copy(expr->paramnos);
	sql->plansource = psrc;
	pe->sql = sql;
	if (h->shadow == NULL)
		h->shadow = shadow_build(func, h->cxt);
	MemoryContextSwitchTo(oldcxt);

	return NULL;
}

/*
 * The first statement of a call connects, atomically: a procedure declines.
 * SPI_connect switches to its own context, which the compiled code is not in.
 */
static void
sql_connect(PjCtx *ctx)
{
	MemoryContext oldcxt = CurrentMemoryContext;

	if (ctx->spi)
		return;
	if (SPI_connect_ext(0) != SPI_OK_CONNECT)
		elog(ERROR, "SPI_connect failed");
	MemoryContextSwitchTo(oldcxt);
	ctx->spi = true;
}

/*
 * The end of a call that ran statements.  The caller has copied the result
 * out of the memory SPI frees.
 */
void
plllvm_pj_sql_finish(PjCtx *ctx)
{
	MemoryContext oldcxt = CurrentMemoryContext;

	if (!ctx->spi)
		return;
	ctx->spi = false;
	if (SPI_finish() != SPI_OK_FINISH)
		elog(ERROR, "SPI_finish failed");
	MemoryContextSwitchTo(oldcxt);
}

/*
 * The parameters of statement idx, for the compiled code to fill: the value
 * and the null flag of each variable the statement names.  Made once per level
 * and statement, since the same variables are named at every call.
 */
void *
plllvm_pj_sql_params(PjCtx *ctx, int32 idx)
{
	PjLevel    *lv = plllvm_pj_level(ctx);
	PjSlot	   *slot = &lv->slots[idx];

	if (slot->sql_params == NULL)
	{
		PjHarvest  *h = ctx->harvest;
		const PjExpr *pe = list_nth(h->exprs, idx);
		MemoryContext oldcxt = MemoryContextSwitchTo(lv->cxt);
		ParamListInfo li = makeParamList(h->ndatums);
		int			dno = -1;

		/* every slot says "no such parameter" but those of the statement */
		for (int i = 0; i < h->ndatums; i++)
		{
			li->params[i].value = (Datum) 0;
			li->params[i].isnull = true;
			li->params[i].pflags = 0;
			li->params[i].ptype = InvalidOid;
		}
		while ((dno = bms_next_member(pe->sql->paramnos, dno)) >= 0)
		{
			li->params[dno].ptype = h->ptypes[dno];
			li->params[dno].pflags = PARAM_FLAG_CONST;
		}
		MemoryContextSwitchTo(oldcxt);
		slot->sql_params = li;
	}

	return slot->sql_params->params;
}

/*
 * Run statement idx, as exec_stmt_perform() or exec_stmt_execsql() does, and
 * say what FOUND becomes.  The tuples stay until plllvm_pj_sql_end().
 */
int32
plllvm_pj_sql(PjCtx *ctx, int32 idx)
{
	PjHarvest  *h = ctx->harvest;
	const PjExpr *pe = list_nth(h->exprs, idx);
	PjSql	   *sql = pe->sql;
	PLpgSQL_expr *expr = sql->expr;
	PLpgSQL_function *func = expr->func;
	PjLevel    *lv = plllvm_pj_level(ctx);
	PjShadow   *shadow = h->shadow;
	PLpgSQL_execstate *saved;
	MemoryContext saved_datum_cxt;
	MemoryContext oldcxt = CurrentMemoryContext;
	ParamListInfo li = NULL;
	long		tcount = 0;
	int			rc;
	int32		found = PJ_FOUND_UNCHANGED;

	sql_connect(ctx);
	ctx->evaluated = true;

	/* NULL, not an empty list, without parameters: the plan stays generic */
	if (!bms_is_empty(sql->paramnos))
		li = lv->slots[idx].sql_params;

	/*
	 * The hooks of an analysis that this execution needs read cur_estate, and
	 * a record they instantiate is made in its datum_context.  Restored
	 * whatever happens, the records of the copy with it: a frame of the same
	 * function below may be running.
	 */
	saved = func->cur_estate;
	saved_datum_cxt = shadow->estate->datum_context;
	PG_TRY();
	{
		func->cur_estate = shadow->estate;
		shadow->estate->datum_context = lv->datum_cxt;
		rc = SPI_execute_plan_with_paramlist(expr->plan, li, func->fn_readonly,
											 tcount);
	}
	PG_FINALLY();
	{
		func->cur_estate = saved;
		shadow->estate->datum_context = saved_datum_cxt;
		for (int i = 0; i < shadow->nrecs; i++)
			((PLpgSQL_rec *) shadow->estate->datums[shadow->recs[i]])->erh = NULL;
	}
	PG_END_TRY();
	MemoryContextSwitchTo(oldcxt);

	if (sql->kind == PJ_SQL_PERFORM)
	{
		/* exec_run_select(): only a SELECT, and it says which not */
		if (rc != SPI_OK_SELECT)
		{
			if (rc == SPI_OK_SELINTO)
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("query is SELECT INTO, but it should be plain SELECT"),
						 errcontext("query: %s", expr->query)));
			else
				ereport(ERROR,
						(errcode(ERRCODE_SYNTAX_ERROR),
						 errmsg("query is not a SELECT"),
						 errcontext("query: %s", expr->query)));
		}
		return SPI_processed != 0 ? PJ_FOUND_TRUE : PJ_FOUND_FALSE;
	}

	/*
	 * Whether the result sets FOUND is by the kind of command, for historical
	 * reasons
	 */
	switch (rc)
	{
		case SPI_OK_SELECT:
		case SPI_OK_INSERT:
		case SPI_OK_UPDATE:
		case SPI_OK_DELETE:
		case SPI_OK_MERGE:
		case SPI_OK_INSERT_RETURNING:
		case SPI_OK_UPDATE_RETURNING:
		case SPI_OK_DELETE_RETURNING:
		case SPI_OK_MERGE_RETURNING:
			found = SPI_processed != 0 ? PJ_FOUND_TRUE : PJ_FOUND_FALSE;
			break;
		case SPI_OK_SELINTO:
		case SPI_OK_UTILITY:
			break;
		case SPI_OK_REWRITTEN:
			found = PJ_FOUND_FALSE;
			break;
		case SPI_ERROR_COPY:
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("cannot COPY to/from client in PL/pgSQL")));
			break;
		case SPI_ERROR_TRANSACTION:
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("unsupported transaction command in PL/pgSQL")));
			break;
		default:
			elog(ERROR, "SPI_execute_plan_with_paramlist failed executing query \"%s\": %s",
				 expr->query, SPI_result_code_string(rc));
			break;
	}

	/* a statement that is not given a place for its result must not have one */
	if (SPI_tuptable != NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("query has no destination for result data"),
				 (rc == SPI_OK_SELECT) ? errhint("If you want to discard the results of a SELECT, use PERFORM instead.") : 0));

	return found;
}

/*
 * The tuples of statement idx are not needed any more: what exec_eval_cleanup()
 * does after one
 */
void
plllvm_pj_sql_end(PjCtx *ctx, int32 idx)
{
	SPI_freetuptable(SPI_tuptable);
	Assert(SPI_tuptable == NULL);
}
