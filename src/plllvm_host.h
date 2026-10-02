/*-------------------------------------------------------------------------
 *
 * plllvm_host.h
 *
 *			  what JIT-compiled PL/LLVM code shares with the server
 *
 * by Matěj Formánek 2026
 *
 * plllvm_types.c includes only this header, and the version of
 * plllvm_types.bc is a checksum of the two files.  Whatever the .bc does
 * not need belongs in plllvm.h.
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_HOST_H
#define PLLLVM_HOST_H

#include "fmgr.h"

/*
 * The language is built on funccache (cached_function_compile), which
 * appeared in PostgreSQL 18.  Only 20devel is checked (see PG_PIN).
 */
#if PG_VERSION_NUM < 180000
#error "plllvm requires PostgreSQL 18 or later"
#endif

#include "lib/ilist.h"
#include "utils/array.h"

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
		offsetof(FunctionCallInfoBaseData, args), \
		offsetof(plllvm_site, userid), \
		offsetof(plllvm_site, fcinfo), \
		offsetof(plllvm_site, flinfo), \
		offsetof(FmgrInfo, fn_addr), \
		offsetof(FmgrInfo, fn_strict), \
		sizeof(ArrayType), \
		ARR_OVERHEAD_NONULLS(1) \
	}

/* a call site of JIT-compiled code (plllvm_sites.c); its address is in the code */
typedef struct plllvm_site
{
	bool		ready;			/* true, while flinfo matches pg_proc */
	bool		busy;			/* true, while a call through flinfo runs */
	Oid			userid;			/* user whose EXECUTE right was checked, or
								 * InvalidOid */
	FunctionCallInfo fcinfo;	/* nargs slots; fcinfo->flinfo = &flinfo */
	FmgrInfo	flinfo;
	Oid			fn_oid;
	uint32		hashvalue;		/* of fn_oid in PROCOID */
	int16		nargs;
	Oid			rettype;		/* with argtypes, to recognise another
								 * function under the same OID */
	Oid		   *argtypes;
	Oid			collation;
	MemoryContext mcxt;			/* fn_mcxt, replaced at each rebuild */
	const char *signature;		/* as written in the IR */
	const char *search_path;	/* the module's resolution path */
	int64		prepares;		/* for plllvm_call_sites() */
	int64		checks;
	int64		reentries;
	dlist_node	node;			/* in the list the callbacks walk */
} plllvm_site;

/* host functions called from JIT-compiled code (plllvm_runtime.c) */
pg_noreturn extern void plllvm_error(int32 sqlstate, const char *msg);
extern void plllvm_notice(const char *msg);
pg_noreturn extern void plllvm_rt_int_overflow(void);
pg_noreturn extern void plllvm_rt_bigint_overflow(void);
pg_noreturn extern void plllvm_rt_div_zero(void);
extern Datum plllvm_keep(Datum value);
extern void plllvm_scratch_reset(void);
extern Datum plllvm_rt_site_call(plllvm_site *site, NullableDatum *args,
								 bool *isnull);
pg_noreturn extern void plllvm_rt_site_null(plllvm_site *site);
extern ArrayType *plllvm_array_arg(FunctionCallInfo fcinfo, int32 argno,
								   Oid elemtype);
extern ArrayType *plllvm_array_new(Oid elemtype, int32 n);
extern ArrayType *plllvm_array_copy(ArrayType *a);
pg_noreturn extern void plllvm_rt_array_access(ArrayType *a, Oid elemtype);

/* plllvm_spi.c */
extern void *plllvm_spi_prepare(void **slot, const char *sql,
								const char *argtypes, const char *coltypes);
extern int32 plllvm_spi_select_into(FunctionCallInfo fcinfo, void *stmt,
									NullableDatum *args, NullableDatum *out);

#endif							/* PLLLVM_HOST_H */
