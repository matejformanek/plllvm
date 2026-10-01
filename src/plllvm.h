/*-------------------------------------------------------------------------
 *
 * plllvm.h
 *
 *			  internal declarations of the PL/LLVM procedural language
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_H
#define PLLLVM_H

#include "fmgr.h"

/*
 * The language is built on funccache (cached_function_compile), which
 * appeared in PostgreSQL 18.  Only 20devel is checked (see PG_PIN).
 */
#if PG_VERSION_NUM < 180000
#error "plllvm requires PostgreSQL 18 or later"
#endif

/* keep in sync with META.json; plllvm.control carries major.minor only */
#define PLLLVM_VERSION "0.1.0"

/*
 * Probes of the fmgr ABI.  They are compiled into plllvm_types.bc by clang
 * and into the library by the server's compiler, and must agree.
 *
 * PLLLVM_TYPES_VERSION, the version stored next to them in the .bc, is not
 * defined here: the Makefile passes a checksum of plllvm_types.c and this
 * file to the .bc and to plllvm_jit.o.
 */
#define PLLLVM_LAYOUT \
	{ \
		sizeof(Datum), \
		sizeof(NullableDatum), \
		offsetof(NullableDatum, isnull), \
		offsetof(FunctionCallInfoBaseData, flinfo), \
		offsetof(FunctionCallInfoBaseData, isnull), \
		offsetof(FunctionCallInfoBaseData, nargs), \
		offsetof(FunctionCallInfoBaseData, args) \
	}

/* host functions called from JIT-compiled code (plllvm_runtime.c) */
pg_noreturn extern void plllvm_error(int32 sqlstate, const char *msg);
extern void plllvm_notice(const char *msg);
pg_noreturn extern void plllvm_rt_int_overflow(void);
pg_noreturn extern void plllvm_rt_bigint_overflow(void);
pg_noreturn extern void plllvm_rt_div_zero(void);

typedef struct plllvm_host_symbol
{
	const char *name;
	void	   *addr;
} plllvm_host_symbol;

/* terminated by {NULL, NULL} */
extern const plllvm_host_symbol plllvm_host_symbols[];

/* GUCs (plllvm.c) */
extern bool plllvm_regress_test_mode;
extern char *plllvm_types_bc_path;
extern int	plllvm_opt_level;
extern bool plllvm_dump_ir;
extern int	plllvm_max_resident_compiles;
extern int	plllvm_max_ir_instructions;
extern int	plllvm_debug_inject;

/* plllvm.c */
extern const char *plllvm_display_path(const char *path);

#endif							/* PLLLVM_H */
