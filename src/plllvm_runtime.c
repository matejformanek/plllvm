/*-------------------------------------------------------------------------
 *
 * plllvm_runtime.c
 *
 *			  host functions called from JIT-compiled PL/LLVM code
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) These are the cold paths of the host API, kept out of line so that the
 *    stock messages exist once.  The inline helpers are in plllvm_types.c.
 *
 * 2) The library is built with -fvisibility=hidden, so the JIT cannot find
 *    these functions with dlsym().  It defines them from plllvm_host_symbols
 *    instead.
 *
 */
#include "postgres.h"

#include "plllvm.h"

const plllvm_host_symbol plllvm_host_symbols[] =
{
	{"plllvm_error", (void *) plllvm_error},
	{"plllvm_notice", (void *) plllvm_notice},
	{"plllvm_rt_int_overflow", (void *) plllvm_rt_int_overflow},
	{"plllvm_rt_bigint_overflow", (void *) plllvm_rt_bigint_overflow},
	{"plllvm_rt_div_zero", (void *) plllvm_rt_div_zero},
	{NULL, NULL}
};

/*
 * Raise an ERROR with the given SQLSTATE (packed by MAKE_SQLSTATE)
 */
void
plllvm_error(int32 sqlstate, const char *msg)
{
	ereport(ERROR,
			(errcode(sqlstate),
			 errmsg_internal("%s", msg)));
}

void
plllvm_notice(const char *msg)
{
	ereport(NOTICE,
			(errmsg_internal("%s", msg)));
}

/* the messages of int4pl, int8pl and int4div */
void
plllvm_rt_int_overflow(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
			 errmsg("integer out of range")));
}

void
plllvm_rt_bigint_overflow(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_NUMERIC_VALUE_OUT_OF_RANGE),
			 errmsg("bigint out of range")));
}

void
plllvm_rt_div_zero(void)
{
	ereport(ERROR,
			(errcode(ERRCODE_DIVISION_BY_ZERO),
			 errmsg("division by zero")));
}
