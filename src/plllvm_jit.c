/*-------------------------------------------------------------------------
 *
 * plllvm_jit.c
 *
 *			  LLVM session of a backend and its own LLJIT
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) Every call into LLVM runs inside a fatal-on-OOM section, and nothing
 *    raises an ERROR inside one: failures are collected, LLVM objects are
 *    disposed, and the ERROR is raised after leaving the section.  palloc
 *    is used inside, as core does; if it fails, the abort callbacks in
 *    plllvm.c close the section.
 *
 * 2) The triple and the data layout come from plllvm_types.bc, which clang
 *    built for this host, as llvmjit takes them from llvmjit_types.bc
 *    (src/backend/jit/llvm/llvmjit.c).
 *
 * 3) Every compile gets a fresh LLVMContext, which ORC takes over with the
 *    module.  llvmjit shares one context and has to recreate it now and
 *    then to bound the types leaked into it; plllvm compiles far less often.
 *
 * 4) Compiled code is never freed in v0.1: a function may still be running
 *    on the stack when its code is replaced.  Each module has its own
 *    resource tracker, kept for good.  Releasing it would hand the code to
 *    the JITDylib's default tracker, which plllvm never touches.  A failed
 *    add or lookup removes its tracker at once.
 *
 * 5) Call sites and constants are resolved between verify and symbol
 *    resolution, outside the section, with PostgreSQL's own errors
 *    (plllvm_sites.c).  Their globals then become addresses and Datums.
 *
 */
#include "postgres.h"

#include <dlfcn.h>

#include "access/xact.h"
#include "jit/jit.h"
#include "nodes/pg_list.h"
#include "portability/instr_time.h"
#include "storage/ipc.h"
#include "storage/proc.h"
#include "utils/memutils.h"
#include "utils/syscache.h"

#include "plllvm.h"
#include "plllvm_jit.h"

#include <llvm-c/Analysis.h>
#include <llvm-c/BitReader.h>
#include <llvm-c/Core.h>
#include <llvm-c/Error.h>
#include <llvm-c/ExecutionEngine.h>
#include <llvm-c/IRReader.h>
#include <llvm-c/LLJIT.h>
#include <llvm-c/Linker.h>
#include <llvm-c/Orc.h>
#include <llvm-c/OrcEE.h>
#include <llvm-c/Support.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
#include <llvm-c/Transforms/PassBuilder.h>
#include <llvm/Config/llvm-config.h>

#if LLVM_VERSION_MAJOR < 22
#error "plllvm requires LLVM 22 or later"
#endif

/* the Makefile sets it, see plllvm.h */
#ifndef PLLLVM_TYPES_VERSION
#error "PLLLVM_TYPES_VERSION is not defined"
#endif

static struct
{
	bool		initialized;
	char	   *llvm_version;
	char	   *types_bc_path;
	LLVMMemoryBufferRef types_bc;	/* private copy of the file */
	char	   *triple;
	char	   *layout;
	LLVMTargetMachineRef tm;	/* for the passes */
	LLVMOrcLLJITRef jit;
	double		init_ms;
}			session;

/* session lifetime allocations */
static MemoryContext plllvm_jit_cxt = NULL;

typedef struct JitCode
{
	plllvm_jit_module mod;		/* must be first */
	LLVMOrcResourceTrackerRef rt;
} JitCode;

/* a call site or constant of the user IR */
typedef struct IrRef
{
	char	   *name;
	int			nargs;			/* of a site's calls, -1 if it has none */
} IrRef;

/* newest first */
static plllvm_jit_module *modules = NULL;

static uint64 plllvm_jit_gen = 0;
static int64 n_compiles = 0;
static int64 n_failures = 0;
static int64 n_retired = 0;

/*
 * The first error LLVM reported to diag_handler(), malloc'd by LLVM.  Not
 * on the stack: code generation reports into a context ORC owns.
 */
static char *diag_error = NULL;

static void types_bc_locate(char *path);
static char *types_module_check(LLVMModuleRef mod, unsigned llvm_major);
static char *target_machine_create(void);
static char *jit_create(void);
static LLVMOrcObjectLayerRef object_layer_create(void *ctx,
												 LLVMOrcExecutionSessionRef es,
												 const char *triple);
static LLVMErrorRef host_symbols_define(void);
static void log_jit_error(void *ctx, LLVMErrorRef error);
static void plllvm_jit_shutdown(int code, Datum arg);
static bool build(const char *ir, bool codegen, Oid collation,
				  const char *search_path, int nargs, plllvm_jit_module *mod,
				  LLVMOrcResourceTrackerRef *rt, plllvm_refs **refs,
				  char **optimized_ir, plllvm_jit_result *result);
static bool helpers_load(LLVMContextRef ctx, LLVMModuleRef *hmod,
						 LLVMAttributeRef *attrs);
static void parse_error_set(char *msg, plllvm_jit_result *result);
static bool user_ir_check(LLVMContextRef ctx, LLVMModuleRef umod,
						  LLVMModuleRef hmod, int nargs, List **irrefs,
						  plllvm_jit_result *result);
static bool ir_ref_check(LLVMValueRef gv, const char *name, int *nargs,
						 plllvm_jit_result *result);
static bool arg_index_check(LLVMValueRef gv, const char *name, int nargs,
							plllvm_jit_result *result);
static bool is_frame_helper(const char *name);
static const char *unresolved_symbol(LLVMModuleRef mod);
static bool host_symbol_exists(const char *name);
static const char *value_name(LLVMValueRef v);
static int	count_instructions(LLVMModuleRef mod);
static int	count_definitions(LLVMModuleRef mod);
static int	count_uses(LLVMModuleRef mod, const char *name);
static void build_error(plllvm_jit_result *result, int sqlerrcode,
						char *errmsg, char *errdetail);
static char *first_line(const char *msg);
static double elapsed_ms(instr_time *since);
static void diag_handler(LLVMDiagnosticInfoRef info, void *arg);
static void diag_error_clear(void);
static char *diag_error_take(void);
static char *llvm_message(char *msg);
static char *llvm_error_message(LLVMErrorRef error);


/*
 * Set up the LLVM side of the session: load plllvm_types.bc, check that it
 * belongs to this library and this LLVM, and create the target machine.
 *
 * A failed attempt leaves nothing behind, so it is retried on the next
 * call, e.g. after plllvm.types_bc_path was fixed.
 */
void
plllvm_jit_session_ensure(void)
{
	char		path[MAXPGPATH];
	instr_time	starttime;
	instr_time	duration;
	MemoryContext oldcxt;
	LLVMMemoryBufferRef buf;
	LLVMContextRef context;
	LLVMModuleRef mod;
	unsigned	major,
				minor,
				patch;
	char	   *msg;
	char	   *open_error = NULL;
	bool		parse_failed = false;
	char	   *parse_error = NULL;
	char	   *incompatible = NULL;
	char	   *jit_error = NULL;

	if (session.initialized)
		return;

	if (plllvm_jit_cxt == NULL)
		plllvm_jit_cxt = AllocSetContextCreate(TopMemoryContext,
											   "plllvm - jit context",
											   ALLOCSET_DEFAULT_SIZES);

	types_bc_locate(path);

	INSTR_TIME_SET_CURRENT(starttime);

	plllvm_reset_after_error();
	plllvm_enter_fatal_on_oom();

	LLVMInitializeNativeTarget();
	LLVMInitializeNativeAsmPrinter();
	LLVMInitializeNativeAsmParser();

	LLVMGetVersion(&major, &minor, &patch);

	if (LLVMCreateMemoryBufferWithContentsOfFile(path, &buf, &msg))
		open_error = llvm_message(msg);
	else
	{
		/*
		 * LLVM may have mmap'd the file, and a reinstall that rewrites it in
		 * place would then crash the next compile.  Keep a copy.
		 */
		session.types_bc =
			LLVMCreateMemoryBufferWithMemoryRangeCopy(LLVMGetBufferStart(buf),
													  LLVMGetBufferSize(buf),
													  "plllvm_types.bc");
		LLVMDisposeMemoryBuffer(buf);

		/* without a handler, LLVM exits on a bitcode error */
		context = LLVMContextCreate();
		LLVMContextSetDiagnosticHandler(context, diag_handler, NULL);

		if (LLVMParseBitcodeInContext2(context, session.types_bc, &mod))
			parse_failed = true;
		else
		{
			/* owned by the module */
			session.triple = MemoryContextStrdup(plllvm_jit_cxt,
												 LLVMGetTarget(mod));
			session.layout = MemoryContextStrdup(plllvm_jit_cxt,
												 LLVMGetDataLayoutStr(mod));
			incompatible = types_module_check(mod, major);
			LLVMDisposeModule(mod);
		}
		parse_error = diag_error_take();
		LLVMContextDispose(context);

		if (!parse_failed && incompatible == NULL)
			incompatible = target_machine_create();

		if (!parse_failed && incompatible == NULL)
		{
			jit_error = jit_create();
			if (jit_error != NULL)
				LLVMDisposeTargetMachine(session.tm);
		}

		if (parse_failed || incompatible != NULL || jit_error != NULL)
			LLVMDisposeMemoryBuffer(session.types_bc);
	}

	plllvm_leave_fatal_on_oom();

	if (open_error != NULL || parse_failed || incompatible != NULL ||
		jit_error != NULL)
	{
		MemoryContextReset(plllvm_jit_cxt);
		memset(&session, 0, sizeof(session));

		if (open_error != NULL)
			ereport(ERROR,
					(errcode(ERRCODE_UNDEFINED_FILE),
					 errmsg("could not open PL/LLVM types file \"%s\": %s",
							plllvm_display_path(path), open_error),
					 errhint("Check the installation of the plllvm extension, or set plllvm.types_bc_path.")));
		else if (parse_failed)
			ereport(ERROR,
					(errmsg("could not parse PL/LLVM types file \"%s\"",
							plllvm_display_path(path)),
					 parse_error ? errdetail("%s", parse_error) : 0,
					 errhint("Rebuild and reinstall the plllvm extension.")));
		else if (incompatible != NULL)
			ereport(ERROR,
					(errmsg("incompatible PL/LLVM types file \"%s\"",
							plllvm_display_path(path)),
					 errdetail("%s", incompatible),
					 errhint("Rebuild and reinstall the plllvm extension.")));
		else
			ereport(ERROR,
					(errmsg("could not create the LLVM JIT: %s", jit_error),
					 errhint("Check the LLVM installation the plllvm extension was built with.")));
	}

	oldcxt = MemoryContextSwitchTo(plllvm_jit_cxt);
	session.llvm_version = psprintf("%u.%u.%u", major, minor, patch);
	session.types_bc_path = pstrdup(path);
	MemoryContextSwitchTo(oldcxt);

	INSTR_TIME_SET_CURRENT(duration);
	INSTR_TIME_SUBTRACT(duration, starttime);
	session.init_ms = INSTR_TIME_GET_MILLISEC(duration);

	/* once per backend: a failed attempt has nothing to shut down */
	on_proc_exit(plllvm_jit_shutdown, 0);

	session.initialized = true;
}

/*
 * Fill *info with palloc'd copies, setting the session up if needed
 */
void
plllvm_jit_get_session_info(plllvm_jit_session_info *info)
{
	Dl_info		dlinfo;

	plllvm_jit_session_ensure();

	info->llvm_version = pstrdup(session.llvm_version);
	info->triple = pstrdup(session.triple);
	info->data_layout = pstrdup(session.layout);
	if (dladdr((void *) LLVMGetVersion, &dlinfo) != 0 && dlinfo.dli_fname)
		info->libllvm = pstrdup(dlinfo.dli_fname);
	else
		info->libllvm = NULL;
	info->types_bc = pstrdup(session.types_bc_path);
	info->init_ms = session.init_ms;
	info->compiles = n_compiles;
	info->compile_failures = n_failures;
	info->retired = n_retired;
}

/*
 * Compile the IR of a function body (entry point @f) into resident code.
 *
 * Returns false with result->sqlerrcode and the messages set when the IR
 * is refused; the caller raises the ERROR.  Hitting the resident cap is an
 * ERROR right here, before anything is built.
 */
bool
plllvm_jit_compile(Oid owner_oid, Oid collation, const char *search_path,
				   int nargs, const char *ir, int opt_level,
				   plllvm_jit_result *result)
{
	plllvm_jit_module mod = {0};
	LLVMOrcResourceTrackerRef rt;
	plllvm_refs *refs = NULL;
	char	   *optimized_ir = NULL;
	JitCode    *code;

	Assert(opt_level >= 0 && opt_level <= 3);

	memset(result, 0, sizeof(*result));

	plllvm_jit_session_ensure();

	/* retired code counts too, nothing is freed */
	if (n_compiles >= plllvm_max_resident_compiles)
		ereport(ERROR,
				(errcode(ERRCODE_CONFIGURATION_LIMIT_EXCEEDED),
				 errmsg("too many compiled PL/LLVM functions in this session"),
				 errdetail("Compiled code stays in memory until the session ends; %lld compiles are resident.",
						   (long long) n_compiles),
				 errhint("Reconnect, or raise plllvm.max_resident_compiles.")));

	mod.owner_oid = owner_oid;
	mod.gen = ++plllvm_jit_gen;
	snprintf(mod.symbol, NAMEDATALEN, "plllvm_%u_" UINT64_FORMAT,
			 owner_oid, mod.gen);
	mod.opt_level = opt_level;

	if (!build(ir, true, collation, search_path, nargs, &mod, &rt, &refs,
			   &optimized_ir, result))
	{
		if (refs != NULL)
			plllvm_refs_end(refs, false);
		n_failures++;
		return false;
	}

	if (refs != NULL)
		plllvm_refs_end(refs, true);
	mod.refs = refs;

	code = MemoryContextAllocZero(plllvm_jit_cxt, sizeof(JitCode));
	code->mod = mod;
	code->rt = rt;
	code->mod.next = modules;
	modules = &code->mod;
	n_compiles++;

	result->mod = &code->mod;

	ereport(DEBUG1,
			(errmsg_internal("plllvm: %s compiled in %.3f ms (parse_bc %.3f, parse %.3f, link %.3f, verify %.3f, resolve %.3f, optimize %.3f, emit %.3f)",
							 mod.symbol,
							 mod.parse_bc_ms + mod.parse_ms + mod.link_ms +
							 mod.verify_ms + mod.resolve_ms +
							 mod.optimize_ms + mod.emit_ms,
							 mod.parse_bc_ms, mod.parse_ms, mod.link_ms,
							 mod.verify_ms, mod.resolve_ms, mod.optimize_ms,
							 mod.emit_ms),
			 errhidestmt(true),
			 errhidecontext(true)));

	if (optimized_ir != NULL)
		ereport(LOG,
				(errmsg_internal("PL/LLVM IR of %s:\n%s",
								 mod.symbol, optimized_ir)));

	return true;
}

/*
 * Check the IR as plllvm_jit_compile() would, without generating code
 */
bool
plllvm_jit_check(const char *ir, const char *search_path, int nargs,
				 plllvm_jit_result *result)
{
	plllvm_jit_module mod = {0};
	plllvm_refs *refs = NULL;
	bool		ok;

	memset(result, 0, sizeof(*result));

	plllvm_jit_session_ensure();

	ok = build(ir, false, InvalidOid, search_path, nargs, &mod, NULL, &refs,
			   NULL, result);
	if (refs != NULL)
		plllvm_refs_end(refs, false);

	return ok;
}

/*
 * Mark code whose owner was replaced or dropped.  Called while unwinding
 * (the language handler's PG_FINALLY), so it must not fail.
 */
void
plllvm_jit_retire(plllvm_jit_module *mod)
{
	if (mod->retired)
		return;

	mod->retired = true;
	n_retired++;
}

/*
 * Note an invalidation of the owner with this PROCOID hash (0: of all).
 * Called from an invalidation callback, so it allocates nothing.
 *
 * Only a transaction that changed catalogs can have dropped the owner
 * without committing yet.  Its mark holds until it ends; any other mark
 * counts at once (the dropping backend reads its own committed DROP back at
 * the start of its next transaction).
 */
void
plllvm_jit_owner_inval(uint32 hashvalue)
{
	LocalTransactionId lxid = InvalidLocalTransactionId;

	if (TransactionIdIsValid(GetTopTransactionIdIfAny()))
		lxid = MyProc->vxid.lxid;

	for (plllvm_jit_module *mod = modules; mod; mod = mod->next)
	{
		if (OidIsValid(mod->owner_oid) && !mod->retired &&
			(hashvalue == 0 || mod->owner_hash == hashvalue) &&
			!(mod->owner_inval && mod->owner_inval_lxid == MyProc->vxid.lxid))
		{
			mod->owner_inval = true;
			mod->owner_inval_lxid = lxid;
		}
	}
}

/*
 * Retire the code of dropped functions, which funccache never deletes.  A
 * mark of this transaction does not count: its DROP may still roll back.
 * The sites stay, an old activation may still run.
 */
void
plllvm_jit_retire_dropped(void)
{
	for (plllvm_jit_module *mod = modules; mod; mod = mod->next)
	{
		HeapTuple	tuple;

		if (!mod->owner_inval || mod->owner_inval_lxid == MyProc->vxid.lxid)
			continue;

		/* before the lookup, which may mark it again */
		mod->owner_inval = false;

		tuple = SearchSysCache1(PROCOID, ObjectIdGetDatum(mod->owner_oid));
		if (HeapTupleIsValid(tuple))
			ReleaseSysCache(tuple);
		else
			plllvm_jit_retire(mod);
	}
}

/*
 * All compiled code of the session, newest first
 */
plllvm_jit_module *
plllvm_jit_modules(void)
{
	return modules;
}

/*
 * plllvm.types_bc_path, or else plllvm/plllvm_types.bc next to the loaded
 * library, which need not be in $libdir (dynamic_library_path).
 */
static void
types_bc_locate(char *path)
{
	Dl_info		info;

	if (plllvm_types_bc_path != NULL && plllvm_types_bc_path[0] != '\0')
	{
		strlcpy(path, plllvm_types_bc_path, MAXPGPATH);
		return;
	}

	if (dladdr((void *) plllvm_jit_session_ensure, &info) == 0 ||
		info.dli_fname == NULL)
		elog(ERROR, "could not determine the file of the plllvm library");

	strlcpy(path, info.dli_fname, MAXPGPATH);
	get_parent_directory(path);
	join_path_components(path, path, "plllvm/plllvm_types.bc");
}

static LLVMValueRef
types_constant(LLVMModuleRef mod, const char *name)
{
	LLVMValueRef global = LLVMGetNamedGlobal(mod, name);

	if (global == NULL || LLVMIsDeclaration(global))
		return NULL;
	return LLVMGetInitializer(global);
}

/*
 * Compare the constants of plllvm_types.c with the library and the loaded
 * LLVM.  Returns NULL, or an errdetail for the first difference.
 */
static char *
types_module_check(LLVMModuleRef mod, unsigned llvm_major)
{
	static const uint64 layout[] = PLLLVM_LAYOUT;
	LLVMValueRef version;
	LLVMValueRef built_by;
	LLVMValueRef probes;

	version = types_constant(mod, "plllvm_types_version");
	if (version == NULL || !LLVMIsAConstantInt(version))
		return pstrdup("The file is not a plllvm types file.");
	/* a checksum, not worth showing */
	if (LLVMConstIntGetZExtValue(version) != PLLLVM_TYPES_VERSION)
		return pstrdup("The file was built from other plllvm sources than the library.");

	built_by = types_constant(mod, "plllvm_types_llvm_major");
	probes = types_constant(mod, "plllvm_types_layout");
	if (built_by == NULL || !LLVMIsAConstantInt(built_by) ||
		probes == NULL || LLVMGetAggregateElement(probes, lengthof(layout) - 1) == NULL)
		return pstrdup("The file is not a plllvm types file.");

	if (LLVMConstIntGetZExtValue(built_by) != llvm_major)
		return psprintf("The file was built by LLVM %u, the server runs LLVM %u.",
						(unsigned) LLVMConstIntGetZExtValue(built_by), llvm_major);

	for (int i = 0; i < lengthof(layout); i++)
	{
		if (LLVMConstIntGetZExtValue(LLVMGetAggregateElement(probes, i)) != layout[i])
			return psprintf("The file and the library disagree on the fmgr ABI (probe %d).",
							i);
	}

	return NULL;
}

/*
 * Create session.tm for session.triple and check its data layout against
 * the file's.  Returns NULL, or an errdetail with session.tm unset.
 */
static char *
target_machine_create(void)
{
	LLVMTargetRef target;
	LLVMTargetDataRef data;
	char	   *msg;
	char	   *cpu;
	char	   *features;
	char	   *layout;
	char	   *detail = NULL;

	if (LLVMGetTargetFromTriple(session.triple, &target, &msg))
		return psprintf("LLVM has no target for \"%s\": %s",
						session.triple, llvm_message(msg));

	cpu = LLVMGetHostCPUName();
	features = LLVMGetHostCPUFeatures();
	session.tm = LLVMCreateTargetMachine(target, session.triple, cpu, features,
										 LLVMCodeGenLevelDefault,
										 LLVMRelocDefault,
										 LLVMCodeModelJITDefault);
	LLVMDisposeMessage(cpu);
	LLVMDisposeMessage(features);

	data = LLVMCreateTargetDataLayout(session.tm);
	layout = LLVMCopyStringRepOfTargetData(data);
	if (strcmp(layout, session.layout) != 0)
		detail = psprintf("The file has data layout \"%s\", the target machine \"%s\".",
						  session.layout, layout);
	LLVMDisposeMessage(layout);
	LLVMDisposeTargetData(data);

	if (detail != NULL)
	{
		LLVMDisposeTargetMachine(session.tm);
		session.tm = NULL;
	}

	return detail;
}

/*
 * Create session.jit with a twin of session.tm, as llvmjit's instances
 * (llvm_create_jit_instance).  Returns NULL, or the error message.
 */
static char *
jit_create(void)
{
	LLVMTargetMachineRef tm;
	LLVMOrcLLJITBuilderRef builder;
	LLVMOrcDefinitionGeneratorRef generator;
	LLVMErrorRef error;
	char	   *cpu;
	char	   *features;
	char	   *msg;

	cpu = LLVMGetTargetMachineCPU(session.tm);
	features = LLVMGetTargetMachineFeatureString(session.tm);
	tm = LLVMCreateTargetMachine(LLVMGetTargetMachineTarget(session.tm),
								 session.triple, cpu, features,
								 LLVMCodeGenLevelDefault,
								 LLVMRelocDefault,
								 LLVMCodeModelJITDefault);
	LLVMDisposeMessage(cpu);
	LLVMDisposeMessage(features);

	/* the builder takes tm, LLVMOrcCreateLLJIT the builder, also on error */
	builder = LLVMOrcCreateLLJITBuilder();
	LLVMOrcLLJITBuilderSetJITTargetMachineBuilder(builder,
												  LLVMOrcJITTargetMachineBuilderCreateFromTargetMachine(tm));
	LLVMOrcLLJITBuilderSetObjectLinkingLayerCreator(builder,
													object_layer_create,
													NULL);
	error = LLVMOrcCreateLLJIT(&session.jit, builder);
	if (error)
	{
		session.jit = NULL;
		return llvm_error_message(error);
	}

	LLVMOrcExecutionSessionSetErrorReporter(LLVMOrcLLJITGetExecutionSession(session.jit),
											log_jit_error, NULL);

	/* the server's symbols; ours are hidden and defined one by one */
	error = LLVMOrcCreateDynamicLibrarySearchGeneratorForProcess(&generator,
																 LLVMOrcLLJITGetGlobalPrefix(session.jit),
																 NULL, NULL);
	if (!error)
	{
		LLVMOrcJITDylibAddGenerator(LLVMOrcLLJITGetMainJITDylib(session.jit),
									generator);
		error = host_symbols_define();
	}
	if (error)
	{
		msg = llvm_error_message(error);
		LLVMConsumeError(LLVMOrcDisposeLLJIT(session.jit));
		session.jit = NULL;
		return msg;
	}

	/* force symbols in main binary to be loaded, as llvmjit */
	LLVMLoadLibraryPermanently(NULL);

	return NULL;
}

/*
 * The object layer of llvmjit (llvm_create_object_layer), with its
 * debugger and profiler listeners
 */
static LLVMOrcObjectLayerRef
object_layer_create(void *ctx, LLVMOrcExecutionSessionRef es,
					const char *triple)
{
	LLVMOrcObjectLayerRef layer;
	LLVMJITEventListenerRef listener;

	layer = LLVMOrcCreateRTDyldObjectLinkingLayerWithSectionMemoryManagerReserveAlloc(es, true);

	if (jit_debugging_support)
	{
		listener = LLVMCreateGDBRegistrationListener();
		if (listener)
			LLVMOrcRTDyldObjectLinkingLayerRegisterJITEventListener(layer, listener);
	}

	if (jit_profiling_support)
	{
		listener = LLVMCreatePerfJITEventListener();
		if (listener)
			LLVMOrcRTDyldObjectLinkingLayerRegisterJITEventListener(layer, listener);
	}

	return layer;
}

/*
 * Define plllvm_host_symbols as absolute symbols of the main JITDylib
 */
static LLVMErrorRef
host_symbols_define(void)
{
	LLVMOrcCSymbolMapPairs pairs;
	LLVMOrcMaterializationUnitRef mu;
	LLVMErrorRef error;
	int			n = 0;

	while (plllvm_host_symbols[n].name != NULL)
		n++;

	pairs = palloc(n * sizeof(LLVMOrcCSymbolMapPair));
	for (int i = 0; i < n; i++)
	{
		pairs[i].Name = LLVMOrcLLJITMangleAndIntern(session.jit,
													plllvm_host_symbols[i].name);
		pairs[i].Sym.Address = (LLVMOrcExecutorAddress) plllvm_host_symbols[i].addr;
		pairs[i].Sym.Flags.GenericFlags = LLVMJITSymbolGenericFlagsExported |
			LLVMJITSymbolGenericFlagsCallable;
		pairs[i].Sym.Flags.TargetFlags = 0;
	}

	/* takes the names, not the array */
	mu = LLVMOrcAbsoluteSymbols(pairs, n);
	pfree(pairs);

	error = LLVMOrcJITDylibDefine(LLVMOrcLLJITGetMainJITDylib(session.jit), mu);
	if (error)
		LLVMOrcDisposeMaterializationUnit(mu);

	return error;
}

/*
 * Errors ORC cannot return to a caller, e.g. from inside a lookup.  Only a
 * WARNING: the caller fails anyway, and we are inside LLVM (as llvmjit).
 */
static void
log_jit_error(void *ctx, LLVMErrorRef error)
{
	elog(WARNING, "error during JITing: %s", llvm_error_message(error));
}

static void
plllvm_jit_shutdown(int code, Datum arg)
{
	/* a FATAL from inside LLVM: do not call back into it */
	if (plllvm_in_fatal_on_oom())
		return;

	plllvm_enter_fatal_on_oom();
	LLVMConsumeError(LLVMOrcDisposeLLJIT(session.jit));
	LLVMDisposeTargetMachine(session.tm);
	LLVMDisposeMemoryBuffer(session.types_bc);
	plllvm_leave_fatal_on_oom();
}

/*
 * The compile pipeline: load the helpers, parse and check the user IR,
 * link, verify, resolve call sites, constants and symbols, and with codegen
 * also optimize, add the module under its own tracker and look up the
 * entry point.
 *
 * Runs in one section and never raises an ERROR there: a failure fills
 * result, disposes what is still ours and returns false.  Only resolving
 * call sites and constants leaves the section; an ERROR there disposes the
 * LLVM objects and is rethrown.  *refs is set once they are resolved, and
 * the caller ends it.
 */
static bool
build(const char *ir, bool codegen, Oid collation, const char *search_path,
	  int nargs, plllvm_jit_module *mod, LLVMOrcResourceTrackerRef *rt,
	  plllvm_refs **refs, char **optimized_ir, plllvm_jit_result *result)
{
	LLVMContextRef ctx;
	LLVMModuleRef hmod = NULL;
	LLVMModuleRef umod = NULL;
	LLVMMemoryBufferRef buf;
	LLVMAttributeRef attrs[2];
	LLVMValueRef fn;
	LLVMErrorRef error;
	instr_time	since;
	const char *name;
	char	   *msg;
	int			ndefs;
	List	   *irrefs = NIL;

	plllvm_reset_after_error();
	plllvm_enter_fatal_on_oom();

	if (plllvm_debug_inject != PLLLVM_INJECT_NONE)
		plllvm_inject_fault(plllvm_debug_inject);

	INSTR_TIME_SET_CURRENT(since);

	diag_error_clear();
	ctx = LLVMContextCreate();
	LLVMContextSetDiagnosticHandler(ctx, diag_handler, NULL);

	if (!helpers_load(ctx, &hmod, attrs))
	{
		build_error(result, ERRCODE_INTERNAL_ERROR,
					pstrdup("could not parse plllvm_types.bc"),
					diag_error_take());
		goto out;
	}
	mod->parse_bc_ms = elapsed_ms(&since);

	/* the IR is NUL-terminated, but the length excludes the NUL */
	buf = LLVMCreateMemoryBufferWithMemoryRange(ir, strlen(ir), "plllvm", true);
	if (LLVMParseIRInContext2(ctx, buf, &umod, &msg))
	{
		umod = NULL;
		parse_error_set(msg, result);
	}
	LLVMDisposeMemoryBuffer(buf);
	if (umod == NULL ||
		!user_ir_check(ctx, umod, hmod, nargs, &irrefs, result))
		goto out;
	mod->parse_ms = elapsed_ms(&since);

	LLVMSetTarget(umod, session.triple);
	LLVMSetDataLayout(umod, session.layout);

	ndefs = count_definitions(umod);
	/* only the helpers the IR uses come along, they are linkonce_odr */
	if (LLVMLinkModules2(umod, hmod))
	{
		hmod = NULL;
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("could not link the IR with the host API: %s",
							 diag_error ? diag_error : "unknown error"),
					NULL);
		goto out;
	}
	hmod = NULL;
	result->helpers_linked = count_definitions(umod) - ndefs;
	mod->link_ms = elapsed_ms(&since);

	/*
	 * One JITDylib holds every module: export only the entry point, under a
	 * name unique in the session, and let the helpers inline everywhere.
	 * Names starting with "llvm." (llvm.used, ...) need appending linkage.
	 */
	if (codegen)
	{
		LLVMValueRef gv;

		fn = LLVMGetNamedFunction(umod, "f");
		LLVMSetValueName2(fn, mod->symbol, strlen(mod->symbol));

		for (gv = LLVMGetFirstFunction(umod); gv; gv = LLVMGetNextFunction(gv))
		{
			if (LLVMIsDeclaration(gv))
				continue;
			if (gv != fn)
				LLVMSetLinkage(gv, LLVMInternalLinkage);
			for (int i = 0; i < lengthof(attrs); i++)
			{
				if (attrs[i] != NULL)
					LLVMAddAttributeAtIndex(gv, LLVMAttributeFunctionIndex,
											attrs[i]);
			}
		}
		for (gv = LLVMGetFirstGlobal(umod); gv; gv = LLVMGetNextGlobal(gv))
		{
			if (!LLVMIsDeclaration(gv) &&
				LLVMGetLinkage(gv) != LLVMPrivateLinkage &&
				strncmp(value_name(gv), "llvm.", 5) != 0)
				LLVMSetLinkage(gv, LLVMInternalLinkage);
		}
	}

	/* the message is allocated also on success */
	if (LLVMVerifyModule(umod, LLVMReturnStatusAction, &msg))
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("invalid IR: %s", first_line(msg)), NULL);
	LLVMDisposeMessage(msg);
	if (result->sqlerrcode != 0)
		goto out;
	mod->verify_ms = elapsed_ms(&since);

	if (irrefs != NIL)
	{
		Datum	   *values = palloc(list_length(irrefs) * sizeof(Datum));
		plllvm_refs *volatile vrefs = NULL;
		LLVMTypeRef i64 = LLVMInt64TypeInContext(ctx);

		plllvm_leave_fatal_on_oom();

		PG_TRY();
		{
			int			i = 0;

			vrefs = plllvm_refs_begin(list_length(irrefs), collation,
									  search_path, !codegen);
			foreach_ptr(IrRef, ref, irrefs)
				values[i++] = plllvm_refs_add(vrefs, ref->name, ref->nargs);
			plllvm_refs_resolved(vrefs);
		}
		PG_CATCH();
		{
			if (vrefs != NULL)
				plllvm_refs_end(vrefs, false);

			plllvm_enter_fatal_on_oom();
			LLVMDisposeModule(umod);
			LLVMContextDispose(ctx);
			diag_error_clear();
			plllvm_leave_fatal_on_oom();

			if (codegen)
				n_failures++;
			PG_RE_THROW();
		}
		PG_END_TRY();

		*refs = vrefs;

		plllvm_enter_fatal_on_oom();

		/* a site becomes its record's address, a constant its Datum */
		for (int i = 0; i < list_length(irrefs); i++)
		{
			IrRef	   *ref = list_nth(irrefs, i);
			LLVMValueRef gv = LLVMGetNamedGlobal(umod, ref->name);
			LLVMValueRef value = LLVMConstInt(i64, values[i], false);

			if (ref->name[0] == '\'')
			{
				LLVMUseRef	use;

				while ((use = LLVMGetFirstUse(gv)) != NULL)
				{
					LLVMValueRef call = LLVMGetUser(use);

					LLVMReplaceAllUsesWith(call, value);
					LLVMInstructionEraseFromParent(call);
				}
			}
			else
				LLVMReplaceAllUsesWith(gv, LLVMConstIntToPtr(value,
															 LLVMTypeOf(gv)));
			LLVMDeleteGlobal(gv);
		}
	}

	/* ORC would fail the lookup too, but only with an error string */
	if ((name = unresolved_symbol(umod)) != NULL)
	{
		build_error(result, ERRCODE_UNDEFINED_FUNCTION,
					psprintf("undefined symbol \"%s\"", name), NULL);
		goto out;
	}
	mod->resolve_ms = elapsed_ms(&since);

	if (!codegen)
	{
		result->cfi_left = -1;
		goto out;
	}

	{
		LLVMPassBuilderOptionsRef options = LLVMCreatePassBuilderOptions();
		char		passes[64];

		/* at O0 only always-inline helpers are inlined, so keep the rest */
		if (mod->opt_level == 0)
			strlcpy(passes, "default<O0>,mem2reg,globaldce", sizeof(passes));
		else
			snprintf(passes, sizeof(passes), "default<O%d>,globaldce",
					 mod->opt_level);

		error = LLVMRunPasses(umod, passes, session.tm, options);
		LLVMDisposePassBuilderOptions(options);
		if (error)
		{
			build_error(result, ERRCODE_INTERNAL_ERROR,
						psprintf("could not optimize the IR: %s",
								 llvm_error_message(error)),
						NULL);
			goto out;
		}
	}
	result->cfi_left = count_uses(umod, "plllvm_cfi");
	if (plllvm_dump_ir)
		*optimized_ir = llvm_message(LLVMPrintModuleToString(umod));
	mod->optimize_ms = elapsed_ms(&since);

	/* ORC owns the module and the context from here, also on error */
	{
		LLVMOrcThreadSafeContextRef tsc;
		LLVMOrcThreadSafeModuleRef tsm;
		LLVMOrcExecutorAddress addr = 0;

		tsc = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(ctx);
		tsm = LLVMOrcCreateNewThreadSafeModule(umod, tsc);
		LLVMOrcDisposeThreadSafeContext(tsc);
		ctx = NULL;
		umod = NULL;

		*rt = LLVMOrcJITDylibCreateResourceTracker(LLVMOrcLLJITGetMainJITDylib(session.jit));

		/* code is generated at the first lookup */
		error = LLVMOrcLLJITAddLLVMIRModuleWithRT(session.jit, *rt, tsm);
		if (!error)
			error = LLVMOrcLLJITLookup(session.jit, &addr, mod->symbol);

		/* code generation may report an error and still succeed */
		if (error)
			msg = llvm_error_message(error);
		else
			msg = diag_error_take();

		if (msg != NULL)
		{
			LLVMOrcSymbolStringPoolRef pool;

			build_error(result, ERRCODE_INTERNAL_ERROR,
						psprintf("could not emit code: %s", first_line(msg)),
						NULL);

			LLVMConsumeError(LLVMOrcResourceTrackerRemove(*rt));
			LLVMOrcReleaseResourceTracker(*rt);
			*rt = NULL;

			/* as llvmjit, else the names of the module leak */
			pool = LLVMOrcExecutionSessionGetSymbolStringPool(LLVMOrcLLJITGetExecutionSession(session.jit));
			LLVMOrcSymbolStringPoolClearDeadEntries(pool);
		}
		else
			mod->addr = (void *) addr;
	}
	mod->emit_ms = elapsed_ms(&since);

out:
	if (hmod != NULL)
		LLVMDisposeModule(hmod);
	if (umod != NULL)
		LLVMDisposeModule(umod);
	if (ctx != NULL)
		LLVMContextDispose(ctx);
	diag_error_clear();

	plllvm_leave_fatal_on_oom();

	mod->ir_instructions = result->ir_instructions;
	mod->helpers_linked = result->helpers_linked;
	mod->cfi_left = result->cfi_left;
	mod->needs_frame = result->needs_frame;

	return result->sqlerrcode == 0;
}

/*
 * Parse the session's plllvm_types.bc into ctx as the module to link the
 * user IR with: drop its constants, make the helpers linkonce_odr, and
 * return the target attributes of plllvm_attr_template.
 */
static bool
helpers_load(LLVMContextRef ctx, LLVMModuleRef *hmod, LLVMAttributeRef *attrs)
{
	LLVMValueRef gv;
	LLVMValueRef next;
	LLVMValueRef tmpl;

	if (LLVMParseBitcodeInContext2(ctx, session.types_bc, hmod))
	{
		*hmod = NULL;
		return false;
	}

	for (gv = LLVMGetFirstGlobal(*hmod); gv; gv = next)
	{
		next = LLVMGetNextGlobal(gv);
		if (!LLVMIsDeclaration(gv) &&
			LLVMGetLinkage(gv) == LLVMExternalLinkage)
			LLVMDeleteGlobal(gv);
	}

	for (gv = LLVMGetFirstFunction(*hmod); gv; gv = LLVMGetNextFunction(gv))
	{
		if (!LLVMIsDeclaration(gv) &&
			LLVMGetLinkage(gv) == LLVMExternalLinkage)
			LLVMSetLinkage(gv, LLVMLinkOnceODRLinkage);
	}

	tmpl = LLVMGetNamedFunction(*hmod, "plllvm_attr_template");
	attrs[0] = LLVMGetStringAttributeAtIndex(tmpl, LLVMAttributeFunctionIndex,
											 "target-cpu", strlen("target-cpu"));
	attrs[1] = LLVMGetStringAttributeAtIndex(tmpl, LLVMAttributeFunctionIndex,
											 "target-features", strlen("target-features"));

	return true;
}

/*
 * The first line of a parser message, without its "plllvm:LINE:COL: error: "
 * prefix, which gives the position
 */
static void
parse_error_set(char *msg, plllvm_jit_result *result)
{
	const char *text = msg;
	int			line;
	int			col;

	if (sscanf(msg, "plllvm:%d:%d:", &line, &col) == 2)
	{
		const char *e = strstr(msg, "error: ");

		result->errline = line;
		result->errcol = col;
		if (e != NULL)
			text = e + strlen("error: ");
	}

	build_error(result, ERRCODE_SYNTAX_ERROR, first_line(text), NULL);
	LLVMDisposeMessage(msg);
}

/*
 * The checks the IR must pass before it is linked with the helpers: the
 * entry point, the size, and the names it defines and declares.  A
 * declaration of a host API function is not type-checked by the linker,
 * hence the explicit comparison.  Call sites and constants are collected
 * into *irrefs.
 */
static bool
user_ir_check(LLVMContextRef ctx, LLVMModuleRef umod, LLVMModuleRef hmod,
			  int nargs, List **irrefs, plllvm_jit_result *result)
{
	LLVMTypeRef ptr = LLVMPointerTypeInContext(ctx, 0);
	LLVMTypeRef entry_type;
	LLVMValueRef fn;
	LLVMValueRef gv;

	fn = LLVMGetNamedFunction(umod, "f");
	if (fn == NULL || LLVMIsDeclaration(fn))
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					pstrdup("IR does not define the entry function \"f\""),
					NULL);
		return false;
	}

	/* a local @f would not be in the object */
	if (LLVMGetLinkage(fn) != LLVMExternalLinkage)
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					pstrdup("entry function \"f\" must have external linkage"),
					NULL);
		return false;
	}

	entry_type = LLVMFunctionType(LLVMInt64TypeInContext(ctx), &ptr, 1, false);
	if (LLVMGlobalGetValueType(fn) != entry_type)
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("entry function \"f\" has type %s",
							 llvm_message(LLVMPrintTypeToString(LLVMGlobalGetValueType(fn)))),
					pstrdup("Expected i64 (ptr)."));
		return false;
	}

	result->ir_instructions = count_instructions(umod);
	if (plllvm_max_ir_instructions > 0 &&
		result->ir_instructions > plllvm_max_ir_instructions)
	{
		build_error(result, ERRCODE_PROGRAM_LIMIT_EXCEEDED,
					pstrdup("PL/LLVM function body has too many instructions"),
					psprintf("%d instructions, the limit is %d.",
							 result->ir_instructions,
							 plllvm_max_ir_instructions));
		result->errhint = pstrdup("Raise plllvm.max_ir_instructions.");
		return false;
	}

	for (int pass = 0; pass < 2; pass++)
	{
		gv = pass == 0 ? LLVMGetFirstFunction(umod) : LLVMGetFirstGlobal(umod);

		for (; gv; gv = pass == 0 ? LLVMGetNextFunction(gv) : LLVMGetNextGlobal(gv))
		{
			const char *name = value_name(gv);
			LLVMValueRef host;

			if (pass == 0 && LLVMGetIntrinsicID(gv) != 0)
				continue;

			host = LLVMGetNamedFunction(hmod, name);
			if (host == NULL)
				host = LLVMGetNamedGlobal(hmod, name);
			/* the link renames local names, as clang's .str of Assert() */
			if (host != NULL && (LLVMGetLinkage(host) == LLVMPrivateLinkage ||
								 LLVMGetLinkage(host) == LLVMInternalLinkage))
				host = NULL;

			if (!LLVMIsDeclaration(gv))
			{
				if (host != NULL || strncmp(name, "plllvm_", 7) == 0)
				{
					build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
								psprintf("the IR must not define \"%s\"", name),
								pstrdup("Names starting with \"plllvm_\" and the names of the host API are reserved."));
					return false;
				}
			}
			else if (host != NULL)
			{
				LLVMTypeRef expected = LLVMGlobalGetValueType(host);
				LLVMTypeRef found = LLVMGlobalGetValueType(gv);

				if (found != expected)
				{
					build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
								psprintf("declaration of \"%s\" does not match the host API",
										 name),
								psprintf("Expected %s, found %s.",
										 llvm_message(LLVMPrintTypeToString(expected)),
										 llvm_message(LLVMPrintTypeToString(found))));
					return false;
				}
				if (!arg_index_check(gv, name, nargs, result))
					return false;
				if (is_frame_helper(name))
					result->needs_frame = true;
				if (strncmp(name, "plllvm_spi_", 11) == 0)
					result->uses_spi = true;
			}
			else if (pass == 1 && (name[0] == '\'' || strchr(name, '(') != NULL))
			{
				IrRef	   *ref = palloc(sizeof(IrRef));

				if (!ir_ref_check(gv, name, &ref->nargs, result))
					return false;
				ref->name = pstrdup(name);
				*irrefs = lappend(*irrefs, ref);
			}
			else if (strncmp(name, "plllvm_", 7) == 0)
			{
				build_error(result, ERRCODE_UNDEFINED_FUNCTION,
							psprintf("host function \"%s\" does not exist", name),
							NULL);
				return false;
			}
		}
	}

	return true;
}

/*
 * A constant ('...::type) may only be the argument of plllvm_const, a call
 * site only the first argument of plllvm_call0..3, always of the same one
 */
static bool
ir_ref_check(LLVMValueRef gv, const char *name, int *nargs,
			 plllvm_jit_result *result)
{
	bool		is_const = (name[0] == '\'');

	*nargs = -1;

	for (LLVMUseRef use = LLVMGetFirstUse(gv); use; use = LLVMGetNextUse(use))
	{
		LLVMValueRef user = LLVMGetUser(use);
		LLVMValueRef callee;
		const char *cname;
		int			n;

		if (!LLVMIsACallInst(user) || LLVMGetOperandUse(user, 0) != use)
			goto misused;

		callee = LLVMGetCalledValue(user);
		cname = LLVMIsAFunction(callee) ? value_name(callee) : "";

		if (is_const)
		{
			if (strcmp(cname, "plllvm_const") != 0)
				goto misused;
			continue;
		}

		if (strncmp(cname, "plllvm_call", 11) != 0 ||
			cname[11] < '0' || cname[11] > '3' || cname[12] != '\0')
			goto misused;

		n = cname[11] - '0';
		if (*nargs >= 0 && *nargs != n)
		{
			build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
						psprintf("call site \"%s\" is called with %d and %d arguments",
								 name, *nargs, n),
						NULL);
			return false;
		}
		*nargs = n;
	}

	return true;

misused:
	build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
				is_const ?
				psprintf("constant \"%s\" must be the argument of plllvm_const",
						 name) :
				psprintf("call site \"%s\" must be the first argument of plllvm_call0 to plllvm_call3",
						 name),
				NULL);
	return false;
}

/*
 * A constant argument number of an argument accessor must be one of the
 * function's (nargs, -1 when there is no function).  Its type is not
 * checked: plllvm_arg_i64 reads any Datum.
 */
static bool
arg_index_check(LLVMValueRef gv, const char *name, int nargs,
				plllvm_jit_result *result)
{
	if (nargs < 0 ||
		(strncmp(name, "plllvm_arg_", 11) != 0 &&
		 strcmp(name, "plllvm_array_arg") != 0))
		return true;

	for (LLVMUseRef use = LLVMGetFirstUse(gv); use; use = LLVMGetNextUse(use))
	{
		LLVMValueRef user = LLVMGetUser(use);
		LLVMValueRef argno;
		long long	n;

		if (!LLVMIsACallInst(user) || LLVMGetCalledValue(user) != gv)
			continue;

		argno = LLVMGetOperand(user, 1);
		if (!LLVMIsAConstantInt(argno))
			continue;

		n = LLVMConstIntGetSExtValue(argno);
		if (n < 0 || n >= nargs)
		{
			build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
						psprintf("\"%s\" reads argument %lld", name, n),
						psprintf("Arguments are numbered from 0; the function has %d.",
								 nargs));
			return false;
		}
	}

	return true;
}

static bool
is_frame_helper(const char *name)
{
	for (int i = 0; plllvm_frame_helpers[i] != NULL; i++)
	{
		if (strcmp(plllvm_frame_helpers[i], name) == 0)
			return true;
	}

	return false;
}

/*
 * The first declaration in mod that the JIT cannot resolve, or NULL
 */
static const char *
unresolved_symbol(LLVMModuleRef mod)
{
	for (LLVMValueRef fn = LLVMGetFirstFunction(mod); fn; fn = LLVMGetNextFunction(fn))
	{
		if (LLVMIsDeclaration(fn) && LLVMGetIntrinsicID(fn) == 0 &&
			!host_symbol_exists(value_name(fn)))
			return value_name(fn);
	}

	for (LLVMValueRef gv = LLVMGetFirstGlobal(mod); gv; gv = LLVMGetNextGlobal(gv))
	{
		if (LLVMIsDeclaration(gv) && !host_symbol_exists(value_name(gv)))
			return value_name(gv);
	}

	return NULL;
}

/*
 * Can the JIT resolve name?  Our own host functions are hidden from
 * dlsym(), the rest comes from the process, as the generator finds it.
 */
static bool
host_symbol_exists(const char *name)
{
	for (int i = 0; plllvm_host_symbols[i].name != NULL; i++)
	{
		if (strcmp(plllvm_host_symbols[i].name, name) == 0)
			return true;
	}

	return dlsym(RTLD_DEFAULT, name) != NULL;
}

static const char *
value_name(LLVMValueRef v)
{
	size_t		len;

	return LLVMGetValueName2(v, &len);
}

static int
count_instructions(LLVMModuleRef mod)
{
	int			n = 0;

	for (LLVMValueRef fn = LLVMGetFirstFunction(mod); fn; fn = LLVMGetNextFunction(fn))
		for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(fn); bb; bb = LLVMGetNextBasicBlock(bb))
			for (LLVMValueRef in = LLVMGetFirstInstruction(bb); in; in = LLVMGetNextInstruction(in))
				n++;

	return n;
}

static int
count_definitions(LLVMModuleRef mod)
{
	int			n = 0;

	for (LLVMValueRef fn = LLVMGetFirstFunction(mod); fn; fn = LLVMGetNextFunction(fn))
	{
		if (!LLVMIsDeclaration(fn))
			n++;
	}

	return n;
}

static int
count_uses(LLVMModuleRef mod, const char *name)
{
	LLVMValueRef fn = LLVMGetNamedFunction(mod, name);
	int			n = 0;

	if (fn == NULL)
		return 0;

	for (LLVMUseRef use = LLVMGetFirstUse(fn); use; use = LLVMGetNextUse(use))
		n++;

	return n;
}

static void
build_error(plllvm_jit_result *result, int sqlerrcode, char *errmsg,
			char *errdetail)
{
	result->sqlerrcode = sqlerrcode;
	result->errmsg = errmsg;
	result->errdetail = errdetail;
}

/*
 * LLVM messages go on with the source line and a caret
 */
static char *
first_line(const char *msg)
{
	const char *nl = strchr(msg, '\n');

	return nl ? pnstrdup(msg, nl - msg) : pstrdup(msg);
}

/*
 * Milliseconds since *since, which moves to now
 */
static double
elapsed_ms(instr_time *since)
{
	instr_time	now;
	instr_time	duration;

	INSTR_TIME_SET_CURRENT(now);
	duration = now;
	INSTR_TIME_SUBTRACT(duration, *since);
	*since = now;

	return INSTR_TIME_GET_MILLISEC(duration);
}

/*
 * Keep the first error.  Must not palloc: it may be called from LLVM code
 * that does not expect a longjmp.
 */
static void
diag_handler(LLVMDiagnosticInfoRef info, void *arg)
{
	if (diag_error == NULL && LLVMGetDiagInfoSeverity(info) == LLVMDSError)
		diag_error = LLVMGetDiagInfoDescription(info);
}

static void
diag_error_clear(void)
{
	if (diag_error != NULL)
		LLVMDisposeMessage(diag_error);
	diag_error = NULL;
}

/*
 * The error kept by diag_handler(), palloc'd, or NULL; clears the slot
 */
static char *
diag_error_take(void)
{
	char	   *msg = diag_error;

	diag_error = NULL;
	return msg ? llvm_message(msg) : NULL;
}

/*
 * palloc'd copy of a message LLVM allocated, which is disposed
 */
static char *
llvm_message(char *msg)
{
	char	   *copy = pstrdup(msg);

	LLVMDisposeMessage(msg);
	return copy;
}

static char *
llvm_error_message(LLVMErrorRef error)
{
	char	   *orig = LLVMGetErrorMessage(error);
	char	   *msg = pstrdup(orig);

	LLVMDisposeErrorMessage(orig);
	return msg;
}
