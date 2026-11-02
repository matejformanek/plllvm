/*-------------------------------------------------------------------------
 *
 * plllvm_stats.c
 *
 *			  SQL functions that show the state of PL/LLVM in a session,
 *			  and plllvm_jit_test()
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#include "postgres.h"

#ifdef __APPLE__
#include <mach/mach.h>
#endif

#include "access/htup_details.h"
#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/syscache.h"
#include "utils/tuplestore.h"

#include "plllvm.h"
#include "plllvm_jit.h"
#include "plllvm_pj.h"

PG_FUNCTION_INFO_V1(plllvm_session_info);
PG_FUNCTION_INFO_V1(plllvm_code_cache);
PG_FUNCTION_INFO_V1(plllvm_jit_test);
PG_FUNCTION_INFO_V1(plllvm_function_status);
PG_FUNCTION_INFO_V1(plllvm_call_sites);
PG_FUNCTION_INFO_V1(plllvm_expr_stats);
PG_FUNCTION_INFO_V1(plllvm_pj_stats);
PG_FUNCTION_INFO_V1(plllvm_pj_status);
PG_FUNCTION_INFO_V1(plllvm_pj_ir);

static bool resident_size(int64 *bytes);

/*
 * The LLVM session of this backend; sets it up if needed
 */
Datum
plllvm_session_info(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_jit_session_info info;
	Datum		values[11];
	bool		nulls[11] = {0};
	int64		rss;

	InitMaterializedSRF(fcinfo, 0);

	plllvm_jit_get_session_info(&info);

	/* the major version only, the paths as file names */
	if (plllvm_regress_test_mode)
	{
		char	   *dot = strchr(info.llvm_version, '.');

		if (dot != NULL)
			*dot = '\0';
	}

	values[0] = CStringGetTextDatum(info.llvm_version);
	values[1] = CStringGetTextDatum(info.triple);
	values[2] = CStringGetTextDatum(info.data_layout);
	if (info.libllvm != NULL)
		values[3] = CStringGetTextDatum(plllvm_display_path(info.libllvm));
	else
		nulls[3] = true;
	values[4] = CStringGetTextDatum(plllvm_display_path(info.types_bc));
	values[5] = Float8GetDatum(info.init_ms);
	values[6] = Int64GetDatum(info.compiles);
	values[7] = Int64GetDatum(info.compile_failures);
	values[8] = Int64GetDatum(info.retired);
	if (resident_size(&rss))
		values[9] = Int64GetDatum(rss);
	else
		nulls[9] = true;
	values[10] = Int64GetDatum(plllvm_spi_statements());

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

	return (Datum) 0;
}

/*
 * The compiled code of this backend, newest first; released code is freed
 * at the next compile
 */
Datum
plllvm_code_cache(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (plllvm_jit_module *mod = plllvm_jit_modules(); mod; mod = mod->next)
	{
		Datum		values[20];
		bool		nulls[20] = {0};

		if (OidIsValid(mod->owner_oid))
			values[0] = ObjectIdGetDatum(mod->owner_oid);
		else
			nulls[0] = true;

		/* OIDs differ between test runs */
		if (plllvm_regress_test_mode && OidIsValid(mod->owner_oid))
			values[1] = CStringGetTextDatum(psprintf("plllvm_N_" UINT64_FORMAT,
													 mod->gen));
		else
			values[1] = CStringGetTextDatum(mod->symbol);

		values[2] = Int64GetDatum(mod->gen);
		values[3] = Int32GetDatum(mod->opt_level);
		values[4] = Int32GetDatum(mod->ir_instructions);
		values[5] = Int32GetDatum(mod->helpers_linked);
		values[6] = Int32GetDatum(mod->cfi_left);
		values[7] = Float8GetDatum(mod->parse_bc_ms);
		values[8] = Float8GetDatum(mod->parse_ms);
		values[9] = Float8GetDatum(mod->link_ms);
		values[10] = Float8GetDatum(mod->verify_ms);
		values[11] = Float8GetDatum(mod->resolve_ms);
		values[12] = Float8GetDatum(mod->optimize_ms);
		values[13] = Float8GetDatum(mod->emit_ms);
		values[14] = Float8GetDatum(mod->parse_bc_ms + mod->parse_ms +
									mod->link_ms + mod->verify_ms +
									mod->resolve_ms + mod->optimize_ms +
									mod->emit_ms);
		values[15] = BoolGetDatum(mod->released);
		values[16] = CStringGetTextDatum(psprintf("%p", mod->addr));
		values[17] = BoolGetDatum(mod->needs_frame);
		values[18] = CStringGetTextDatum(mod->kind == PLLLVM_JIT_EXPR ? "expr" :
										 mod->kind == PLLLVM_JIT_PJ ? "pj" :
										 "function");
		if (mod->kind == PLLLVM_JIT_PJ)
			values[19] = Float8GetDatum(mod->translate_ms);
		else
			nulls[19] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

/*
 * Compile (codegen) or only check IR, and return the outcome as a row
 * instead of an ERROR.  Nothing calls the code, so it is released at once.
 */
Datum
plllvm_jit_test(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_jit_result result;
	plllvm_path path;
	char	   *ir;
	int			opt_level = plllvm_opt_level;
	bool		codegen;
	bool		ok;
	Datum		values[11];
	bool		nulls[11] = {0};

	if (PG_ARGISNULL(0) || PG_ARGISNULL(2))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("ir and codegen must not be null")));

	ir = text_to_cstring(PG_GETARG_TEXT_PP(0));
	codegen = PG_GETARG_BOOL(2);

	if (!PG_ARGISNULL(1))
	{
		opt_level = PG_GETARG_INT32(1);
		if (opt_level < 0 || opt_level > 3)
			ereport(ERROR,
					(errcode(ERRCODE_INVALID_PARAMETER_VALUE),
					 errmsg("opt_level must be between 0 and 3")));
	}

	InitMaterializedSRF(fcinfo, 0);

	/* there is no function whose path or collation would apply */
	path.search_path = "pg_catalog, pg_temp";
	path.nspoid = InvalidOid;
	if (codegen)
		ok = plllvm_jit_compile(InvalidOid, InvalidOid, &path, -1, ir,
								opt_level, &result);
	else
		ok = plllvm_jit_check(ir, &path, -1, &result);

	values[0] = BoolGetDatum(ok);
	if (ok)
		nulls[1] = nulls[2] = nulls[3] = true;
	else
	{
		values[1] = CStringGetTextDatum(unpack_sql_state(result.sqlerrcode));
		values[2] = CStringGetTextDatum(result.errmsg);
		if (result.errdetail != NULL)
			values[3] = CStringGetTextDatum(result.errdetail);
		else
			nulls[3] = true;
	}

	if (result.errline > 0)
	{
		values[4] = Int32GetDatum(result.errline);
		values[5] = Int32GetDatum(result.errcol);
	}
	else
		nulls[4] = nulls[5] = true;

	if (result.mod != NULL)
		values[6] = Int64GetDatum(result.mod->gen);
	else
		nulls[6] = true;

	values[7] = Int32GetDatum(result.ir_instructions);
	values[8] = Int32GetDatum(result.helpers_linked);
	if (result.cfi_left >= 0 && ok && codegen)
		values[9] = Int32GetDatum(result.cfi_left);
	else
		nulls[9] = true;
	if (ok && codegen)
		values[10] = Int32GetDatum(result.checks_inserted);
	else
		nulls[10] = true;

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

	if (result.mod != NULL)
		plllvm_jit_release(result.mod);

	return (Datum) 0;
}

/*
 * State of a function's code in this backend, from its newest compile that
 * is not released.  Other backends compile and release on their own.
 */
Datum
plllvm_function_status(PG_FUNCTION_ARGS)
{
	Oid			fn = PG_GETARG_OID(0);
	plllvm_jit_module *newest = NULL;
	int64		compiles = 0;
	int64		retired = 0;
	const char *state;
	TupleDesc	tupdesc;
	Datum		values[3];
	bool		nulls[3] = {0};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	for (plllvm_jit_module *mod = plllvm_jit_modules(); mod; mod = mod->next)
	{
		if (!OidIsValid(fn) || mod->owner_oid != fn)
			continue;

		compiles++;
		if (mod->released)
			retired++;
		else if (newest == NULL || mod->gen > newest->gen)
			newest = mod;
	}

	if (newest == NULL)
		state = "not_compiled";
	else
	{
		HeapTuple	tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn));

		/* funccache never lets go of a dropped function's entry */
		if (!HeapTupleIsValid(tuple))
			state = "dropped";
		else
		{
			if (HeapTupleHeaderGetRawXmin(tuple->t_data) != newest->owner_xmin ||
				!ItemPointerEquals(&tuple->t_self, &newest->owner_tid))
				state = "stale";
			else
				state = "live";
			ReleaseSysCache(tuple);
		}
	}

	values[0] = CStringGetTextDatum(state);
	values[1] = Int64GetDatum(compiles);
	values[2] = Int64GetDatum(retired);

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/*
 * The call sites of the compiled code of this backend
 */
Datum
plllvm_call_sites(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (plllvm_jit_module *mod = plllvm_jit_modules(); mod; mod = mod->next)
	{
		plllvm_site *sites;
		int			nsites;

		if (mod->refs == NULL)
			continue;

		nsites = plllvm_refs_sites(mod->refs, &sites);
		for (int i = 0; i < nsites; i++)
		{
			Datum		values[8];
			bool		nulls[8] = {0};

			if (OidIsValid(mod->owner_oid))
				values[0] = ObjectIdGetDatum(mod->owner_oid);
			else
				nulls[0] = true;
			values[1] = CStringGetTextDatum(sites[i].signature);
			values[2] = BoolGetDatum(sites[i].ready);
			values[3] = BoolGetDatum(sites[i].busy);
			values[4] = Int64GetDatum(sites[i].prepares);
			values[5] = Int64GetDatum(sites[i].checks);
			values[6] = Int64GetDatum(sites[i].reentries);
			values[7] = BoolGetDatum(mod->released);

			tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values,
								 nulls);
		}
	}

	return (Datum) 0;
}

/*
 * Expression JIT in the PL/pgSQL functions of this backend
 */
Datum
plllvm_expr_stats(PG_FUNCTION_ARGS)
{
	TupleDesc	tupdesc;
	Datum		values[9];
	bool		nulls[9] = {0};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	values[0] = CStringGetTextDatum(plllvm_plpgsql_state());
	values[1] = Int64GetDatum(plllvm_expr_fired);
	values[2] = Int64GetDatum(plllvm_expr_compiled + plllvm_expr_hits);
	values[3] = Int64GetDatum(plllvm_expr_compiled);
	values[4] = Int64GetDatum(plllvm_expr_declined);
	values[5] = Int64GetDatum(plllvm_expr_failures);
	values[6] = Int64GetDatum(plllvm_expr_capped);
	values[7] = Int64GetDatum(plllvm_expr_programs);
	values[8] = Int64GetDatum(plllvm_expr_compiled_evals);

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/*
 * LANGUAGE plpgsql_jit in this backend
 */
Datum
plllvm_pj_stats(PG_FUNCTION_ARGS)
{
	const plllvm_pj_counters *c = &plllvm_pj_count;
	TupleDesc	tupdesc;
	Datum		values[15];
	bool		nulls[15] = {0};

	if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
		elog(ERROR, "return type must be a row type");

	values[0] = Int64GetDatum(c->calls);
	values[1] = Int64GetDatum(c->compiled_calls);
	values[2] = Int64GetDatum(c->deopts);
	values[3] = Int64GetDatum(c->interpreted_calls);
	values[4] = Int64GetDatum(c->declines);
	values[5] = Int64GetDatum(c->guard_misses);
	values[6] = Int64GetDatum(c->null_args);
	values[7] = Int64GetDatum(c->plugin_fallbacks);
	values[8] = Int64GetDatum(c->capped);
	values[9] = Int64GetDatum(c->translations);
	values[10] = Int64GetDatum(c->attempts);
	values[11] = Int64GetDatum(c->failures);
	values[12] = Int64GetDatum(c->boxed_evals);
	values[13] = Int64GetDatum(plllvm_jit_pj_resident());
	values[14] = Int64GetDatum(c->peak_tuple_bytes);

	PG_RETURN_DATUM(HeapTupleGetDatum(heap_form_tuple(tupdesc, values, nulls)));
}

/*
 * The side entries of a plpgsql_jit function, one per signature and input
 * collation.  The columns about the translation are NULL until there is one.
 */
Datum
plllvm_pj_status(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_pj_info *infos;
	int			ninfos;

	InitMaterializedSRF(fcinfo, 0);

	ninfos = plllvm_pj_infos(PG_GETARG_OID(0), &infos);
	for (int i = 0; i < ninfos; i++)
	{
		Datum		values[17] = {0};
		bool		nulls[17] = {0};

		values[0] = CStringGetTextDatum(infos[i].signature);
		values[1] = ObjectIdGetDatum(infos[i].collation);
		values[2] = CStringGetTextDatum(infos[i].state);
		if (infos[i].reason != NULL)
			values[3] = CStringGetTextDatum(infos[i].reason);
		else
			nulls[3] = true;
		values[4] = Int64GetDatum(infos[i].calls);
		values[5] = Int64GetDatum(infos[i].compiled_calls);
		values[6] = Int64GetDatum(infos[i].deopts);
		values[7] = Int64GetDatum(infos[i].guard_misses);
		values[8] = Int64GetDatum(infos[i].translations);
		if (infos[i].last_path != NULL)
			values[9] = CStringGetTextDatum(infos[i].last_path);
		else
			nulls[9] = true;
		if (infos[i].has_harvest)
		{
			values[10] = Int32GetDatum(infos[i].exprs);
			values[11] = Int32GetDatum(infos[i].unplanned);
			values[12] = Int32GetDatum(infos[i].variants);
		}
		else
			nulls[10] = nulls[11] = nulls[12] = true;
		if (infos[i].has_variant)
		{
			values[13] = BoolGetDatum(infos[i].native);
			values[14] = BoolGetDatum(infos[i].boxed);
			values[15] = BoolGetDatum(infos[i].restartable);
			values[16] = Float8GetDatum(infos[i].translate_ms);
		}
		else
			nulls[13] = nulls[14] = nulls[15] = nulls[16] = true;

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

/*
 * Resident set size of this backend, where the platform tells it cheaply
 */
static bool
resident_size(int64 *bytes)
{
#ifdef __APPLE__

	mach_task_basic_info_data_t info;
	mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;

	if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
				  (task_info_t) &info, &count) != KERN_SUCCESS)
		return false;
	*bytes = (int64) info.resident_size;
	return true;

#else

	return false;

#endif
}

/*
 * The IR of the code a plpgsql_jit function runs in this session, for
 * inspection
 */
Datum
plllvm_pj_ir(PG_FUNCTION_ARGS)
{
	char	   *ir = plllvm_pj_ir_text(PG_GETARG_OID(0));

	if (ir == NULL)
		PG_RETURN_NULL();
	PG_RETURN_TEXT_P(cstring_to_text(ir));
}
