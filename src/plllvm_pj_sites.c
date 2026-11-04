/*-------------------------------------------------------------------------
 *
 * plllvm_pj_sites.c
 *
 *			  plpgsql_jit: the calls compiled code makes through fmgr
 *
 * by Matěj Formánek 2026
 *
 * Portions Copyright (c) 1996-2026, PostgreSQL Global Development Group
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) A site is what the executor builds for a FuncExpr, OpExpr or
 *    CoerceViaIO (ExecInitFunc, EEOP_IOCOERCE), per activation level and
 *    transaction, as an ExprState is.
 *
 * 2) Nothing here checks EXECUTE: the function is on the harvest's list, which
 *    the handler checks (plllvm_pj_execute_check).
 *
 * 3) The first site of a call switches to the level's per-tuple memory, where
 *    the callee allocates as it does for the executor.  The handler switches
 *    back when the call ends.
 */
#include "postgres.h"

#include "catalog/pg_proc.h"
#include "executor/executor.h"
#include "nodes/nodeFuncs.h"
#include "pgstat.h"
#include "tcop/pquery.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"

#include "plllvm.h"
#include "plllvm_pj.h"

static PjSiteSlot *site_enter(PjCtx *ctx, int32 idx);
static void site_build(PjLevel *lv, const PjSiteDesc *desc, PjSiteSlot *slot);

PjSite *
plllvm_pj_site(PjCtx *ctx, int32 idx)
{
	return &site_enter(ctx, idx)->site;
}

/*
 * A CoerceViaIO: the output function of the argument, then the input
 * function of the result.  A NULL stays NULL: the input function is strict
 * (the translator checks), so the interpreter does not call it either
 * (execExprInterp.c, EEOP_IOCOERCE).  The null flag of the result goes to the
 * context.
 */
Datum
plllvm_pj_io(PjCtx *ctx, int32 idx, Datum arg, int32 isnull)
{
	PjSiteSlot *slot = site_enter(ctx, idx);
	FunctionCallInfo out = slot->site.fcinfo;
	FunctionCallInfo in = slot->fcinfo_in;
	char	   *str;
	Datum		result;

	if (isnull)
	{
		ctx->isnull = true;
		return (Datum) 0;
	}

	out->args[0].value = arg;
	out->args[0].isnull = false;
	out->isnull = false;
	str = DatumGetCString(FunctionCallInvoke(out));

	in->args[0].value = CStringGetDatum(str);
	in->args[0].isnull = false;
	in->isnull = false;
	result = FunctionCallInvoke(in);
	ctx->isnull = in->isnull;

	return result;
}

/*
 * plllvm_pj_invoke() of a site that counts its calls, as
 * ExecEvalFuncExprStrictFusage()
 */
Datum
plllvm_pj_invoke_track(PjSite *site)
{
	FunctionCallInfo fcinfo = site->fcinfo;
	PgStat_FunctionCallUsage fcusage;
	Datum		result;

	if (fcinfo->flinfo->fn_strict)
	{
		for (int i = 0; i < fcinfo->nargs; i++)
		{
			if (fcinfo->args[i].isnull)
			{
				fcinfo->isnull = true;
				return (Datum) 0;
			}
		}
	}

	pgstat_init_function_usage(fcinfo, &fcusage);
	fcinfo->isnull = false;
	result = FunctionCallInvoke(fcinfo);
	pgstat_end_function_usage(&fcusage, true);

	return result;
}

/*
 * The slot of a site, built when this transaction first reaches it, in the
 * state a call needs: a snapshot as exec_eval_simple_expr() ensures, and the
 * memory of the evaluation
 */
static PjSiteSlot *
site_enter(PjCtx *ctx, int32 idx)
{
	PjLevel    *lv = plllvm_pj_level(ctx);
	const PjSiteDesc *desc = &ctx->variant->sites[idx];
	PjSiteSlot *slot = &lv->sites[idx];

	EnsurePortalSnapshotExists();

	if (!slot->built)
		site_build(lv, desc, slot);

	/* the callee may have sent a message or run SQL: no deopt after it */
	ctx->evaluated = true;

	MemoryContextSwitchTo(lv->econtext->ecxt_per_tuple_memory);

	return slot;
}

static void
site_build(PjLevel *lv, const PjSiteDesc *desc, PjSiteSlot *slot)
{
	MemoryContext oldcxt = MemoryContextSwitchTo(lv->cxt);
	FmgrInfo   *flinfo = palloc0_object(FmgrInfo);
	FunctionCallInfo fcinfo;

	if (desc->kind == PJ_SITE_CALL)
	{
		fmgr_info_cxt(desc->funcid, flinfo, lv->cxt);
		fmgr_info_set_expr((Node *) desc->node, flinfo);
		if (flinfo->fn_retset)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("set-valued function called in context that cannot accept a set")));

		fcinfo = palloc0(SizeForFunctionCallInfo(desc->nargs));
		InitFunctionCallInfoData(*fcinfo, flinfo, desc->nargs,
								 desc->collation, NULL, NULL);
		slot->site.fcinfo = fcinfo;
		slot->site.track = pgstat_track_functions > flinfo->fn_stats;
	}
	else
	{
		const CoerceViaIO *io = (const CoerceViaIO *) desc->node;
		FmgrInfo   *flinfo_in = palloc0_object(FmgrInfo);
		Oid			iofunc;
		Oid			ioparam;
		bool varlena;

		getTypeOutputInfo(exprType((Node *) io->arg), &iofunc, &varlena);
		fmgr_info_cxt(iofunc, flinfo, lv->cxt);
		fmgr_info_set_expr((Node *) io, flinfo);
		fcinfo = palloc0(SizeForFunctionCallInfo(1));
		InitFunctionCallInfoData(*fcinfo, flinfo, 1, InvalidOid, NULL, NULL);

		getTypeInputInfo(io->resulttype, &iofunc, &ioparam);
		fmgr_info_cxt(iofunc, flinfo_in, lv->cxt);
		fmgr_info_set_expr((Node *) io, flinfo_in);

		/*
		 * the input function's typioparam and typmod, as EEOP_IOCOERCE sets
		 * them
		 */
		slot->fcinfo_in = palloc0(SizeForFunctionCallInfo(3));
		InitFunctionCallInfoData(*slot->fcinfo_in, flinfo_in, 3, InvalidOid,
								 NULL, NULL);
		slot->fcinfo_in->args[1].value = ObjectIdGetDatum(ioparam);
		slot->fcinfo_in->args[2].value = Int32GetDatum(-1);

		slot->site.fcinfo = fcinfo;
		slot->site.track = false;
	}

	slot->built = true;
	MemoryContextSwitchTo(oldcxt);
}
