/*-------------------------------------------------------------------------
 *
 * plllvm_jit.c
 *
 *			  LLVM session of a backend
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
 *    is used inside, as core does.
 *
 * 2) The triple and the data layout come from plllvm_types.bc, which clang
 *    built for this host, as llvmjit takes them from llvmjit_types.bc
 *    (src/backend/jit/llvm/llvmjit.c).
 *
 */
#include "postgres.h"

#include <dlfcn.h>

#include "portability/instr_time.h"
#include "utils/memutils.h"

#include "plllvm.h"
#include "plllvm_jit.h"

#include <llvm-c/BitReader.h>
#include <llvm-c/Core.h>
#include <llvm-c/Target.h>
#include <llvm-c/TargetMachine.h>
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
	LLVMTargetMachineRef tm;
	double		init_ms;
}			session;

/* session lifetime allocations */
static MemoryContext plllvm_jit_cxt = NULL;

/*
 * The first error LLVM reported to diag_handler(), malloc'd by LLVM.  Not
 * on the stack: code generation reports into a context ORC owns.
 */
static char *diag_error = NULL;

static void types_bc_locate(char *path);
static char *types_module_check(LLVMModuleRef mod, unsigned llvm_major);
static char *target_machine_create(void);
static void diag_handler(LLVMDiagnosticInfoRef info, void *arg);
static char *diag_error_take(void);
static char *llvm_message(char *msg);


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

		if (parse_failed || incompatible != NULL)
			LLVMDisposeMemoryBuffer(session.types_bc);
	}

	plllvm_leave_fatal_on_oom();

	if (open_error != NULL || parse_failed || incompatible != NULL)
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
		else
			ereport(ERROR,
					(errmsg("incompatible PL/LLVM types file \"%s\"",
							plllvm_display_path(path)),
					 errdetail("%s", incompatible),
					 errhint("Rebuild and reinstall the plllvm extension.")));
	}

	oldcxt = MemoryContextSwitchTo(plllvm_jit_cxt);
	session.llvm_version = psprintf("%u.%u.%u", major, minor, patch);
	session.types_bc_path = pstrdup(path);
	MemoryContextSwitchTo(oldcxt);

	INSTR_TIME_SET_CURRENT(duration);
	INSTR_TIME_SUBTRACT(duration, starttime);
	session.init_ms = INSTR_TIME_GET_MILLISEC(duration);

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

	/* the same sources from here on, so the same shapes */
	built_by = types_constant(mod, "plllvm_types_llvm_major");
	if (LLVMConstIntGetZExtValue(built_by) != llvm_major)
		return psprintf("The file was built by LLVM %u, the server runs LLVM %u.",
						(unsigned) LLVMConstIntGetZExtValue(built_by), llvm_major);

	probes = types_constant(mod, "plllvm_types_layout");
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
 * Keep the first error.  Must not palloc: it may be called from LLVM code
 * that does not expect a longjmp.
 */
static void
diag_handler(LLVMDiagnosticInfoRef info, void *arg)
{
	if (diag_error == NULL && LLVMGetDiagInfoSeverity(info) == LLVMDSError)
		diag_error = LLVMGetDiagInfoDescription(info);
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
