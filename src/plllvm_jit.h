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

#ifdef __cplusplus
}								/* extern "C" */
#endif

#ifndef __cplusplus

typedef struct plllvm_jit_session_info
{
	char	   *llvm_version;
	char	   *triple;			/* of plllvm_types.bc */
	char	   *data_layout;
	char	   *libllvm;		/* file of the loaded libLLVM */
	char	   *types_bc;		/* file the session was set up from */
	double		init_ms;
} plllvm_jit_session_info;

/* plllvm_jit.c */
extern void plllvm_jit_session_ensure(void);
extern void plllvm_jit_get_session_info(plllvm_jit_session_info *info);

#endif							/* !__cplusplus */

#endif							/* PLLLVM_JIT_H */
