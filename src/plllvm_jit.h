/*-------------------------------------------------------------------------
 *
 * plllvm_jit.h
 *
 *			  the LLVM-facing API of plllvm, shared by C and C++
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The part shared with the C++ file may use only LLVM-C types (LLVM*Ref),
 *    as core's jit/llvmjit.h.  The rest is for C only.
 *
 */
#ifndef PLLLVM_JIT_H
#define PLLLVM_JIT_H

#ifdef __cplusplus
extern "C"
{
#endif

/* plllvm_error.cpp */
extern void plllvm_enter_fatal_on_oom(void);
extern void plllvm_leave_fatal_on_oom(void);
extern bool plllvm_in_fatal_on_oom(void);
extern void plllvm_reset_after_error(void);
extern void plllvm_assert_in_fatal_section(void);

/* values of plllvm.debug_inject */
#define PLLLVM_INJECT_NONE			0
#define PLLLVM_INJECT_LLVM_FATAL	1
#define PLLLVM_INJECT_BAD_ALLOC		2

extern void plllvm_inject_fault(int kind);

#ifdef __cplusplus
}								/* extern "C" */
#endif

#ifndef __cplusplus

#include "storage/itemptr.h"

/* compiled code, owned by plllvm_jit.c and never freed in v0.1 */
typedef struct plllvm_jit_module
{
	Oid			owner_oid;		/* function, InvalidOid for plllvm_jit_test() */
	TransactionId owner_xmin;	/* pg_proc row compiled, set by the caller */
	ItemPointerData owner_tid;	/* likewise */
	uint64		gen;			/* backend-wide compile number */
	char		symbol[NAMEDATALEN];	/* plllvm_<owner_oid>_<gen> */
	int			opt_level;
	int			ir_instructions;	/* of the user IR, before linking */
	int			helpers_linked; /* host helper definitions pulled in */
	int			cfi_left;		/* calls of plllvm_cfi after optimisation */
	double		parse_bc_ms;
	double		parse_ms;
	double		link_ms;
	double		verify_ms;
	double		resolve_ms;		/* call sites, constants and symbols */
	double		optimize_ms;
	double		emit_ms;
	void	   *addr;			/* entry point */
	bool		needs_frame;	/* true, when the IR uses a frame helper */
	bool		retired;		/* true, when the owner's code was replaced or
								 * dropped; the code itself stays */
	uint32		owner_hash;		/* of owner_oid in PROCOID, set by the caller */
	bool		owner_inval;	/* true, when the owner's row was invalidated
								 * since the last check */
	LocalTransactionId owner_inval_lxid;	/* transaction that may have
											 * dropped the owner, or invalid */
	struct plllvm_refs *refs;	/* call sites and constants, or NULL */
	struct plllvm_jit_module *next;
} plllvm_jit_module;

typedef struct plllvm_jit_result
{
	plllvm_jit_module *mod;		/* NULL unless code was emitted */
	int			sqlerrcode;		/* 0 on success */
	char	   *errmsg;			/* palloc'd in the caller's context */
	char	   *errdetail;
	char	   *errhint;
	int			errline;		/* position in the IR, 0 if unknown */
	int			errcol;
	int			ir_instructions;
	int			helpers_linked;
	int			cfi_left;		/* -1 when not optimised */
	bool		needs_frame;
	bool		uses_spi;
} plllvm_jit_result;

typedef struct plllvm_jit_session_info
{
	char	   *llvm_version;
	char	   *triple;			/* of plllvm_types.bc */
	char	   *data_layout;
	char	   *libllvm;		/* file of the loaded libLLVM */
	char	   *types_bc;		/* file the session was set up from */
	double		init_ms;
	int64		compiles;
	int64		compile_failures;
	int64		retired;
} plllvm_jit_session_info;

/* plllvm_jit.c */
extern void plllvm_jit_session_ensure(void);
extern void plllvm_jit_get_session_info(plllvm_jit_session_info *info);
extern bool plllvm_jit_compile(Oid owner_oid, Oid collation,
							   const char *search_path, const char *ir,
							   int opt_level, plllvm_jit_result *result);
extern bool plllvm_jit_check(const char *ir, const char *search_path,
							 plllvm_jit_result *result);
extern void plllvm_jit_retire(plllvm_jit_module *mod);
extern void plllvm_jit_owner_inval(uint32 hashvalue);
extern void plllvm_jit_retire_dropped(void);
extern plllvm_jit_module *plllvm_jit_modules(void);

#endif							/* !__cplusplus */

#endif							/* PLLLVM_JIT_H */
