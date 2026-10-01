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

#include <limits.h>

#include "access/xact.h"
#include "fmgr.h"
#include "utils/guc.h"

#include "plllvm.h"
#include "plllvm_jit.h"

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
char	   *plllvm_types_bc_path = NULL;
int			plllvm_opt_level = 2;
bool		plllvm_dump_ir = false;
int			plllvm_max_resident_compiles = 2000;
int			plllvm_max_ir_instructions = 100000;
int			plllvm_debug_inject = PLLLVM_INJECT_NONE;

static const struct config_enum_entry debug_inject_options[] = {
	{"none", PLLLVM_INJECT_NONE, false},
	{"llvm_fatal", PLLLVM_INJECT_LLVM_FATAL, false},
	{"bad_alloc", PLLLVM_INJECT_BAD_ALLOC, false},
	{NULL, 0, false}
};

static void plllvm_xact_callback(XactEvent event, void *arg);
static void plllvm_subxact_callback(SubXactEvent event,
									SubTransactionId mySubid,
									SubTransactionId parentSubid,
									void *arg);

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

	DefineCustomStringVariable("plllvm.types_bc_path",
							   gettext_noop("Sets the path of plllvm_types.bc."),
							   gettext_noop("Read when a session first uses LLVM. Empty means plllvm/plllvm_types.bc next to the plllvm library."),
							   &plllvm_types_bc_path,
							   "",
							   PGC_SUSET, GUC_NOT_IN_SAMPLE,
							   NULL, NULL, NULL);

	DefineCustomIntVariable("plllvm.opt_level",
							gettext_noop("Sets the LLVM optimization level of compiled functions."),
							NULL,
							&plllvm_opt_level,
							2, 0, 3,
							PGC_SUSET, 0,
							NULL, NULL, NULL);

	DefineCustomBoolVariable("plllvm.dump_ir",
							 gettext_noop("Logs the optimized IR of every compiled function."),
							 NULL,
							 &plllvm_dump_ir,
							 false,
							 PGC_SUSET, 0,
							 NULL, NULL, NULL);

	DefineCustomIntVariable("plllvm.max_resident_compiles",
							gettext_noop("Sets the maximum number of compiles kept in a session."),
							gettext_noop("Compiled code stays in memory until the session ends, also after the function was replaced."),
							&plllvm_max_resident_compiles,
							2000, 1, 1000000,
							PGC_SUSET, 0,
							NULL, NULL, NULL);

	DefineCustomIntVariable("plllvm.max_ir_instructions",
							gettext_noop("Sets the maximum number of IR instructions of a function body."),
							gettext_noop("Zero turns the limit off."),
							&plllvm_max_ir_instructions,
							100000, 0, INT_MAX,
							PGC_SUSET, 0,
							NULL, NULL, NULL);

	DefineCustomEnumVariable("plllvm.debug_inject",
							 gettext_noop("Raises an LLVM error in the next compile, for testing."),
							 NULL,
							 &plllvm_debug_inject,
							 PLLLVM_INJECT_NONE,
							 debug_inject_options,
							 PGC_SUSET, GUC_NO_SHOW_ALL | GUC_NOT_IN_SAMPLE,
							 NULL, NULL, NULL);

	MarkGUCPrefixReserved("plllvm");

	RegisterXactCallback(plllvm_xact_callback, NULL);
	RegisterSubXactCallback(plllvm_subxact_callback, NULL);

	inited = true;
}

/*
 * An ERROR (e.g. out of memory in palloc) can leave a fatal-on-OOM section
 * open.  Core resets its own in PostgresMain(); an extension has to do it
 * at (sub)transaction abort.
 */
static void
plllvm_xact_callback(XactEvent event, void *arg)
{
	if (event == XACT_EVENT_ABORT || event == XACT_EVENT_PARALLEL_ABORT)
		plllvm_reset_after_error();
}

static void
plllvm_subxact_callback(SubXactEvent event, SubTransactionId mySubid,
						SubTransactionId parentSubid, void *arg)
{
	if (event == SUBXACT_EVENT_ABORT_SUB)
		plllvm_reset_after_error();
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

/*
 * Path for messages: only its last component in regression tests
 */
const char *
plllvm_display_path(const char *path)
{
	const char *sep = last_dir_separator(path);

	if (plllvm_regress_test_mode && sep != NULL)
		return sep + 1;
	return path;
}
