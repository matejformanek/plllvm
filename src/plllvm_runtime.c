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
 * 3) A body that uses a call, text or memory helper runs in a frame: a
 *    scratch context deleted after the call, as PL/pgSQL's eval context.
 *    The handler copies a by-reference result out into the caller's
 *    context, where kept values live too, as PL/pgSQL's datums.
 *
 */
#include "postgres.h"

#include "utils/datum.h"
#include "utils/memutils.h"

#include "plllvm.h"

const plllvm_host_symbol plllvm_host_symbols[] =
{
	{"plllvm_error", (void *) plllvm_error},
	{"plllvm_notice", (void *) plllvm_notice},
	{"plllvm_rt_int_overflow", (void *) plllvm_rt_int_overflow},
	{"plllvm_rt_bigint_overflow", (void *) plllvm_rt_bigint_overflow},
	{"plllvm_rt_div_zero", (void *) plllvm_rt_div_zero},
	{"plllvm_keep", (void *) plllvm_keep},
	{"plllvm_scratch_reset", (void *) plllvm_scratch_reset},
	{"plllvm_rt_site_call", (void *) plllvm_rt_site_call},
	{"plllvm_rt_site_null", (void *) plllvm_rt_site_null},
	{NULL, NULL}
};

/* a body declaring any of these runs in a frame */
const char *const plllvm_frame_helpers[] =
{
	"plllvm_call0",
	"plllvm_call1",
	"plllvm_call2",
	"plllvm_call3",
	"plllvm_cstring_to_text",
	"plllvm_text_to_cstring",
	"plllvm_detoast",
	"plllvm_keep",
	"plllvm_free",
	"plllvm_scratch_reset",
	NULL
};

/* innermost frame of the running PL/LLVM functions */
plllvm_frame *plllvm_cur_frame = NULL;

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

/*
 * Enter a frame.  The caller's context is passed in, not taken from
 * CurrentMemoryContext, which SPI_connect() may have changed.
 */
void
plllvm_frame_push(plllvm_frame *frame, MemoryContext caller)
{
	frame->caller_cxt = caller;
	frame->scratch = AllocSetContextCreate(caller, "PL/LLVM scratch",
										   ALLOCSET_DEFAULT_SIZES);
	frame->prev = plllvm_cur_frame;
	plllvm_cur_frame = frame;
	MemoryContextSwitchTo(frame->scratch);
}

/* the only copy of the result, made before the scratch goes */
Datum
plllvm_frame_copy_out(plllvm_frame *frame, Datum value, int16 typlen)
{
	MemoryContext oldcxt = MemoryContextSwitchTo(frame->caller_cxt);

	value = datumCopy(value, false, typlen);
	MemoryContextSwitchTo(oldcxt);

	return value;
}

/* on success and on ERROR */
void
plllvm_frame_pop(plllvm_frame *frame)
{
	plllvm_cur_frame = frame->prev;
	MemoryContextSwitchTo(frame->caller_cxt);
	MemoryContextDelete(frame->scratch);
}

/*
 * Copy of a varlena in the caller's context, where it survives
 * plllvm_scratch_reset() and the call
 */
Datum
plllvm_keep(Datum value)
{
	MemoryContext oldcxt;

	Assert(plllvm_cur_frame != NULL);
	oldcxt = MemoryContextSwitchTo(plllvm_cur_frame->caller_cxt);
	value = datumCopy(value, false, -1);
	MemoryContextSwitchTo(oldcxt);

	return value;
}

void
plllvm_scratch_reset(void)
{
	Assert(plllvm_cur_frame != NULL);
	MemoryContextReset(plllvm_cur_frame->scratch);
}
