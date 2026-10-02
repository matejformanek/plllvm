/*-------------------------------------------------------------------------
 *
 * plllvm_spi.c
 *
 *			  read-only SQL statements of PL/LLVM functions
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The handler connects only for functions whose IR declares a
 *    plllvm_spi_ function, and finishes only when the call returns.  After
 *    an ERROR the abort pops the level, as for PL/pgSQL.
 *
 * 2) A statement is prepared on first use in a backend and kept in a slot
 *    of the compiled module, and on the module's list, through the frame:
 *    it is freed with the code.
 *
 * 3) SPI leaves its procedure context current after each call; every
 *    function here switches back to the frame's scratch.  By-reference
 *    columns go to the frame's caller context, like PL/pgSQL's SELECT INTO
 *    targets.
 *
 * 4) SPI names the statement in the context of its own errors; the errors
 *    raised here name it too, in the same words.
 *
 */
#include "postgres.h"

#include "executor/spi.h"
#include "nodes/parsenodes.h"
#include "parser/parse_type.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/memutils.h"
#include "utils/plancache.h"

#include "plllvm.h"

typedef struct plllvm_spi_stmt
{
	SPIPlanPtr	plan;			/* SPI_keepplan'd */
	char	   *sql;			/* for errcontext */
	int			nargs;
	List	   *coltypes;		/* OIDs */
	struct plllvm_spi_stmt *next;	/* in the module's list */
} plllvm_spi_stmt;

static MemoryContext spi_cxt = NULL;
static int64 n_statements = 0;

static void stmt_error_callback(void *arg);
static List *type_list(const char *types);
static void type_error_callback(void *arg);
static void check_plain_select(SPIPlanPtr plan);
static void check_result(List *coltypes, TupleDesc tupdesc);

/*
 * The statement of a slot, prepared on first use.  argtypes and coltypes
 * are comma-separated type names, so that a dump restores the body as it
 * was written.
 */
void *
plllvm_spi_prepare(void **slot, const char *sql, const char *argtypes,
				   const char *coltypes)
{
	List	   *args;
	List	   *cols;
	Oid			argoids[FUNC_MAX_ARGS];
	SPIPlanPtr	plan;
	plllvm_spi_stmt *stmt;
	MemoryContext oldcxt;
	ErrorContextCallback errcallback;
	ListCell   *lc;
	int			i;

	if (*slot != NULL)
		return *slot;

	Assert(plllvm_cur_frame != NULL);

	errcallback.callback = stmt_error_callback;
	errcallback.arg = unconstify(char *, sql);
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	args = type_list(argtypes);
	if (list_length(args) > FUNC_MAX_ARGS)
		ereport(ERROR,
				(errcode(ERRCODE_TOO_MANY_ARGUMENTS),
				 errmsg("PL/LLVM statements cannot have more than %d parameters",
						FUNC_MAX_ARGS)));
	i = 0;
	foreach(lc, args)
		argoids[i++] = lfirst_oid(lc);
	cols = type_list(coltypes);

	error_context_stack = errcallback.previous;

	plan = SPI_prepare_cursor(sql, list_length(args), argoids,
							  CURSOR_OPT_PARALLEL_OK);
	MemoryContextSwitchTo(plllvm_cur_frame->scratch);
	if (plan == NULL)
		elog(ERROR, "SPI_prepare_cursor failed for \"%s\": %s",
			 sql, SPI_result_code_string(SPI_result));

	/* until SPI_keepplan, an ERROR leaves the plan to SPI_finish */
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;
	check_plain_select(plan);
	check_result(cols, ((CachedPlanSource *) linitial(SPI_plan_get_plan_sources(plan)))->resultDesc);
	error_context_stack = errcallback.previous;

	if (spi_cxt == NULL)
		spi_cxt = AllocSetContextCreate(TopMemoryContext,
										"plllvm - spi context",
										ALLOCSET_SMALL_SIZES);
	oldcxt = MemoryContextSwitchTo(spi_cxt);
	stmt = palloc(sizeof(plllvm_spi_stmt));
	stmt->sql = pstrdup(sql);
	stmt->nargs = list_length(args);
	stmt->coltypes = list_copy(cols);
	MemoryContextSwitchTo(oldcxt);

	/* cannot fail */
	SPI_keepplan(plan);
	stmt->plan = plan;
	stmt->next = *plllvm_cur_frame->stmts;
	*plllvm_cur_frame->stmts = stmt;
	*slot = stmt;
	n_statements++;

	return stmt;
}

/*
 * Run a prepared statement as a non-STRICT SELECT INTO: the first row into
 * out, or NULLs when there is none.  Returns the number of rows, 0 or 1.
 */
int32
plllvm_spi_select_into(FunctionCallInfo fcinfo, void *stmtp,
					   NullableDatum *args, NullableDatum *out)
{
	plllvm_function *func = (plllvm_function *) fcinfo->flinfo->fn_extra;
	plllvm_spi_stmt *stmt = (plllvm_spi_stmt *) stmtp;
	Datum		values[FUNC_MAX_ARGS];
	char		nulls[FUNC_MAX_ARGS];
	SPITupleTable *tuptable;
	uint64		processed;
	ErrorContextCallback errcallback;
	int			rc;

	if (func == NULL || func->magic != PLLLVM_FN_MAGIC || !func->uses_spi)
		elog(ERROR, "plllvm_spi_select_into called outside a PL/LLVM function");
	Assert(plllvm_cur_frame != NULL);

	for (int i = 0; i < stmt->nargs; i++)
	{
		values[i] = args[i].value;
		nulls[i] = args[i].isnull ? 'n' : ' ';
	}

	rc = SPI_execute_plan(stmt->plan, values, nulls, func->readonly, 1);
	MemoryContextSwitchTo(plllvm_cur_frame->scratch);
	if (rc != SPI_OK_SELECT)
		elog(ERROR, "SPI_execute_plan failed: %s", SPI_result_code_string(rc));

	/* taken at once: a nested SPI user changes them */
	tuptable = SPI_tuptable;
	processed = SPI_processed;

	/* a saved plan revalidates itself, its result may change */
	errcallback.callback = stmt_error_callback;
	errcallback.arg = stmt->sql;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;
	check_result(stmt->coltypes, tuptable->tupdesc);
	error_context_stack = errcallback.previous;

	for (int i = 0; i < list_length(stmt->coltypes); i++)
	{
		Form_pg_attribute attr = TupleDescAttr(tuptable->tupdesc, i);
		bool		isnull = true;
		Datum		value = (Datum) 0;

		if (processed > 0)
			value = SPI_getbinval(tuptable->vals[0], tuptable->tupdesc, i + 1,
								  &isnull);

		if (!isnull && !attr->attbyval)
		{
			if (attr->attlen == -1)
				value = plllvm_keep(value);
			else
			{
				MemoryContextSwitchTo(plllvm_cur_frame->caller_cxt);
				value = datumCopy(value, false, attr->attlen);
				MemoryContextSwitchTo(plllvm_cur_frame->scratch);
			}
		}
		out[i].value = value;
		out[i].isnull = isnull;
	}

	SPI_freetuptable(tuptable);

	return processed > 0 ? 1 : 0;
}

/* statements prepared in this backend */
int64
plllvm_spi_statements(void)
{
	return n_statements;
}

/*
 * Free a module's statements.  No call of the module runs, so none of them
 * is executing.
 */
void
plllvm_spi_free(plllvm_spi_stmt *stmts)
{
	while (stmts != NULL)
	{
		plllvm_spi_stmt *next = stmts->next;

		SPI_freeplan(stmts->plan);
		pfree(stmts->sql);
		list_free(stmts->coltypes);
		pfree(stmts);
		stmts = next;
	}
}

static void
stmt_error_callback(void *arg)
{
	errcontext("SQL statement \"%s\"", (const char *) arg);
}

/*
 * The OIDs of a comma-separated list of type names.  Commas inside
 * parentheses do not separate, so that numeric(5,2) is refused as one name:
 * a typmod would not be applied to the values.
 */
static List *
type_list(const char *types)
{
	List	   *result = NIL;
	const char *p = types;

	while (*p != '\0')
	{
		const char *start = p;
		int			depth = 0;
		char	   *name;
		Oid			typid;
		int32		typmod;
		ErrorContextCallback errcallback;

		while (*p != '\0' && (*p != ',' || depth > 0))
		{
			if (*p == '(')
				depth++;
			else if (*p == ')')
				depth--;
			p++;
		}

		name = pnstrdup(start, p - start);
		errcallback.callback = type_error_callback;
		errcallback.arg = name;
		errcallback.previous = error_context_stack;
		error_context_stack = &errcallback;
		parseTypeString(name, &typid, &typmod, NULL);
		error_context_stack = errcallback.previous;
		if (typmod != -1)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/LLVM statement types cannot have type modifiers"),
					 errhint("Cast in the statement, e.g. $1::numeric(5,2).")));
		result = lappend_oid(result, typid);
		pfree(name);

		if (*p == ',')
			p++;
	}

	return result;
}

/* a syntax error points into the type name, not into the caller's query */
static void
type_error_callback(void *arg)
{
	int			pos = geterrposition();

	if (pos > 0)
	{
		errposition(0);
		internalerrposition(pos);
		internalerrquery((const char *) arg);
	}
}

/*
 * One SELECT that returns rows and locks nothing.  SPI checks this only for
 * read_only, and only by the plan.  Functions the statement calls are not
 * restricted.
 */
static void
check_plain_select(SPIPlanPtr plan)
{
	List	   *plansources = SPI_plan_get_plan_sources(plan);
	CachedPlanSource *plansource;
	ListCell   *lc;

	if (list_length(plansources) != 1)
		goto refuse;

	plansource = (CachedPlanSource *) linitial(plansources);
	if (plansource->commandTag != CMDTAG_SELECT ||
		plansource->resultDesc == NULL)
		goto refuse;

	foreach(lc, plansource->query_list)
	{
		Query	   *query = lfirst_node(Query, lc);

		if (query->commandType != CMD_SELECT || query->hasModifyingCTE ||
			query->rowMarks != NIL)
			goto refuse;
	}

	return;

refuse:
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("PL/LLVM supports only plain SELECT statements")));
}

/* so that IR never reads a Datum as another type than it declared */
static void
check_result(List *coltypes, TupleDesc tupdesc)
{
	if (tupdesc->natts != list_length(coltypes))
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("PL/LLVM statement result does not match its declaration"),
				 errdetail("The statement returns %d columns, its declaration has %d.",
						   tupdesc->natts, list_length(coltypes))));

	for (int i = 0; i < tupdesc->natts; i++)
	{
		Oid			atttypid = TupleDescAttr(tupdesc, i)->atttypid;

		if (atttypid != list_nth_oid(coltypes, i))
			ereport(ERROR,
					(errcode(ERRCODE_DATATYPE_MISMATCH),
					 errmsg("PL/LLVM statement result does not match its declaration"),
					 errdetail("Column %d has type %s, %s was declared.",
							   i + 1, format_type_be(atttypid),
							   format_type_be(list_nth_oid(coltypes, i)))));
	}
}
