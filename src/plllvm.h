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

#include "plllvm_host.h"

#include "utils/funccache.h"

/* keep in sync with META.json; plllvm.control carries major.minor only */
#define PLLLVM_VERSION "0.2.0"

/* the memory of a running function that calls other functions */
typedef struct plllvm_frame
{
	MemoryContext caller_cxt;	/* context at handler entry: result and kept
								 * values */
	MemoryContext scratch;		/* CurrentMemoryContext of the JIT code */
	struct plllvm_spi_stmt **stmts; /* the running module's statements */
	struct plllvm_frame *prev;
} plllvm_frame;

/* the sites and constants of one compile (plllvm_sites.c) */
typedef struct plllvm_refs plllvm_refs;

/* where the names of a function's IR resolve (plllvm_sites.c, note 1) */
typedef struct plllvm_path
{
	const char *search_path;	/* the function's own setting, or NULL */
	Oid			nspoid;			/* else pg_catalog, this schema, pg_temp */
} plllvm_path;

/* plllvm_runtime.c */
extern plllvm_frame *plllvm_cur_frame;
extern void plllvm_frame_push(plllvm_frame *frame, MemoryContext caller,
							  struct plllvm_spi_stmt **stmts);
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
	struct plllvm_jit_module *mod;	/* code record; NULL once released */
} plllvm_function;

/* GUCs (plllvm.c) */
extern bool plllvm_regress_test_mode;
extern char *plllvm_types_bc_path;
extern int	plllvm_opt_level;
extern bool plllvm_dump_ir;
extern int	plllvm_max_resident_compiles;
extern int	plllvm_max_ir_instructions;
extern int	plllvm_debug_inject;
extern bool plllvm_auto_checks;
extern bool plllvm_expr_jit;
extern bool plllvm_expr_eager;
extern int	plllvm_expr_opt_level;
extern int	plllvm_expr_max_programs;

/* plllvm.c */
extern const char *plllvm_display_path(const char *path);

/* plllvm_compile.c */
extern plllvm_function *plllvm_compile_get(FunctionCallInfo fcinfo);
extern void plllvm_compile_unpin(plllvm_function *func);
extern void plllvm_compile_check_scope(HeapTuple procTup);
extern void plllvm_compile_check_body(HeapTuple procTup);

/* plllvm_plpgsql.c */
extern int64 plllvm_expr_fired;
extern int64 plllvm_expr_declined;
extern void plllvm_plpgsql_init(void);
extern const char *plllvm_plpgsql_state(void);

/* plllvm_exprjit.c */
struct ExprState;
struct plllvm_expr_env;

extern int64 plllvm_expr_compiled;
extern int64 plllvm_expr_hits;
extern int64 plllvm_expr_failures;
extern int64 plllvm_expr_capped;
extern int64 plllvm_expr_programs;
extern int64 plllvm_expr_compiled_evals;
extern bool plllvm_expr_build_broken;
extern void plllvm_exprjit_install(struct ExprState *state,
								   struct plllvm_expr_env *env);

/* plllvm_spi.c */
extern int64 plllvm_spi_statements(void);
extern void plllvm_spi_free(struct plllvm_spi_stmt *stmts);

/* plllvm_sites.c */
extern void plllvm_sites_init(void);
extern void plllvm_sites_path(HeapTuple procTup, plllvm_path *path);
extern plllvm_refs *plllvm_refs_begin(int nrefs, Oid collation,
									  const plllvm_path *path,
									  bool check_only);
extern Datum plllvm_refs_add(plllvm_refs *refs, const char *name, int nargs);
extern void plllvm_refs_resolved(plllvm_refs *refs);
extern void plllvm_refs_end(plllvm_refs *refs, bool publish);
extern int	plllvm_refs_sites(plllvm_refs *refs, plllvm_site **sites);
extern void plllvm_refs_idle(plllvm_refs *refs);
extern void plllvm_refs_unsure(plllvm_refs *refs);
extern const char *plllvm_refs_running(plllvm_refs *refs, int ncalls);
extern void plllvm_refs_release(plllvm_refs *refs);
extern void plllvm_refs_free(plllvm_refs *refs);

#endif							/* PLLLVM_H */
