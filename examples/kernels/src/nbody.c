/*-------------------------------------------------------------------------
 *
 * nbody.c
 *
 *			  nbody(n integer) as a PL/LLVM function; "make kernels"
 *			  compiles it to examples/kernels/nbody.ll
 *
 * by Matěj Formánek 2026
 *
 * The Computer Language Benchmarks Game "n-body", see
 * LICENSES/BENCHMARKS-GAME-BSD-3.md.
 *   Copyright (c) 2004-2008 Brent Fulgham, 2005-2024 Isaac Gouy.
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) This is bench/ctwins/cb/nbody.c with the bodies in float8 arrays of
 *    the host API, subscripted from 1 as in bench/kernels/10_nbody.sql.
 *    The arithmetic is float.h's, in PL/pgSQL's order and without FP
 *    contraction, so the result is bit-identical to nbody_imm's.
 *
 * 2) round(e0::numeric, 9)::text || ' ' || round(e::numeric, 9)::text is
 *    formatted in C, as cb_nbody_result() does: float8_numeric's %.15g,
 *    then rounding half away from zero.
 *
 */
#include "postgres.h"

#include <math.h>

#include "catalog/pg_type_d.h"
#include "common/int.h"
#include "fmgr.h"
#include "lib/stringinfo.h"
#include "miscadmin.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/float.h"

#define NB 5

/* the host API used here (docs/host-api.ll) */
extern ArrayType *plllvm_array_new(Oid elemtype, int32 n);
extern float8 plllvm_array_get_f64(ArrayType *a, int32 i);
extern void plllvm_array_set_f64(ArrayType *a, int32 i, float8 v);
pg_noreturn extern void plllvm_int_overflow(void);

extern Datum f(PG_FUNCTION_ARGS);

#define GET(a, i)		plllvm_array_get_f64((a), (i))
#define SET(a, i, v)	plllvm_array_set_f64((a), (i), (v))

/* sqrt_checked(), float.c */
static float8
sqrt_checked(float8 a)
{
	float8		r;

	if (a < 0)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_ARGUMENT_FOR_POWER_FUNCTION),
				 errmsg("cannot take square root of a negative number")));
	r = sqrt(a);
	if (unlikely(isinf(r)) && !isinf(a))
		float_overflow_error();
	if (unlikely(r == 0.0) && a != 0.0)
		float_underflow_error();
	return r;
}

/* the inner FOR's lower bound i + 1 */
static int32
int4_add(int32 a, int32 b)
{
	int32		r;

	if (unlikely(pg_add_s32_overflow(a, b, &r)))
		plllvm_int_overflow();
	return r;
}

/* round(v::numeric, 9)::text, as bench/ctwins/cb/nbody.c */
static void
append_round9(StringInfo buf, float8 v)
{
	char		s[64];
	char		digits[16];
	char		r[400];
	int			rl;
	int			p;
	int			kept;
	bool		neg;
	int			z = 0;

	if (isnan(v))
	{
		appendStringInfoString(buf, "NaN");
		return;
	}
	if (isinf(v))
	{
		appendStringInfoString(buf, v < 0 ? "-Infinity" : "Infinity");
		return;
	}

	neg = v < 0;
	if (v == 0)
		rl = snprintf(r, sizeof(r), "0");
	else
	{
		/* "d.dddddddddddddde[+-]XX": the same 15 digits as %.15g */
		snprintf(s, sizeof(s), "%.14e", fabs(v));
		digits[0] = s[0];
		memcpy(digits + 1, s + 2, 14);
		digits[15] = '\0';
		p = atoi(s + 17) + 1;	/* digits before the decimal point */
		kept = p + 9;			/* digits of round(|v| * 10^9) */

		if (kept < 0)
			rl = snprintf(r, sizeof(r), "0");
		else if (kept == 0)
			rl = snprintf(r, sizeof(r), "%c", digits[0] >= '5' ? '1' : '0');
		else if (kept >= 15)
		{
			memcpy(r, digits, 15);
			memset(r + 15, '0', kept - 15);
			rl = kept;
			r[rl] = '\0';
		}
		else
		{
			memcpy(r, digits, kept);
			rl = kept;
			r[rl] = '\0';
			if (digits[kept] >= '5')
			{
				int			k = rl - 1;

				while (k >= 0 && r[k] == '9')
					r[k--] = '0';
				if (k >= 0)
					r[k]++;
				else
				{
					memmove(r + 1, r, rl + 1);
					r[0] = '1';
					rl++;
				}
			}
		}
	}

	/* strip leading zeros, keep one */
	while (z < rl - 1 && r[z] == '0')
		z++;
	if (z > 0)
	{
		memmove(r, r + z, rl - z + 1);
		rl -= z;
	}
	if (rl == 1 && r[0] == '0')
		neg = false;

	if (neg)
		appendStringInfoChar(buf, '-');
	if (rl <= 9)
	{
		appendStringInfoString(buf, "0.");
		for (int k = rl; k < 9; k++)
			appendStringInfoChar(buf, '0');
		appendStringInfoString(buf, r);
	}
	else
	{
		appendBinaryStringInfo(buf, r, rl - 9);
		appendStringInfoChar(buf, '.');
		appendStringInfoString(buf, r + rl - 9);
	}
}

static float8
energy(ArrayType *x, ArrayType *y, ArrayType *z, ArrayType *vx,
	   ArrayType *vy, ArrayType *vz, ArrayType *m)
{
	const float8 half = 0.5;
	float8		e = 0.0;

	for (int32 i = 1; i <= NB; i++)
	{
		e = float8_pl(e,
					  float8_mul(float8_mul(half, GET(m, i)),
								 float8_pl(float8_pl(float8_mul(GET(vx, i), GET(vx, i)),
													 float8_mul(GET(vy, i), GET(vy, i))),
										   float8_mul(GET(vz, i), GET(vz, i)))));
		for (int32 j = int4_add(i, 1); j <= NB; j++)
		{
			float8		dx = float8_mi(GET(x, i), GET(x, j));
			float8		dy = float8_mi(GET(y, i), GET(y, j));
			float8		dz = float8_mi(GET(z, i), GET(z, j));

			e = float8_mi(e,
						  float8_div(float8_mul(GET(m, i), GET(m, j)),
									 sqrt_checked(float8_pl(float8_pl(float8_mul(dx, dx),
															   float8_mul(dy, dy)),
													 float8_mul(dz, dz)))));
		}
	}
	return e;
}

Datum
f(PG_FUNCTION_ARGS)
{
	const float8 pi = 3.141592653589793;
	const float8 days_per_year = 365.24;
	const float8 dt = 0.01;
	float8		solar_mass;
	ArrayType  *x = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *y = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *z = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *vx = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *vy = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *vz = plllvm_array_new(FLOAT8OID, NB);
	ArrayType  *m = plllvm_array_new(FLOAT8OID, NB);
	float8		px = 0,
				py = 0,
				pz = 0;
	float8		e,
				e0;
	int32		n;
	StringInfoData buf;

	solar_mass = float8_mul(float8_mul(4.0, pi), pi);

	/* the sun is at rest at 0: the new arrays are zeros */
	SET(x, 2, 4.84143144246472090e+00);
	SET(x, 3, 8.34336671824457987e+00);
	SET(x, 4, 1.28943695621391310e+01);
	SET(x, 5, 1.53796971148509165e+01);
	SET(y, 2, -1.16032004402742839e+00);
	SET(y, 3, 4.12479856412430479e+00);
	SET(y, 4, -1.51111514016986312e+01);
	SET(y, 5, -2.59193146099879641e+01);
	SET(z, 2, -1.03622044471123109e-01);
	SET(z, 3, -4.03523417114321381e-01);
	SET(z, 4, -2.23307578892655734e-01);
	SET(z, 5, 1.79258772950371181e-01);
	SET(vx, 2, float8_mul(1.66007664274403694e-03, days_per_year));
	SET(vx, 3, float8_mul(-2.76742510726862411e-03, days_per_year));
	SET(vx, 4, float8_mul(2.96460137564761618e-03, days_per_year));
	SET(vx, 5, float8_mul(2.68067772490389322e-03, days_per_year));
	SET(vy, 2, float8_mul(7.69901118419740425e-03, days_per_year));
	SET(vy, 3, float8_mul(4.99852801234917238e-03, days_per_year));
	SET(vy, 4, float8_mul(2.37847173959480950e-03, days_per_year));
	SET(vy, 5, float8_mul(1.62824170038242295e-03, days_per_year));
	SET(vz, 2, float8_mul(-6.90460016972063023e-05, days_per_year));
	SET(vz, 3, float8_mul(2.30417297573763929e-05, days_per_year));
	SET(vz, 4, float8_mul(-2.96589568540237556e-05, days_per_year));
	SET(vz, 5, float8_mul(-9.51592254519715870e-05, days_per_year));
	SET(m, 1, solar_mass);
	SET(m, 2, float8_mul(9.54791938424326609e-04, solar_mass));
	SET(m, 3, float8_mul(2.85885980666130812e-04, solar_mass));
	SET(m, 4, float8_mul(4.36624404335156298e-05, solar_mass));
	SET(m, 5, float8_mul(5.15138902046611451e-05, solar_mass));

	/* offset momentum */
	for (int32 i = 1; i <= NB; i++)
	{
		px = float8_pl(px, float8_mul(GET(vx, i), GET(m, i)));
		py = float8_pl(py, float8_mul(GET(vy, i), GET(m, i)));
		pz = float8_pl(pz, float8_mul(GET(vz, i), GET(m, i)));
	}
	SET(vx, 1, float8_div(-px, solar_mass));
	SET(vy, 1, float8_div(-py, solar_mass));
	SET(vz, 1, float8_div(-pz, solar_mass));

	e0 = energy(x, y, z, vx, vy, vz, m);

	/* PL/pgSQL reads n only at the FOR */
	if (PG_ARGISNULL(0))
		ereport(ERROR,
				(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
				 errmsg("upper bound of FOR loop cannot be null")));
	n = PG_GETARG_INT32(0);

	/* FOR s IN 1..n, stepping as exec_stmt_fori */
	for (int32 s = 1; s <= n; s++)
	{
		for (int32 i = 1; i <= NB; i++)
		{
			for (int32 j = int4_add(i, 1); j <= NB; j++)
			{
				float8		dx = float8_mi(GET(x, i), GET(x, j));
				float8		dy = float8_mi(GET(y, i), GET(y, j));
				float8		dz = float8_mi(GET(z, i), GET(z, j));
				float8		d2 = float8_pl(float8_pl(float8_mul(dx, dx),
													 float8_mul(dy, dy)),
										   float8_mul(dz, dz));
				float8		mag = float8_div(dt, float8_mul(d2, sqrt_checked(d2)));
				float8		mi = float8_mul(GET(m, i), mag);
				float8		mj = float8_mul(GET(m, j), mag);

				SET(vx, i, float8_mi(GET(vx, i), float8_mul(dx, mj)));
				SET(vy, i, float8_mi(GET(vy, i), float8_mul(dy, mj)));
				SET(vz, i, float8_mi(GET(vz, i), float8_mul(dz, mj)));
				SET(vx, j, float8_pl(GET(vx, j), float8_mul(dx, mi)));
				SET(vy, j, float8_pl(GET(vy, j), float8_mul(dy, mi)));
				SET(vz, j, float8_pl(GET(vz, j), float8_mul(dz, mi)));
			}
		}
		for (int32 i = 1; i <= NB; i++)
		{
			SET(x, i, float8_pl(GET(x, i), float8_mul(dt, GET(vx, i))));
			SET(y, i, float8_pl(GET(y, i), float8_mul(dt, GET(vy, i))));
			SET(z, i, float8_pl(GET(z, i), float8_mul(dt, GET(vz, i))));
		}
		CHECK_FOR_INTERRUPTS();
		if (s == PG_INT32_MAX)
			break;
	}

	e = energy(x, y, z, vx, vy, vz, m);

	initStringInfo(&buf);
	append_round9(&buf, e0);
	appendStringInfoChar(&buf, ' ');
	append_round9(&buf, e);

	PG_RETURN_TEXT_P(cstring_to_text_with_len(buf.data, buf.len));
}
