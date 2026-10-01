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

#include "funcapi.h"
#include "utils/builtins.h"
#include "utils/tuplestore.h"

#include "plllvm.h"
#include "plllvm_jit.h"

PG_FUNCTION_INFO_V1(plllvm_session_info);
PG_FUNCTION_INFO_V1(plllvm_code_cache);
PG_FUNCTION_INFO_V1(plllvm_jit_test);

/*
 * The LLVM session of this backend; sets it up if needed
 */
Datum
plllvm_session_info(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_jit_session_info info;
	Datum		values[9];
	bool		nulls[9] = {0};

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

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

	return (Datum) 0;
}

/*
 * The compiled code of this backend, newest first
 */
Datum
plllvm_code_cache(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;

	InitMaterializedSRF(fcinfo, 0);

	for (plllvm_jit_module *mod = plllvm_jit_modules(); mod; mod = mod->next)
	{
		Datum		values[16];
		bool		nulls[16] = {0};

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
		values[11] = Float8GetDatum(mod->optimize_ms);
		values[12] = Float8GetDatum(mod->emit_ms);
		values[13] = Float8GetDatum(mod->parse_bc_ms + mod->parse_ms +
									mod->link_ms + mod->verify_ms +
									mod->optimize_ms + mod->emit_ms);
		values[14] = BoolGetDatum(mod->retired);
		values[15] = CStringGetTextDatum(psprintf("%p", mod->addr));

		tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);
	}

	return (Datum) 0;
}

/*
 * Compile (codegen) or only check IR, and return the outcome as a row
 * instead of an ERROR.  The compiled code stays resident.
 */
Datum
plllvm_jit_test(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_jit_result result;
	char	   *ir;
	int			opt_level = plllvm_opt_level;
	bool		codegen;
	bool		ok;
	Datum		values[10];
	bool		nulls[10] = {0};

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

	if (codegen)
		ok = plllvm_jit_compile(InvalidOid, ir, opt_level, &result);
	else
		ok = plllvm_jit_check(ir, &result);

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

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

	return (Datum) 0;
}
