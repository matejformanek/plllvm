/*-------------------------------------------------------------------------
 *
 * plllvm_ops.h
 *
 *			  int4, int8 and float8 operators for JIT-compiled code
 *
 * by Matěj Formánek 2026
 *
 * The functions behind the SQL operators, abs(), sqrt() and the casts
 * from float8 (int.c, int8.c, float.c), with the same results and errors,
 * but without fmgr.  The other float8 operators are those of
 * utils/float.h, which float.c uses itself.  plllvm_types.c
 * exports them as plllvm_int4_pl() and so on.  Cites are of PostgreSQL
 * 9510a826e4a.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_OPS_H
#define PLLLVM_OPS_H

#include "common/int.h"
#include "utils/float.h"

#include "plllvm_host.h"

static pg_always_inline int32
int4_pl(int32 val1, int32 val2)
{
	int32		result;

	if (unlikely(pg_add_s32_overflow(val1, val2, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int32
int4_mi(int32 val1, int32 val2)
{
	int32		result;

	if (unlikely(pg_sub_s32_overflow(val1, val2, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int32
int4_mul(int32 val1, int32 val2)
{
	int32		result;

	if (unlikely(pg_mul_s32_overflow(val1, val2, &result)))
		plllvm_int_overflow();
	return result;
}

/* int4div() (int.c:863); INT_MIN / -1 does not fit, the division would trap */
static pg_always_inline int32
int4_div(int32 val1, int32 val2)
{
	int32		result;

	if (unlikely(val2 == 0))
		plllvm_div_zero();
	if (val2 == -1)
	{
		if (unlikely(pg_neg_s32_overflow(val1, &result)))
			plllvm_int_overflow();
		return result;
	}
	return val1 / val2;
}

/* int4mod() (int.c:1158); INT_MIN % -1 would trap as well, the result is 0 */
static pg_always_inline int32
int4_mod(int32 val1, int32 val2)
{
	if (unlikely(val2 == 0))
		plllvm_div_zero();
	if (val2 == -1)
		return 0;
	return val1 % val2;
}

static pg_always_inline int32
int4_um(int32 val)
{
	int32		result;

	if (unlikely(pg_neg_s32_overflow(val, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int64
int8_pl(int64 val1, int64 val2)
{
	int64		result;

	if (unlikely(pg_add_s64_overflow(val1, val2, &result)))
		plllvm_bigint_overflow();
	return result;
}

static pg_always_inline int64
int8_mi(int64 val1, int64 val2)
{
	int64		result;

	if (unlikely(pg_sub_s64_overflow(val1, val2, &result)))
		plllvm_bigint_overflow();
	return result;
}

static pg_always_inline int64
int8_mul(int64 val1, int64 val2)
{
	int64		result;

	if (unlikely(pg_mul_s64_overflow(val1, val2, &result)))
		plllvm_bigint_overflow();
	return result;
}

/* int8div() (int8.c:510) and int84div() (int8.c:969), as int4_div() */
static pg_always_inline int64
int8_div(int64 val1, int64 val2)
{
	int64		result;

	if (unlikely(val2 == 0))
		plllvm_div_zero();
	if (val2 == -1)
	{
		if (unlikely(pg_neg_s64_overflow(val1, &result)))
			plllvm_bigint_overflow();
		return result;
	}
	return val1 / val2;
}

/* int8mod() (int8.c:570), as int4_mod() */
static pg_always_inline int64
int8_mod(int64 val1, int64 val2)
{
	if (unlikely(val2 == 0))
		plllvm_div_zero();
	if (val2 == -1)
		return 0;
	return val1 % val2;
}

static pg_always_inline int64
int8_um(int64 val)
{
	int64		result;

	if (unlikely(pg_neg_s64_overflow(val, &result)))
		plllvm_bigint_overflow();
	return result;
}

/* int48div() (int8.c:1049): an int4 divided by -1 always fits in int8 */
static pg_always_inline int64
int48_div(int32 val1, int64 val2)
{
	if (unlikely(val2 == 0))
		plllvm_div_zero();
	return (int64) val1 / val2;
}

/* int84() (int8.c:1285) */
static pg_always_inline int32
int4_from_int8(int64 val)
{
	if (unlikely(val < PG_INT32_MIN || val > PG_INT32_MAX))
		plllvm_int_overflow();
	return (int32) val;
}

/* float8um() (float.c:710) */
static pg_always_inline float8
float8_um(float8 val)
{
	return -val;
}

/* int4abs() (int.c:1220) */
static pg_always_inline int32
int4_abs(int32 val)
{
	if (unlikely(val == PG_INT32_MIN))
		plllvm_int_overflow();
	return (val < 0) ? -val : val;
}

/* int8abs() (int8.c:552) */
static pg_always_inline int64
int8_abs(int64 val)
{
	if (unlikely(val == PG_INT64_MIN))
		plllvm_bigint_overflow();
	return (val < 0) ? -val : val;
}

/* float8abs() (float.c:698) */
static pg_always_inline float8
float8_abs(float8 val)
{
	return fabs(val);
}

/* dsqrt() (float.c:1487) */
static pg_always_inline float8
float8_sqrt(float8 val)
{
	float8		result;

	if (val < 0)
		plllvm_sqrt_negative();
	result = sqrt(val);
	if (unlikely(isinf(result)) && !isinf(val))
		float_overflow_error();
	if (unlikely(result == 0.0) && val != 0.0)
		float_underflow_error();
	return result;
}

/*
 * dtoi4() (float.c:1255): rounded first, so that a value just out of range
 * that rounds into it passes; rint() keeps NaN and infinities
 */
static pg_always_inline int32
int4_from_float8(float8 val)
{
	val = rint(val);
	if (unlikely(isnan(val) || !FLOAT8_FITS_IN_INT32(val)))
		plllvm_int_overflow();
	return (int32) val;
}

/* dtoi8() (int8.c:1334), as int4_from_float8() */
static pg_always_inline int64
int8_from_float8(float8 val)
{
	val = rint(val);
	if (unlikely(isnan(val) || !FLOAT8_FITS_IN_INT64(val)))
		plllvm_bigint_overflow();
	return (int64) val;
}

#endif							/* PLLLVM_OPS_H */
