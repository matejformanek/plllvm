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

@hello = private constant [6 x i8] c"hello\00"
@"pi()" = external global i8
@"abs(integer)" = external global i8
@"substr(text,integer,integer)" = external global i8

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
