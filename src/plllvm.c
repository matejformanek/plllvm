/*-------------------------------------------------------------------------
 *
 * plllvm.c
 *
 *			  module initialization, call handler and validator of
 *			  the PL/LLVM procedural language
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The handler and the validator are stubs until the compiler is in place.
 *
 * 2) There is no inline handler, so PostgreSQL itself rejects DO blocks.
 *
 */
#include "postgres.h"

#include "fmgr.h"
#include "utils/guc.h"

#include "plllvm.h"

#ifdef PG_MODULE_MAGIC_EXT

PG_MODULE_MAGIC_EXT(
					.name = "plllvm",
					.version = PLLLVM_VERSION
);

#else

PG_MODULE_MAGIC;

#endif

PG_FUNCTION_INFO_V1(plllvm_call_handler);
PG_FUNCTION_INFO_V1(plllvm_validator);

bool		plllvm_regress_test_mode = false;

/*
 * Module initialization
 */
void
_PG_init(void)
{
	static bool inited = false;

	if (inited)
		return;

	DefineCustomBoolVariable("plllvm.regress_test_mode",
							 gettext_noop("Reduces volatile output (times, addresses) for regression tests."),
							 NULL,
							 &plllvm_regress_test_mode,
							 false,
							 PGC_USERSET, 0,
							 NULL, NULL, NULL);

	MarkGUCPrefixReserved("plllvm");

	inited = true;
}

/*
 * Call handler for PL/LLVM functions
 */
Datum
plllvm_call_handler(PG_FUNCTION_ARGS)
{
	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("PL/LLVM functions are not implemented yet")));

	PG_RETURN_VOID();			/* keep compiler quiet */
}

/*
 * Validator for PL/LLVM functions
 *
 * Note: it rejects every function, also with check_function_bodies = off,
 * so that no PL/LLVM function can exist before the compiler does.
 */
Datum
plllvm_validator(PG_FUNCTION_ARGS)
{
	Oid			funcoid = PG_GETARG_OID(0);

	if (!CheckFunctionValidatorAccess(fcinfo->flinfo->fn_oid, funcoid))
		PG_RETURN_VOID();

	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("PL/LLVM functions are not implemented yet")));

	PG_RETURN_VOID();			/* keep compiler quiet */
}
