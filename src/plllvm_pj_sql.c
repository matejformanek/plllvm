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
 * 4) SELECT INTO is exec_stmt_execsql() after the call: the number of rows,
 *    STRICT, the extra checks, FOUND, and the move of the first row into the
 *    variables, as exec_move_row() does it.  The values are left for the
 *    compiled code to store, since it keeps the variables in its own slots; it
 *    has them until plllvm_pj_sql_end().
 *
 * The rest is in docs/architecture.md.
 *
 */
#include "postgres.h"

#include "access/genam.h"
#include "access/htup_details.h"
#include "access/table.h"
#include "catalog/indexing.h"
#include "catalog/namespace.h"
#include "catalog/pg_class.h"
#include "catalog/pg_constraint.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_trigger.h"
#include "catalog/pg_type.h"
#include "executor/spi.h"
#include "miscadmin.h"
#include "nodes/nodeFuncs.h"
#include "nodes/params.h"
#include "optimizer/optimizer.h"
#include "parser/parsetree.h"
#include "plpgsql.h"
#include "utils/builtins.h"
#include "utils/fmgroids.h"
#include "utils/guc.h"
#include "utils/lsyscache.h"
#include "utils/plancache.h"
#include "utils/rls.h"
#include "utils/syscache.h"
#include "utils/varlena.h"

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
	bool		writes;			/* a command or a CTE of it writes */
} SqlFacts;

static bool sql_scan_walker(Node *node, SqlFacts *facts);
static bool sql_cmd_writes(CachedPlanSource *psrc);
static const char *sql_write_reason(Query *query);
static const char *sql_relation_reason(Oid relid);
static const char *sql_trigger_reason(Oid relid);
static bool sql_check_volatile(Oid conrelid, Oid typid);
static bool sql_domain_volatile(Oid typid);
static bool sql_expr_volatile(Node *expr);
static bool sql_expr_volatile_walker(Node *node, void *context);
static bool sql_scan_func(Oid funcid, void *context);
static bool sql_func_pinned(Oid funcid);
static bool sql_facts_ok(PjSql *sql);
static void sql_recheck(PjHarvest *h, PjSql *sql);
static const char *sql_into_admit(PLpgSQL_function *func,
								  CachedPlanSource *psrc,
								  PLpgSQL_stmt_execsql *stmt);
static bool sql_result_same(PjSql *sql, CachedPlanSource *psrc);
static void sql_xchecks(PjCtx *ctx);
static void sql_move(PjCtx *ctx, PjSql *sql, PjSlot *slot);

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
 * What a statement for SPI may be: a query that writes only to a table with
 * no code of its own (sql_relation_reason()), and no callee that can change
 * what the plan was made from.  Any other command, and MERGE, are the
 * interpreter's.  A data-modifying CTE under a SELECT is a query of its own
 * here, so the rule applies to its result relation as to the top level's.  A
 * VOLATILE function may run SQL of its own, or set what a later simple
 * expression of the function was planned with (search_path), so it is not
 * admitted either, but the built-in ones that change no plan input.
 */
static bool
sql_scan_walker(Node *node, SqlFacts *facts)
{
	if (node == NULL)
		return false;
	if (IsA(node, Query))
	{
		Query	   *query = (Query *) node;

		switch (query->commandType)
		{
			case CMD_SELECT:
				break;
			case CMD_INSERT:
			case CMD_UPDATE:
			case CMD_DELETE:
				facts->writes = true;
				facts->reason = sql_write_reason(query);
				if (facts->reason != NULL)
					return true;
				break;
			default:
				facts->reason = "statement:SQL statement";
				return true;
		}
		if (query->hasModifyingCTE)
			facts->writes = true;
		foreach_node(RangeTblEntry, rte, query->rtable)
		{
			/* ApplyRetrieveRule() leaves the relkind of the view */
			if (rte->rtekind == RTE_SUBQUERY && rte->relkind == RELKIND_VIEW)
				facts->has_view = true;
		}
		return query_tree_walker(query, sql_scan_walker, facts, 0);
	}
	if (IsA(node, CoerceToDomain) &&
		sql_domain_volatile(((CoerceToDomain *) node)->resulttype))
	{
		facts->reason = "relation:check";
		return true;
	}
	if (check_functions_in_node(node, sql_scan_func, facts))
		return true;
	return expression_tree_walker(node, sql_scan_walker, facts);
}

/*
 * Is the statement INSERT, UPDATE, DELETE or MERGE?  The command tag says, as
 * for exec_stmt_execsql(): not the rewritten query, which a rule may have made
 * into something else, or into nothing.
 */
static bool
sql_cmd_writes(CachedPlanSource *psrc)
{
	return psrc->commandTag == CMDTAG_INSERT ||
		psrc->commandTag == CMDTAG_UPDATE ||
		psrc->commandTag == CMDTAG_DELETE ||
		psrc->commandTag == CMDTAG_MERGE;
}

/* the result relation of a command that writes, as the rewriter left it */
static const char *
sql_write_reason(Query *query)
{
	RangeTblEntry *rte;

	if (query->resultRelation <= 0)
		return "statement:SQL statement";
	rte = rt_fetch(query->resultRelation, query->rtable);
	if (rte->rtekind != RTE_RELATION)
		return "relation:kind";
	return sql_relation_reason(rte->relid);
}

/*
 * May compiled code write to this table?  What a write does besides storing
 * the row is code that the plan does not show: triggers, rules, the actions
 * of foreign keys, the children of an inheritance tree, the partitions, the
 * wrapper of a foreign table.  Any of them is the interpreter's.  The checks
 * of a foreign key on the table written, and of a deferred unique constraint,
 * are not: they change no row and run no code of a user.  Read from the
 * catalogs with no lock on the table: a change to the table that matters (a
 * trigger, a rule, a default, a check, the children) invalidates the plan,
 * which is looked at again.  A function that only a CHECK or a domain
 * constraint calls is no dependency of the plan, so a change of its
 * volatility is not seen until something else invalidates the plan: a stated
 * gap.
 */
static const char *
sql_relation_reason(Oid relid)
{
	HeapTuple	tup = SearchSysCache1(RELOID, ObjectIdGetDatum(relid));
	Form_pg_class rel;
	const char *reason = NULL;

	if (!HeapTupleIsValid(tup))
		return "relation:kind";
	rel = (Form_pg_class) GETSTRUCT(tup);

	if (rel->relkind == RELKIND_PARTITIONED_TABLE)
		reason = "relation:partitioned";
	else if (rel->relkind == RELKIND_FOREIGN_TABLE)
		reason = "relation:foreign table";
	else if (rel->relkind != RELKIND_RELATION)
		reason = "relation:kind";
	else if (rel->relhasrules)
		reason = "relation:rule";
	else if (rel->relhassubclass)
		reason = "relation:inheritance";
	else if (rel->relhastriggers)
		reason = sql_trigger_reason(relid);
	if (reason == NULL && rel->relchecks > 0 &&
		sql_check_volatile(relid, InvalidOid))
		reason = "relation:check";
	ReleaseSysCache(tup);
	return reason;
}

/*
 * Does a CHECK constraint of the table, or of the domain, call a VOLATILE
 * function?  The executor runs the constraints, so they are no part of the
 * plan: the walk over the query does not show them.
 */
static bool
sql_check_volatile(Oid conrelid, Oid typid)
{
	Relation	conrel = table_open(ConstraintRelationId, AccessShareLock);
	ScanKeyData key[2];
	SysScanDesc scan;
	HeapTuple	tup;
	bool		found = false;

	ScanKeyInit(&key[0], Anum_pg_constraint_conrelid, BTEqualStrategyNumber,
				F_OIDEQ, ObjectIdGetDatum(conrelid));
	ScanKeyInit(&key[1], Anum_pg_constraint_contypid, BTEqualStrategyNumber,
				F_OIDEQ, ObjectIdGetDatum(typid));
	scan = systable_beginscan(conrel, ConstraintRelidTypidNameIndexId, true,
							  NULL, 2, key);
	while (!found && HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_constraint con = (Form_pg_constraint) GETSTRUCT(tup);
		Datum		bin;
		bool		isnull;

		if (con->contype != CONSTRAINT_CHECK)
			continue;
		bin = heap_getattr(tup, Anum_pg_constraint_conbin,
						   RelationGetDescr(conrel), &isnull);
		if (isnull)
			continue;
		found = sql_expr_volatile(stringToNode(TextDatumGetCString(bin)));
	}
	systable_endscan(scan);
	table_close(conrel, AccessShareLock);
	return found;
}

/*
 * contain_volatile_functions() takes a coercion to a domain for immutable,
 * though the constraints of the domain run: look at them too
 */
static bool
sql_expr_volatile(Node *expr)
{
	return contain_volatile_functions(expr) ||
		sql_expr_volatile_walker(expr, NULL);
}

static bool
sql_expr_volatile_walker(Node *node, void *context)
{
	if (node == NULL)
		return false;
	if (IsA(node, CoerceToDomain) &&
		sql_domain_volatile(((CoerceToDomain *) node)->resulttype))
		return true;
	return expression_tree_walker(node, sql_expr_volatile_walker, context);
}

/* the same for a domain and the domains it is made on */
static bool
sql_domain_volatile(Oid typid)
{
	while (OidIsValid(typid))
	{
		HeapTuple	tup = SearchSysCache1(TYPEOID, ObjectIdGetDatum(typid));
		Form_pg_type typ;
		Oid			base;

		if (!HeapTupleIsValid(tup))
			return false;
		typ = (Form_pg_type) GETSTRUCT(tup);
		if (typ->typtype != TYPTYPE_DOMAIN)
		{
			ReleaseSysCache(tup);
			return false;
		}
		base = typ->typbasetype;
		ReleaseSysCache(tup);
		if (sql_check_volatile(InvalidOid, typid))
			return true;
		typid = base;
	}
	return false;
}

static const char *
sql_trigger_reason(Oid relid)
{
	Relation	tgrel = table_open(TriggerRelationId, AccessShareLock);
	ScanKeyData key;
	SysScanDesc scan;
	HeapTuple	tup;
	const char *reason = NULL;

	ScanKeyInit(&key, Anum_pg_trigger_tgrelid, BTEqualStrategyNumber,
				F_OIDEQ, ObjectIdGetDatum(relid));
	scan = systable_beginscan(tgrel, TriggerRelidNameIndexId, true, NULL, 1,
							  &key);
	while (reason == NULL && HeapTupleIsValid(tup = systable_getnext(scan)))
	{
		Form_pg_trigger trig = (Form_pg_trigger) GETSTRUCT(tup);

		if (!trig->tgisinternal)
		{
			reason = "relation:trigger";
			continue;
		}
		switch (trig->tgfoid)
		{
			case F_RI_FKEY_CHECK_INS:
			case F_RI_FKEY_CHECK_UPD:
			case F_RI_FKEY_NOACTION_DEL:
			case F_RI_FKEY_NOACTION_UPD:
			case F_RI_FKEY_RESTRICT_DEL:
			case F_RI_FKEY_RESTRICT_UPD:
			case F_UNIQUE_KEY_RECHECK:
				break;
			case F_RI_FKEY_CASCADE_DEL:
			case F_RI_FKEY_CASCADE_UPD:
			case F_RI_FKEY_SETNULL_DEL:
			case F_RI_FKEY_SETNULL_UPD:
			case F_RI_FKEY_SETDEFAULT_DEL:
			case F_RI_FKEY_SETDEFAULT_UPD:
				reason = "relation:cascade";
				break;
			default:
				reason = "relation:trigger";
				break;
		}
	}
	systable_endscan(scan);
	table_close(tgrel, AccessShareLock);
	return reason;
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
		(!sql->into || sql_result_same(sql, psrc)) &&
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
	PLpgSQL_stmt_execsql *stmt = pe->stmt;
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
	if (stmt != NULL && stmt->into)
	{
		const char *reason = sql_into_admit(func, psrc, stmt);

		if (reason != NULL)
			return reason;
	}

	oldcxt = MemoryContextSwitchTo(h->cxt);
	sql = palloc0_object(PjSql);
	sql->expr = expr;
	sql->kind = pe->sql_kind;
	if (stmt != NULL && stmt->into)
	{
		PLpgSQL_row *row = (PLpgSQL_row *) stmt->target;
		TupleDesc	desc = psrc->resultDesc;

		sql->into = true;
		sql->strict = stmt->strict;
		sql->mod = sql_cmd_writes(psrc);
		sql->ntargets = row->nfields;
		sql->targets = palloc_array(int, row->nfields);
		memcpy(sql->targets, row->varnos, sizeof(int) * row->nfields);
		sql->ncols = desc->natts;
		sql->coltypes = palloc_array(Oid, desc->natts);
		sql->coltypmods = palloc_array(int32, desc->natts);
		for (int i = 0; i < desc->natts; i++)
		{
			sql->coltypes[i] = TupleDescAttr(desc, i)->atttypid;
			sql->coltypmods[i] = TupleDescAttr(desc, i)->atttypmod;
		}
	}
	sql->paramnos = bms_copy(expr->paramnos);
	sql->plansource = psrc;
	sql->generation = psrc->generation;
	sql->has_view = facts.has_view;

	/*
	 * A command that a rule turned into nothing has no query to show it, and
	 * writes as much as any: its tag tells
	 */
	sql->writes = facts.writes || sql_cmd_writes(psrc);
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
 * What an INTO may be, as the code stores it: the columns that the variables
 * take come in their type, so that no value needs a cast, and the variables
 * take a NULL without one.  A cast that the interpreter makes is its own:
 * the function is declined.  A zero-row result and a column that is missing
 * give a NULL of unknown type, which exec_cast_value() turns into the NULL of
 * the type by its input function; that is no work only if the function is
 * strict.  print_strict_params adds a DETAIL that is not ported.
 */
static const char *
sql_into_admit(PLpgSQL_function *func, CachedPlanSource *psrc,
			   PLpgSQL_stmt_execsql *stmt)
{
	PLpgSQL_row *row = (PLpgSQL_row *) stmt->target;
	TupleDesc	desc = psrc->resultDesc;
	int			anum = 0;

	if (func->print_strict_params)
		return "print_strict_params";
	if (desc == NULL)
		return "statement:SQL statement";

	for (int i = 0; i < row->nfields; i++)
	{
		PLpgSQL_var *var = (PLpgSQL_var *) func->datums[row->varnos[i]];
		Oid			input;
		Oid			ioparam;

		getTypeInputInfo(var->datatype->typoid, &input, &ioparam);
		if (!func_strict(input))
			return "cast";

		while (anum < desc->natts && TupleDescAttr(desc, anum)->attisdropped)
			anum++;
		if (anum < desc->natts)
		{
			Form_pg_attribute att = TupleDescAttr(desc, anum++);

			if (att->atttypid != var->datatype->typoid ||
				(att->atttypmod != var->datatype->atttypmod &&
				 var->datatype->atttypmod != -1))
				return "cast";
		}
	}
	return NULL;
}

/* does the statement still give the columns it was admitted with? */
static bool
sql_result_same(PjSql *sql, CachedPlanSource *psrc)
{
	TupleDesc	desc = psrc->resultDesc;

	if (desc == NULL || desc->natts != sql->ncols)
		return false;
	for (int i = 0; i < sql->ncols; i++)
	{
		if (TupleDescAttr(desc, i)->atttypid != sql->coltypes[i] ||
			TupleDescAttr(desc, i)->atttypmod != sql->coltypmods[i])
			return false;
	}
	return true;
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
 * policy, or the table of a statement that writes, which may have a trigger
 * now.  A plan that others have rebuilt since our last look (an interpreted
 * call may have) is checked as it stands.
 */
bool
plllvm_pj_sql_guard(PjSql *sql, bool *replan)
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
		/*
		 * A statement that writes also depends on what its table has: a
		 * default, a generated column, a trigger, a rule
		 */
		if (sql->writes)
		{
			/*
			 * The interpreter plans it again, and a planning that fails (a
			 * custom plan that raises) leaves the new query list in a valid
			 * plan source with the old generation: so the walk is for the
			 * next valid plan, whatever the counter says
			 */
			sql->rewalk = true;
			*replan = true;
			return false;
		}
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

	if (psrc->generation != sql->generation || sql->rewalk)
	{
		plllvm_pj_count.sql_rewalks++;
		if (!sql_facts_ok(sql))
			return false;
		sql->generation = psrc->generation;
		sql->rewalk = false;
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

	/*
	 * With an INTO one row is enough, but two are asked for to see that there
	 * is not more, when STRICT or the check says so; a command that writes is
	 * always strict.  Without, the statement runs to the end.
	 */
	if (sql->into)
	{
		sql_xchecks(ctx);
		tcount = (sql->strict || sql->mod || ctx->xrows != 0) ? 2 : 1;
	}

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

	if (sql->into)
	{
		PjSlot	   *slot = &lv->slots[idx];

		if (slot->sql_out == NULL)
		{
			MemoryContext cxt = MemoryContextSwitchTo(lv->cxt);

			slot->sql_out = palloc_array(PjSqlOut, sql->ntargets);
			MemoryContextSwitchTo(cxt);
		}
		sql_move(ctx, sql, slot);
		return found;
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
	PjSlot	   *slot = &plllvm_pj_level(ctx)->slots[idx];

	SPI_freetuptable(SPI_tuptable);
	Assert(SPI_tuptable == NULL);

	/* what the conversions allocated, now that the targets have their copies */
	if (slot->sql_converted)
	{
		plllvm_pj_boxed_reset(ctx);
		slot->sql_converted = false;
	}

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

/* where plllvm_pj_sql() left the values of the INTO targets of statement idx */
void *
plllvm_pj_sql_out(PjCtx *ctx, int32 idx)
{
	return plllvm_pj_level(ctx)->slots[idx].sql_out;
}

/*
 * The flags of a list of extra checks of PL/pgSQL (plpgsql.extra_errors and
 * plpgsql.extra_warnings), parsed as plpgsql_extra_checks_check_hook() does;
 * the value was accepted by it when it was set.
 */
static int
xcheck_flags(const char *name)
{
	const char *value = GetConfigOption(name, true, false);
	char	   *raw;
	List	   *elems;
	int			flags = 0;

	if (value == NULL || pg_strcasecmp(value, "none") == 0)
		return 0;
	if (pg_strcasecmp(value, "all") == 0)
		return PLPGSQL_XCHECK_ALL;

	raw = pstrdup(value);
	if (SplitIdentifierString(raw, ',', &elems))
	{
		foreach_ptr(char, tok, elems)
		{
			if (pg_strcasecmp(tok, "too_many_rows") == 0)
				flags |= PLPGSQL_XCHECK_TOOMANYROWS;
			else if (pg_strcasecmp(tok, "strict_multi_assignment") == 0)
				flags |= PLPGSQL_XCHECK_STRICTMULTIASSIGNMENT;
		}
	}
	list_free(elems);
	pfree(raw);
	return flags;
}

/*
 * The extra checks that an INTO reads, once for the call: PL/pgSQL reads them
 * at each statement.  They change in a call only through set_config(), which
 * is not admitted, or through a function that is not what it says it is.
 */
static void
sql_xchecks(PjCtx *ctx)
{
	int			errors;
	int			warnings;

	if (ctx->xchecks)
		return;
	errors = xcheck_flags("plpgsql.extra_errors");
	warnings = xcheck_flags("plpgsql.extra_warnings");

	if (errors & PLPGSQL_XCHECK_TOOMANYROWS)
		ctx->xrows = ERROR;
	else if (warnings & PLPGSQL_XCHECK_TOOMANYROWS)
		ctx->xrows = WARNING;
	if (errors & PLPGSQL_XCHECK_STRICTMULTIASSIGNMENT)
		ctx->xcols = ERROR;
	else if (warnings & PLPGSQL_XCHECK_STRICTMULTIASSIGNMENT)
		ctx->xcols = WARNING;
	ctx->xchecks = true;
}

/*
 * The row of the result into the targets of the INTO, as exec_move_row() with
 * a row for a target does it, but for the store: each field is converted to
 * the type of its variable, checked for NOT NULL, and left in the slot.  The
 * columns that are dropped do not count, a target without a column gets a
 * NULL, and a column without a target is ignored (with the extra check, they
 * are errors).  No row gives a NULL for each target.
 */
static void
sql_move(PjCtx *ctx, PjSql *sql, PjSlot *slot)
{
	PjSqlOut   *out = slot->sql_out;
	SPITupleTable *tuptab = SPI_tuptable;
	PLpgSQL_function *func = sql->expr->func;
	TupleDesc	tupdesc = NULL;
	Datum		values_local[64];
	bool		nulls_local[64];
	Datum	   *values = values_local;
	bool	   *nulls = nulls_local;
	int			anum = 0;

	if (tuptab == NULL)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("INTO used with a command that cannot return data")));

	if (SPI_processed == 0)
	{
		if (sql->strict)
			ereport(ERROR,
					(errcode(ERRCODE_NO_DATA_FOUND),
					 errmsg("query returned no rows")));
	}
	else
	{
		if (SPI_processed > 1 && (sql->strict || sql->mod || ctx->xrows != 0))
			ereport((sql->strict || sql->mod) ? ERROR : ctx->xrows,
					(errcode(ERRCODE_TOO_MANY_ROWS),
					 errmsg("query returned more than one row"),
					 errhint("Make sure the query returns a single row, or use LIMIT 1.")));

		tupdesc = tuptab->tupdesc;
		if (tupdesc->natts > lengthof(values_local))
		{
			values = palloc_array(Datum, tupdesc->natts);
			nulls = palloc_array(bool, tupdesc->natts);
		}
		heap_deform_tuple(tuptab->vals[0], tupdesc, values, nulls);
	}

	for (int i = 0; i < sql->ntargets; i++)
	{
		PLpgSQL_var *var = (PLpgSQL_var *) func->datums[sql->targets[i]];
		Datum		value = (Datum) 0;
		bool		isnull = true;

		while (tupdesc != NULL && anum < tupdesc->natts &&
			   TupleDescAttr(tupdesc, anum)->attisdropped)
			anum++;

		if (tupdesc != NULL && anum < tupdesc->natts)
		{
			Form_pg_attribute att = TupleDescAttr(tupdesc, anum);

			value = values[anum];
			isnull = nulls[anum];
			anum++;
			if (att->atttypid != var->datatype->typoid ||
				(att->atttypmod != var->datatype->atttypmod &&
				 var->datatype->atttypmod != -1))
			{
				value = plllvm_pj_convert(ctx, value, &isnull, att->atttypid,
										  att->atttypmod, var->datatype->typoid,
										  var->datatype->atttypmod);
				slot->sql_converted = true;
			}
		}
		else if (tupdesc != NULL && ctx->xcols != 0)
			ereport(ctx->xcols,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("number of source and target fields in assignment does not match"),
					 errdetail("%s check of %s is active.",
							   "strict_multi_assignment",
							   ctx->xcols == ERROR ? "extra_errors" : "extra_warnings"),
					 errhint("Make sure the query returns the exact list of columns.")));

		if (isnull && var->notnull)
			plllvm_pj_not_null(var->refname);

		out[i].value = value;
		out[i].isnull = isnull;
	}

	/* the arrays are the call's, which lasts through a loop of statements */
	if (values != values_local)
	{
		pfree(values);
		pfree(nulls);
	}

	if (tupdesc != NULL && ctx->xcols != 0)
	{
		while (anum < tupdesc->natts && TupleDescAttr(tupdesc, anum)->attisdropped)
			anum++;
		if (anum < tupdesc->natts)
			ereport(ctx->xcols,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("number of source and target fields in assignment does not match"),
					 errdetail("%s check of %s is active.",
							   "strict_multi_assignment",
							   ctx->xcols == ERROR ? "extra_errors" : "extra_warnings"),
					 errhint("Make sure the query returns the exact list of columns.")));
	}
}

/*
 * exec_cast_value() for a value of another type than the variable's: the
 * cast of the type pair as get_cast_hashentry() builds it, run on the value.
 * It is for a column whose type changed after the statement was admitted; the
 * statement is then admitted again, or declined, at the next call.  The
 * result is in the per-tuple memory of the level until plllvm_pj_sql_end().
 */
Datum
plllvm_pj_convert(PjCtx *ctx, Datum value, bool *isnull, Oid srctype,
				  int32 srctypmod, Oid dsttype, int32 dsttypmod)
{
	Expr	   *tree;
	ExprState  *state;
	ExprContext *econtext = plllvm_pj_level(ctx)->econtext;
	MemoryContext oldcxt;

	if (srctype == dsttype && (dsttypmod == -1 || srctypmod == dsttypmod))
		return value;

	plllvm_pj_cast_get(srctype, srctypmod, dsttype, dsttypmod, &tree);
	if (tree == NULL)
		return value;

	oldcxt = MemoryContextSwitchTo(econtext->ecxt_per_tuple_memory);
	state = ExecInitExpr(tree, NULL);
	econtext->caseValue_datum = value;
	econtext->caseValue_isNull = *isnull;
	value = ExecEvalExpr(state, econtext, isnull);
	MemoryContextSwitchTo(oldcxt);

	return value;
}
