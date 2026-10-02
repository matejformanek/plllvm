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
 * 4) Call sites: the executor's protocol (EEOP_FUNCEXPR) is inline, all
 *    that is rare is in plllvm_sites.c.
 *
 */
#include "postgres.h"

#include "catalog/pg_type_d.h"
#include "fmgr.h"
#include "mb/pg_wchar.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/float.h"
#include "varatt.h"

#include "plllvm_host.h"

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
extern Datum plllvm_call0(plllvm_site *site, bool *isnull);
extern Datum plllvm_call1(plllvm_site *site, Datum a0, bool n0, bool *isnull);
extern Datum plllvm_call2(plllvm_site *site, Datum a0, bool n0,
						  Datum a1, bool n1, bool *isnull);
extern Datum plllvm_call3(plllvm_site *site, Datum a0, bool n0,
						  Datum a1, bool n1, Datum a2, bool n2,
						  bool *isnull);
extern Datum plllvm_const(const void *k);
extern Datum plllvm_cstring_to_text(const char *s);
extern char *plllvm_text_to_cstring(Datum t);
extern Datum plllvm_detoast(Datum v);
extern char *plllvm_vardata_any(Datum v);
extern int32 plllvm_varsize_any_exhdr(Datum v);
extern void plllvm_free(Datum v);
extern int32 plllvm_array_length(ArrayType *a);
extern int32 plllvm_array_lower(ArrayType *a);
extern int32 plllvm_array_get_i32(ArrayType *a, int32 i);
extern int64 plllvm_array_get_i64(ArrayType *a, int32 i);
extern float8 plllvm_array_get_f64(ArrayType *a, int32 i);
extern void plllvm_array_set_i32(ArrayType *a, int32 i, int32 v);
extern void plllvm_array_set_i64(ArrayType *a, int32 i, int64 v);
extern void plllvm_array_set_f64(ArrayType *a, int32 i, float8 v);

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

/* a busy site is never called again: an FmgrInfo carries one call at a time */
static pg_always_inline Datum
site_call(plllvm_site *site, NullableDatum *args, int nargs, bool *isnull)
{
	FunctionCallInfo fcinfo = site->fcinfo;

	if (unlikely(!site->ready || site->busy || site->userid != GetUserId()))
		return plllvm_rt_site_call(site, args, isnull);

	return plllvm_site_invoke(site, fcinfo, site->flinfo.fn_strict, true,
							  args, nargs, isnull);
}

pg_always_inline Datum
plllvm_call0(plllvm_site *site, bool *isnull)
{
	return site_call(site, NULL, 0, isnull);
}

pg_always_inline Datum
plllvm_call1(plllvm_site *site, Datum a0, bool n0, bool *isnull)
{
	NullableDatum args[1] = {{a0, n0}};

	return site_call(site, args, 1, isnull);
}

pg_always_inline Datum
plllvm_call2(plllvm_site *site, Datum a0, bool n0, Datum a1, bool n1,
			 bool *isnull)
{
	NullableDatum args[2] = {{a0, n0}, {a1, n1}};

	return site_call(site, args, 2, isnull);
}

pg_always_inline Datum
plllvm_call3(plllvm_site *site, Datum a0, bool n0, Datum a1, bool n1,
			 Datum a2, bool n2, bool *isnull)
{
	NullableDatum args[3] = {{a0, n0}, {a1, n1}, {a2, n2}};

	return site_call(site, args, 3, isnull);
}

/* never reached: the compile folds every call into the constant's Datum */
pg_always_inline Datum
plllvm_const(const void *k)
{
	return *(const Datum *) k;
}

/* unlike cstring_to_text(), checks the encoding: IR may build any bytes */
pg_always_inline Datum
plllvm_cstring_to_text(const char *s)
{
	int			len = strlen(s);

	(void) pg_verifymbstr(s, len, false);

	return PointerGetDatum(cstring_to_text_with_len(s, len));
}

pg_always_inline char *
plllvm_text_to_cstring(Datum t)
{
	return text_to_cstring((text *) DatumGetPointer(t));
}

pg_always_inline Datum
plllvm_detoast(Datum v)
{
	return PointerGetDatum(pg_detoast_datum_packed((struct varlena *) DatumGetPointer(v)));
}

/* data and size of a detoasted value, as plllvm_detoast() returns */
pg_always_inline char *
plllvm_vardata_any(Datum v)
{
	return VARDATA_ANY(DatumGetPointer(v));
}

pg_always_inline int32
plllvm_varsize_any_exhdr(Datum v)
{
	return (int32) VARSIZE_ANY_EXHDR(DatumGetPointer(v));
}

/* frees a value from plllvm_keep(); 0, a NULL column, is ignored */
pg_always_inline void
plllvm_free(Datum v)
{
	if (DatumGetPointer(v) != NULL)
		pfree(DatumGetPointer(v));
}

/*
 * Arrays from plllvm_array_arg, _new and _copy: flat, one-dimensional or
 * empty, without NULL elements.  The element type is compared on every
 * access, so that IR never reads an element as the wrong type.
 */
pg_always_inline int32
plllvm_array_length(ArrayType *a)
{
	return ARR_NDIM(a) == 0 ? 0 : ARR_DIMS(a)[0];
}

pg_always_inline int32
plllvm_array_lower(ArrayType *a)
{
	return ARR_NDIM(a) == 0 ? 1 : ARR_LBOUND(a)[0];
}

static pg_always_inline int64
array_index(ArrayType *a, int32 i, Oid elemtype)
{
	int64		k = (int64) i - plllvm_array_lower(a);

	if (unlikely(ARR_ELEMTYPE(a) != elemtype ||
				 k < 0 || k >= plllvm_array_length(a)))
		plllvm_rt_array_access(a, elemtype);
	return k;
}

pg_always_inline int32
plllvm_array_get_i32(ArrayType *a, int32 i)
{
	return ((int32 *) ARR_DATA_PTR(a))[array_index(a, i, INT4OID)];
}

pg_always_inline int64
plllvm_array_get_i64(ArrayType *a, int32 i)
{
	return ((int64 *) ARR_DATA_PTR(a))[array_index(a, i, INT8OID)];
}

pg_always_inline float8
plllvm_array_get_f64(ArrayType *a, int32 i)
{
	return ((float8 *) ARR_DATA_PTR(a))[array_index(a, i, FLOAT8OID)];
}

pg_always_inline void
plllvm_array_set_i32(ArrayType *a, int32 i, int32 v)
{
	((int32 *) ARR_DATA_PTR(a))[array_index(a, i, INT4OID)] = v;
}

pg_always_inline void
plllvm_array_set_i64(ArrayType *a, int32 i, int64 v)
{
	((int64 *) ARR_DATA_PTR(a))[array_index(a, i, INT8OID)] = v;
}

pg_always_inline void
plllvm_array_set_f64(ArrayType *a, int32 i, float8 v)
{
	((float8 *) ARR_DATA_PTR(a))[array_index(a, i, FLOAT8OID)] = v;
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
	plllvm_keep,
	plllvm_scratch_reset,
	plllvm_array_arg,
	plllvm_array_new,
	plllvm_array_copy,
	plllvm_spi_prepare,
	plllvm_spi_select_into,
	float_overflow_error,
	float_underflow_error,
	float_zero_divide_error,
};
