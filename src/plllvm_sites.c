/*-------------------------------------------------------------------------
 *
 * plllvm_sites.c
 *
 *			  calls of other functions and constants in PL/LLVM code
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) Names resolve under the function's own search_path, else
 *    "pg_catalog, <its schema>, pg_temp", never under the caller's: a pooled
 *    session must not bind one client's function for another.  The schema
 *    is kept by OID, so that the path follows a rename of it.  As a cached
 *    plan, a site follows the name: it is resolved again whenever its callee
 *    or any schema changes.
 *
 * 2) The fast path of a call is inline in the code (plllvm_types.c).  This
 *    file has the rest: building the FmgrInfo, the EXECUTE check, calls
 *    that cannot use the site's own FmgrInfo, and the callbacks.
 *
 * 3) An FmgrInfo carries one call at a time, as fmgr_security_definer()
 *    and fmgr_sql() assume.  A call that finds its site busy (recursion
 *    through the site, or a flag left by an ERROR) gets a fresh FmgrInfo.
 *    The flags are cleared when no call of the code is left.
 *
 * 4) Sites are released with their code, which deletes their contexts.  The
 *    records themselves stay, like the code.
 *
 * 5) The errcontext of a call costs the fast path nothing: on ERROR, the
 *    busy site is the running call.  That holds only while one call of the
 *    code runs and no ERROR has left a flag behind (note 3): an ERROR
 *    leaving a call under another one drops the line until the code is
 *    idle.  The slow path pushes a callback of its own.
 *
 */
#include "postgres.h"

#include "access/htup_details.h"
#include "catalog/objectaccess.h"
#include "catalog/pg_proc.h"
#include "catalog/pg_type.h"
#include "miscadmin.h"
#include "parser/parse_type.h"
#include "utils/acl.h"
#include "utils/array.h"
#include "utils/builtins.h"
#include "utils/datum.h"
#include "utils/guc.h"
#include "utils/inval.h"
#include "utils/lsyscache.h"
#include "utils/memutils.h"
#include "utils/regproc.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_jit.h"

struct plllvm_refs
{
	MemoryContext cxt;			/* "PL/LLVM module data": all of the below */
	Oid			collation;		/* input collation of the compile */
	const char *search_path;
	int			guc_level;
	bool		check_only;		/* true, when nothing is kept (validator) */
	bool		published;		/* true, while the sites are in the list */
	bool		unsure;			/* true, when a busy flag may be stale */
	int			nsites;
	plllvm_site *sites;
};

/* parent of the sites' contexts and of published module data */
static MemoryContext sites_cxt = NULL;

/* sites of compiled code, walked by the callbacks */
static dlist_head published = DLIST_STATIC_INIT(published);

static void procoid_callback(Datum arg, SysCacheIdentifier cacheid,
							 uint32 hashvalue);
static void namespace_callback(Datum arg, SysCacheIdentifier cacheid,
							   uint32 hashvalue);
static void role_callback(Datum arg, SysCacheIdentifier cacheid,
						  uint32 hashvalue);
static void ref_error_callback(void *arg);
static Datum const_eval(plllvm_refs *refs, const char *name);
static Datum site_add(plllvm_refs *refs, const char *name, int nargs);
static void callee_check(Oid fn_oid, Form_pg_proc proc);
static int	path_set(const char *search_path);
static Oid	site_lookup(plllvm_site *site);
static void rebuild(plllvm_site *site);
static void execute_check(Oid fn_oid);
static Datum call(plllvm_site *site, FunctionCallInfo fcinfo,
				  NullableDatum *args, bool *isnull);
static Datum call_reentrant(plllvm_site *site, NullableDatum *args,
							bool *isnull);


void
plllvm_sites_init(void)
{
	sites_cxt = AllocSetContextCreate(TopMemoryContext,
									  "plllvm - call sites context",
									  ALLOCSET_DEFAULT_SIZES);

	/* role membership, superuser and pg_database_owner decide EXECUTE */
	CacheRegisterSyscacheCallback(PROCOID, procoid_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(NAMESPACEOID, namespace_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(AUTHMEMROLEMEM, role_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(AUTHOID, role_callback, (Datum) 0);
	CacheRegisterSyscacheCallback(DATABASEOID, role_callback, (Datum) 0);
}

/*
 * No callback may allocate or fail
 */
static void
procoid_callback(Datum arg, SysCacheIdentifier cacheid, uint32 hashvalue)
{
	dlist_iter	iter;

	dlist_foreach(iter, &published)
	{
		plllvm_site *site = dlist_container(plllvm_site, node, iter.cur);

		if (hashvalue == 0 || site->hashvalue == hashvalue)
			site->ready = false;
	}

	plllvm_jit_owner_inval(hashvalue);
}

/* a renamed or dropped schema may change what any name resolves to */
static void
namespace_callback(Datum arg, SysCacheIdentifier cacheid, uint32 hashvalue)
{
	dlist_iter	iter;

	dlist_foreach(iter, &published)
		dlist_container(plllvm_site, node, iter.cur)->ready = false;
}

static void
role_callback(Datum arg, SysCacheIdentifier cacheid, uint32 hashvalue)
{
	dlist_iter	iter;

	dlist_foreach(iter, &published)
		dlist_container(plllvm_site, node, iter.cur)->userid = InvalidOid;
}

/*
 * The path names of a function resolve under: its own search_path, or else
 * its schema between pg_catalog and pg_temp (pg_temp last, so that a
 * temporary type cannot shadow a catalog one).  The latter is returned as
 * PATH_NSP and the schema's OID, which path_set() turns into the path of
 * the schema's current name.  A search_path setting never starts with it.
 */
#define PATH_NSP '\001'

char *
plllvm_sites_path(HeapTuple procTup)
{
	Form_pg_proc procStruct = (Form_pg_proc) GETSTRUCT(procTup);
	Datum		proconfig;
	bool		isnull;

	proconfig = SysCacheGetAttr(PROCOID, procTup, Anum_pg_proc_proconfig,
								&isnull);
	if (!isnull)
	{
		Datum	   *elems;
		int			nelems;

		deconstruct_array_builtin(DatumGetArrayTypeP(proconfig), TEXTOID,
								  &elems, NULL, &nelems);
		for (int i = 0; i < nelems; i++)
		{
			char	   *setting = TextDatumGetCString(elems[i]);

			if (pg_strncasecmp(setting, "search_path=", 12) == 0)
				return setting + 12;
		}
	}

	return psprintf("%c%u", PATH_NSP, procStruct->pronamespace);
}

/*
 * Start resolving the nrefs names of a compile.  The path stays set until
 * plllvm_refs_resolved(), or an ERROR's (sub)transaction abort.
 */
plllvm_refs *
plllvm_refs_begin(int nrefs, Oid collation, const char *search_path,
				  bool check_only)
{
	MemoryContext cxt;
	plllvm_refs *refs;

	/* under the caller's context until published, so that an ERROR frees it */
	cxt = AllocSetContextCreate(CurrentMemoryContext, "PL/LLVM module data",
								ALLOCSET_SMALL_SIZES);
	refs = MemoryContextAllocZero(cxt, sizeof(plllvm_refs));
	refs->cxt = cxt;
	refs->collation = collation;
	refs->search_path = MemoryContextStrdup(cxt, search_path);
	refs->check_only = check_only;
	/* final size: fcinfo->flinfo points into it */
	if (!check_only)
		refs->sites = MemoryContextAllocZero(cxt, nrefs * sizeof(plllvm_site));

	refs->guc_level = path_set(refs->search_path);

	return refs;
}

/*
 * Resolve one name: the address of a call site, or the Datum of a constant.
 * nargs is the arity of the site's calls, -1 when it has none.  0 in check
 * mode.
 */
Datum
plllvm_refs_add(plllvm_refs *refs, const char *name, int nargs)
{
	ErrorContextCallback errcallback;
	Datum		result;

	errcallback.callback = ref_error_callback;
	errcallback.arg = unconstify(char *, name);
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	if (name[0] == '\'')
		result = const_eval(refs, name);
	else
		result = site_add(refs, name, nargs);

	error_context_stack = errcallback.previous;

	return refs->check_only ? (Datum) 0 : result;
}

static void
ref_error_callback(void *arg)
{
	const char *name = (const char *) arg;

	if (name[0] == '\'')
		errcontext("PL/LLVM constant \"%s\"", name);
	else
		errcontext("PL/LLVM call site \"%s\"", name);
}

void
plllvm_refs_resolved(plllvm_refs *refs)
{
	AtEOXact_GUC(true, refs->guc_level);
}

/*
 * 'literal'::type, read by the input function at compile time.  Only an
 * immutable one gives the same value in every session that compiles it.
 */
static Datum
const_eval(plllvm_refs *refs, const char *name)
{
	StringInfoData literal;
	const char *p = name + 1;
	Oid			typid;
	int32		typmod;
	Oid			typinput;
	Oid			typioparam;
	int16		typlen;
	bool		typbyval;
	Datum		value;

	initStringInfo(&literal);
	for (;;)
	{
		if (*p == '\0')
			break;
		if (*p == '\'' && *++p != '\'')
			break;
		appendStringInfoChar(&literal, *p++);
	}
	if (strncmp(p, "::", 2) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_SYNTAX_ERROR),
				 errmsg("invalid PL/LLVM constant \"%s\"", name),
				 errdetail("A constant is written as 'literal'::type.")));

	(void) parseTypeString(p + 2, &typid, &typmod, NULL);

	if (get_typtype(typid) == TYPTYPE_DOMAIN ||
		get_typtype(typid) == TYPTYPE_PSEUDO)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM constants cannot have type %s",
						format_type_be(typid))));

	getTypeInputInfo(typid, &typinput, &typioparam);
	if (func_volatile(typinput) != PROVOLATILE_IMMUTABLE)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("input function of type %s is not immutable",
						format_type_be(typid)),
				 errhint("Call the input function through a call site.")));

	value = OidInputFunctionCall(typinput, literal.data, typioparam, typmod);

	get_typlenbyval(typid, &typlen, &typbyval);
	if (!typbyval && !refs->check_only)
	{
		MemoryContext oldcxt = MemoryContextSwitchTo(refs->cxt);

		value = datumCopy(value, false, typlen);
		MemoryContextSwitchTo(oldcxt);
	}

	return value;
}

static Datum
site_add(plllvm_refs *refs, const char *name, int nargs)
{
	HeapTuple	tup;
	Form_pg_proc proc;
	Oid			fn_oid;
	Oid			collation = InvalidOid;
	plllvm_site *site;

	fn_oid = DatumGetObjectId(DirectFunctionCall1(regprocedurein,
												  CStringGetDatum(name)));

	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for function %u", fn_oid);
	proc = (Form_pg_proc) GETSTRUCT(tup);

	callee_check(fn_oid, proc);

	if (nargs >= 0 && nargs != proc->pronargs)
		ereport(ERROR,
				(errcode(ERRCODE_INVALID_FUNCTION_DEFINITION),
				 errmsg("call site \"%s\" is called with %d arguments",
						name, nargs),
				 errdetail("The function takes %d.", proc->pronargs)));

	/* as PL/pgSQL variables get it: the input collation, else the type's */
	for (int i = 0; i < proc->pronargs; i++)
	{
		Oid			argtype = proc->proargtypes.values[i];

		if (type_is_collatable(argtype))
		{
			collation = OidIsValid(refs->collation) ? refs->collation :
				get_typcollation(argtype);
			break;
		}
	}

	if (refs->check_only || nargs < 0)
	{
		ReleaseSysCache(tup);
		return (Datum) 0;
	}

	site = &refs->sites[refs->nsites++];
	site->fcinfo = MemoryContextAllocZero(refs->cxt,
										  SizeForFunctionCallInfo(proc->pronargs));
	InitFunctionCallInfoData(*site->fcinfo, &site->flinfo, proc->pronargs,
							 collation, NULL, NULL);
	site->fn_oid = fn_oid;
	site->hashvalue = GetSysCacheHashValue1(PROCOID, ObjectIdGetDatum(fn_oid));
	site->nargs = proc->pronargs;
	site->rettype = proc->prorettype;
	site->argtypes = MemoryContextAlloc(refs->cxt,
										Max(proc->pronargs, 1) * sizeof(Oid));
	memcpy(site->argtypes, proc->proargtypes.values,
		   proc->pronargs * sizeof(Oid));
	site->collation = collation;
	site->signature = MemoryContextStrdup(refs->cxt, name);
	site->search_path = refs->search_path;

	ReleaseSysCache(tup);

	return PointerGetDatum(site);
}

/*
 * A site has no expression tree and no result info, so it can call only
 * plain functions of fixed types
 */
static void
callee_check(Oid fn_oid, Form_pg_proc proc)
{
	bool		ok;

	if (proc->prokind != PROKIND_FUNCTION)
		ereport(ERROR,
				(errcode(ERRCODE_WRONG_OBJECT_TYPE),
				 errmsg("%s is not a function", format_procedure(fn_oid))));

	ok = !proc->proretset &&
		!IsPolymorphicType(proc->prorettype) &&
		proc->prorettype != ANYOID &&
		proc->prorettype != RECORDOID &&
		proc->prorettype != TRIGGEROID &&
		proc->prorettype != EVENT_TRIGGEROID;
	for (int i = 0; ok && i < proc->pronargs; i++)
		ok = !IsPolymorphicType(proc->proargtypes.values[i]) &&
			proc->proargtypes.values[i] != ANYOID;

	if (!ok)
		ereport(ERROR,
				(errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
				 errmsg("PL/LLVM cannot call function %s",
						format_procedure(fn_oid)),
				 errdetail("Set-returning functions, polymorphic and \"any\" arguments, and record and trigger results are not supported.")));
}

static int
path_set(const char *search_path)
{
	int			level = NewGUCNestLevel();
	char	   *path = NULL;

	if (search_path[0] == PATH_NSP)
	{
		Oid			nspoid = atooid(search_path + 1);
		char	   *nspname = get_namespace_name(nspoid);

		if (nspname == NULL)
			elog(ERROR, "cache lookup failed for namespace %u", nspoid);
		path = psprintf("pg_catalog, %s, pg_temp", quote_identifier(nspname));
		search_path = path;
	}

	(void) set_config_option("search_path", search_path, PGC_USERSET,
							 PGC_S_SESSION, GUC_ACTION_SAVE, true, 0, false);

	if (path != NULL)
		pfree(path);

	return level;
}

/*
 * Publish the sites of compiled code, or free everything
 */
void
plllvm_refs_end(plllvm_refs *refs, bool publish)
{
	if (!publish)
	{
		MemoryContextDelete(refs->cxt);
		return;
	}

	MemoryContextSetParent(refs->cxt, sites_cxt);
	for (int i = 0; i < refs->nsites; i++)
		dlist_push_head(&published, &refs->sites[i].node);
	refs->published = true;
}

int
plllvm_refs_sites(plllvm_refs *refs, plllvm_site **sites)
{
	*sites = refs->sites;
	return refs->nsites;
}

/*
 * No call of the code is left: no site is busy, whatever an ERROR left
 */
void
plllvm_sites_idle(plllvm_refs *refs)
{
	for (int i = 0; i < refs->nsites; i++)
		refs->sites[i].busy = false;
	refs->unsure = false;
}

/*
 * An ERROR leaves a call while other calls of the code run: its busy flags
 * stay (note 5)
 */
void
plllvm_sites_unsure(plllvm_refs *refs)
{
	refs->unsure = true;
}

/*
 * For errcontext: the signature of the site whose call is running, or NULL
 * when that is not certain.  ncalls is the number of running calls of the
 * code.
 */
const char *
plllvm_sites_running(plllvm_refs *refs, int ncalls)
{
	const char *signature = NULL;

	if (ncalls > 1 || refs->unsure)
		return NULL;

	for (int i = 0; i < refs->nsites; i++)
	{
		if (!refs->sites[i].busy)
			continue;
		if (signature != NULL)
			return NULL;
		signature = refs->sites[i].signature;
	}

	return signature;
}

/*
 * The code is retired and not running.  Deleting the contexts also unpins
 * SQL-function callees.  Allocates nothing.
 */
void
plllvm_sites_release(plllvm_refs *refs)
{
	if (!refs->published)
		return;

	for (int i = 0; i < refs->nsites; i++)
	{
		plllvm_site *site = &refs->sites[i];

		if (site->mcxt != NULL)
			MemoryContextDelete(site->mcxt);
		site->mcxt = NULL;
		site->ready = false;
		dlist_delete(&site->node);
	}
	refs->published = false;
}

/*
 * Everything the inline protocol does not do
 */
Datum
plllvm_rt_site_call(plllvm_site *site, NullableDatum *args, bool *isnull)
{
	ErrorContextCallback errcallback;
	Datum		result;

	errcallback.callback = ref_error_callback;
	errcallback.arg = unconstify(char *, site->signature);
	errcallback.previous = error_context_stack;
	error_context_stack = &errcallback;

	if (site->busy)
	{
		result = call_reentrant(site, args, isnull);
		error_context_stack = errcallback.previous;
		return result;
	}

	if (!site->ready)
		rebuild(site);

	/* set before the check, so that an invalidation during it wins */
	if (site->userid != GetUserId())
	{
		site->userid = GetUserId();
		PG_TRY();
		{
			execute_check(site->fn_oid);
		}
		PG_CATCH();
		{
			site->userid = InvalidOid;
			PG_RE_THROW();
		}
		PG_END_TRY();
		site->checks++;
	}

	/* the busy site names itself (note 5) */
	error_context_stack = errcallback.previous;

	return call(site, site->fcinfo, args, isnull);
}

void
plllvm_rt_site_null(plllvm_site *site)
{
	ereport(ERROR,
			(errcode(ERRCODE_NULL_VALUE_NOT_ALLOWED),
			 errmsg("function %s returned NULL", site->signature),
			 errhint("Pass a pointer for the NULL flag.")));
}

/*
 * The OID the site's signature stands for now, under the module's path
 */
static Oid
site_lookup(plllvm_site *site)
{
	HeapTuple	tup;
	Form_pg_proc proc;
	Oid			fn_oid;
	int			level;

	level = path_set(site->search_path);
	fn_oid = DatumGetObjectId(DirectFunctionCall1(regprocedurein,
												  CStringGetDatum(site->signature)));
	AtEOXact_GUC(true, level);

	tup = SearchSysCache1(PROCOID, ObjectIdGetDatum(fn_oid));
	if (!HeapTupleIsValid(tup))
		elog(ERROR, "cache lookup failed for function %u", fn_oid);
	proc = (Form_pg_proc) GETSTRUCT(tup);

	callee_check(fn_oid, proc);

	/* the code was compiled for the old types */
	if (proc->prorettype != site->rettype)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("return type of function %s has changed",
						site->signature),
				 errhint("Replace the calling PL/LLVM function.")));
	if (memcmp(proc->proargtypes.values, site->argtypes,
			   site->nargs * sizeof(Oid)) != 0)
		ereport(ERROR,
				(errcode(ERRCODE_DATATYPE_MISMATCH),
				 errmsg("argument types of function %s have changed",
						site->signature),
				 errhint("Replace the calling PL/LLVM function.")));

	ReleaseSysCache(tup);

	return fn_oid;
}

/*
 * Build the FmgrInfo anew after an invalidation of the callee.  The site
 * is ready before the lookups, so that an invalidation during them makes it
 * not ready again.  It is not busy, so its context can go.
 */
static void
rebuild(plllvm_site *site)
{
	site->ready = true;
	site->userid = InvalidOid;

	PG_TRY();
	{
		Oid			fn_oid = site_lookup(site);
		MemoryContext mcxt;

		site->fn_oid = fn_oid;
		site->hashvalue = GetSysCacheHashValue1(PROCOID,
												ObjectIdGetDatum(fn_oid));

		if (site->mcxt != NULL)
		{
			MemoryContextDelete(site->mcxt);
			site->mcxt = NULL;
		}
		mcxt = AllocSetContextCreate(sites_cxt, "PL/LLVM call site",
									 ALLOCSET_SMALL_SIZES);
		MemoryContextSetIdentifier(mcxt, site->signature);
		site->mcxt = mcxt;

		fmgr_info_cxt(fn_oid, &site->flinfo, mcxt);
		site->prepares++;
	}
	PG_CATCH();
	{
		site->ready = false;
		PG_RE_THROW();
	}
	PG_END_TRY();
}

/* the checks of the executor (ExecInitFunc) */
static void
execute_check(Oid fn_oid)
{
	AclResult	aclresult;

	aclresult = object_aclcheck(ProcedureRelationId, fn_oid, GetUserId(),
								ACL_EXECUTE);
	if (aclresult != ACLCHECK_OK)
		aclcheck_error(aclresult, OBJECT_FUNCTION, get_func_name(fn_oid));
	InvokeFunctionExecuteHook(fn_oid);
}

/*
 * The inline protocol, out of line; only the site's own fcinfo marks the
 * site busy
 */
static Datum
call(plllvm_site *site, FunctionCallInfo fcinfo, NullableDatum *args,
	 bool *isnull)
{
	bool		own = (fcinfo == site->fcinfo);
	Datum		result = (Datum) 0;
	bool		resultnull = true;

	if (fcinfo->flinfo->fn_strict)
	{
		for (int i = 0; i < site->nargs; i++)
		{
			if (args[i].isnull)
				goto out;
		}
	}

	for (int i = 0; i < site->nargs; i++)
		fcinfo->args[i] = args[i];
	fcinfo->isnull = false;
	if (own)
		site->busy = true;
	result = FunctionCallInvoke(fcinfo);
	if (own)
		site->busy = false;
	resultnull = fcinfo->isnull;

out:
	if (resultnull && isnull == NULL)
		plllvm_rt_site_null(site);
	if (isnull != NULL)
		*isnull = resultnull;

	return resultnull ? (Datum) 0 : result;
}

/*
 * A call while the site's FmgrInfo is in use.  The callee still runs in the
 * caller's context, where its result must stay; its FmgrInfo goes after the
 * call (on ERROR, with the scratch).
 */
static Datum
call_reentrant(plllvm_site *site, NullableDatum *args, bool *isnull)
{
	MemoryContext cxt;
	FmgrInfo   *flinfo;
	FunctionCallInfo fcinfo;
	Oid			fn_oid;
	Datum		result;

	fn_oid = site->ready ? site->fn_oid : site_lookup(site);
	execute_check(fn_oid);

	cxt = AllocSetContextCreate(CurrentMemoryContext, "PL/LLVM call site",
								ALLOCSET_SMALL_SIZES);
	flinfo = MemoryContextAlloc(cxt, sizeof(FmgrInfo));
	fmgr_info_cxt(fn_oid, flinfo, cxt);
	fcinfo = MemoryContextAlloc(cxt, SizeForFunctionCallInfo(site->nargs));
	InitFunctionCallInfoData(*fcinfo, flinfo, site->nargs, site->collation,
							 NULL, NULL);
	site->reentries++;

	result = call(site, fcinfo, args, isnull);

	MemoryContextDelete(cxt);

	return result;
}
