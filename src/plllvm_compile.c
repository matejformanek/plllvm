/*-------------------------------------------------------------------------
 *
 * plllvm_compile.c
 *
 *			  compiling PL/LLVM functions through the core function cache
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) Code is never freed in v0.1.  funccache may zero and reuse an entry,
 *    or forget one that is still running, so the entry only points at a
 *    record owned by plllvm_jit.c, and retiring just marks it.
 *
 * 2) funccache reuses an entry found through fn_extra without looking at
 *    its hash table again, also one it forgot while a call ran it (after a
 *    replace made during that call).  A compile into it would insert a
 *    second entry under the key of the one that replaced it, so such an
 *    entry is looked up by its key instead.  A retired entry also gets an
 *    invalid fn_xmin, the second guard: if the replace rolls back, the
 *    entry must not match pg_proc again.
 *
 * 3) The validator never goes through funccache.
 *
 */
#include "postgres.h"

#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "funcapi.h"
#include "mb/pg_wchar.h"
#include "utils/builtins.h"
#include "utils/lsyscache.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_jit.h"

typedef struct compile_error_arg
{
	const char *proname;
	const char *src;			/* the body when validating, else NULL */
} compile_error_arg;

static void compile_callback(FunctionCallInfo fcinfo, HeapTuple procTup,
							 const CachedFunctionHashKey *hashkey,
							 CachedFunction *cfunc, bool forValidator);
static void delete_callback(CachedFunction *cfunc);
static void compile_error_callback(void *arg);
pg_noreturn static void report_jit_error(plllvm_jit_result *r,
										 const char *src);
static int	char_position(const char *src, int line, int col);


/*
 * The compiled function of this call, compiling it if needed
 */
plllvm_function *
plllvm_compile_get(FunctionCallInfo fcinfo)
{
	CachedFunction *cfunc = (CachedFunction *) fcinfo->flinfo->fn_extra;
	plllvm_function *func;

	/* forgotten by funccache (note 2) */
	if (cfunc != NULL && cfunc->fn_hashkey == NULL)
		cfunc = NULL;

	func = (plllvm_function *)
		cached_function_compile(fcinfo, cfunc,
								compile_callback, delete_callback,
								sizeof(plllvm_function), false, false);
	Assert(func->magic == PLLLVM_FN_MAGIC);
	fcinfo->flinfo->fn_extra = func;

	return func;
}

static void
compile_callback(FunctionCallInfo fcinfo, HeapTuple procTup,
				 const CachedFunctionHashKey *hashkey,
				 CachedFunction *cfunc, bool forValidator)
{
	plllvm_function *func = (plllvm_function *) cfunc;
	Form_pg_proc procStruct = (Form_pg_proc) GETSTRUCT(procTup);
	plllvm_jit_result r;
	compile_error_arg cbarg;
	ErrorContextCallback errcallback;
	char	   *src;
	char	   *path;
	uint32		hash;
	int16		rettyplen;
	bool		rettypbyval;

	Assert(!forValidator);

	cbarg.proname = NameStr(procStruct->proname);
	cbarg.src = NULL;
	errcallback.callback = compile_error_callback;
	errcallback.arg = &cbarg;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	/* the validator checked it, but pg_proc may have been edited directly */
	plllvm_compile_check_scope(procTup);

	/* on ERROR, these go with the memory context of the call */
	src = TextDatumGetCString(SysCacheGetAttrNotNull(PROCOID, procTup,
													 Anum_pg_proc_prosrc));
	path = plllvm_sites_path(procTup);
	hash = GetSysCacheHashValue1(PROCOID,
								 ObjectIdGetDatum(fcinfo->flinfo->fn_oid));
	get_typlenbyval(procStruct->prorettype, &rettyplen, &rettypbyval);

	if (!plllvm_jit_compile(fcinfo->flinfo->fn_oid, hashkey->inputCollation,
							path, procStruct->pronargs, src, plllvm_opt_level,
							&r))
		report_jit_error(&r, src);

	error_context_stack = errcallback.previous;

	/*
	 * Nothing below may fail: funccache would free a new entry, and a code
	 * record without an entry is never retired.
	 */
	r.mod->owner_xmin = HeapTupleHeaderGetRawXmin(procTup->t_data);
	r.mod->owner_tid = procTup->t_self;
	r.mod->owner_hash = hash;
	func->magic = PLLLVM_FN_MAGIC;
	namestrcpy(&func->proname, NameStr(procStruct->proname));
	func->addr = (PGFunction) r.mod->addr;
	func->needs_frame = r.mod->needs_frame;
	func->uses_spi = r.uses_spi;
	func->readonly = (procStruct->provolatile != PROVOLATILE_VOLATILE);
	func->rettypbyval = rettypbyval;
	func->rettyplen = rettyplen;
	func->mod = r.mod;
	/* the SPI helpers are frame helpers */
	Assert(!func->uses_spi || func->needs_frame);

	pfree(src);
}

/*
 * funccache found the entry stale and nobody is running it.  The code stays
 * resident in v0.1, so only account for it.
 */
static void
delete_callback(CachedFunction *cfunc)
{
	plllvm_function *func = (plllvm_function *) cfunc;

	if (func->mod != NULL)
	{
		if (func->mod->refs != NULL)
			plllvm_sites_release(func->mod->refs);
		plllvm_jit_retire(func->mod);
		func->mod = NULL;
	}
}

/*
 * Release the pin of the call handler.  Runs in its PG_FINALLY, so it must
 * not fail.
 *
 * funccache skips the delete callback of an entry it finds stale while a
 * call is running it, and forgets the entry.  The last call to leave it
 * retires the code instead.
 */
void
plllvm_compile_unpin(plllvm_function *func)
{
	Assert(func->cfunc.use_count > 0);
	func->cfunc.use_count--;

	if (func->cfunc.use_count == 0 && func->mod != NULL &&
		func->mod->refs != NULL)
		plllvm_sites_idle(func->mod->refs);

	if (func->cfunc.use_count == 0 && func->cfunc.fn_hashkey == NULL)
	{
		/* the second guard of note 2 */
		func->cfunc.fn_xmin = InvalidTransactionId;
		delete_callback(&func->cfunc);
	}
}

/*
 * Reject what the handler cannot call: the signature is not part of the
 * body, so the validator checks it also with check_function_bodies = off.
 */
void
plllvm_compile_check_scope(HeapTuple procTup)
{
	Form_pg_proc procStruct = (Form_pg_proc) GETSTRUCT(procTup);
	Oid			rettype = procStruct->prorettype;
	Oid		   *argtypes;
	char	  **argnames;
	char	   *argmodes;
	int			nargs;

	/* a window function gets its arguments through the WindowObject */
	if (procStruct->prokind != PROKIND_FUNCTION)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM does not support procedures or window functions")));

	if (procStruct->proretset)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM functions cannot return sets")));

	/* the constraints of a domain would never be checked */
	if ((get_typtype(rettype) == TYPTYPE_PSEUDO && rettype != VOIDOID) ||
		get_typtype(rettype) == TYPTYPE_DOMAIN ||
		type_is_rowtype(rettype))
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM functions cannot return type %s",
						format_type_be(rettype))));

	nargs = get_func_arg_info(procTup, &argtypes, &argnames, &argmodes);
	for (int i = 0; i < nargs; i++)
	{
		if (argmodes != NULL && argmodes[i] != PROARGMODE_IN)
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/LLVM functions support only IN parameters")));

		if (get_typtype(argtypes[i]) == TYPTYPE_PSEUDO ||
			type_is_rowtype(argtypes[i]))
			ereport(ERROR,
					(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
					 errmsg("PL/LLVM functions cannot accept type %s",
							format_type_be(argtypes[i]))));
	}
}

/*
 * Check the body as a compile would, without generating code
 */
void
plllvm_compile_check_body(HeapTuple procTup)
{
	Form_pg_proc procStruct = (Form_pg_proc) GETSTRUCT(procTup);
	plllvm_jit_result r;
	compile_error_arg cbarg;
	ErrorContextCallback errcallback;
	char	   *src;

	src = TextDatumGetCString(SysCacheGetAttrNotNull(PROCOID, procTup,
													 Anum_pg_proc_prosrc));

	cbarg.proname = NameStr(procStruct->proname);
	cbarg.src = src;
	errcallback.callback = compile_error_callback;
	errcallback.arg = &cbarg;
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	if (!plllvm_jit_check(src, plllvm_sites_path(procTup),
						  procStruct->pronargs, &r))
		report_jit_error(&r, src);

	error_context_stack = errcallback.previous;

	pfree(src);
}

static void
compile_error_callback(void *arg)
{
	compile_error_arg *cbarg = (compile_error_arg *) arg;

	/* in CREATE FUNCTION, point into its text instead */
	if (cbarg->src != NULL && function_parse_error_transpose(cbarg->src))
		return;

	errcontext("compilation of PL/LLVM function \"%s\"", cbarg->proname);
}

static void
report_jit_error(plllvm_jit_result *r, const char *src)
{
	ereport(ERROR,
			(errcode(r->sqlerrcode),
			 errmsg("%s", r->errmsg),
			 r->errdetail ? errdetail("%s", r->errdetail) : 0,
			 r->errhint ? errhint("%s", r->errhint) : 0,
			 r->errline > 0 ?
			 internalerrposition(char_position(src, r->errline, r->errcol)) : 0,
			 r->errline > 0 ? internalerrquery(src) : 0));
}

/*
 * 1-based character offset of a 1-based line and byte column of src,
 * clamped to the text
 */
static int
char_position(const char *src, int line, int col)
{
	const char *s = src;

	for (int l = 1; l < line && *s != '\0'; s++)
	{
		if (*s == '\n')
			l++;
	}

	return pg_mbstrlen_with_len(src, s - src) +
		pg_mbstrlen_with_len(s, Min(Max(col - 1, 0), (int) strlen(s))) + 1;
}
