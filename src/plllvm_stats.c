/*-------------------------------------------------------------------------
 *
 * plllvm_stats.c
 *
 *			  SQL functions that show the state of PL/LLVM in a session
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

/*
 * The LLVM session of this backend; sets it up if needed
 */
Datum
plllvm_session_info(PG_FUNCTION_ARGS)
{
	ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
	plllvm_jit_session_info info;
	Datum		values[6];
	bool		nulls[6] = {0};

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

	tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);

	return (Datum) 0;
}
