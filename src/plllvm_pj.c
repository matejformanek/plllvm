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
 * 1) The side entry of each function lives in our own hash table, because
 *    fn_extra belongs to PL/pgSQL: plpgsql_call_handler reads it back as a
 *    PLpgSQL_function.
 *
 * 2) funccache reuses the PLpgSQL_function of a replaced function in place,
 *    so the pointer alone does not identify an entry.  A reset callback on
 *    fn_cxt, which PL/pgSQL deletes when the function goes stale and only
 *    with no call running, marks the entry stale; the next lookup of that
 *    pointer starts a new one.
 *
 * The rest is in docs/architecture.md.
 *
 */
#include "postgres.h"

#include "access/xact.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_proc.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "plpgsql.h"
#include "portability/instr_time.h"
#include "storage/proc.h"
#include "utils/acl.h"
#include "utils/datum.h"
#include "utils/hsearch.h"
#include "utils/inval.h"
#include "utils/memutils.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_pj.h"

/* invalidations of what EXECUTE depends on; see execute_allowed() */
static uint64 exec_epoch = 0;

/* of the compiled calls, for the levels of boxed expressions */
static uint64 call_serial = 0;

/* guard misses before a function is declined as thrashing */
#define PJ_MAX_MISSES		8
/* compiled calls after which the misses are forgotten */
#define PJ_MISS_FORGET		1000

typedef PLpgSQL_function *(*plpgsql_compile_t) (FunctionCallInfo fcinfo,
												bool forValidator);
typedef Datum (*plpgsql_call_handler_t) (PG_FUNCTION_ARGS);
typedef const char *(*plpgsql_stmt_typename_t) (PLpgSQL_stmt *stmt);

StaticAssertVariableIsOfType(&plpgsql_compile, plpgsql_compile_t);
StaticAssertVariableIsOfType(&plpgsql_stmt_typename, plpgsql_stmt_typename_t);

typedef enum PjState
{
	PJ_NEW,						/* compiled by PL/pgSQL, not called yet */
	PJ_SEEN,					/* called once, expressions planned */
	PJ_COMPILED,				/* has a harvest */
	PJ_DECLINED					/* runs in PL/pgSQL for good */
} PjState;

typedef struct PjEntry
{
	PLpgSQL_function *func;		/* hash key */
	PjCtx	   *top;			/* innermost compiled frame */
	bool		stale;			/* true, when fn_cxt is gone */
	PjState		state;
	const char *reason;			/* when declined */
	const char *last_path;
	char	   *declined_path;	/* "declined:" and the reason */
	Oid			fn_oid;
	Oid			collation;
	char	   *signature;		/* in fn_cxt */
	int64		calls;
	int64		compiled_calls;
	int64		deopts;
	int64		guard_misses;
	int64		translations;
	PjHarvest  *harvest;
	int			frames;			/* compiled calls running */
	bool		waiting;		/* see translate_guarded() */
	int			misses;			/* guard misses since the last reset */
	int64		since_translation;	/* compiled calls since the last
									 * translation */
	int			deopt_expr;		/* expression of the last deopt, or -1 */
	TransactionId fn_xmin;		/* only for an Assert */
	ItemPointerData fn_tid;
} PjEntry;

typedef enum PjMay
{
	PJ_MAY,
	PJ_MAY_NOT,					/* a frame runs, or no subtransaction is
								 * possible */
	PJ_MAY_CAPPED
} PjMay;

/* what the error callback reads */
typedef struct PjErrArg
{
	PLpgSQL_function *func;
	PjHarvest  *harvest;
	PjCtx	   *ctx;
} PjErrArg;

plllvm_pj_counters plllvm_pj_count;

static HTAB *entries = NULL;
static MemoryContext pj_cxt = NULL;
static plpgsql_compile_t compile_p = NULL;
static plpgsql_call_handler_t call_handler_p = NULL;
static plpgsql_stmt_typename_t stmt_typename_p = NULL;

PG_FUNCTION_INFO_V1(plllvm_pj_call_handler);

static void load_plpgsql(void);
static PjEntry *entry_get(PLpgSQL_function *func);
static void entry_reset_callback(void *arg);
static Datum fall_back(FunctionCallInfo fcinfo, PjEntry *e, const char *path);
static PjMay may_translate(PLpgSQL_function *func, PjEntry *e,
						   bool replacing);
static bool seen_step(PLpgSQL_function *func, PjEntry *e);
static bool translate_guarded(PLpgSQL_function *func, PjEntry *e,
							  PjScope *scope);
static bool variant_guarded(PLpgSQL_function *func, PjEntry *e);
static Datum run_compiled(PLpgSQL_function *func, FunctionCallInfo fcinfo,
						  PjEntry *e);
static Datum wait_step(PLpgSQL_function *func, FunctionCallInfo fcinfo,
					   PjEntry *e);
static Datum run(PLpgSQL_function *func, FunctionCallInfo fcinfo, PjEntry *e,
				 PjVariant *v);
static void activation_end(PLpgSQL_function *func, PjEntry *e,
						   MemoryContext entry_cxt);
static void exec_error_callback(void *arg);
static bool guards_ok(PjHarvest *h);
static bool execute_allowed(PjEntry *e);
static void pj_mark_busy(PjEntry *e);
static Datum interp(FunctionCallInfo fcinfo, PjEntry *e);
static void pj_mark_running(PjCtx *ctx);
static PLpgSQL_expr *pj_frame_expr(PjCtx *ctx);
static bool pj_outer_runs(PjCtx *ctx, PLpgSQL_expr *expr);
static bool pj_any_in_use(PjEntry *e);
static PjVariant *variant_find(PjHarvest *h);
static void decline(PjEntry *e, const char *reason);
static void decline_idle(PjEntry *e, const char *reason);
static void release_harvest(PjEntry *e);
static void pj_init(void);
static void exec_inval_callback(Datum arg, int cacheid, uint32 hashvalue);

Datum
plllvm_pj_call_handler(PG_FUNCTION_ARGS)
{
	PLpgSQL_function *func;
	PjEntry    *e = NULL;

	load_plpgsql();
	plllvm_pj_count.calls++;

	if (!plllvm_plpgsql_jit)
		return fall_back(fcinfo, NULL, NULL);

	if (plllvm_plpgsql_foreign_plugin())
	{
		plllvm_pj_count.plugin_fallbacks++;
		return fall_back(fcinfo, NULL, NULL);
	}

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
			return fall_back(fcinfo, e, e->declined_path);
		}
	}

	check_stack_depth();
	func = compile_p(fcinfo, false);
	e = entry_get(func);

	switch (e->state)
	{
		case PJ_NEW:
			e->state = PJ_SEEN;
			return fall_back(fcinfo, e, "interpreted:first call");
		case PJ_DECLINED:
			plllvm_pj_count.declines++;
			return fall_back(fcinfo, e, e->declined_path);
		case PJ_SEEN:
			if (!seen_step(func, e))
				return fall_back(fcinfo, e, e->last_path);
			break;
		case PJ_COMPILED:
			break;
	}

	return run_compiled(func, fcinfo, e);
}

/*
 * plpgsql_compile() left the function in fn_extra, so the compile in
 * plpgsql_call_handler() finds it at once
 */
static Datum
fall_back(FunctionCallInfo fcinfo, PjEntry *e, const char *path)
{
	plllvm_pj_count.interpreted_calls++;
	if (e != NULL)
	{
		e->calls++;
		e->last_path = path;
	}

	return interp(fcinfo, e);
}

static void
load_plpgsql(void)
{
	const char *lib = "$libdir/plpgsql";

	if (call_handler_p != NULL)
		return;

	compile_p = (plpgsql_compile_t)
		load_external_function(lib, "plpgsql_compile", true, NULL);
	stmt_typename_p = (plpgsql_stmt_typename_t)
		load_external_function(lib, "plpgsql_stmt_typename", true, NULL);
	call_handler_p = (plpgsql_call_handler_t)
		load_external_function(lib, "plpgsql_call_handler", true, NULL);
}

const char *
plllvm_pj_stmt_typename(void *stmt)
{
	return stmt_typename_p((PLpgSQL_stmt *) stmt);
}

static void
pj_init(void)
{
	HASHCTL		ctl = {0};

	Assert(entries == NULL);

	pj_cxt = AllocSetContextCreate(TopMemoryContext,
								   "plllvm - pj entries context",
								   ALLOCSET_DEFAULT_SIZES);
	ctl.keysize = sizeof(PLpgSQL_function *);
	ctl.entrysize = sizeof(PjEntry);
	ctl.hcxt = pj_cxt;
	entries = hash_create("plllvm plpgsql_jit entries", 64, &ctl,
						  HASH_ELEM | HASH_BLOBS | HASH_CONTEXT);

	CacheRegisterSyscacheCallback(PROCOID, exec_inval_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(AUTHMEMROLEMEM, exec_inval_callback,
								  (Datum) 0);
	CacheRegisterSyscacheCallback(AUTHOID, exec_inval_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(DATABASEOID, exec_inval_callback, (Datum) 0);
}

static void
exec_inval_callback(Datum arg, int cacheid, uint32 hashvalue)
{
	exec_epoch++;
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
		pj_init();

	e = hash_search(entries, &func, HASH_ENTER, &found);
	if (found && !e->stale)
	{
		Assert(e->fn_xmin == func->cfunc.fn_xmin &&
			   ItemPointerEquals(&e->fn_tid, &func->cfunc.fn_tid));
		return e;
	}

	/* a stale entry has no frames: fn_cxt goes only at use_count == 0 */
	if (found)
		release_harvest(e);

	memset(e, 0, sizeof(PjEntry));
	e->func = func;
	e->state = PJ_NEW;
	e->deopt_expr = -1;
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
 * Translate, re-translate and release only with no frame of the function on
 * the stack, so that no code or tree is replaced under a running call.  Not
 * in parallel mode (the subtransaction's commit raises there), and not while
 * interrupts are held, as under a btree page lock, which a subtransaction
 * abort would release.  A translation that replaces the harvest of the entry
 * gives its code back, so that code does not count against the cap.
 */
static PjMay
may_translate(PLpgSQL_function *func, PjEntry *e, bool replacing)
{
	int64		own = 0;

	if (func->cfunc.use_count != 0 || IsInParallelMode() ||
		InterruptHoldoffCount != 0)
		return PJ_MAY_NOT;

	if (replacing && e->harvest != NULL)
	{
		for (PjVariant *v = e->harvest->variants; v != NULL; v = v->next)
			own += (v->mod != NULL);
	}

	if (plllvm_jit_pj_resident() - own >= plllvm_max_resident_compiles)
	{
		plllvm_pj_count.capped++;
		return PJ_MAY_CAPPED;
	}

	return PJ_MAY;
}

/*
 * The second call of a function: translate it if it is in scope and has
 * something to compile.  Returns true when the entry is COMPILED, else
 * e->last_path says why not.
 */
static bool
seen_step(PLpgSQL_function *func, PjEntry *e)
{
	PjScope		scope;

	switch (may_translate(func, e, true))
	{
		case PJ_MAY_NOT:
			e->last_path = "interpreted:busy";
			return false;
		case PJ_MAY_CAPPED:
			e->last_path = "interpreted:capped";
			return false;
		case PJ_MAY:
			break;
	}

	plllvm_pj_scope(func, &scope);
	if (scope.reason != NULL)
	{
		decline_idle(e, scope.reason);
		return false;
	}

	plllvm_pj_classify(&scope);
	if (scope.nnotsimple > 0)
	{
		decline_idle(e, "not simple");
		return false;
	}

	/* planned on the interpreter's next run; waiting costs the pre-check */
	if (scope.nready == 0 && scope.nunplanned > 0)
	{
		e->last_path = "interpreted:unplanned";
		return false;
	}
	if (e->waiting && scope.nunplanned > 0)
	{
		e->last_path = "waiting";
		return false;
	}

	/*
	 * After a deopt, only once the expression is planned: a plan that fails
	 * would loop through LLVM.
	 */
	if (e->deopt_expr >= 0)
	{
		PjExpr	   *pe = list_nth(scope.exprs, e->deopt_expr);

		if (pe->h1 != PJ_H1_READY)
		{
			e->last_path = "interpreted:unplanned";
			return false;
		}
		e->deopt_expr = -1;
	}

	return translate_guarded(func, e, &scope);
}

/* what a translation builds, for build_in_subxact() */
typedef struct PjBuild
{
	PLpgSQL_function *func;
	const PjScope *scope;		/* NULL: add the variant to the harvest */
	PjHarvest  *harvest;
	PjVariant  *variant;
	MemoryContext tmp;			/* holds the harvest until it is published */
	const char *reason;			/* why the function is declined, or NULL */
	PjEmitResult emitted;
} PjBuild;

static void
build_run(PjBuild *b)
{
	if (plllvm_debug_inject == PLLLVM_INJECT_TRANSLATE_CANCEL)
		ereport(ERROR,
				(errcode(ERRCODE_QUERY_CANCELED),
				 errmsg("canceling statement due to user request")));

	if (b->scope != NULL)
	{
		MemoryContext cxt = AllocSetContextCreate(b->tmp,
												  "plllvm - pj harvest context",
												  ALLOCSET_DEFAULT_SIZES);

		b->harvest = MemoryContextAllocZero(cxt, sizeof(PjHarvest));
		b->harvest->cxt = cxt;
		b->reason = plllvm_pj_harvest(b->func, b->scope, b->harvest);
		if (b->reason != NULL)
			return;

		b->variant = MemoryContextAllocZero(cxt, sizeof(PjVariant));
		b->variant->opt_level = plllvm_pj_opt_level;
		b->variant->codegen = plllvm_pj_codegen;
	}

	b->emitted = plllvm_pj_emit(b->func, b->harvest, b->variant);
}

/*
 * Run build_run() in a subtransaction: whatever goes wrong there is rolled
 * back, and returned as an ErrorData (a cancel is raised again).  b->tmp
 * is for the caller to delete, once it has taken what it keeps.
 */
static ErrorData *
build_in_subxact(PjBuild *b)
{
	MemoryContext oldcxt = CurrentMemoryContext;
	ResourceOwner oldowner = CurrentResourceOwner;
	ErrorData  *volatile edata = NULL;

	b->tmp = AllocSetContextCreate(oldcxt, "plllvm - pj translate",
								   ALLOCSET_DEFAULT_SIZES);

	PG_TRY();
	{
		BeginInternalSubTransaction(NULL);
		MemoryContextSwitchTo(b->tmp);
		build_run(b);
		ReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;
	}
	PG_CATCH();
	{
		MemoryContextSwitchTo(oldcxt);
		edata = CopyErrorData();
		FlushErrorState();

		RollbackAndReleaseCurrentSubTransaction();
		MemoryContextSwitchTo(oldcxt);
		CurrentResourceOwner = oldowner;

		if (b->variant != NULL && b->variant->mod != NULL)
		{
			plllvm_jit_release(b->variant->mod);
			b->variant->mod = NULL;
		}
		MemoryContextDelete(b->tmp);
		b->tmp = NULL;

		if (edata->sqlerrcode == ERRCODE_QUERY_CANCELED)
			ReThrowError(edata);
	}
	PG_END_TRY();

	return edata;
}

/*
 * Translate a function whose expressions are planned.  Everything that stays
 * is built in a temporary context and published last.
 */
static bool
translate_guarded(PLpgSQL_function *func, PjEntry *e, PjScope *scope)
{
	PjBuild		b = {func, scope};
	ErrorData  *edata;
	instr_time	start;
	instr_time	elapsed;

	plllvm_pj_count.attempts++;
	INSTR_TIME_SET_CURRENT(start);

	/*
	 * The old code goes first: it counts against the cap until released, and
	 * nothing runs it, as no frame of the function is on the stack.
	 */
	release_harvest(e);

	edata = build_in_subxact(&b);
	if (edata != NULL)
	{
		plllvm_pj_count.failures++;
		decline_idle(e, psprintf("%s: %s", unpack_sql_state(edata->sqlerrcode),
								 edata->message));
		FreeErrorData(edata);
		return false;
	}

	if (b.reason != NULL)
		decline_idle(e, b.reason);
	else if (b.emitted == PJ_EMIT_CAPPED)
	{
		plllvm_pj_count.capped++;
		e->last_path = "interpreted:capped";
	}
	else if (b.emitted == PJ_EMIT_WAITING)
	{
		/*
		 * Code that runs the executor cannot give a call back to the
		 * interpreter, and an unplanned expression is one it could not
		 * evaluate: the calls stay interpreted until all are planned.
		 */
		e->waiting = true;
		e->last_path = "waiting";
	}
	else
	{
		e->waiting = false;
		INSTR_TIME_SET_CURRENT(elapsed);
		INSTR_TIME_SUBTRACT(elapsed, start);
		b.variant->translate_ms = INSTR_TIME_GET_MILLISEC(elapsed);
		b.variant->mod->translate_ms = b.variant->translate_ms;

		/* nothing below raises an ERROR */
		b.variant->next = b.harvest->variants;
		b.harvest->variants = b.variant;
		MemoryContextSetParent(b.harvest->cxt, pj_cxt);
		e->harvest = b.harvest;
		e->state = PJ_COMPILED;
		e->translations++;
		e->since_translation = 0;
		plllvm_pj_count.translations++;
	}

	MemoryContextDelete(b.tmp);
	return e->state == PJ_COMPILED;
}

/*
 * A harvest without the variant the session's options ask for.  A failure
 * marks the variant, the others keep running.
 */
static bool
variant_guarded(PLpgSQL_function *func, PjEntry *e)
{
	PjHarvest  *h = e->harvest;
	PjVariant  *v = MemoryContextAllocZero(h->cxt, sizeof(PjVariant));
	PjBuild		b = {func, NULL, h, v};
	ErrorData  *edata;
	instr_time	start;
	instr_time	elapsed;

	v->opt_level = plllvm_pj_opt_level;
	v->codegen = plllvm_pj_codegen;
	plllvm_pj_count.attempts++;
	INSTR_TIME_SET_CURRENT(start);

	edata = build_in_subxact(&b);
	if (edata != NULL)
	{
		plllvm_pj_count.failures++;
		v->failed = true;
		v->next = h->variants;
		h->variants = v;
		e->last_path = "interpreted:failed";
		FreeErrorData(edata);
		return false;
	}

	MemoryContextDelete(b.tmp);

	if (b.emitted == PJ_EMIT_CAPPED)
	{
		/* not kept: retried at the next call */
		plllvm_pj_count.capped++;
		pfree(v);
		e->last_path = "interpreted:capped";
		return false;
	}
	if (b.emitted == PJ_EMIT_WAITING)
	{
		v->waiting = true;
		v->next = h->variants;
		h->variants = v;
		e->last_path = "waiting";
		return false;
	}

	INSTR_TIME_SET_CURRENT(elapsed);
	INSTR_TIME_SUBTRACT(elapsed, start);
	v->translate_ms = INSTR_TIME_GET_MILLISEC(elapsed);
	v->mod->translate_ms = v->translate_ms;
	v->next = h->variants;
	h->variants = v;
	e->translations++;
	plllvm_pj_count.translations++;

	return true;
}

static Datum
run_compiled(PLpgSQL_function *func, FunctionCallInfo fcinfo, PjEntry *e)
{
	PjHarvest  *h = e->harvest;
	PjVariant  *v;

	/* NULLs are what the interpreter does best, and nothing has run yet */
	for (int i = 0; i < fcinfo->nargs; i++)
	{
		if (fcinfo->args[i].isnull)
		{
			plllvm_pj_count.null_args++;
			return fall_back(fcinfo, e, "interpreted:null arg");
		}
	}

	if (!guards_ok(h))
	{
		plllvm_pj_count.guard_misses++;
		e->guard_misses++;
		if (e->since_translation >= PJ_MISS_FORGET)
			e->misses = 0;
		if (++e->misses >= PJ_MAX_MISSES)
		{
			if (func->cfunc.use_count == 0)
				decline_idle(e, "thrash");
			else
				decline(e, "thrash");
		}
		else
			e->state = PJ_SEEN;
		return fall_back(fcinfo, e, e->state == PJ_DECLINED ?
						 e->declined_path : "interpreted:guard miss");
	}

	v = variant_find(h);
	if (v == NULL)
	{
		switch (may_translate(func, e, false))
		{
			case PJ_MAY_NOT:
				return fall_back(fcinfo, e, "interpreted:busy");
			case PJ_MAY_CAPPED:
				return fall_back(fcinfo, e, "interpreted:capped");
			case PJ_MAY:
				break;
		}
		if (!variant_guarded(func, e))
			return fall_back(fcinfo, e, e->last_path);
		v = variant_find(h);
	}

	if (v->failed)
		return fall_back(fcinfo, e, "interpreted:failed");

	if (v->waiting)
		return wait_step(func, fcinfo, e);

	/*
	 * an expression in use takes PL/pgSQL's SPI path, which plans differently
	 */
	if (pj_any_in_use(e))
		return fall_back(fcinfo, e, "interpreted:in use");

	if (!execute_allowed(e))
		return fall_back(fcinfo, e, "interpreted:execute");

	return run(func, fcinfo, e, v);
}

/* a variant waiting for plans: translate again once none is missing */
static Datum
wait_step(PLpgSQL_function *func, FunctionCallInfo fcinfo, PjEntry *e)
{
	PjScope		scope;

	plllvm_pj_scope(func, &scope);
	plllvm_pj_classify(&scope);
	if (scope.nunplanned == 0)
	{
		e->state = PJ_SEEN;
		return fall_back(fcinfo, e, "interpreted:replan");
	}

	return fall_back(fcinfo, e, "waiting");
}

/*
 * Run the code of a variant.  The activation holds use_count, as PL/pgSQL's
 * handler does: funccache then forgets a running function instead of
 * freeing it.
 */
static Datum
run(PLpgSQL_function *func, FunctionCallInfo fcinfo, PjEntry *e, PjVariant *v)
{
	MemoryContext entry_cxt = CurrentMemoryContext;
	PjCtx		ctx = {0};
	PjErrArg	arg;
	ErrorContextCallback errcallback;
	volatile Datum retval = (Datum) 0;

	arg.func = func;
	arg.harvest = e->harvest;
	arg.ctx = &ctx;

	func->cfunc.use_count++;
	e->frames++;
	ctx.outer = e->top;
	e->top = &ctx;
	ctx.level = func->cfunc.use_count - 1;
	ctx.serial = ++call_serial;
	ctx.user = e->harvest->key_user;
	ctx.epoch = e->harvest->key_epoch;
	ctx.variant = v;
	ctx.harvest = e->harvest;
	errcallback.callback = exec_error_callback;
	errcallback.arg = &arg;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	PG_TRY();
	{
		retval = v->code(fcinfo, &ctx);

		/* code that ran the executor was not given a deopt point */
		if (ctx.deopt != 0 && ctx.evaluated)
			elog(ERROR, "plpgsql_jit: deopt after the executor ran");

		/* the result lives in memory of the code's own */
		if (ctx.deopt == 0 && !fcinfo->isnull && !func->fn_retbyval)
			retval = datumCopy(retval, false, func->fn_rettyplen);
	}
	PG_CATCH();
	{
		e->top = ctx.outer;
		plllvm_pj_count.compiled_calls++;
		e->compiled_calls++;
		e->calls++;
		e->last_path = "compiled";

		/*
		 * Leave the expression the error stopped as an interpreted failure
		 * would: its next evaluation takes the path that checks EXECUTE.
		 * Without positions, mark them all.  The cast of the code cannot
		 * fail, so PL/pgSQL's cast state needs no mark.
		 */
		MemoryContextSwitchTo(entry_cxt);
		plllvm_pj_level_abort(&ctx);
		if (v->codegen == PLLLVM_PJ_NOPOS)
			pj_mark_busy(e);
		else
			pj_mark_running(&ctx);
		activation_end(func, e, entry_cxt);
		PG_RE_THROW();
	}
	PG_END_TRY();

	error_context_stack = errcallback.previous;
	e->top = ctx.outer;

	if (ctx.deopt != 0)
	{
		plllvm_pj_count.deopts++;
		e->deopts++;
		e->last_path = "deopt";
		e->deopt_expr = ctx.deopt - 1;
		e->state = PJ_SEEN;
		e->calls++;
		activation_end(func, e, entry_cxt);
		return interp(fcinfo, e);
	}

	plllvm_pj_count.compiled_calls++;
	e->compiled_calls++;
	e->since_translation++;
	e->calls++;
	e->last_path = "compiled";
	activation_end(func, e, entry_cxt);

	return retval;
}

/*
 * Must not fail: it runs while an ERROR is being handled
 */
static void
activation_end(PLpgSQL_function *func, PjEntry *e, MemoryContext entry_cxt)
{
	MemoryContextSwitchTo(entry_cxt);
	func->cfunc.use_count--;
	e->frames--;

	/* funccache forgot a running function: its last frame lets go of us */
	if (func->cfunc.use_count == 0 && func->cfunc.fn_hashkey == NULL)
	{
		release_harvest(e);
		e->stale = true;
	}
}

/*
 * The context of the activity, as plpgsql_exec_error_callback() reports it
 */
static void
exec_error_callback(void *arg)
{
	PjErrArg   *a = (PjErrArg *) arg;
	const PjPos *pos = &a->harvest->pos[a->ctx->pos];
	const char *signature = a->func->fn_signature;

	set_errcontext_domain(PG_TEXTDOMAIN("plpgsql"));

	if (pos->text != NULL && pos->lineno > 0)
		errcontext("PL/pgSQL function %s line %d %s", signature, pos->lineno,
				   dgettext(PG_TEXTDOMAIN("plpgsql"), pos->text));
	else if (pos->text != NULL)
		errcontext("PL/pgSQL function %s %s", signature,
				   dgettext(PG_TEXTDOMAIN("plpgsql"), pos->text));
	else if (pos->stmt != NULL && pos->lineno > 0)
		errcontext("PL/pgSQL function %s line %d at %s", signature,
				   pos->lineno, pos->stmt);
	else
		errcontext("PL/pgSQL function %s", signature);
}

/*
 * Are the plans the code was made from still the interpreter's?  A shared
 * plansource needs the generation too (plancache.c).  The cast trees are
 * ours: valid while the cached expression is.
 */
static bool
guards_ok(PjHarvest *h)
{
	foreach_ptr(PjExpr, pe, h->exprs)
	{
		if (pe->h1 != PJ_H1_READY)
			continue;
		if (pe->expr != NULL &&
			(!CachedPlanIsSimplyValid(pe->plansource, pe->plan, NULL) ||
			 pe->plan->generation != pe->generation))
			return false;
		if (pe->cast != NULL &&
			(pe->cast->gen != pe->cast_gen || pe->cast->cexpr == NULL ||
			 !pe->cast->cexpr->is_valid))
			return false;
	}

	return true;
}

/*
 * May the user execute the functions in the code?  PL/pgSQL checks them when
 * it builds the ExprState of an expression, and again at every evaluation of
 * one that failed.  We check all of them whenever the transaction, the user
 * or the privileges changed since the last check, so no function runs that
 * PL/pgSQL would refuse, but for a privilege lost inside a transaction.  A
 * failure here sends the call to PL/pgSQL, which raises it at the right
 * expression, or not at all.
 */
static bool
execute_allowed(PjEntry *e)
{
	PjHarvest  *h = e->harvest;
	Oid			user = GetUserId();
	uint64		epoch = exec_epoch; /* before the checks, which may deliver
									 * one */

	if (h->key_lxid == MyProc->vxid.lxid && h->key_user == user &&
		h->key_epoch == epoch)
		return true;

	return plllvm_pj_execute_check(h, user, epoch, NULL);
}

/*
 * The check itself, for the call's entry and for a call that finds the user
 * or the privileges changed after the executor ran.  If a function is denied,
 * its OID goes to *denied.
 */
bool
plllvm_pj_execute_check(PjHarvest *h, Oid user, uint64 epoch, Oid *denied)
{
	/*
	 * A function dropped since the plan was made is not denied: the call that
	 * reaches it fails as PL/pgSQL's does, and one that does not, runs.
	 */
	foreach_oid(funcid, h->funcids)
	{
		bool		missing = false;

		if (object_aclcheck_ext(ProcedureRelationId, funcid, user,
								ACL_EXECUTE, &missing) != ACLCHECK_OK &&
			!missing)
		{
			if (denied != NULL)
				*denied = funcid;
			return false;
		}
	}
	foreach_oid(funcid, h->funcids)
	{
		if (SearchSysCacheExists1(PROCOID, ObjectIdGetDatum(funcid)))
			InvokeFunctionExecuteHook(funcid);
	}

	h->key_lxid = MyProc->vxid.lxid;
	h->key_user = user;
	h->key_epoch = epoch;
	return true;
}

uint64
plllvm_pj_exec_epoch(void)
{
	return exec_epoch;
}

/*
 * The state PL/pgSQL leaves an expression when it fails in it: built in this
 * transaction, and busy, so that its next evaluation takes the path that
 * checks EXECUTE again.  Compiled code fails without touching either.
 */
static void
pj_mark_busy(PjEntry *e)
{
	foreach_ptr(PjExpr, pe, e->harvest->exprs)
	{
		if (pe->h1 != PJ_H1_READY || pe->expr == NULL)
			continue;
		pe->expr->expr_simple_lxid = MyProc->vxid.lxid;
		pe->expr->expr_simple_in_use = true;
	}
}

/*
 * pj_mark_busy() for the expression ctx->pos names, if it names one: PL/pgSQL
 * leaves the others as they were, and so does an error outside an expression
 * (exec_eval_simple_expr)
 */
static void
pj_mark_running(PjCtx *ctx)
{
	PLpgSQL_expr *expr = pj_frame_expr(ctx);

	if (expr == NULL || pj_outer_runs(ctx, expr))
		return;
	expr->expr_simple_lxid = MyProc->vxid.lxid;
	expr->expr_simple_in_use = true;
}

/* the expression the position of a compiled frame names, or NULL */
static PLpgSQL_expr *
pj_frame_expr(PjCtx *ctx)
{
	PjHarvest  *h = ctx->harvest;
	int			idx;
	PjExpr	   *pe;

	if (ctx->pos < 0 || ctx->pos >= h->npos)
		return NULL;
	idx = h->pos[ctx->pos].expr;
	if (idx < 0)
		return NULL;
	pe = list_nth(h->exprs, idx);
	if (pe->h1 != PJ_H1_READY)
		return NULL;
	return pe->expr;
}

/*
 * Does a frame below this one run the expression?  Then that frame owns the
 * flag, as PL/pgSQL's outer frame does: a nested one writes nothing.
 */
static bool
pj_outer_runs(PjCtx *ctx, PLpgSQL_expr *expr)
{
	for (PjCtx *c = ctx->outer; c != NULL; c = c->outer)
	{
		if (pj_frame_expr(c) == expr)
			return true;
	}
	return false;
}

/*
 * Does an expression stand where PL/pgSQL would evaluate it through SPI?
 */
static bool
pj_any_in_use(PjEntry *e)
{
	LocalTransactionId lxid = MyProc->vxid.lxid;

	foreach_ptr(PjExpr, pe, e->harvest->exprs)
	{
		if (pe->h1 == PJ_H1_READY && pe->expr != NULL &&
			pe->expr->expr_simple_in_use && pe->expr->expr_simple_lxid == lxid)
			return true;
	}
	return false;
}

/*
 * What a compiled frame of the entry has saved of an expression while the
 * interpreter runs
 */
typedef struct PjSaved
{
	PLpgSQL_expr *expr;
	LocalTransactionId lxid;
	bool		in_use;
} PjSaved;

/*
 * The interpreter, with the expression each compiled frame of the entry is
 * running marked busy, as PL/pgSQL's own frames leave them while a nested call
 * runs.  They are given back afterwards, but only if no one has changed them.
 */
static Datum
interp(FunctionCallInfo fcinfo, PjEntry *e)
{
	PjSaved    *saved;
	volatile int n = 0;
	volatile Datum result = (Datum) 0;
	LocalTransactionId lxid = MyProc->vxid.lxid;

	if (e == NULL || e->top == NULL)
		return call_handler_p(fcinfo);

	saved = palloc_array(PjSaved, e->frames);
	for (PjCtx *c = e->top; c != NULL; c = c->outer)
	{
		PLpgSQL_expr *expr = pj_frame_expr(c);

		if (expr == NULL)
			continue;
		saved[n].expr = expr;
		saved[n].lxid = expr->expr_simple_lxid;
		saved[n].in_use = expr->expr_simple_in_use;
		n++;
		expr->expr_simple_lxid = lxid;
		expr->expr_simple_in_use = true;
	}

	PG_TRY();
	{
		result = call_handler_p(fcinfo);
	}
	PG_FINALLY();
	{
		for (int i = n - 1; i >= 0; i--)
		{
			PLpgSQL_expr *x = saved[i].expr;

			if (x->expr_simple_lxid == lxid && x->expr_simple_in_use)
			{
				x->expr_simple_lxid = saved[i].lxid;
				x->expr_simple_in_use = saved[i].in_use;
			}
		}
	}
	PG_END_TRY();

	return result;
}

static PjVariant *
variant_find(PjHarvest *h)
{
	for (PjVariant *v = h->variants; v != NULL; v = v->next)
	{
		if (v->opt_level == plllvm_pj_opt_level &&
			v->codegen == plllvm_pj_codegen)
			return v;
	}
	return NULL;
}

/*
 * The function stays in PL/pgSQL until its entry goes stale
 */
static void
decline(PjEntry *e, const char *reason)
{
	e->state = PJ_DECLINED;
	e->reason = MemoryContextStrdup(pj_cxt, reason);
	e->declined_path = MemoryContextStrdup(pj_cxt,
										   psprintf("declined:%s", reason));
	e->last_path = e->declined_path;
}

static void
decline_idle(PjEntry *e, const char *reason)
{
	release_harvest(e);
	decline(e, reason);
}

/*
 * Let go of the code and trees of an entry; must not fail.  Only with no
 * frame of the function running.
 */
static void
release_harvest(PjEntry *e)
{
	PjHarvest  *h = e->harvest;

	if (h == NULL)
		return;
	for (PjVariant *v = h->variants; v != NULL; v = v->next)
	{
		plllvm_pj_levels_release(v);
		if (v->mod != NULL)
			plllvm_jit_release(v->mod);
	}
	MemoryContextDelete(h->cxt);
	e->harvest = NULL;
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
		PjHarvest  *h = e->harvest;

		if (e->stale || e->fn_oid != fn)
			continue;

		memset(info, 0, sizeof(plllvm_pj_info));
		info->signature = pstrdup(e->signature);
		info->collation = e->collation;
		info->state = e->state == PJ_NEW ? "new" :
			e->state == PJ_SEEN ? "seen" :
			e->state == PJ_COMPILED ? "compiled" : "declined";
		info->reason = e->reason;
		info->calls = e->calls;
		info->compiled_calls = e->compiled_calls;
		info->deopts = e->deopts;
		info->guard_misses = e->guard_misses;
		info->translations = e->translations;
		info->last_path = e->last_path;

		if (h != NULL)
		{
			PjVariant  *v = variant_find(h);

			info->has_harvest = true;
			foreach_ptr(PjExpr, pe, h->exprs)
				info->exprs += (pe->expr != NULL);
			info->unplanned = h->nunplanned;
			for (PjVariant *w = h->variants; w != NULL; w = w->next)
				info->variants++;
			if (v != NULL && !v->failed && !v->waiting)
			{
				info->has_variant = true;
				info->native = v->native;
				info->boxed = v->boxed;
				info->restartable = v->restartable;
				info->translate_ms = v->translate_ms;
				info->symbol = pstrdup(v->mod->symbol);
			}
		}
		n++;
	}

	return n;
}

char *
plllvm_pj_ir_text(Oid fn)
{
	HASH_SEQ_STATUS seq;
	PjEntry    *e;

	if (entries == NULL)
		return NULL;

	hash_seq_init(&seq, entries);
	while ((e = hash_seq_search(&seq)) != NULL)
	{
		PjVariant  *v;

		if (e->stale || e->fn_oid != fn || e->harvest == NULL)
			continue;
		v = variant_find(e->harvest);
		if (v != NULL && !v->failed && !v->waiting)
		{
			hash_seq_term(&seq);
			return pstrdup(v->ir);
		}
	}

	return NULL;
}
