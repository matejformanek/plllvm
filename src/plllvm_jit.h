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
 * 1) Only LLVM-C types (LLVM*Ref) may appear here, so that both the C files
 *    and the C++ file can include it (as core's jit/llvmjit.h).
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

#endif							/* PLLLVM_JIT_H */
