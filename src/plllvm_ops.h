/*-------------------------------------------------------------------------
 *
 * plllvm_ops.h
 *
 *			  int4, int8 and float8 operators for JIT-compiled code
 *
 * by Matěj Formánek 2026
 *
 * The functions behind the SQL operators (int.c, int8.c), with the same
 * results and errors, but without fmgr.  The float8 operators are those of
 * utils/float.h, which float.c uses itself.  plllvm_types.c exports them as
 * plllvm_int4_pl() and so on.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_OPS_H
#define PLLLVM_OPS_H

#include "common/int.h"
#include "utils/float.h"

#include "plllvm_host.h"

static pg_always_inline int32
int4_pl(int32 a, int32 b)
{
	int32		result;

	if (unlikely(pg_add_s32_overflow(a, b, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int32
int4_mi(int32 a, int32 b)
{
	int32		result;

	if (unlikely(pg_sub_s32_overflow(a, b, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int32
int4_mul(int32 a, int32 b)
{
	int32		result;

	if (unlikely(pg_mul_s32_overflow(a, b, &result)))
		plllvm_int_overflow();
	return result;
}

/* int4div(); INT_MIN / -1 does not fit, the division would trap */
static pg_always_inline int32
int4_div(int32 a, int32 b)
{
	int32		result;

	if (unlikely(b == 0))
		plllvm_div_zero();
	if (b == -1)
	{
		if (unlikely(pg_neg_s32_overflow(a, &result)))
			plllvm_int_overflow();
		return result;
	}
	return a / b;
}

/* int4mod(); INT_MIN % -1 would trap as well, the result is 0 */
static pg_always_inline int32
int4_mod(int32 a, int32 b)
{
	if (unlikely(b == 0))
		plllvm_div_zero();
	if (b == -1)
		return 0;
	return a % b;
}

static pg_always_inline int32
int4_um(int32 a)
{
	int32		result;

	if (unlikely(pg_neg_s32_overflow(a, &result)))
		plllvm_int_overflow();
	return result;
}

static pg_always_inline int64
int8_pl(int64 a, int64 b)
{
	int64		result;

	if (unlikely(pg_add_s64_overflow(a, b, &result)))
		plllvm_bigint_overflow();
	return result;
}

static pg_always_inline int64
int8_mi(int64 a, int64 b)
{
	int64		result;

	if (unlikely(pg_sub_s64_overflow(a, b, &result)))
		plllvm_bigint_overflow();
	return result;
}

static pg_always_inline int64
int8_mul(int64 a, int64 b)
{
	int64		result;

	if (unlikely(pg_mul_s64_overflow(a, b, &result)))
		plllvm_bigint_overflow();
	return result;
}

/* int8div() and int84div(), as int4_div() */
static pg_always_inline int64
int8_div(int64 a, int64 b)
{
	int64		result;

	if (unlikely(b == 0))
		plllvm_div_zero();
	if (b == -1)
	{
		if (unlikely(pg_neg_s64_overflow(a, &result)))
			plllvm_bigint_overflow();
		return result;
	}
	return a / b;
}

/* int8mod(), as int4_mod() */
static pg_always_inline int64
int8_mod(int64 a, int64 b)
{
	if (unlikely(b == 0))
		plllvm_div_zero();
	if (b == -1)
		return 0;
	return a % b;
}

static pg_always_inline int64
int8_um(int64 a)
{
	int64		result;

	if (unlikely(pg_neg_s64_overflow(a, &result)))
		plllvm_bigint_overflow();
	return result;
}

/* int48div(): an int4 divided by -1 always fits in int8 */
static pg_always_inline int64
int48_div(int32 a, int64 b)
{
	if (unlikely(b == 0))
		plllvm_div_zero();
	return (int64) a / b;
}

/* int84() */
static pg_always_inline int32
int4_from_int8(int64 a)
{
	if (unlikely(a < PG_INT32_MIN || a > PG_INT32_MAX))
		plllvm_int_overflow();
	return (int32) a;
}

#endif							/* PLLLVM_OPS_H */
