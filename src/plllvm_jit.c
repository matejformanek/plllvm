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
 * 4) Code is released only at use_count 0, and the handler pins it through
 *    the call, including the copy-out of the result.  Calls reach it only
 *    through its funccache entry, which is rechecked before each call.  It
 *    is freed at the next compile, never in a callback.  A body must not
 *    hand out pointers to its code or data (README, Security).  Each module
 *    has its own resource tracker; releasing one without removing it would
 *    hand the code to the JITDylib's default tracker.
 *
 * 5) Call sites and constants are resolved between verify and symbol
 *    resolution, outside the section, with PostgreSQL's own errors
 *    (plllvm_sites.c).  Their globals then become addresses and Datums.
 *
 * 6) The body is not trusted to check for interrupts or the stack depth:
 *    with plllvm.auto_checks, checks_insert() adds the calls its loops and
 *    recursions lack, before anything is linked or optimised.
 *
 */
#include "postgres.h"

#include <dlfcn.h>
#include <sys/stat.h>

#include "jit/jit.h"
#include "nodes/pg_list.h"
#include "portability/instr_time.h"
#include "storage/ipc.h"
#include "utils/memutils.h"

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

/* the Makefile sets it, see plllvm_host.h */
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

/* a block or function of checks_insert()'s graphs, sorted by ptr */
typedef struct NodeIndex
{
	const void *ptr;
	int			node;
} NodeIndex;

/* newest first */
static plllvm_jit_module *modules = NULL;

static uint64 plllvm_jit_gen = 0;
static int64 n_compiles = 0;
static int64 n_failures = 0;
static int64 n_retired = 0;
static int	n_unfreed = 0;		/* released, not yet freed */

/*
 * The first error LLVM reported to diag_handler(), malloc'd by LLVM.  Not
 * on the stack: code generation reports into a context ORC owns.
 */
static char *diag_error = NULL;

static void plllvm_jit_session_ensure(void);
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
static void released_free(void);
static void tracker_remove(LLVMOrcResourceTrackerRef rt);
static bool build(const char *ir, bool codegen, Oid collation,
				  const plllvm_path *path, int nargs, plllvm_jit_module *mod,
				  LLVMOrcResourceTrackerRef *rt, plllvm_refs **refs,
				  char **optimized_ir, plllvm_jit_result *result);
static bool helpers_load(LLVMContextRef ctx, LLVMModuleRef *hmod,
						 LLVMAttributeRef *attrs, plllvm_jit_result *result);
static bool user_ir_parse(LLVMContextRef ctx, const char *ir,
						  LLVMModuleRef hmod, int nargs, LLVMModuleRef *umod,
						  List **irrefs, plllvm_jit_result *result);
static bool helpers_link(LLVMModuleRef umod, LLVMModuleRef hmod,
						 plllvm_jit_result *result);
static void symbols_internalize(LLVMModuleRef umod, const char *symbol,
								LLVMAttributeRef *attrs, int nattrs);
static bool ir_verify(LLVMModuleRef umod, plllvm_jit_result *result);
static void refs_apply(LLVMContextRef ctx, LLVMModuleRef umod, List *irrefs,
					   bool codegen, Oid collation, const plllvm_path *path,
					   plllvm_refs **refs);
static bool symbols_check(LLVMModuleRef umod, plllvm_jit_result *result);
static bool ir_optimize(LLVMModuleRef umod, int opt_level, char **optimized_ir,
						plllvm_jit_result *result);
static void code_emit(LLVMContextRef ctx, LLVMModuleRef umod,
					  plllvm_jit_module *mod, LLVMOrcResourceTrackerRef *rt,
					  plllvm_jit_result *result);
static void parse_error_set(char *msg, plllvm_jit_result *result);
static bool user_ir_check(LLVMContextRef ctx, LLVMModuleRef umod,
						  LLVMModuleRef hmod, int nargs, List **irrefs,
						  plllvm_jit_result *result);
static bool global_check(LLVMValueRef gv, LLVMModuleRef hmod, int nargs,
						 List **irrefs, plllvm_jit_result *result);
static bool ir_ref_check(LLVMValueRef gv, const char *name, int *nargs,
						 plllvm_jit_result *result);
static bool arg_index_check(LLVMValueRef gv, const char *name, int nargs,
							plllvm_jit_result *result);
static bool llvm_global_check(LLVMValueRef gv, const char *name,
							  plllvm_jit_result *result);
static bool spi_slot_check(LLVMModuleRef umod, plllvm_jit_result *result);
static void checks_insert(LLVMContextRef ctx, LLVMModuleRef umod,
						  plllvm_jit_result *result);
static void block_checks(LLVMBasicBlockRef bb, bool *polls,
						 bool *checks_stack);
static bool address_taken(LLVMValueRef fn);
static void call_check(LLVMContextRef ctx, LLVMModuleRef umod,
					   LLVMBuilderRef builder, LLVMValueRef *fn,
					   const char *name);
static void graph_build(void **nodes, int n, bool calls, int **off,
						int **adj);
static void edge_add(int *adj, int *nedges, NodeIndex *index, int n,
					 void *target);
static int	node_index_cmp(const void *a, const void *b);
static bool *graph_cut(void **nodes, int n, bool calls, const bool *checked);
static bool call_callee_use(LLVMValueRef user, LLVMUseRef use);
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
static void
plllvm_jit_session_ensure(void)
{
	char		path[MAXPGPATH];
	struct stat st;
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

	/* LLVM would read a FIFO or a device forever, and uninterruptibly */
	if (stat(path, &st) == 0 && !S_ISREG(st.st_mode))
		ereport(ERROR,
				(errcode(ERRCODE_UNDEFINED_FILE),
				 errmsg("PL/LLVM types file \"%s\" is not a regular file",
						plllvm_display_path(path)),
				 errhint("Check the installation of the plllvm extension, or set plllvm.types_bc_path.")));

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
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("could not parse PL/LLVM types file \"%s\"",
							plllvm_display_path(path)),
					 parse_error ? errdetail("%s", parse_error) : 0,
					 errhint("Rebuild and reinstall the plllvm extension.")));
		else if (incompatible != NULL)
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("incompatible PL/LLVM types file \"%s\"",
							plllvm_display_path(path)),
					 errdetail("%s", incompatible),
					 errhint("Rebuild and reinstall the plllvm extension.")));
		else
			ereport(ERROR,
					(errcode(ERRCODE_INTERNAL_ERROR),
					 errmsg("could not create the LLVM JIT: %s", jit_error),
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
 * is refused or the resident cap is reached; the caller raises the ERROR.
 */
bool
plllvm_jit_compile(Oid owner_oid, Oid collation, const plllvm_path *path,
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

	released_free();

	if (n_compiles - n_retired >= plllvm_max_resident_compiles)
	{
		build_error(result, ERRCODE_CONFIGURATION_LIMIT_EXCEEDED,
					pstrdup("too many compiled PL/LLVM functions in this session"),
					psprintf("Resident compiles: %lld, the limit is %d.",
							 (long long) (n_compiles - n_retired),
							 plllvm_max_resident_compiles));
		result->errhint = pstrdup("Reconnect, or raise plllvm.max_resident_compiles.");
		return false;
	}

	mod.owner_oid = owner_oid;
	mod.gen = ++plllvm_jit_gen;
	snprintf(mod.symbol, NAMEDATALEN, "plllvm_%u_" UINT64_FORMAT,
			 owner_oid, mod.gen);
	mod.opt_level = opt_level;

	if (!build(ir, true, collation, path, nargs, &mod, &rt, &refs,
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
plllvm_jit_check(const char *ir, const plllvm_path *path, int nargs,
				 plllvm_jit_result *result)
{
	plllvm_jit_module mod = {0};
	plllvm_refs *refs = NULL;
	bool		ok;

	memset(result, 0, sizeof(*result));

	plllvm_jit_session_ensure();

	ok = build(ir, false, InvalidOid, path, nargs, &mod, NULL, &refs,
			   NULL, result);
	if (refs != NULL)
		plllvm_refs_end(refs, false);

	return ok;
}

/*
 * No entry points at the code any more; the next compile frees it.  Called
 * while unwinding (the language handler's PG_FINALLY), so it must not fail.
 */
void
plllvm_jit_release(plllvm_jit_module *mod)
{
	if (mod->released)
		return;

	if (mod->refs != NULL)
		plllvm_refs_release(mod->refs);
	mod->released = true;
	n_retired++;
	n_unfreed++;
}

/*
 * Free the released modules (note 4)
 */
static void
released_free(void)
{
	plllvm_jit_module **link = &modules;

	while (n_unfreed > 0 && *link != NULL)
	{
		JitCode    *code = (JitCode *) *link;

		if (!code->mod.released)
		{
			link = &code->mod.next;
			continue;
		}

		/* unlinked first: an ERROR below leaks it, nothing worse */
		*link = code->mod.next;
		n_unfreed--;

		if (code->mod.stmts != NULL)
			plllvm_spi_free(code->mod.stmts);
		if (code->mod.refs != NULL)
			plllvm_refs_free(code->mod.refs);

		plllvm_enter_fatal_on_oom();
		tracker_remove(code->rt);
		plllvm_leave_fatal_on_oom();

		pfree(code);
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
 *
 * The steps that take over hmod, umod or ctx do so also on failure; the
 * caller forgets them right after the call, so out: disposes what is left.
 */
static bool
build(const char *ir, bool codegen, Oid collation, const plllvm_path *path,
	  int nargs, plllvm_jit_module *mod, LLVMOrcResourceTrackerRef *rt,
	  plllvm_refs **refs, char **optimized_ir, plllvm_jit_result *result)
{
	LLVMContextRef ctx;
	LLVMModuleRef hmod = NULL;
	LLVMModuleRef umod = NULL;
	LLVMAttributeRef attrs[2];
	instr_time	since;
	bool		linked;
	List	   *irrefs = NIL;

	plllvm_reset_after_error();
	plllvm_enter_fatal_on_oom();

	if (plllvm_debug_inject != PLLLVM_INJECT_NONE)
		plllvm_inject_fault(plllvm_debug_inject);

	INSTR_TIME_SET_CURRENT(since);

	diag_error_clear();
	ctx = LLVMContextCreate();
	LLVMContextSetDiagnosticHandler(ctx, diag_handler, NULL);

	if (!helpers_load(ctx, &hmod, attrs, result))
		goto out;
	mod->parse_bc_ms = elapsed_ms(&since);

	if (!user_ir_parse(ctx, ir, hmod, nargs, &umod, &irrefs, result))
		goto out;
	if (codegen && plllvm_auto_checks)
		checks_insert(ctx, umod, result);
	mod->parse_ms = elapsed_ms(&since);

	linked = helpers_link(umod, hmod, result);
	hmod = NULL;
	if (!linked)
		goto out;
	mod->link_ms = elapsed_ms(&since);

	if (codegen)
		symbols_internalize(umod, mod->symbol, attrs, lengthof(attrs));

	if (!ir_verify(umod, result))
		goto out;
	mod->verify_ms = elapsed_ms(&since);

	if (irrefs != NIL)
		refs_apply(ctx, umod, irrefs, codegen, collation, path, refs);

	if (!symbols_check(umod, result))
		goto out;
	mod->resolve_ms = elapsed_ms(&since);

	if (!codegen)
	{
		result->cfi_left = -1;
		goto out;
	}

	if (!ir_optimize(umod, mod->opt_level, optimized_ir, result))
		goto out;
	mod->optimize_ms = elapsed_ms(&since);

	code_emit(ctx, umod, mod, rt, result);
	ctx = NULL;
	umod = NULL;
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
helpers_load(LLVMContextRef ctx, LLVMModuleRef *hmod, LLVMAttributeRef *attrs,
			 plllvm_jit_result *result)
{
	LLVMValueRef gv;
	LLVMValueRef next;
	LLVMValueRef tmpl;

	if (LLVMParseBitcodeInContext2(ctx, session.types_bc, hmod))
	{
		*hmod = NULL;
		build_error(result, ERRCODE_INTERNAL_ERROR,
					pstrdup("could not parse plllvm_types.bc"),
					diag_error_take());
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
 * Parse the user IR into ctx and check it.  *umod is set also when the
 * check fails.
 */
static bool
user_ir_parse(LLVMContextRef ctx, const char *ir, LLVMModuleRef hmod,
			  int nargs, LLVMModuleRef *umod, List **irrefs,
			  plllvm_jit_result *result)
{
	LLVMMemoryBufferRef buf;
	char	   *msg;

	/* the IR is NUL-terminated, but the length excludes the NUL */
	buf = LLVMCreateMemoryBufferWithMemoryRange(ir, strlen(ir), "plllvm", true);
	if (LLVMParseIRInContext2(ctx, buf, umod, &msg))
	{
		*umod = NULL;
		parse_error_set(msg, result);
	}
	LLVMDisposeMemoryBuffer(buf);

	return *umod != NULL &&
		user_ir_check(ctx, *umod, hmod, nargs, irrefs, result);
}

/*
 * Link the helpers into umod.  The linker takes hmod, also on failure.
 */
static bool
helpers_link(LLVMModuleRef umod, LLVMModuleRef hmod, plllvm_jit_result *result)
{
	int			ndefs;

	LLVMSetTarget(umod, session.triple);
	LLVMSetDataLayout(umod, session.layout);

	ndefs = count_definitions(umod);
	/* only the helpers the IR uses come along, they are linkonce_odr */
	if (LLVMLinkModules2(umod, hmod))
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("could not link the IR with the host API: %s",
							 diag_error ? diag_error : "unknown error"),
					NULL);
		return false;
	}
	result->helpers_linked = count_definitions(umod) - ndefs;

	return true;
}

/*
 * One JITDylib holds every module: export only the entry point, under a
 * name unique in the session, and let the helpers inline everywhere.
 * Names starting with "llvm." (llvm.used, ...) need appending linkage.
 *
 * The module gets that name too: ORC names a module's init symbol after
 * it, and on macOS even a global in an Objective-C section makes one.
 */
static void
symbols_internalize(LLVMModuleRef umod, const char *symbol,
					LLVMAttributeRef *attrs, int nattrs)
{
	LLVMValueRef fn;
	LLVMValueRef gv;

	LLVMSetModuleIdentifier(umod, symbol, strlen(symbol));

	fn = LLVMGetNamedFunction(umod, "f");
	LLVMSetValueName2(fn, symbol, strlen(symbol));

	for (gv = LLVMGetFirstFunction(umod); gv; gv = LLVMGetNextFunction(gv))
	{
		if (LLVMIsDeclaration(gv))
			continue;
		if (gv != fn)
			LLVMSetLinkage(gv, LLVMInternalLinkage);
		for (int i = 0; i < nattrs; i++)
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

static bool
ir_verify(LLVMModuleRef umod, plllvm_jit_result *result)
{
	char	   *msg;
	bool		failed;

	/* the message is allocated also on success */
	failed = LLVMVerifyModule(umod, LLVMReturnStatusAction, &msg);
	if (failed)
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("invalid IR: %s", first_line(msg)), NULL);
	LLVMDisposeMessage(msg);

	return !failed;
}

/*
 * Resolve the call sites and constants outside the section and replace
 * their globals.  An ERROR disposes umod and ctx and is rethrown.
 */
static void
refs_apply(LLVMContextRef ctx, LLVMModuleRef umod, List *irrefs, bool codegen,
		   Oid collation, const plllvm_path *path, plllvm_refs **refs)
{
	Datum	   *values = palloc(list_length(irrefs) * sizeof(Datum));
	plllvm_refs *volatile vrefs = NULL;
	LLVMTypeRef i64 = LLVMInt64TypeInContext(ctx);

	plllvm_leave_fatal_on_oom();

	PG_TRY();
	{
		int			i = 0;

		vrefs = plllvm_refs_begin(list_length(irrefs), collation,
								  path, !codegen);
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

static bool
symbols_check(LLVMModuleRef umod, plllvm_jit_result *result)
{
	const char *name;

	/* ORC would fail the lookup too, but only with an error string */
	if ((name = unresolved_symbol(umod)) != NULL)
	{
		build_error(result, ERRCODE_UNDEFINED_FUNCTION,
					psprintf("undefined symbol \"%s\"", name), NULL);
		return false;
	}

	return true;
}

static bool
ir_optimize(LLVMModuleRef umod, int opt_level, char **optimized_ir,
			plllvm_jit_result *result)
{
	LLVMPassBuilderOptionsRef options = LLVMCreatePassBuilderOptions();
	LLVMErrorRef error;
	char		passes[64];

	/* at O0 only always-inline helpers are inlined, so keep the rest */
	if (opt_level == 0)
		strlcpy(passes, "default<O0>,mem2reg,globaldce", sizeof(passes));
	else
		snprintf(passes, sizeof(passes), "default<O%d>,globaldce", opt_level);

	error = LLVMRunPasses(umod, passes, session.tm, options);
	LLVMDisposePassBuilderOptions(options);
	if (error)
	{
		build_error(result, ERRCODE_INTERNAL_ERROR,
					psprintf("could not optimize the IR: %s",
							 llvm_error_message(error)),
					NULL);
		return false;
	}
	result->cfi_left = count_uses(umod, "plllvm_cfi");
	if (plllvm_dump_ir)
		*optimized_ir = llvm_message(LLVMPrintModuleToString(umod));

	return true;
}

/*
 * Add umod under its own tracker and look up the entry point.  ORC takes
 * the module and the context, also on error.
 */
static void
code_emit(LLVMContextRef ctx, LLVMModuleRef umod, plllvm_jit_module *mod,
		  LLVMOrcResourceTrackerRef *rt, plllvm_jit_result *result)
{
	LLVMOrcThreadSafeContextRef tsc;
	LLVMOrcThreadSafeModuleRef tsm;
	LLVMOrcExecutorAddress addr = 0;
	LLVMErrorRef error;
	char	   *msg;

	tsc = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(ctx);
	tsm = LLVMOrcCreateNewThreadSafeModule(umod, tsc);
	LLVMOrcDisposeThreadSafeContext(tsc);

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
		build_error(result, ERRCODE_INTERNAL_ERROR,
					psprintf("could not emit code: %s", first_line(msg)),
					NULL);

		tracker_remove(*rt);
		*rt = NULL;
	}
	else
		mod->addr = (void *) addr;
}

/*
 * Free the code of a tracker, inside a section.  As llvmjit, the error of
 * the removal is not reported.
 */
static void
tracker_remove(LLVMOrcResourceTrackerRef rt)
{
	LLVMOrcSymbolStringPoolRef pool;

	LLVMConsumeError(LLVMOrcResourceTrackerRemove(rt));
	LLVMOrcReleaseResourceTracker(rt);

	/* as llvmjit, else the names of the module leak */
	pool = LLVMOrcExecutionSessionGetSymbolStringPool(LLVMOrcLLJITGetExecutionSession(session.jit));
	LLVMOrcSymbolStringPoolClearDeadEntries(pool);
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
 *
 * Only the entry point may be visible to other modules, so module asm,
 * aliases and ifuncs, which symbols_internalize() cannot hide, are refused.
 */
static bool
user_ir_check(LLVMContextRef ctx, LLVMModuleRef umod, LLVMModuleRef hmod,
			  int nargs, List **irrefs, plllvm_jit_result *result)
{
	LLVMTypeRef ptr = LLVMPointerTypeInContext(ctx, 0);
	LLVMTypeRef entry_type;
	LLVMValueRef fn;
	LLVMValueRef gv;
	size_t		asmlen;

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

	LLVMGetModuleInlineAsm(umod, &asmlen);
	if (asmlen > 0)
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					pstrdup("the IR must not contain module-level inline assembly"),
					NULL);
		return false;
	}

	if ((gv = LLVMGetFirstGlobalAlias(umod)) != NULL ||
		(gv = LLVMGetFirstGlobalIFunc(umod)) != NULL)
	{
		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("the IR must not define %s \"%s\"",
							 LLVMIsAGlobalAlias(gv) ? "alias" : "ifunc",
							 value_name(gv)),
					pstrdup("Only functions and global variables can be defined."));
		return false;
	}

	for (gv = LLVMGetFirstFunction(umod); gv; gv = LLVMGetNextFunction(gv))
	{
		if (!global_check(gv, hmod, nargs, irrefs, result))
			return false;
	}
	for (gv = LLVMGetFirstGlobal(umod); gv; gv = LLVMGetNextGlobal(gv))
	{
		if (!global_check(gv, hmod, nargs, irrefs, result))
			return false;
	}

	return spi_slot_check(umod, result);
}

/*
 * One function or global variable of the user IR: a definition must not
 * take a reserved name, a declaration must match the host API or name a
 * call site or constant.
 */
static bool
global_check(LLVMValueRef gv, LLVMModuleRef hmod, int nargs, List **irrefs,
			 plllvm_jit_result *result)
{
	const char *name = value_name(gv);
	bool		is_function = LLVMIsAFunction(gv) != NULL;
	LLVMValueRef host;

	if (is_function && LLVMGetIntrinsicID(gv) != 0 && LLVMIsDeclaration(gv))
		return true;

	host = LLVMGetNamedFunction(hmod, name);
	if (host == NULL)
		host = LLVMGetNamedGlobal(hmod, name);
	/* the link renames local names, as clang's .str of Assert() */
	if (host != NULL && (LLVMGetLinkage(host) == LLVMPrivateLinkage ||
						 LLVMGetLinkage(host) == LLVMInternalLinkage))
		host = NULL;

	if (!LLVMIsDeclaration(gv))
	{
		if (strncmp(name, "llvm.", 5) == 0)
			return llvm_global_check(gv, name, result);
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
	else if (!is_function && (name[0] == '\'' || strchr(name, '(') != NULL))
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

	return true;
}

/*
 * A global named "llvm.*" stays external (symbols_internalize()), and the
 * JIT runs no static constructors or destructors.  So only llvm.used,
 * llvm.compiler.used and the empty lists that opt leaves behind may be
 * defined, and no function.
 */
static bool
llvm_global_check(LLVMValueRef gv, const char *name, plllvm_jit_result *result)
{
	LLVMTypeRef type = LLVMGlobalGetValueType(gv);

	if (LLVMIsAFunction(gv))
		goto reserved;

	if (strcmp(name, "llvm.used") == 0 ||
		strcmp(name, "llvm.compiler.used") == 0)
		return true;

	if (strcmp(name, "llvm.global_ctors") == 0 ||
		strcmp(name, "llvm.global_dtors") == 0)
	{
		if (LLVMGetTypeKind(type) == LLVMArrayTypeKind &&
			LLVMGetArrayLength2(type) == 0)
			return true;

		build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
					psprintf("the IR must not define \"%s\"", name),
					pstrdup("PL/LLVM never runs static constructors or destructors."));
		return false;
	}

reserved:
	build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
				psprintf("the IR must not define \"%s\"", name),
				pstrdup("Names starting with \"llvm.\" are reserved for LLVM."));
	return false;
}

/*
 * plllvm_spi_prepare keeps a statement in its slot for good.  Each call
 * must name a slot of its own, a global ptr defined null and used by no
 * other instruction, and always with the same statement and types: a slot
 * shared by two statements would run the first one for both, a slot on
 * the stack would leak a plan per call.
 */
static bool
spi_slot_check(LLVMModuleRef umod, plllvm_jit_result *result)
{
	LLVMValueRef prepare = LLVMGetNamedFunction(umod, "plllvm_spi_prepare");

	if (prepare == NULL)
		return true;

	for (LLVMUseRef use = LLVMGetFirstUse(prepare); use; use = LLVMGetNextUse(use))
	{
		LLVMValueRef call = LLVMGetUser(use);
		LLVMValueRef slot;
		LLVMValueRef first;

		if (!LLVMIsACallInst(call) || !call_callee_use(call, use))
		{
			build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
						pstrdup("plllvm_spi_prepare can only be called directly"),
						NULL);
			return false;
		}

		slot = LLVMGetOperand(call, 0);
		if (!LLVMIsAGlobalVariable(slot) || LLVMIsDeclaration(slot) ||
			LLVMIsGlobalConstant(slot) ||
			LLVMGetTypeKind(LLVMGlobalGetValueType(slot)) != LLVMPointerTypeKind ||
			!LLVMIsNull(LLVMGetInitializer(slot)))
			goto bad_slot;

		for (int i = 1; i <= 3; i++)
		{
			if (!LLVMIsConstant(LLVMGetOperand(call, i)))
			{
				build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
							pstrdup("the statement and the types of plllvm_spi_prepare must be constants"),
							NULL);
				return false;
			}
		}

		/* every use of the slot is checked once, with its first user */
		first = LLVMGetUser(LLVMGetFirstUse(slot));
		for (LLVMUseRef suse = LLVMGetFirstUse(slot); suse; suse = LLVMGetNextUse(suse))
		{
			LLVMValueRef other = LLVMGetUser(suse);

			if (!LLVMIsACallInst(other) ||
				LLVMGetCalledValue(other) != prepare ||
				LLVMGetOperandUse(other, 0) != suse)
				goto bad_slot;
			if (first != call)
				break;
		}

		for (int i = 1; i <= 3; i++)
		{
			if (LLVMGetOperand(call, i) != LLVMGetOperand(first, i))
			{
				build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
							psprintf("statement slot \"%s\" is prepared with different arguments",
									 value_name(slot)),
							pstrdup("Each statement needs a slot of its own."));
				return false;
			}
		}
	}

	return true;

bad_slot:
	build_error(result, ERRCODE_INVALID_FUNCTION_DEFINITION,
				pstrdup("the slot of plllvm_spi_prepare must be a global ptr initialized to null"),
				pstrdup("Each statement needs a slot of its own, used by no other instruction."));
	return false;
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

/*
 * plllvm.auto_checks: add the interrupt and stack depth checks that the
 * body's loops and recursions lack.  The handler checks the stack once per
 * call of @f, which does not help inside it.
 *
 * A block polls when it calls plllvm_cfi or ProcessInterrupts, or reads
 * InterruptPending (CHECK_FOR_INTERRUPTS() as clang compiles it).  A poll
 * before the terminator of every back edge's source, in a DFS forest over
 * the blocks that do not poll, puts one on every loop.  The same over the
 * direct calls between functions whose entries do not both poll and check
 * the stack finds the recursions; there the checks go into the entry,
 * where tail recursion elimination keeps them inside the loop it makes.  A
 * function called through a pointer gets them too.
 *
 * Runs before the helpers are linked, which have loops of their own, and
 * declares a helper only when it is called: an empty body links none.
 */
static void
checks_insert(LLVMContextRef ctx, LLVMModuleRef umod,
			  plllvm_jit_result *result)
{
	LLVMBuilderRef builder = LLVMCreateBuilderInContext(ctx);
	LLVMValueRef cfi = NULL;
	LLVMValueRef check_stack = NULL;
	LLVMValueRef *fns;
	int			nfns = 0;
	bool	   *polled;
	bool	   *stacked;
	bool	   *checked;
	bool	   *cut;

	/* loops */
	for (LLVMValueRef fn = LLVMGetFirstFunction(umod); fn; fn = LLVMGetNextFunction(fn))
	{
		int			n = LLVMCountBasicBlocks(fn);
		LLVMBasicBlockRef *blocks;

		if (n == 0)
			continue;
		nfns++;

		blocks = palloc(n * sizeof(LLVMBasicBlockRef));
		LLVMGetBasicBlocks(fn, blocks);
		polled = palloc(n * sizeof(bool));
		for (int i = 0; i < n; i++)
			block_checks(blocks[i], &polled[i], NULL);

		cut = graph_cut((void **) blocks, n, false, polled);
		for (int i = 0; i < n; i++)
		{
			if (!cut[i])
				continue;
			LLVMPositionBuilderBefore(builder,
									  LLVMGetBasicBlockTerminator(blocks[i]));
			call_check(ctx, umod, builder, &cfi, "plllvm_cfi");
			result->checks_inserted++;
		}
	}

	/* recursion, and calls through pointers */
	fns = palloc(nfns * sizeof(LLVMValueRef));
	polled = palloc(nfns * sizeof(bool));
	stacked = palloc(nfns * sizeof(bool));
	checked = palloc(nfns * sizeof(bool));
	nfns = 0;
	for (LLVMValueRef fn = LLVMGetFirstFunction(umod); fn; fn = LLVMGetNextFunction(fn))
	{
		if (LLVMIsDeclaration(fn))
			continue;
		block_checks(LLVMGetEntryBasicBlock(fn), &polled[nfns], &stacked[nfns]);
		checked[nfns] = polled[nfns] && stacked[nfns];
		fns[nfns++] = fn;
	}

	cut = graph_cut((void **) fns, nfns, true, checked);
	for (int i = 0; i < nfns; i++)
	{
		LLVMValueRef in;

		if (checked[i] || !(cut[i] || address_taken(fns[i])))
			continue;

		/* after the allocas, which mem2reg wants first */
		in = LLVMGetFirstInstruction(LLVMGetEntryBasicBlock(fns[i]));
		while (LLVMIsAAllocaInst(in))
			in = LLVMGetNextInstruction(in);
		LLVMPositionBuilderBefore(builder, in);

		if (!stacked[i])
		{
			call_check(ctx, umod, builder, &check_stack, "plllvm_check_stack");
			result->checks_inserted++;
		}
		if (!polled[i])
		{
			call_check(ctx, umod, builder, &cfi, "plllvm_cfi");
			result->checks_inserted++;
		}
	}

	LLVMDisposeBuilder(builder);
}

/*
 * Does bb poll for interrupts, and does it check the stack depth?
 */
static void
block_checks(LLVMBasicBlockRef bb, bool *polls, bool *checks_stack)
{
	*polls = false;
	if (checks_stack)
		*checks_stack = false;

	for (LLVMValueRef in = LLVMGetFirstInstruction(bb); in; in = LLVMGetNextInstruction(in))
	{
		LLVMValueRef v;
		const char *name;

		if (LLVMIsALoadInst(in) && LLVMGetVolatile(in))
			v = LLVMGetOperand(in, 0);
		else if (LLVMIsACallInst(in))
			v = LLVMGetCalledValue(in);
		else
			continue;
		if (!LLVMIsAGlobalValue(v))
			continue;

		name = value_name(v);
		if (LLVMIsALoadInst(in))
			*polls |= strcmp(name, "InterruptPending") == 0;
		else if (strcmp(name, "plllvm_cfi") == 0 ||
				 strcmp(name, "ProcessInterrupts") == 0)
			*polls = true;
		else if (checks_stack && (strcmp(name, "plllvm_check_stack") == 0 ||
								  strcmp(name, "check_stack_depth") == 0))
			*checks_stack = true;
	}
}

/*
 * Is fn used other than as a callee or in a blockaddress?
 */
static bool
address_taken(LLVMValueRef fn)
{
	for (LLVMUseRef use = LLVMGetFirstUse(fn); use; use = LLVMGetNextUse(use))
	{
		LLVMValueRef user = LLVMGetUser(use);

		if (!LLVMIsABlockAddress(user) && !call_callee_use(user, use))
			return true;
	}

	return false;
}

/*
 * Call void name() at the builder, declaring it unless the IR does
 */
static void
call_check(LLVMContextRef ctx, LLVMModuleRef umod, LLVMBuilderRef builder,
		   LLVMValueRef *fn, const char *name)
{
	if (*fn == NULL)
		*fn = LLVMGetNamedFunction(umod, name);
	if (*fn == NULL)
		*fn = LLVMAddFunction(umod, name,
							  LLVMFunctionType(LLVMVoidTypeInContext(ctx),
											   NULL, 0, false));

	LLVMBuildCall2(builder, LLVMGlobalGetValueType(*fn), *fn, NULL, 0, "");
}

/*
 * The graph of nodes for graph_cut(): blocks and their successors, or with
 * calls, defined functions and the defined functions they call directly.
 * The edges of node i go to adj[off[i]] .. adj[off[i + 1] - 1], as indexes
 * into nodes.
 */
static void
graph_build(void **nodes, int n, bool calls, int **off, int **adj)
{
	NodeIndex  *index = palloc(n * sizeof(NodeIndex));
	int			nedges = 0;

	for (int i = 0; i < n; i++)
	{
		index[i].ptr = nodes[i];
		index[i].node = i;
	}
	qsort(index, n, sizeof(NodeIndex), node_index_cmp);

	*off = palloc((n + 1) * sizeof(int));
	*adj = NULL;

	/* count the edges, then store them */
	for (int round = 0; round < 2; round++)
	{
		nedges = 0;
		for (int i = 0; i < n; i++)
		{
			(*off)[i] = nedges;

			if (!calls)
			{
				LLVMValueRef term = LLVMGetBasicBlockTerminator(nodes[i]);

				for (unsigned s = 0; s < LLVMGetNumSuccessors(term); s++)
					edge_add(*adj, &nedges, index, n, LLVMGetSuccessor(term, s));
				continue;
			}

			for (LLVMBasicBlockRef bb = LLVMGetFirstBasicBlock(nodes[i]); bb; bb = LLVMGetNextBasicBlock(bb))
			{
				for (LLVMValueRef in = LLVMGetFirstInstruction(bb); in; in = LLVMGetNextInstruction(in))
				{
					LLVMValueRef callee;

					if (!LLVMIsACallInst(in) && !LLVMIsAInvokeInst(in) &&
						!LLVMIsACallBrInst(in))
						continue;
					callee = LLVMGetCalledValue(in);
					if (LLVMIsAFunction(callee) && !LLVMIsDeclaration(callee))
						edge_add(*adj, &nedges, index, n, callee);
				}
			}
		}
		(*off)[n] = nedges;

		if (round == 0)
			*adj = palloc(nedges * sizeof(int));
	}
}

/*
 * Count an edge to target, and store it once adj is allocated
 */
static void
edge_add(int *adj, int *nedges, NodeIndex *index, int n, void *target)
{
	NodeIndex	key = {.ptr = target};

	if (adj != NULL)
		adj[*nedges] = ((NodeIndex *) bsearch(&key, index, n, sizeof(NodeIndex),
											  node_index_cmp))->node;
	(*nedges)++;
}

static int
node_index_cmp(const void *a, const void *b)
{
	uintptr_t	pa = (uintptr_t) ((const NodeIndex *) a)->ptr;
	uintptr_t	pb = (uintptr_t) ((const NodeIndex *) b)->ptr;

	return (pa > pb) - (pa < pb);
}

/*
 * The back edges' sources of a depth-first forest over the nodes that are
 * not checked, every one not visited yet a root, in order: cut[u] is set
 * for each.  A DFS forest without its back edges has no cycle, so every
 * cycle among these nodes has one in cut.
 */
static bool *
graph_cut(void **nodes, int n, bool calls, const bool *checked)
{
	bool	   *cut = palloc0(n * sizeof(bool));
	char	   *state = palloc0(n); /* 0 new, 1 on the stack, 2 done */
	int		   *stack = palloc(n * sizeof(int));
	int		   *next = palloc(n * sizeof(int)); /* edge to follow */
	int		   *off;
	int		   *adj;

	graph_build(nodes, n, calls, &off, &adj);

	for (int root = 0; root < n; root++)
	{
		int			depth = 0;

		if (checked[root] || state[root] != 0)
			continue;

		state[root] = 1;
		next[root] = off[root];
		stack[depth++] = root;

		while (depth > 0)
		{
			int			u = stack[depth - 1];
			int			v;

			if (next[u] == off[u + 1])
			{
				state[u] = 2;
				depth--;
				continue;
			}

			v = adj[next[u]++];
			if (checked[v])
				continue;
			if (state[v] == 1)
				cut[u] = true;
			else if (state[v] == 0)
			{
				state[v] = 1;
				next[v] = off[v];
				stack[depth++] = v;
			}
		}
	}

	return cut;
}

/*
 * Is use the callee of the call, invoke or callbr user?
 */
static bool
call_callee_use(LLVMValueRef user, LLVMUseRef use)
{
	if (!LLVMIsACallInst(user) && !LLVMIsAInvokeInst(user) &&
		!LLVMIsACallBrInst(user))
		return false;

	/* the callee is the last operand */
	return LLVMGetOperandUse(user, LLVMGetNumOperands(user) - 1) == use;
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
