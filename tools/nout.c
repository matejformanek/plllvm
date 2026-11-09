/*
 * A by-value type whose output function sends a NOTICE, and fails on 0, for
 * pj_raise_effect.sh
 */
#include "postgres.h"
#include "fmgr.h"

PG_MODULE_MAGIC;

PG_FUNCTION_INFO_V1(nout);

Datum
nout(PG_FUNCTION_ARGS)
{
	int32		v = PG_GETARG_INT32(0);

	if (v == 0)
		elog(ERROR, "nout of zero");
	elog(NOTICE, "nout ran for %d", v);
	PG_RETURN_CSTRING(psprintf("<%d>", v));
}
