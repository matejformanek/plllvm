; spectralnorm(n integer) RETURNS text    (bench/kernels/11_spectralnorm.sql)
;
; The Computer Language Benchmarks Game "spectral-norm" algorithm, BSD-3, see
; LICENSES/BENCHMARKS-GAME-BSD-3.md.
;   Copyright (c) 2004-2008 Brent Fulgham, 2005-2024 Isaac Gouy.
;
;   u := array_fill(1.0::float8, ARRAY[n]);
;   v := array_fill(0.0::float8, ARRAY[n]);
;   t := array_fill(0.0::float8, ARRAY[n]);
;   FOR k IN 1..10 LOOP
;     -- v := AtA(u):  t := A u ; v := At t
;     FOR i IN 0..n-1 LOOP
;       s := 0;
;       FOR j IN 0..n-1 LOOP
;         ij := i + j;
;         s := s + one / (ij * (ij + 1) / 2 + i + 1) * u[j+1];
;       END LOOP;
;       t[i+1] := s;
;     END LOOP;
;     -- the same for v := At t (+ j + 1 instead of + i + 1), then
;     -- t := A v and u := At t
;   END LOOP;
;   FOR i IN 1..n LOOP
;     vbv := vbv + u[i] * v[i];
;     vv := vv + v[i] * v[i];
;   END LOOP;
;   RETURN round(sqrt(vbv / vv)::numeric, 9)::text;
;
; The four loop nests of the PL/pgSQL code are one function, @times, which
; computes A x or At x.  The integer and float8 operators are native, with
; PostgreSQL's errors (as in mandelbrot.ll); sqrt, the cast to numeric,
; round and the output are calls.  n = 0 fails at vbv / vv with "division
; by zero", as in PL/pgSQL.

@msg.null_dim = private unnamed_addr constant [32 x i8] c"dimension values cannot be null\00"

@"sqrt(double precision)" = external global i8
@"numeric(double precision)" = external global i8
@"round(numeric,integer)" = external global i8
@"numeric_out(numeric)" = external global i8

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_int_overflow() noreturn
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
declare i64 @plllvm_cstring_to_text(ptr)
declare ptr @plllvm_array_new(i32, i32)
declare double @plllvm_array_get_f64(ptr, i32)
declare void @plllvm_array_set_f64(ptr, i32, double)
declare void @float_overflow_error() noreturn
declare void @float_underflow_error() noreturn
declare void @float_zero_divide_error() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare { i32, i1 } @llvm.smul.with.overflow.i32(i32, i32)
declare double @llvm.fabs.f64(double)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %n.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %n.isnull, label %null_dim, label %start

start:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  ; a negative n fails here, as in array_fill
  %u = call ptr @plllvm_array_new(i32 701, i32 %n)
  %v = call ptr @plllvm_array_new(i32 701, i32 %n)
  %t = call ptr @plllvm_array_new(i32 701, i32 %n)
  br label %fill.cond

fill.cond:
  %f = phi i32 [ 1, %start ], [ %f.next, %fill.body ]
  %f.more = icmp sle i32 %f, %n
  br i1 %f.more, label %fill.body, label %k.body

fill.body:
  call void @plllvm_array_set_f64(ptr %u, i32 %f, double 1.0)
  ; n is a valid array size, far below INT_MAX
  %f.next = add nsw i32 %f, 1
  call void @plllvm_cfi()
  br label %fill.cond

k.body:
  %k = phi i32 [ 1, %fill.cond ], [ %k.next, %k.body ]
  call void @times(ptr %t, ptr %u, i32 %n, i1 false)
  call void @times(ptr %v, ptr %t, i32 %n, i1 true)
  call void @times(ptr %t, ptr %v, i32 %n, i1 false)
  call void @times(ptr %u, ptr %t, i32 %n, i1 true)
  %k.next = add nsw i32 %k, 1
  call void @plllvm_cfi()
  %k.more = icmp sle i32 %k.next, 10
  br i1 %k.more, label %k.body, label %dot.cond

dot.cond:
  %i = phi i32 [ 1, %k.body ], [ %i.next, %dot.body ]
  %vbv = phi double [ 0.0, %k.body ], [ %vbv.next, %dot.body ]
  %vv = phi double [ 0.0, %k.body ], [ %vv.next, %dot.body ]
  %i.more = icmp sle i32 %i, %n
  br i1 %i.more, label %dot.body, label %done

dot.body:
  %ui = call double @plllvm_array_get_f64(ptr %u, i32 %i)
  %vi = call double @plllvm_array_get_f64(ptr %v, i32 %i)
  %uv = call double @f8_mul(double %ui, double %vi)
  %vbv.next = call double @f8_pl(double %vbv, double %uv)
  %v2 = call double @f8_mul(double %vi, double %vi)
  %vv.next = call double @f8_pl(double %vv, double %v2)
  %i.next = add nsw i32 %i, 1
  call void @plllvm_cfi()
  br label %dot.cond

done:
  ; round(sqrt(vbv / vv)::numeric, 9)::text
  %q = call double @f8_div(double %vbv, double %vv)
  %q.d = bitcast double %q to i64
  %r.0 = call i64 @plllvm_call1(ptr @"sqrt(double precision)", i64 %q.d, i1 false, ptr null)
  %r.1 = call i64 @plllvm_call1(ptr @"numeric(double precision)", i64 %r.0, i1 false, ptr null)
  %r.2 = call i64 @plllvm_call2(ptr @"round(numeric,integer)", i64 %r.1, i1 false, i64 9, i1 false, ptr null)
  %r.s = call i64 @plllvm_call1(ptr @"numeric_out(numeric)", i64 %r.2, i1 false, ptr null)
  %r.p = inttoptr i64 %r.s to ptr
  %r = call i64 @plllvm_cstring_to_text(ptr %r.p)
  ret i64 %r

null_dim:
  ; 22004 = MAKE_SQLSTATE('2','2','0','0','4')
  call void @plllvm_error(i32 67108994, ptr @msg.null_dim)
  unreachable
}

;
; out[i+1] := sum over j of one / (ij * (ij + 1) / 2 + m + 1) * x[j+1], for
; i and j in 0..n-1, ij = i + j, and m = i for A x, m = j for At x
;
define internal void @times(ptr %out, ptr %x, i32 %n, i1 %at) {
entry:
  ; n >= 0, the arrays exist
  %end = sub nsw i32 %n, 1
  br label %i.cond

i.cond:
  %i = phi i32 [ 0, %entry ], [ %i.next, %i.latch ]
  %i.more = icmp sle i32 %i, %end
  br i1 %i.more, label %j.cond, label %done

j.cond:
  %j = phi i32 [ 0, %i.cond ], [ %j.next, %j.body ]
  %s = phi double [ 0.0, %i.cond ], [ %s.next, %j.body ]
  %j.more = icmp sle i32 %j, %end
  br i1 %j.more, label %j.body, label %i.latch

j.body:
  %ij = call i32 @int4pl(i32 %i, i32 %j)
  %ij.1 = call i32 @int4pl(i32 %ij, i32 1)
  %d.0 = call i32 @int4mul(i32 %ij, i32 %ij.1)
  ; int4div by a constant 2 cannot fail
  %d.1 = sdiv i32 %d.0, 2
  %m = select i1 %at, i32 %j, i32 %i
  %d.2 = call i32 @int4pl(i32 %d.1, i32 %m)
  %d.3 = call i32 @int4pl(i32 %d.2, i32 1)
  %d = sitofp i32 %d.3 to double
  %a = call double @f8_div(double 1.0, double %d)
  ; j <= n - 1, so j + 1, also the subscript, cannot overflow
  %j.next = add nsw i32 %j, 1
  %xj = call double @plllvm_array_get_f64(ptr %x, i32 %j.next)
  %ax = call double @f8_mul(double %a, double %xj)
  %s.next = call double @f8_pl(double %s, double %ax)
  call void @plllvm_cfi()
  br label %j.cond

i.latch:
  %i.next = add nsw i32 %i, 1
  call void @plllvm_array_set_f64(ptr %out, i32 %i.next, double %s)
  call void @plllvm_cfi()
  br label %i.cond

done:
  ret void
}

; integer operators with PostgreSQL's "integer out of range" error

define internal i32 @int4pl(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_int_overflow()
  unreachable
}

define internal i32 @int4mul(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.smul.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_int_overflow()
  unreachable
}

; float8 operators, as utils/float.h (the same as in mandelbrot.ll)

define internal i1 @isinf(double %v) alwaysinline {
  %abs = call double @llvm.fabs.f64(double %v)
  %inf = fcmp oeq double %abs, 0x7FF0000000000000
  ret i1 %inf
}

; overflow if the result is inf and neither operand was
define internal void @check_overflow(double %r, double %a, double %b) alwaysinline {
  %r.inf = call i1 @isinf(double %r)
  br i1 %r.inf, label %operands, label %ok
operands:
  %a.inf = call i1 @isinf(double %a)
  %b.inf = call i1 @isinf(double %b)
  %from.inf = or i1 %a.inf, %b.inf
  br i1 %from.inf, label %ok, label %overflow
ok:
  ret void
overflow:
  call void @float_overflow_error()
  unreachable
}

define internal double @f8_pl(double %a, double %b) alwaysinline {
  %r = fadd double %a, %b
  call void @check_overflow(double %r, double %a, double %b)
  ret double %r
}

define internal double @f8_mul(double %a, double %b) alwaysinline {
entry:
  %r = fmul double %a, %b
  call void @check_overflow(double %r, double %a, double %b)
  %r.zero = fcmp oeq double %r, 0.0
  br i1 %r.zero, label %operands, label %ok
operands:
  ; une: a NaN operand counts as nonzero, like "val1 != 0.0" in C
  %a.nz = fcmp une double %a, 0.0
  %b.nz = fcmp une double %b, 0.0
  %underflow = and i1 %a.nz, %b.nz
  br i1 %underflow, label %error, label %ok
ok:
  ret double %r
error:
  call void @float_underflow_error()
  unreachable
}

define internal double @f8_div(double %a, double %b) alwaysinline {
entry:
  %b.zero = fcmp oeq double %b, 0.0
  %a.num = fcmp ord double %a, 0.0
  %div.zero = and i1 %b.zero, %a.num
  br i1 %div.zero, label %zero_divide, label %divide
divide:
  %r = fdiv double %a, %b
  %r.inf = call i1 @isinf(double %r)
  %a.inf = call i1 @isinf(double %a)
  %a.fin = xor i1 %a.inf, true
  %overflow = and i1 %r.inf, %a.fin
  br i1 %overflow, label %overflow_error, label %check_underflow
check_underflow:
  %r.zero = fcmp oeq double %r, 0.0
  %a.nz = fcmp une double %a, 0.0
  %b.inf = call i1 @isinf(double %b)
  %b.fin = xor i1 %b.inf, true
  %u.0 = and i1 %r.zero, %a.nz
  %underflow = and i1 %u.0, %b.fin
  br i1 %underflow, label %underflow_error, label %ok
ok:
  ret double %r
zero_divide:
  call void @float_zero_divide_error()
  unreachable
overflow_error:
  call void @float_overflow_error()
  unreachable
underflow_error:
  call void @float_underflow_error()
  unreachable
}
