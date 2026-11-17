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

#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_proc.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "nodes/params.h"
#include "plpgsql.h"
#include "utils/fmgroids.h"
#include "utils/plancache.h"
#include "utils/rls.h"
#include "utils/syscache.h"

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

/* what the walk over the queries of a plan finds */
typedef struct SqlFacts
{
	const char *reason;			/* why the statement is not admitted */
	List	   *funcs;			/* the callees, once each ... */
	List	   *volatility;		/* ... and their provolatile (as int) */
	bool		has_view;
} SqlFacts;

static bool sql_scan_walker(Node *node, SqlFacts *facts);
static bool sql_scan_func(Oid funcid, void *context);
static bool sql_func_pinned(Oid funcid);
static bool sql_facts_ok(PjSql *sql);
static void sql_recheck(PjHarvest *h, PjSql *sql);

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
 * What a statement for SPI may be: a query with no writes, and no callee that
 * can change what the plan was made from.  A command that is not a SELECT
 * and a data-modifying CTE under a SELECT are the interpreter's: the triggers,
 * rules and constraints of the table they write are code that no walk of the
 * query shows.  A VOLATILE function may run SQL of its own, or set what a later
 * simple expression of the function was planned with (search_path), so it is
 * not admitted either, but the built-in ones that change no plan input.
 */
static bool
sql_scan_walker(Node *node, SqlFacts *facts)
{
	if (node == NULL)
		return false;
	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;

		if (query->commandType != CMD_SELECT || query->hasModifyingCTE)
		{
			facts->reason = "statement:SQL statement";
			return true;
		}
		foreach_node(RangeTblEntry, rte, query->rtable)
		{
			/* ApplyRetrieveRule() leaves the relkind of the view */
			if (rte->rtekind == RTE_SUBQUERY && rte->relkind == RELKIND_VIEW)
				facts->has_view = true;
		}
		return query_tree_walker(query, sql_scan_walker, facts, 0);
	}
	if (check_functions_in_node(node, sql_scan_func, facts))
		return true;
	return expression_tree_walker(node, sql_scan_walker, facts);
}

static bool
sql_scan_func(Oid funcid, void *context)
{
	SqlFacts   *facts = (SqlFacts *) context;
	HeapTuple	tup;
	char		provolatile;

	if (sql_func_pinned(funcid))
		return false;
	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(funcid));
	if (!HeapTupleIsValid(tup))
	{
		facts->reason = "callee";
		return true;
	}
	provolatile = ((Form_pg_proc) GETSTRUCT(tup))->provolatile;
	ReleaseSysCache(tup);
	if (provolatile == PROVOLATILE_VOLATILE)
	{
		facts->reason = "volatile callee";
		return true;
	}
	if (!list_member_oid(facts->funcs, funcid))
	{
		facts->funcs = lappend_oid(facts->funcs, funcid);
		facts->volatility = lappend_int(facts->volatility, provolatile);
	}
	return false;
}

/*
 * The VOLATILE built-ins that change no input of a plan: the sequence
 * functions, the clocks and random numbers, the transaction id, notify and
 * sleep.  set_config is none of them.
 */
static bool
sql_func_pinned(Oid funcid)
{
	switch (funcid)
	{
		case F_NEXTVAL:
		case F_CURRVAL:
		case F_LASTVAL:
		case F_SETVAL_REGCLASS_INT8:
		case F_SETVAL_REGCLASS_INT8_BOOL:
		case F_RANDOM_:
		case F_RANDOM_NORMAL:
		case F_RANDOM_INT4_INT4:
		case F_RANDOM_INT8_INT8:
		case F_RANDOM_NUMERIC_NUMERIC:
		case F_CLOCK_TIMESTAMP:
		case F_TIMEOFDAY:
		case F_GEN_RANDOM_UUID:
		case F_UUIDV4:
		case F_UUIDV7_:
		case F_UUIDV7_INTERVAL:
		case F_TXID_CURRENT:
		case F_PG_CURRENT_XACT_ID:
		case F_PG_NOTIFY:
		case F_PG_SLEEP:
		case F_PG_SLEEP_FOR:
		case F_PG_SLEEP_UNTIL:
			return true;
		default:
			return false;
	}
}

/*
 * Is the plan of the statement, as it is now, one it was admitted as?  The
 * same walk, and the same variables for parameters.  Only for a plan that is
 * valid: the trees of a stale one may name what is gone.
 */
static bool
sql_facts_ok(PjSql *sql)
{
	SqlFacts	facts = {0};
	CachedPlanSource *psrc = sql->plansource;
	bool		ok = false;

	/* the lists are in the caller's context, which lasts as long as the call */
	if (bms_equal(sql->expr->paramnos, sql->paramnos) &&
		!sql_scan_walker((Node *) psrc->query_list, &facts) &&
		facts.has_view == sql->has_view &&
		list_length(facts.funcs) == sql->nfuncs)
	{
		ok = true;
		for (int i = 0; i < sql->nfuncs && ok; i++)
		{
			int			at = -1;

			for (int j = 0; j < list_length(facts.funcs); j++)
			{
				if (list_nth_oid(facts.funcs, j) == sql->funcs[i])
					at = j;
			}
			ok = at >= 0 &&
				list_nth_int(facts.volatility, at) == sql->volatility[i];
		}
	}
	list_free(facts.funcs);
	list_free(facts.volatility);
	return ok;
}

/*
 * The facts of an SQL statement the code depends on, copied into the harvest.
 * Returns the reason to decline the function, or NULL.  The plan of the
 * statement is valid, or the statement counts as unplanned (see below).
 */
const char *
plllvm_pj_sql_harvest(PLpgSQL_function *func, PjHarvest *h, PjExpr *pe)
{
	PLpgSQL_expr *expr = pe->expr;
	CachedPlanSource *psrc;
	PjSql	   *sql;
	SqlFacts	facts = {0};
	MemoryContext oldcxt;

	Assert(expr->plan != NULL);
	psrc = (CachedPlanSource *) linitial(SPI_plan_get_plan_sources(expr->plan));

	/*
	 * classify() found the plan valid, but taking the locks of a first
	 * translation delivers invalidations, so another session's DDL may have
	 * made it stale since.  Its trees are not ours to read: the statement is
	 * unplanned, and the function waits as for one the interpreter has not
	 * reached.
	 */
	if (!psrc->is_valid)
	{
		pe->h1 = PJ_H1_UNPLANNED;
		h->nunplanned++;
		return NULL;
	}

	if (sql_scan_walker((Node *) psrc->query_list, &facts))
		return facts.reason;

	oldcxt = MemoryContextSwitchTo(h->cxt);
	sql = palloc0_object(PjSql);
	sql->expr = expr;
	sql->kind = pe->sql_kind;
	sql->paramnos = bms_copy(expr->paramnos);
	sql->plansource = psrc;
	sql->generation = psrc->generation;
	sql->has_view = facts.has_view;
	sql->nfuncs = list_length(facts.funcs);
	sql->funcs = palloc_array(Oid, Max(sql->nfuncs, 1));
	sql->volatility = palloc_array(char, Max(sql->nfuncs, 1));
	for (int i = 0; i < sql->nfuncs; i++)
	{
		sql->funcs[i] = list_nth_oid(facts.funcs, i);
		sql->volatility[i] = (char) list_nth_int(facts.volatility, i);
	}
	pe->sql = sql;
	if (h->shadow == NULL)
		h->shadow = shadow_build(func, h->cxt);
	MemoryContextSwitchTo(oldcxt);

	return NULL;
}

/*
 * May the next call run the statement on the plan it has?  The checks SPI
 * itself would make are the ones that can change what the code assumed, so
 * they are made before anything runs: a miss sends the call to the
 * interpreter, which translates again.
 *
 * An invalid plan is not a miss: SPI analyses it again inside the call, and
 * a function whose table is truncated and analysed between calls would
 * otherwise never stay compiled.  It is one only if what the statement was
 * admitted for may have changed: a callee that is not as it was, a view, a
 * policy.  A plan that others have rebuilt since our last look (an interpreted
 * call may have) is checked as it stands.
 */
bool
plllvm_pj_sql_guard(PjSql *sql)
{
	CachedPlanSource *psrc = sql->plansource;

	/* the names would resolve in another schema */
	if (psrc->search_path == NULL ||
		!SearchPathMatchesCurrentEnvironment(psrc->search_path))
		return false;

	/* another role or row_security rewrites the query another way */
	if (psrc->dependsOnRLS &&
		(!psrc->is_valid || psrc->rewriteRoleId != GetUserId() ||
		 psrc->rewriteRowSecurity != row_security))
		return false;

	if (!bms_equal(sql->expr->paramnos, sql->paramnos))
		return false;

	if (!psrc->is_valid)
	{
		if (sql->has_view)
			return false;
		for (int i = 0; i < sql->nfuncs; i++)
		{
			HeapTuple	tup = SearchSysCache1(PROCOID,
											  ObjectIdGetDatum(sql->funcs[i]));
			bool		same;

			if (!HeapTupleIsValid(tup))
				return false;
			same = ((Form_pg_proc) GETSTRUCT(tup))->provolatile ==
				sql->volatility[i];
			ReleaseSysCache(tup);
			if (!same)
				return false;
		}
		return true;
	}

	if (psrc->generation != sql->generation)
	{
		plllvm_pj_count.sql_rewalks++;
		if (!sql_facts_ok(sql))
			return false;
		sql->generation = psrc->generation;
	}
	return true;
}

/*
 * After an execution: if a plan was built since we looked, SPI may have
 * analysed the statement again, and the query list has changed under us.  The
 * list's address would not tell (the new one can take the place of the old),
 * the counter of plans does: it moves with every plan built, and a new query
 * list is followed by one, unless the plan that follows the analysis fails
 * to build (a custom plan that raises): then the next call runs that list
 * once unchecked, and this check, after it, finds it.  The statement goes on
 * with the trees it has, as PL/pgSQL does until its next evaluation, and the
 * next call translates again if the plan is no longer the one it was
 * admitted as.
 */
static void
sql_recheck(PjHarvest *h, PjSql *sql)
{
	CachedPlanSource *psrc = sql->plansource;

	if (psrc->generation == sql->generation || !psrc->is_valid)
		return;

	plllvm_pj_count.sql_rewalks++;
	if (sql_facts_ok(sql))
		sql->generation = psrc->generation;
	else
	{
		plllvm_pj_count.sql_stale++;
		h->sql_stale = true;
	}
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
	plllvm_pj_count.sql_execs++;

	/* for the tests: every execution analyses its statement again */
	if (plllvm_debug_inject == PLLLVM_INJECT_PJ_SQL_REPLAN)
		ResetPlanCache();

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

	sql_recheck(h, sql);

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
	bool		moved;

	SPI_freetuptable(SPI_tuptable);
	Assert(SPI_tuptable == NULL);

	/*
	 * The statement may have run code that changed the user or a privilege.
	 * Code that changes a function says so in the same way, and may have made
	 * a plan of the function's own stale: it goes on with its trees, as
	 * PL/pgSQL goes on until its next evaluation, and the next call finds
	 * out.
	 */
	moved = plllvm_pj_exec_epoch() != ctx->epoch;
	plllvm_pj_key_recheck(ctx, list_nth(ctx->harvest->exprs, idx));
	if (moved && !plllvm_pj_guards_ok(ctx->harvest, false))
		plllvm_pj_count.sql_stale++;
}
