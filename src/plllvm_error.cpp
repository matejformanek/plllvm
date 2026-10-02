/*-------------------------------------------------------------------------
 *
 * plllvm_error.cpp
 *
 *			  LLVM error handling that needs C++
 *
 * by Matěj Formánek 2026
 *
 * Copies src/backend/jit/llvm/llvmjit_error.cpp (PostgreSQL 9510a826e4a).
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) Core's llvm_enter_fatal_on_oom() cannot be used: llvmjit's symbols
 *    are hidden, and llvmjit is not loaded at all with jit = off.
 *
 * 2) The C++ new handler and the LLVM error handlers are process global
 *    and shared with llvmjit, so ours are installed only while plllvm is
 *    inside LLVM.  Neither llvmjit nor plllvm runs SQL inside such a
 *    section, so the two never nest.
 *
 * 3) Core resets its own depth only in PostgresMain()'s error recovery.  If
 *    an out-of-memory ERROR inside llvmjit is caught by a PL/pgSQL EXCEPTION
 *    block, core keeps counting a depth > 0 while a later plllvm section
 *    empties LLVM's handler slot, so a later LLVM fatal error in llvmjit in
 *    that transaction aborts instead of raising FATAL.  An extension cannot
 *    fix that.
 *
 */

extern "C"
{
#include "postgres.h"
}

#include <llvm/Support/ErrorHandling.h>

#include "plllvm_jit.h"

#include <new>

static int	fatal_new_handler_depth = 0;
static std::new_handler old_new_handler = NULL;

static void fatal_system_new_handler(void);
static void plllvm_assert_in_fatal_section(void);
static void fatal_llvm_new_handler(void *user_data, const char *reason, bool gen_crash_diag);
static void fatal_llvm_error_handler(void *user_data, const char *reason, bool gen_crash_diag);


/*
 * Enter a section in which C++ and LLVM errors are treated as FATAL errors.
 *
 * LLVM's own handling of these cases (exit(), abort(), or a bad_alloc that
 * nobody catches) is not compatible with PostgreSQL's error handling, and
 * there is no reliable way to raise an ERROR from inside LLVM without
 * corrupting LLVM's state, hence FATAL.
 *
 * Wrap every call into LLVM in such a section, but never the execution of
 * JIT-compiled code: that code calls back into PostgreSQL, which may raise
 * ordinary ERRORs.
 */
void
plllvm_enter_fatal_on_oom(void)
{
	if (fatal_new_handler_depth == 0)
	{
		old_new_handler = std::set_new_handler(fatal_system_new_handler);
		llvm::install_bad_alloc_error_handler(fatal_llvm_new_handler);
		llvm::install_fatal_error_handler(fatal_llvm_error_handler);
	}
	fatal_new_handler_depth++;
}

/*
 * Leave a section started with plllvm_enter_fatal_on_oom().
 */
void
plllvm_leave_fatal_on_oom(void)
{
	fatal_new_handler_depth--;
	if (fatal_new_handler_depth == 0)
	{
		std::set_new_handler(old_new_handler);
		llvm::remove_bad_alloc_error_handler();
		llvm::remove_fatal_error_handler();
	}
}

/*
 * Are we inside a fatal-on-oom section?  Callers use it to skip LLVM
 * cleanup after an error.
 */
bool
plllvm_in_fatal_on_oom(void)
{
	return fatal_new_handler_depth > 0;
}

/*
 * Reset fatal error handling after an ERROR left a section open.
 *
 * Core calls llvm_reset_after_error() from PostgresMain()'s error recovery.
 * An extension has no such hook, so this is called at (sub)transaction
 * abort instead (plllvm.c), and before each section (plllvm_jit.c).
 */
void
plllvm_reset_after_error(void)
{
	if (fatal_new_handler_depth != 0)
	{
		std::set_new_handler(old_new_handler);
		llvm::remove_bad_alloc_error_handler();
		llvm::remove_fatal_error_handler();
	}
	fatal_new_handler_depth = 0;
}

static void
plllvm_assert_in_fatal_section(void)
{
	Assert(fatal_new_handler_depth > 0);
}

/*
 * Raise the LLVM error that plllvm.debug_inject asks for, as LLVM itself
 * would.  Called inside a section, so it ends the session with FATAL.
 */
void
plllvm_inject_fault(int kind)
{
	plllvm_assert_in_fatal_section();

	if (kind == PLLLVM_INJECT_LLVM_FATAL)
		llvm::reportFatalInternalError("plllvm.debug_inject");
	else if (kind == PLLLVM_INJECT_BAD_ALLOC)
		llvm::report_bad_alloc_error("plllvm.debug_inject");
}

static void
fatal_system_new_handler(void)
{
	ereport(FATAL,
			(errcode(ERRCODE_OUT_OF_MEMORY),
			 errmsg("out of memory"),
			 errdetail("While in LLVM (plllvm).")));
}

static void
fatal_llvm_new_handler(void *user_data,
					   const char *reason,
					   bool gen_crash_diag)
{
	ereport(FATAL,
			(errcode(ERRCODE_OUT_OF_MEMORY),
			 errmsg("out of memory"),
			 errdetail("While in LLVM (plllvm): %s", reason)));
}

/*
 * Note: ERRCODE_OUT_OF_MEMORY as in core, because some LLVM out-of-memory
 * conditions are reported as fatal errors.
 */
static void
fatal_llvm_error_handler(void *user_data,
						 const char *reason,
						 bool gen_crash_diag)
{
	ereport(FATAL,
			(errcode(ERRCODE_OUT_OF_MEMORY),
			 errmsg("fatal llvm error in plllvm: %s", reason)));
}
