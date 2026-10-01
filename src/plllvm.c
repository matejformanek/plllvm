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
 * 1) A body is LLVM IR whose entry "i64 @f(ptr %fcinfo)" is called as a
 *    version 1 function.  The handler adds only the pin and the error
 *    context; argument and NULL handling are the IR's.
 *
 * 2) There is no inline handler, so PostgreSQL itself rejects DO blocks.
 *
 */
#include "postgres.h"

#include <limits.h>

#include "access/xact.h"
#include "fmgr.h"
#include "miscadmin.h"
#include "utils/guc.h"
#include "utils/syscache.h"

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

static void exec_error_callback(void *arg);
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
	plllvm_function *func;
	ErrorContextCallback errcallback;
	volatile Datum retval = (Datum) 0;

	/* PL/LLVM functions may call each other through fmgr alone */
	check_stack_depth();

	func = plllvm_compile_get(fcinfo);

	/* pin entry, so that funccache cannot reuse it under this call */
	func->cfunc.use_count++;

	errcallback.callback = exec_error_callback;
	errcallback.arg = func;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	PG_TRY();
	{
		retval = func->addr(fcinfo);
	}
	PG_FINALLY();
	{
		plllvm_compile_unpin(func);
	}
	PG_END_TRY();

	/* not in PG_FINALLY: PG_END_TRY restores the stack PG_TRY saw */
	error_context_stack = errcallback.previous;

	return retval;
}

static void
exec_error_callback(void *arg)
{
	plllvm_function *func = (plllvm_function *) arg;

	errcontext("PL/LLVM function \"%s\"", NameStr(func->proname));
}

/*
 * Validator for PL/LLVM functions
 */
Datum
plllvm_validator(PG_FUNCTION_ARGS)
{
	Oid			funcoid = PG_GETARG_OID(0);
	HeapTuple	tuple;

	if (!CheckFunctionValidatorAccess(fcinfo->flinfo->fn_oid, funcoid))
		PG_RETURN_VOID();

	tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(funcoid));
	if (!HeapTupleIsValid(tuple))
		elog(ERROR, "cache lookup failed for function %u", funcoid);

	plllvm_compile_check_scope(tuple);

	if (check_function_bodies)
		plllvm_compile_check_body(tuple);

	ReleaseSysCache(tuple);

	PG_RETURN_VOID();
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
