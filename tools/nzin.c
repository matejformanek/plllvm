/*
 * A by-value type whose input function is not strict: it sends a NOTICE when
 * it is given a NULL, and returns NULL (the executor asserts that), for
 * pj_cmodule_pins.sh
 */
#include "postgres.h"
#include "fmgr.h"
#include "utils/builtins.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(nzin_in);
PG_FUNCTION_INFO_V1(nzin_out);

Datum
nzin_in(PG_FUNCTION_ARGS)
{
	if (PG_ARGISNULL(0))
	{
		elog(NOTICE, "nzin_in of NULL");
		PG_RETURN_NULL();
	}
	PG_RETURN_INT32(pg_strtoint32(PG_GETARG_CSTRING(0)));
}

Datum
nzin_out(PG_FUNCTION_ARGS)
{
	PG_RETURN_CSTRING(psprintf("%d", PG_GETARG_INT32(0)));
}
