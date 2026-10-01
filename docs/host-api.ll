; PL/LLVM host API v0.1
;
; Every function a PL/LLVM body may declare, with the types the compiler
; checks the declarations against.  Datums are i64, C bool is i1.  The
; inline helpers come from src/plllvm_types.c, the rest from
; src/plllvm_runtime.c.  Other external symbols resolve against the server.
;
; This file is a valid body: sql/plllvm_host_api.sql compiles it.

; --- arguments and result (v0.1a) -------------------------------------------

; is argument n NULL
declare i1 @plllvm_arg_isnull(ptr %fcinfo, i32 %n)
; argument n as int4, int8, float8, bool (no bounds or NULL checks)
declare i32 @plllvm_arg_i32(ptr %fcinfo, i32 %n)
declare i64 @plllvm_arg_i64(ptr %fcinfo, i32 %n)
declare double @plllvm_arg_f64(ptr %fcinfo, i32 %n)
declare i1 @plllvm_arg_bool(ptr %fcinfo, i32 %n)
; number of arguments of the call
declare i32 @plllvm_nargs(ptr %fcinfo)
; sets the result NULL; return its value from @f
declare i64 @plllvm_return_null(ptr %fcinfo)

; --- errors and interrupts (v0.1a) ------------------------------------------

; ERROR with a SQLSTATE packed as MAKE_SQLSTATE and a message
declare void @plllvm_error(i32 %sqlstate, ptr %msg)
; NOTICE with a message
declare void @plllvm_notice(ptr %msg)
; the ERRORs of int4pl, int8pl and int4div
declare void @plllvm_rt_int_overflow()
declare void @plllvm_rt_bigint_overflow()
declare void @plllvm_rt_div_zero()
; CHECK_FOR_INTERRUPTS() and check_stack_depth()
declare void @plllvm_cfi()
declare void @plllvm_check_stack()

; --- calls of other functions (v0.1b) ---------------------------------------
;
; A call site is a declared global named by the callee's regprocedure text,
; resolved under the function's own search_path, else
; "pg_catalog, <its schema>, pg_temp".  It may only be the first argument of
; @plllvm_call0 to @plllvm_call3, with its number of arguments.  Each
; argument is a Datum and its NULL flag.  A strict callee with a NULL
; argument is not called.  The result's NULL flag goes to %isnull; with a
; null %isnull a NULL result is an ERROR.

@"int4pl(integer,integer)" = external global i8

declare i64 @plllvm_call0(ptr %site, ptr %isnull)
declare i64 @plllvm_call1(ptr %site, i64 %a0, i1 %n0, ptr %isnull)
declare i64 @plllvm_call2(ptr %site, i64 %a0, i1 %n0, i64 %a1, i1 %n1, ptr %isnull)
declare i64 @plllvm_call3(ptr %site, i64 %a0, i1 %n0, i64 %a1, i1 %n1, i64 %a2, i1 %n2, ptr %isnull)

; A constant is a declared global named 'literal'::type ('' is a quote),
; read once per compile by the type's input function, which must be
; immutable.  @plllvm_const of it is folded into its Datum; a by-reference
; value is read-only.

@"'42'::integer" = external global i8

declare i64 @plllvm_const(ptr %k)

; --- text and varlena (v0.1b) -----------------------------------------------

; text from a C string, and back
declare i64 @plllvm_cstring_to_text(ptr %s)
declare ptr @plllvm_text_to_cstring(i64 %t)
; detoasted value; data and size of a detoasted value
declare i64 @plllvm_detoast(i64 %v)
declare ptr @plllvm_vardata_any(i64 %v)
declare i32 @plllvm_varsize_any_exhdr(i64 %v)

; --- memory (v0.1b) ----------------------------------------------------------
;
; A body that declares a call, text or memory helper (all above except
; @plllvm_const, @plllvm_vardata_any and @plllvm_varsize_any_exhdr) runs in
; a scratch context that is deleted after the call; a by-reference result
; is copied out.

; copy of a varlena in the caller's context, which outlives the scratch
declare i64 @plllvm_keep(i64 %v)
; pfree of a value from @plllvm_keep
declare void @plllvm_free(i64 %v)
; frees everything allocated in the scratch so far
declare void @plllvm_scratch_reset()

; --- SQL statements (v0.1c) --------------------------------------------------
;
; A body that declares a @plllvm_spi_ function runs connected to SPI, in a
; frame.  A statement is one plain SELECT; the functions it calls are not
; restricted.  It runs read-only unless the function is VOLATILE, as in
; PL/pgSQL.  The slot is an internal global ptr, null at first:
; @plllvm_spi_prepare fills it on the first call in a backend.  The types
; are comma-separated names, as in "numeric(5,2), int4"; the result must
; have the declared column types.  NullableDatum is { i64, i8 },
; %struct.NullableDatum of plllvm_types.bc.

; (slot, sql, argtypes, coltypes) -> statement
declare ptr @plllvm_spi_prepare(ptr %slot, ptr %sql, ptr %argtypes, ptr %coltypes)
; runs it with the NullableDatum %args as a non-STRICT SELECT INTO: the
; first row into the NullableDatum %out, all NULL without one; returns the
; number of rows, 0 or 1.  By-reference columns are copies as from
; @plllvm_keep: free them with @plllvm_free.
declare i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stmt, ptr %args, ptr %out)

; --- arrays (v0.1c) ----------------------------------------------------------
;
; Flat one-dimensional (or empty) arrays of int4, int8 or float8 (element
; type OIDs 23, 20, 701), without NULL elements, allocated in the current
; context: the scratch in a frame.  Subscripts start at the lower bound;
; one out of range, or an element type other than the accessor's, is an
; ERROR.

; argument n as an array of the element type: a private copy, which
; @plllvm_array_set_* may change.  It is made at each call.
declare ptr @plllvm_array_arg(ptr %fcinfo, i32 %n, i32 %elemtype)
; n zeros, lower bound 1
declare ptr @plllvm_array_new(i32 %elemtype, i32 %n)
; copy of an array, also of one a call returned
declare ptr @plllvm_array_copy(ptr %a)
; number of elements and lower bound (1 when empty)
declare i32 @plllvm_array_length(ptr %a)
declare i32 @plllvm_array_lower(ptr %a)
declare i32 @plllvm_array_get_i32(ptr %a, i32 %i)
declare i64 @plllvm_array_get_i64(ptr %a, i32 %i)
declare double @plllvm_array_get_f64(ptr %a, i32 %i)
declare void @plllvm_array_set_i32(ptr %a, i32 %i, i32 %v)
declare void @plllvm_array_set_i64(ptr %a, i32 %i, i64 %v)
declare void @plllvm_array_set_f64(ptr %a, i32 %i, double %v)

@hello = private constant [6 x i8] c"hello\00"
@"pi()" = external global i8
@"abs(integer)" = external global i8
@"substr(text,integer,integer)" = external global i8
@q = internal global ptr null
@q.sql = private constant [20 x i8] c"SELECT $1::int8 + 1\00"
@q.types = private constant [5 x i8] c"int8\00"

; every helper once; argument 0 picks the path
define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  call void @plllvm_check_stack()
  %nargs = call i32 @plllvm_nargs(ptr %fcinfo)
  %null = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %i32 = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %i64 = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %f64 = call double @plllvm_arg_f64(ptr %fcinfo, i32 0)
  %b = call i1 @plllvm_arg_bool(ptr %fcinfo, i32 0)
  switch i32 %i32, label %calls [
    i32 1, label %error
    i32 2, label %int_overflow
    i32 3, label %bigint_overflow
    i32 4, label %div_zero
    i32 5, label %null_result
    i32 6, label %spi
    i32 7, label %arrays
  ]

error:
  call void @plllvm_error(i32 0, ptr @hello)
  unreachable

int_overflow:
  call void @plllvm_rt_int_overflow()
  unreachable

bigint_overflow:
  call void @plllvm_rt_bigint_overflow()
  unreachable

div_zero:
  call void @plllvm_rt_div_zero()
  unreachable

null_result:
  call void @plllvm_notice(ptr @hello)
  %r = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %r

spi:
  %args = alloca { i64, i8 }
  %out = alloca { i64, i8 }
  store { i64, i8 } { i64 41, i8 0 }, ptr %args
  %stmt = call ptr @plllvm_spi_prepare(ptr @q, ptr @q.sql, ptr @q.types, ptr @q.types)
  %rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stmt, ptr %args, ptr %out)
  %v = load i64, ptr %out
  ret i64 %v

arrays:
  %a = call ptr @plllvm_array_arg(ptr %fcinfo, i32 1, i32 20)
  %a4 = call ptr @plllvm_array_new(i32 23, i32 3)
  %a8 = call ptr @plllvm_array_copy(ptr %a)
  %af = call ptr @plllvm_array_new(i32 701, i32 1)
  %len = call i32 @plllvm_array_length(ptr %a)
  %lo = call i32 @plllvm_array_lower(ptr %a)
  call void @plllvm_array_set_i32(ptr %a4, i32 1, i32 %len)
  call void @plllvm_array_set_i64(ptr %a8, i32 %lo, i64 %i64)
  call void @plllvm_array_set_f64(ptr %af, i32 1, double %f64)
  %e4 = call i32 @plllvm_array_get_i32(ptr %a4, i32 1)
  %e8 = call i64 @plllvm_array_get_i64(ptr %a8, i32 %lo)
  %ef = call double @plllvm_array_get_f64(ptr %af, i32 1)
  %e4.64 = sext i32 %e4 to i64
  %efi = fptosi double %ef to i64
  %s.0 = add i64 %e4.64, %e8
  %s.1 = add i64 %s.0, %efi
  ret i64 %s.1

calls:
  %isnull = alloca i1
  %k = call i64 @plllvm_const(ptr @"'42'::integer")
  %t = call i64 @plllvm_cstring_to_text(ptr @hello)
  %c0 = call i64 @plllvm_call0(ptr @"pi()", ptr %isnull)
  %c1 = call i64 @plllvm_call1(ptr @"abs(integer)", i64 %i64, i1 %null, ptr %isnull)
  %c2 = call i64 @plllvm_call2(ptr @"int4pl(integer,integer)", i64 %k, i1 false, i64 %c1, i1 %b, ptr %isnull)
  %c3 = call i64 @plllvm_call3(ptr @"substr(text,integer,integer)", i64 %t, i1 false, i64 %c2, i1 false, i64 1, i1 false, ptr null)
  %d = call i64 @plllvm_detoast(i64 %t)
  %p = call ptr @plllvm_vardata_any(i64 %d)
  %n = call i32 @plllvm_varsize_any_exhdr(i64 %d)
  %s = call ptr @plllvm_text_to_cstring(i64 %t)
  %kept = call i64 @plllvm_keep(i64 %t)
  call void @plllvm_scratch_reset()
  call void @plllvm_free(i64 %kept)
  %fi = fptosi double %f64 to i64
  %r0 = add i64 %c3, %c0
  %r1 = add i64 %r0, %fi
  %n64 = sext i32 %nargs to i64
  %r2 = add i64 %r1, %n64
  ret i64 %r2
}
