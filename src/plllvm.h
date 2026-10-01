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

#include "lib/ilist.h"
#include "utils/array.h"
#include "utils/funccache.h"

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

/* the memory of a running function that calls other functions */
typedef struct plllvm_frame
{
	MemoryContext caller_cxt;	/* context at handler entry: result and kept
								 * values */
	MemoryContext scratch;		/* CurrentMemoryContext of the JIT code */
	struct plllvm_frame *prev;
} plllvm_frame;

/* the sites and constants of one compile (plllvm_sites.c) */
typedef struct plllvm_refs plllvm_refs;

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

extern plllvm_frame *plllvm_cur_frame;
extern void plllvm_frame_push(plllvm_frame *frame, MemoryContext caller);
extern Datum plllvm_frame_copy_out(plllvm_frame *frame, Datum value,
								   int16 typlen);
extern void plllvm_frame_pop(plllvm_frame *frame);

/* host functions that need a frame; NULL-terminated */
extern const char *const plllvm_frame_helpers[];

typedef struct plllvm_host_symbol
{
	const char *name;
	void	   *addr;
} plllvm_host_symbol;

/* terminated by {NULL, NULL} */
extern const plllvm_host_symbol plllvm_host_symbols[];

/* stored in fn_extra; set once a compile succeeded */
#define PLLLVM_FN_MAGIC		2026100101

typedef struct plllvm_function
{
	CachedFunction cfunc;		/* must be first */
	int			magic;
	NameData	proname;		/* for errcontext; funccache zeroes a reused
								 * entry, so nothing here may own memory */
	PGFunction	addr;
	bool		needs_frame;	/* true, when the IR uses a frame helper */
	bool		uses_spi;		/* true, when the IR declares a plllvm_spi_
								 * function */
	bool		readonly;		/* true, when not VOLATILE */
	bool		rettypbyval;
	int16		rettyplen;
	struct plllvm_jit_module *mod;	/* code record, never freed; NULL once
									 * retired */
} plllvm_function;

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

/* plllvm_compile.c */
extern plllvm_function *plllvm_compile_get(FunctionCallInfo fcinfo);
extern void plllvm_compile_unpin(plllvm_function *func);
extern void plllvm_compile_check_scope(HeapTuple procTup);
extern void plllvm_compile_check_body(HeapTuple procTup);

/* plllvm_spi.c */
extern void *plllvm_spi_prepare(void **slot, const char *sql,
								const char *argtypes, const char *coltypes);
extern int32 plllvm_spi_select_into(FunctionCallInfo fcinfo, void *stmt,
									NullableDatum *args, NullableDatum *out);
extern int64 plllvm_spi_statements(void);

/* plllvm_sites.c */
extern void plllvm_sites_init(void);
extern char *plllvm_sites_path(HeapTuple procTup);
extern plllvm_refs *plllvm_refs_begin(int nrefs, Oid collation,
									  const char *search_path,
									  bool check_only);
extern Datum plllvm_refs_add(plllvm_refs *refs, const char *name, int nargs);
extern void plllvm_refs_resolved(plllvm_refs *refs);
extern void plllvm_refs_end(plllvm_refs *refs, bool publish);
extern int	plllvm_refs_sites(plllvm_refs *refs, plllvm_site **sites);
extern void plllvm_sites_idle(plllvm_refs *refs);
extern void plllvm_sites_release(plllvm_refs *refs);

#endif							/* PLLLVM_H */
