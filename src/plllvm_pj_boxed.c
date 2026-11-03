/*-------------------------------------------------------------------------
 *
 * plllvm_pj_boxed.c
 *
 *			  plpgsql_jit: the expressions the compiler does not do, run by
 *			  the executor
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) This is exec_eval_simple_expr() without the interpreter: the tree is
 *    our copy of the one PL/pgSQL planned, and the ParamListInfo is filled
 *    by the compiled code from its own slots.  No SPI, so no CONTEXT line
 *    of a SQL expression.
 *
 * 2) The state of one activation level of a variant lives in a PjLevel: an
 *    ExprContext, the parameters and an ExprState per expression.  A level
 *    is never shared: the frame of a recursive call has the next one, so
 *    nothing is read after the call that overwrote it.  All of it hangs
 *    under one EState of the transaction, as PL/pgSQL's own, and goes with
 *    it; levels are kept between calls, and an ERROR deletes the one it
 *    crosses, as PL/pgSQL does not reuse a tree that failed.
 *
 * 3) A level and the code of its variant go together (plllvm_pj_levels_
 *    release()): an ExprState points into the harvest's tree copies, and a
 *    stale one must never be found again.
 *
 */
#include "postgres.h"

#include "access/xact.h"
#include "executor/executor.h"
#include "miscadmin.h"
#include "tcop/pquery.h"
#include "utils/acl.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/snapmgr.h"

#include "plllvm.h"
#include "plllvm_pj.h"

/* the levels that have state in this transaction, for the callbacks */
static dlist_head live_levels = DLIST_STATIC_INIT(live_levels);
static EState *xact_estate = NULL;

static PjLevel *level_get(PjCtx *ctx);
static PjLevel *level_find(PjCtx *ctx);
static void level_build(PjLevel *lv, PjHarvest *h);
static void level_free(PjLevel *lv);
static void level_reset(PjLevel *lv);
static void slot_build(PjLevel *lv, PjSlot *slot, const PjExpr *pe, PjCtx *ctx);
static void key_recheck(PjCtx *ctx);

/*
 * The parameters of the level, for the compiled code to fill
 */
void *
plllvm_pj_params(PjCtx *ctx)
{
	return level_get(ctx)->params->params;
}

/*
 * Evaluate expression idx of the function, the null flag goes to the context.
 * The compiled code has stored the variables it reads.
 */
Datum
plllvm_pj_boxed_eval(PjCtx *ctx, int32 idx)
{
	PjLevel    *lv = level_get(ctx);
	const PjExpr *pe = list_nth(ctx->harvest->exprs, idx);
	PjSlot	   *slot = &lv->slots[idx];
	MemoryContext oldcxt;
	Datum		result;
	bool		isnull;

	EnsurePortalSnapshotExists();

	if (slot->state == NULL || slot->user != ctx->user ||
		slot->epoch != ctx->epoch)
		slot_build(lv, slot, pe, ctx);

	plllvm_pj_count.boxed_evals++;
	ctx->evaluated = true;

	/* the interpreter's snapshot rule, exec_eval_simple_expr() */
	oldcxt = MemoryContextSwitchTo(lv->econtext->ecxt_per_tuple_memory);
	if (pe->need)
	{
		CommandCounterIncrement();
		PushActiveSnapshot(GetTransactionSnapshot());
	}
	result = ExecEvalExpr(slot->state, lv->econtext, &isnull);
	if (pe->need)
		PopActiveSnapshot();
	MemoryContextSwitchTo(oldcxt);

	key_recheck(ctx);

	ctx->isnull = isnull;
	return result;
}

/*
 * What an evaluation allocated, once its value is out: exec_eval_cleanup()
 */
void
plllvm_pj_boxed_reset(PjCtx *ctx)
{
	level_reset(ctx->lv);
}

/*
 * The level of the frame, made on first use in a transaction.  Its memory is
 * reset by the first use of a later call, which is when the result of a RETURN
 * has been copied out.
 */
static PjLevel *
level_get(PjCtx *ctx)
{
	PjLevel    *lv = ctx->lv;

	if (lv == NULL)
	{
		lv = level_find(ctx);
		ctx->lv = lv;
	}
	if (lv->cxt == NULL)
		level_build(lv, ctx->harvest);
	if (lv->serial != ctx->serial)
	{
		level_reset(lv);
		lv->serial = ctx->serial;
	}

	return lv;
}

static PjLevel *
level_find(PjCtx *ctx)
{
	PjVariant  *v = ctx->variant;
	MemoryContext cxt = ctx->harvest->cxt;
	PjLevel    *lv;

	if (ctx->level >= v->nlevels)
	{
		int			n = Max(ctx->level + 1, Max(4, 2 * v->nlevels));
		PjLevel   **levels = MemoryContextAllocZero(cxt, n * sizeof(PjLevel *));

		if (v->nlevels > 0)
		{
			memcpy(levels, v->levels, v->nlevels * sizeof(PjLevel *));
			pfree(v->levels);
		}
		v->levels = levels;
		v->nlevels = n;
	}

	lv = v->levels[ctx->level];
	if (lv == NULL)
	{
		lv = MemoryContextAllocZero(cxt, sizeof(PjLevel));
		lv->variant = v;
		dlist_push_tail(&live_levels, &lv->node);
		v->levels[ctx->level] = lv;
	}

	return lv;
}

static void
level_build(PjLevel *lv, PjHarvest *h)
{
	MemoryContext oldcxt;
	MemoryContext cxt;
	ExprContext *econtext;
	ParamListInfo params;

	if (xact_estate == NULL)
	{
		oldcxt = MemoryContextSwitchTo(TopTransactionContext);
		xact_estate = CreateExecutorState();
		MemoryContextSwitchTo(oldcxt);
	}

	cxt = AllocSetContextCreate(xact_estate->es_query_cxt,
								"plllvm - pj level",
								ALLOCSET_SMALL_SIZES);
	econtext = CreateExprContext(xact_estate);

	oldcxt = MemoryContextSwitchTo(cxt);
	params = makeParamList(h->ndatums);
	for (int i = 0; i < h->ndatums; i++)
	{
		params->params[i].ptype = h->ptypes[i];
		params->params[i].pflags = PARAM_FLAG_CONST;
	}
	lv->slots = palloc0_array(PjSlot, list_length(h->exprs));
	MemoryContextSwitchTo(oldcxt);

	econtext->ecxt_param_list_info = params;
	lv->econtext = econtext;
	lv->params = params;
	lv->serial = 0;
	lv->cxt = cxt;
}

/* nothing of the level is left; must not fail */
static void
level_free(PjLevel *lv)
{
	if (lv->cxt == NULL)
		return;
	FreeExprContext(lv->econtext, false);
	MemoryContextDelete(lv->cxt);
	lv->cxt = NULL;
	lv->econtext = NULL;
	lv->params = NULL;
	lv->slots = NULL;
}

/* the biggest the per-tuple memory has been is what peak_tuple_bytes reports */
static void
level_reset(PjLevel *lv)
{
	Size		size = MemoryContextMemAllocated(lv->econtext->ecxt_per_tuple_memory,
												 false);

	plllvm_pj_count.peak_tuple_bytes = Max(plllvm_pj_count.peak_tuple_bytes,
										   (int64) size);
	ResetExprContext(lv->econtext);
}

/*
 * An ExprState checks EXECUTE of the functions it calls as it is built, under
 * the user of that moment, which the call's own check cannot see for what lies
 * outside the tree's function nodes: a domain's CHECK, a hashed array
 * operator's hash function.  So one is rebuilt when the key has changed.
 */
static void
slot_build(PjLevel *lv, PjSlot *slot, const PjExpr *pe, PjCtx *ctx)
{
	MemoryContext oldcxt;

	slot->state = NULL;
	if (slot->cxt == NULL)
		slot->cxt = AllocSetContextCreate(lv->cxt, "plllvm - pj expression",
										  ALLOCSET_SMALL_SIZES);
	else
		MemoryContextReset(slot->cxt);

	oldcxt = MemoryContextSwitchTo(slot->cxt);
	slot->state = ExecInitExprWithParams(pe->tree, lv->params);
	MemoryContextSwitchTo(oldcxt);

	slot->user = ctx->user;
	slot->epoch = ctx->epoch;
}

/*
 * After the executor ran, which may have run any code: if the user or what
 * the privileges depend on is not what the call was checked for, check again.
 * No call can fall back now, so a function that is no longer allowed raises.
 */
static void
key_recheck(PjCtx *ctx)
{
	uint64		epoch = plllvm_pj_exec_epoch();
	Oid			user = GetUserId();
	Oid			denied;

	if (user == ctx->user && epoch == ctx->epoch)
		return;

	if (!plllvm_pj_execute_check(ctx->harvest, user, epoch, &denied))
		aclcheck_error(ACLCHECK_NO_PRIV, OBJECT_FUNCTION,
					   get_func_name(denied));

	ctx->user = user;
	ctx->epoch = epoch;
}

/*
 * An ERROR leaves the frame: the level it used is deleted, as PL/pgSQL does
 * not reuse the expressions of an evaluation that failed
 */
void
plllvm_pj_level_abort(PjCtx *ctx)
{
	if (ctx->lv != NULL)
		level_free(ctx->lv);
}

/* with the code: all at use_count 0, so no frame holds a level */
void
plllvm_pj_levels_release(PjVariant *v)
{
	for (int i = 0; i < v->nlevels; i++)
	{
		PjLevel    *lv = v->levels[i];

		if (lv == NULL)
			continue;
		level_free(lv);
		dlist_delete(&lv->node);
	}
}

/*
 * The EState goes with the transaction, as PL/pgSQL's.  On an abort the
 * regular recovery frees what it holds.
 */
void
plllvm_pj_xact_callback(XactEvent event)
{
	dlist_iter	iter;

	if (event != XACT_EVENT_COMMIT && event != XACT_EVENT_PARALLEL_COMMIT &&
		event != XACT_EVENT_PREPARE && event != XACT_EVENT_ABORT &&
		event != XACT_EVENT_PARALLEL_ABORT)
		return;

	if (xact_estate != NULL && event != XACT_EVENT_ABORT &&
		event != XACT_EVENT_PARALLEL_ABORT)
		FreeExecutorState(xact_estate);
	xact_estate = NULL;

	dlist_foreach(iter, &live_levels)
	{
		PjLevel    *lv = dlist_container(PjLevel, node, iter.cur);

		lv->cxt = NULL;
		lv->econtext = NULL;
		lv->params = NULL;
		lv->slots = NULL;
	}
}
