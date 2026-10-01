/*-------------------------------------------------------------------------
 *
 * revcomp.c
 *
 *			  revcomp(nlines integer) as a PL/LLVM function; "make kernels"
 *			  compiles it to examples/kernels/revcomp.ll
 *
 * by Matěj Formánek 2026
 *
 * The Computer Language Benchmarks Game "fasta" and "reverse-complement",
 * see LICENSES/BENCHMARKS-GAME-BSD-3.md.
 *   Copyright (c) 2004-2008 Brent Fulgham, 2005-2024 Isaac Gouy.
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) This is bench/ctwins/cb/revcomp.c: the sequence is one byte buffer,
 *    where bench/kernels/30_revcomp.sql has a text[] of 60-character
 *    lines.  Bytes are characters only under UTF8 and a C default
 *    collation and ctype, which the function checks first.
 *
 * 2) int4 arithmetic keeps the overflow checks of int4pl and int4mul.
 *    "r < 0.27" compares as float8lt(r, '0.27'::numeric::float8), and
 *    numeric_float8 rounds the decimal as the C literal does.
 *
 */
#include "postgres.h"

#include "catalog/pg_collation_d.h"
#include "common/int.h"
#include "common/md5.h"
#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "utils/builtins.h"
#include "utils/float.h"
#include "utils/pg_locale.h"

#define LINE 60

/* the host API used here (docs/host-api.ll) */
pg_noreturn extern void plllvm_rt_int_overflow(void);

extern Datum f(PG_FUNCTION_ARGS);

static const float8 iub_p[14] = {0.27, 0.39, 0.51, 0.78, 0.80, 0.82, 0.84,
0.86, 0.88, 0.90, 0.92, 0.94, 0.96, 0.98};
static const char iub_c[15] = {'a', 'c', 'g', 't', 'B', 'D', 'H', 'K', 'M',
'N', 'R', 'S', 'V', 'W', 'Y'};
static const float8 hs_p[3] = {0.3029549426680, 0.5009432431601,
0.6984905497992};
static const char hs_c[4] = {'a', 'c', 'g', 't'};

static int32
int4_add(int32 a, int32 b)
{
	int32		r;

	if (unlikely(pg_add_s32_overflow(a, b, &r)))
		plllvm_rt_int_overflow();
	return r;
}

static int32
int4_mul(int32 a, int32 b)
{
	int32		r;

	if (unlikely(pg_mul_s32_overflow(a, b, &r)))
		plllvm_rt_int_overflow();
	return r;
}

static void
for_null(bool lower)
{
	ereport(ERROR,
			(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
			 lower ? errmsg("lower bound of FOR loop cannot be null") :
			 errmsg("upper bound of FOR loop cannot be null")));
}

Datum
f(PG_FUNCTION_ARGS)
{
	int32		nlines;
	int32		seed = 42;
	const float8 im = 139968.0;
	int32		ngc = 0;
	char	   *seq;
	char	   *out;
	Size		pos = 0;
	Size		olen;
	unsigned char comp[256];
	char		hex[33];
	const char *errstr = NULL;
	pg_locale_t loc;

	if (GetDatabaseEncoding() != PG_UTF8)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("revcomp needs database encoding UTF8, not %s",
						GetDatabaseEncodingName())));
	loc = pg_newlocale_from_collation(DEFAULT_COLLATION_OID);
	if (!loc->collate_is_c || !loc->ctype_is_c)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("revcomp needs a C default collation and ctype")));

	if (PG_ARGISNULL(0))
		for_null(false);
	nlines = PG_GETARG_INT32(0);
	if (nlines <= 0)
		for_null(true);			/* n := array_length('{}', 1) is NULL */

	/* CASE c WHEN 'A' THEN 'T' ... ELSE c END */
	for (int k = 0; k < 256; k++)
		comp[k] = (unsigned char) k;
	comp['A'] = 'T';
	comp['C'] = 'G';
	comp['G'] = 'C';
	comp['T'] = 'A';
	comp['U'] = 'A';
	comp['M'] = 'K';
	comp['R'] = 'Y';
	comp['W'] = 'W';
	comp['S'] = 'S';
	comp['Y'] = 'R';
	comp['K'] = 'M';
	comp['V'] = 'B';
	comp['H'] = 'D';
	comp['D'] = 'H';
	comp['B'] = 'V';
	comp['N'] = 'N';

	/* fasta-style generation: IUB codes, then homo sapiens */
	seq = palloc((Size) nlines * LINE);
	for (int32 i = 1; i <= nlines; i++)
	{
		for (int j = 1; j <= LINE; j++)
		{
			float8		r;
			int			k = 0;

			seed = int4_add(int4_mul(seed, 3877), 29573) % 139968;
			r = float8_div((float8) seed, im);
			if (i <= nlines / 2)
			{
				while (k < 14 && !float8_lt(r, iub_p[k]))
					k++;
				seq[pos++] = iub_c[k];
			}
			else
			{
				while (k < 3 && !float8_lt(r, hs_p[k]))
					k++;
				seq[pos++] = hs_c[k];
			}
		}
		if (i == PG_INT32_MAX)
			break;
	}

	/* reverse complement, lines joined by '\n' */
	olen = (Size) nlines * (LINE + 1) - 1;
	out = palloc(olen);
	pos = 0;
	for (int32 i = nlines; i >= 1; i--)
	{
		const char *line = seq + (Size) (i - 1) * LINE;

		for (int j = LINE; j >= 1; j--)
		{
			unsigned char c = comp[(unsigned char) pg_ascii_toupper((unsigned char) line[j - 1])];

			if (c == 'G' || c == 'C')
				ngc = int4_add(ngc, 1);
			out[pos++] = (char) c;
		}
		if (i > 1)
			out[pos++] = '\n';
	}

	if (!pg_md5_hash(out, olen, hex, &errstr))
		ereport(ERROR,
				(errcode(ERRCODE_OUT_OF_MEMORY),
				 errmsg("could not compute %s hash: %s", "MD5", errstr)));

	PG_RETURN_TEXT_P(cstring_to_text(psprintf("%d/%s", ngc, hex)));
}
