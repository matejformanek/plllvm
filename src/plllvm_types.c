/*-------------------------------------------------------------------------
 *
 * plllvm_types.c
 *
 *			  host types and inline helpers for JIT-compiled PL/LLVM code
 *
 * by Matěj Formánek 2026
 *
 * NB: This file will not be linked into the library, it's only compiled to
 * plllvm_types.bc (as src/backend/jit/llvm/llvmjit_types.c).
 *
 *-------------------------------------------------------------------------
 *
 * Notes:
 *
 * 1) The helpers are non-static, so that clang keeps them, and always
 *    inline, because at -O0 only always-inline functions get inlined.
 *
 * 2) plllvm_jit.c gives them linkonce_odr linkage when it loads the file,
 *    so linking user IR pulls in only the helpers the IR calls.
 *
 * 3) The version and the layout probes are checked against the library
 *    when a session loads the file.
 *
 */
#include "postgres.h"

#include "fmgr.h"
#include "miscadmin.h"
#include "utils/float.h"

#include "plllvm.h"

const uint32 plllvm_types_version = PLLLVM_TYPES_VERSION;
const uint32 plllvm_types_llvm_major = __clang_major__;
const uint64 plllvm_types_layout[] = PLLLVM_LAYOUT;

/*
 * The attributes of this function are copied to JIT-compiled functions, so
 * that the helpers can be inlined into them.
 */
extern Datum plllvm_attr_template(PG_FUNCTION_ARGS);
Datum
plllvm_attr_template(PG_FUNCTION_ARGS)
{
	PG_RETURN_NULL();
}

extern bool plllvm_arg_isnull(FunctionCallInfo fcinfo, int n);
extern int32 plllvm_arg_i32(FunctionCallInfo fcinfo, int n);
extern int64 plllvm_arg_i64(FunctionCallInfo fcinfo, int n);
extern float8 plllvm_arg_f64(FunctionCallInfo fcinfo, int n);
extern bool plllvm_arg_bool(FunctionCallInfo fcinfo, int n);
extern int32 plllvm_nargs(FunctionCallInfo fcinfo);
extern Datum plllvm_return_null(FunctionCallInfo fcinfo);
extern void plllvm_cfi(void);
extern void plllvm_check_stack(void);

/* no bounds checks, as PG_GETARG_* */
pg_always_inline bool
plllvm_arg_isnull(FunctionCallInfo fcinfo, int n)
{
	return fcinfo->args[n].isnull;
}

pg_always_inline int32
plllvm_arg_i32(FunctionCallInfo fcinfo, int n)
{
	return DatumGetInt32(fcinfo->args[n].value);
}

pg_always_inline int64
plllvm_arg_i64(FunctionCallInfo fcinfo, int n)
{
	return DatumGetInt64(fcinfo->args[n].value);
}

pg_always_inline float8
plllvm_arg_f64(FunctionCallInfo fcinfo, int n)
{
	return DatumGetFloat8(fcinfo->args[n].value);
}

pg_always_inline bool
plllvm_arg_bool(FunctionCallInfo fcinfo, int n)
{
	return DatumGetBool(fcinfo->args[n].value);
}

pg_always_inline int32
plllvm_nargs(FunctionCallInfo fcinfo)
{
	return fcinfo->nargs;
}

pg_always_inline Datum
plllvm_return_null(FunctionCallInfo fcinfo)
{
	PG_RETURN_NULL();
}

pg_always_inline void
plllvm_cfi(void)
{
	CHECK_FOR_INTERRUPTS();
}

pg_always_inline void
plllvm_check_stack(void)
{
	check_stack_depth();
}

/*
 * Forces the declarations of the out-of-line host functions into the .bc,
 * where declarations in user IR are checked against them.
 */
void	   *referenced_functions[] =
{
	plllvm_error,
	plllvm_notice,
	plllvm_rt_int_overflow,
	plllvm_rt_bigint_overflow,
	plllvm_rt_div_zero,
	float_overflow_error,
	float_underflow_error,
	float_zero_divide_error,
};
