/*-------------------------------------------------------------------------
 *
 * plllvm_pj.c
 *
 *			  the call handler of LANGUAGE plpgsql_jit
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The language has PL/pgSQL's syntax and PL/pgSQL's compiler: the
 *    handler calls plpgsql_compile() and keeps a side entry per compiled
 *    function, in its own hash table, because fn_extra belongs to PL/pgSQL
 *    (plpgsql_call_handler reads it back as a PLpgSQL_function).  Nothing
 *    here compiles to LLVM yet: every call goes to plpgsql_call_handler
 *    with the same fcinfo, so the results, errors and CONTEXT lines are
 *    PL/pgSQL's.  The inline handler and the validator of the language are
 *    PL/pgSQL's own (plllvm--0.3.sql).
 *
 * 2) plpgsql_compile() and plpgsql_call_handler() are looked up in the
 *    plpgsql library when the first call comes, as plpgsql_check does.
 *    plpgsql_compile() uses no SPI (pl_comp.c has no SPI_ call), so the
 *    handler needs no SPI connection of its own.
 *
 * 3) An entry is valid while the function's memory context lives: funccache
 *    reuses the PLpgSQL_function of a replaced function in place, so the
 *    pointer alone does not tell.  A reset callback on fn_cxt (PL/pgSQL
 *    deletes it when the function goes stale, and only with no call
 *    running, funccache.c delete_function) marks the entry stale, and the
 *    next lookup of that pointer starts a new one.
 *
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"
#include "plpgsql.h"
#include "utils/hsearch.h"
#include "utils/memutils.h"

#include "plllvm.h"
#include "plllvm_pj.h"

#define REASON_NOT_IMPLEMENTED	"not implemented"

typedef PLpgSQL_function *(*plpgsql_compile_t) (FunctionCallInfo fcinfo,
												bool forValidator);
typedef Datum (*plpgsql_call_handler_t) (PG_FUNCTION_ARGS);

StaticAssertVariableIsOfType(&plpgsql_compile, plpgsql_compile_t);

typedef enum PjState
{
	PJ_NEW,						/* compiled by PL/pgSQL, not called yet */
	PJ_SEEN,					/* called once, so its expressions are planned */
	PJ_DECLINED					/* runs in PL/pgSQL for good */
} PjState;

typedef struct PjEntry
{
	PLpgSQL_function *func;		/* hash key */
	bool		stale;			/* true, when fn_cxt is gone */
	PjState		state;
	const char *reason;			/* when declined */
	const char *last_path;
	Oid			fn_oid;
	Oid			collation;
	char	   *signature;		/* in fn_cxt */
	int64		calls;
	TransactionId fn_xmin;		/* only for an Assert */
	ItemPointerData fn_tid;
} PjEntry;

plllvm_pj_counters plllvm_pj_count;

static HTAB *entries = NULL;
static plpgsql_compile_t compile_p = NULL;
static plpgsql_call_handler_t call_handler_p = NULL;

PG_FUNCTION_INFO_V1(plllvm_pj_call_handler);

static void load_plpgsql(void);
static PjEntry *entry_get(PLpgSQL_function *func);
static void entry_reset_callback(void *arg);
static Datum fall_back(FunctionCallInfo fcinfo, PjEntry *e);

Datum
plllvm_pj_call_handler(PG_FUNCTION_ARGS)
{
	PLpgSQL_function *func;
	PjEntry    *e = NULL;

	load_plpgsql();

	if (!plllvm_plpgsql_jit)
		return fall_back(fcinfo, NULL);

	/*
	 * A declined function skips our own plpgsql_compile(), which costs a
	 * pg_proc lookup.  fn_extra is only compared here, never followed: it may
	 * be a function that has been freed since.
	 */
	if (fcinfo->flinfo->fn_extra != NULL && entries != NULL)
	{
		void	   *key = fcinfo->flinfo->fn_extra;

		e = hash_search(entries, &key, HASH_FIND, NULL);
		if (e != NULL && !e->stale && e->state == PJ_DECLINED)
		{
			plllvm_pj_count.declines++;
			return fall_back(fcinfo, e);
		}
	}

	check_stack_depth();
	func = compile_p(fcinfo, false);
	e = entry_get(func);

	switch (e->state)
	{
		case PJ_NEW:
			e->state = PJ_SEEN;
			e->last_path = "interpreted:first call";
			break;
		case PJ_SEEN:
			e->state = PJ_DECLINED;
			e->reason = REASON_NOT_IMPLEMENTED;
			e->last_path = "declined:" REASON_NOT_IMPLEMENTED;
			plllvm_pj_count.declines++;
			break;
		case PJ_DECLINED:
			plllvm_pj_count.declines++;
			break;
	}

	return fall_back(fcinfo, e);
}

/*
 * plpgsql_compile() left the function in fn_extra, so the compile in
 * plpgsql_call_handler() finds it at once
 */
static Datum
fall_back(FunctionCallInfo fcinfo, PjEntry *e)
{
	plllvm_pj_count.calls++;
	plllvm_pj_count.interpreted_calls++;
	if (e != NULL)
		e->calls++;

	return call_handler_p(fcinfo);
}

static void
load_plpgsql(void)
{
	if (call_handler_p != NULL)
		return;

	compile_p = (plpgsql_compile_t)
		load_external_function("$libdir/plpgsql", "plpgsql_compile", true, NULL);
	call_handler_p = (plpgsql_call_handler_t)
		load_external_function("$libdir/plpgsql", "plpgsql_call_handler", true, NULL);
}

/*
 * The entry of func, a new one if there is none or its function went stale
 */
static PjEntry *
entry_get(PLpgSQL_function *func)
{
	PjEntry    *e;
	bool		found;
	MemoryContextCallback *cb;

	if (entries == NULL)
	{
		HASHCTL		ctl = {0};

		ctl.keysize = sizeof(PLpgSQL_function *);
		ctl.entrysize = sizeof(PjEntry);
		ctl.hcxt = AllocSetContextCreate(TopMemoryContext,
										 "plllvm - plpgsql_jit entries context",
										 ALLOCSET_DEFAULT_SIZES);
		entries = hash_create("plllvm plpgsql_jit entries", 64, &ctl,
							  HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);
	}

	e = hash_search(entries, &func, HASH_ENTER, &found);
	if (found && !e->stale)
	{
		Assert(e->fn_xmin == func->cfunc.fn_xmin &&
			   ItemPointerEquals(&e->fn_tid, &func->cfunc.fn_tid));
		return e;
	}

	memset(e, 0, sizeof(PjEntry));
	e->func = func;
	e->state = PJ_NEW;
	e->fn_oid = func->fn_oid;
	e->collation = func->fn_input_collation;
	e->signature = func->fn_signature;
	e->fn_xmin = func->cfunc.fn_xmin;
	e->fn_tid = func->cfunc.fn_tid;

	cb = MemoryContextAlloc(func->fn_cxt, sizeof(MemoryContextCallback));
	cb->func = entry_reset_callback;
	cb->arg = e;
	MemoryContextRegisterResetCallback(func->fn_cxt, cb);

	return e;
}

static void
entry_reset_callback(void *arg)
{
	((PjEntry *) arg)->stale = true;
}

/*
 * The live entries of function fn, as plain records for plllvm_pj_status()
 */
int
plllvm_pj_infos(Oid fn, plllvm_pj_info **infos)
{
	HASH_SEQ_STATUS seq;
	PjEntry    *e;
	int			n = 0;

	*infos = NULL;
	if (entries == NULL)
		return 0;

	*infos = palloc(sizeof(plllvm_pj_info) * hash_get_num_entries(entries));

	hash_seq_init(&seq, entries);
	while ((e = hash_seq_search(&seq)) != NULL)
	{
		plllvm_pj_info *info = &(*infos)[n];

		if (e->stale || e->fn_oid != fn)
			continue;

		info->signature = pstrdup(e->signature);
		info->collation = e->collation;
		info->state = e->state == PJ_NEW ? "new" :
			e->state == PJ_SEEN ? "seen" : "declined";
		info->reason = e->reason;
		info->calls = e->calls;
		info->last_path = e->last_path;
		n++;
	}

	return n;
}
