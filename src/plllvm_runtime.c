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

#include "access/detoast.h"
#include "catalog/pg_type_d.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/memutils.h"
#include "varatt.h"

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
	{"plllvm_array_arg", (void *) plllvm_array_arg},
	{"plllvm_array_new", (void *) plllvm_array_new},
	{"plllvm_array_copy", (void *) plllvm_array_copy},
	{"plllvm_rt_array_access", (void *) plllvm_rt_array_access},
	{"plllvm_spi_prepare", (void *) plllvm_spi_prepare},
	{"plllvm_spi_select_into", (void *) plllvm_spi_select_into},
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
	"plllvm_spi_prepare",
	"plllvm_spi_select_into",
	NULL
};

/* innermost frame of the running PL/LLVM functions */
plllvm_frame *plllvm_cur_frame = NULL;

static int	array_elmlen(Oid elemtype);
static void array_check(ArrayType *a, Oid elemtype);
pg_noreturn static void array_elemtype_error(ArrayType *a, Oid elemtype);

/*
 * Raise an ERROR with the given SQLSTATE (packed by MAKE_SQLSTATE); 0 means
 * P0001, as for RAISE without ERRCODE (exec_stmt_raise)
 */
void
plllvm_error(int32 sqlstate, const char *msg)
{
	if (sqlstate == 0)
		sqlstate = ERRCODE_RAISE_EXCEPTION;

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
 * plllvm_scratch_reset() and the call.  A toast pointer is fetched, as
 * PL/pgSQL does on assignment: the row it points into may go meanwhile.
 */
Datum
plllvm_keep(Datum value)
{
	MemoryContext oldcxt;

	Assert(plllvm_cur_frame != NULL);
	oldcxt = MemoryContextSwitchTo(plllvm_cur_frame->caller_cxt);
	if (VARATT_IS_EXTERNAL_NON_EXPANDED(DatumGetPointer(value)))
		value = PointerGetDatum(detoast_external_attr((struct varlena *) DatumGetPointer(value)));
	else
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

/*
 * Argument argno as an array of elemtype.  The copy is private to the call,
 * so that plllvm_array_set_* never writes into the caller's datum, which
 * may point into a shared buffer.
 */
ArrayType *
plllvm_array_arg(FunctionCallInfo fcinfo, int32 argno, Oid elemtype)
{
	ArrayType  *a;

	if (fcinfo->args[argno].isnull)
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("PL/LLVM array argument %d is null", argno + 1)));

	a = DatumGetArrayTypePCopy(fcinfo->args[argno].value);
	array_check(a, elemtype);

	return a;
}

/* n zeros, lower bound 1 */
ArrayType *
plllvm_array_new(Oid elemtype, int32 n)
{
	int			elmlen = array_elmlen(elemtype);
	Size		nbytes;
	ArrayType  *a;

	if (n == 0)
		return construct_empty_array(elemtype);

	nbytes = ARR_OVERHEAD_NONULLS(1) + (Size) ArrayGetNItems(1, &n) * elmlen;
	a = palloc0(nbytes);
	SET_VARSIZE(a, nbytes);
	a->ndim = 1;
	a->elemtype = elemtype;
	ARR_DIMS(a)[0] = n;
	ARR_LBOUND(a)[0] = 1;

	return a;
}

/* also of an array a call returned, which may be toasted or expanded */
ArrayType *
plllvm_array_copy(ArrayType *a)
{
	a = DatumGetArrayTypePCopy(PointerGetDatum(a));
	array_check(a, ARR_ELEMTYPE(a));

	return a;
}

/* the failed check of an inline accessor */
void
plllvm_rt_array_access(ArrayType *a, Oid elemtype)
{
	if (ARR_ELEMTYPE(a) != elemtype)
		array_elemtype_error(a, elemtype);

	ereport(ERROR,
			(errcode(ERRCODE_ARRAY_SUBSCRIPT_ERROR),
			 errmsg("array subscript out of range")));
}

static int
array_elmlen(Oid elemtype)
{
	switch (elemtype)
	{
		case INT4OID:
			return sizeof(int32);
		case INT8OID:
			return sizeof(int64);
		case FLOAT8OID:
			return sizeof(float8);
	}

	ereport(ERROR,
			(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
			 errmsg("PL/LLVM arrays of type %s are not supported",
					format_type_extended(elemtype, -1,
										 FORMAT_TYPE_ALLOW_INVALID))));
	return 0;					/* keep compiler quiet */
}

/*
 * What the inline accessors rely on.  Without NULL elements the data are
 * dense, also when a bitmap is present.
 */
static void
array_check(ArrayType *a, Oid elemtype)
{
	(void) array_elmlen(elemtype);

	if (ARR_NDIM(a) > 1)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM supports only one-dimensional arrays")));

	if (array_contains_nulls(a))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM arrays cannot contain null elements")));

	if (ARR_ELEMTYPE(a) != elemtype)
		array_elemtype_error(a, elemtype);
}

static void
array_elemtype_error(ArrayType *a, Oid elemtype)
{
	ereport(ERROR,
			(errcode(ERRCODE_DATATYPE_MISMATCH),
			 errmsg("array has element type %s, expected %s",
					format_type_be(ARR_ELEMTYPE(a)),
					format_type_be(elemtype))));
}
