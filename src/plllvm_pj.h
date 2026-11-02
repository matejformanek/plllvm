/*-------------------------------------------------------------------------
 *
 * plllvm_pj.h
 *
 *			  declarations of LANGUAGE plpgsql_jit (plllvm_pj.c)
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_PJ_H
#define PLLLVM_PJ_H

/* per backend; plllvm_pj_stats() */
typedef struct plllvm_pj_counters
{
	int64		calls;
	int64		compiled_calls;
	int64		deopts;
	int64		interpreted_calls;
	int64		declines;
	int64		guard_misses;
	int64		null_args;
	int64		plugin_fallbacks;
	int64		capped;
	int64		translations;
	int64		attempts;
	int64		failures;
	int64		boxed_evals;
	int64		resident;
	int64		peak_tuple_bytes;
} plllvm_pj_counters;

/* one side entry of a function, for plllvm_pj_status() */
typedef struct plllvm_pj_info
{
	char	   *signature;
	Oid			collation;
	const char *state;
	const char *reason;			/* NULL unless declined */
	int64		calls;
	const char *last_path;		/* NULL before the first call */
} plllvm_pj_info;

extern plllvm_pj_counters plllvm_pj_count;
extern int	plllvm_pj_infos(Oid fn, plllvm_pj_info **infos);

#endif							/* PLLLVM_PJ_H */
