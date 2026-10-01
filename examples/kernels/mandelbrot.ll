; mandelbrot(sz integer)    (bench/kernels/12_mandelbrot.sql)
;
; The Computer Language Benchmarks Game "mandelbrot" algorithm, BSD-3, see
; LICENSES/BENCHMARKS-GAME-BSD-3.md.
;   Copyright (c) 2004-2008 Brent Fulgham, 2005-2024 Isaac Gouy.
;
;   fsz := sz;
;   FOR y IN 0..sz-1 LOOP
;     ci := two * y / fsz - one;
;     FOR x IN 0..sz-1 LOOP
;       cr := two * x / fsz - onehalf;
;       zr := 0; zi := 0; tr := 0; ti := 0; k := 0;
;       WHILE k < 50 AND tr + ti <= four LOOP
;         zi := two * zr * zi + ci;
;         zr := tr - ti + cr;
;         tr := zr * zr;
;         ti := zi * zi;
;         k := k + 1;
;       END LOOP;
;       IF tr + ti <= four THEN
;         cnt := cnt + 1;
;         h := (h * 31 + x * 7 + y) % 1000000007;
;       END IF;
;     END LOOP;
;   END LOOP;
;   RETURN cnt::text || '/' || h::text;
;
; float8 arithmetic goes through @f8_* below, which copy float8_pl/mi/mul/div
; from utils/float.h with their overflow, underflow and division-by-zero
; errors.  No fast-math flags, so "two * zr * zi + ci" is never fused.

@msg.null_bound = private unnamed_addr constant [39 x i8] c"upper bound of FOR loop cannot be null\00"

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_rt_int_overflow() noreturn
declare void @plllvm_rt_bigint_overflow() noreturn
declare i64 @plllvm_cstring_to_text(ptr)
declare i32 @pg_ltoa(i32, ptr)
declare i32 @pg_lltoa(i64, ptr)
declare void @float_overflow_error() noreturn
declare void @float_underflow_error() noreturn
declare void @float_zero_divide_error() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare { i32, i1 } @llvm.ssub.with.overflow.i32(i32, i32)
declare { i32, i1 } @llvm.smul.with.overflow.i32(i32, i32)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)
declare double @llvm.fabs.f64(double)

define i64 @f(ptr %fcinfo) {
entry:
  ; cnt '/' h: at most 11 + 1 + 20 bytes and the NUL
  %buf = alloca [40 x i8]
  call void @plllvm_cfi()
  %sz.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %sz.isnull, label %null_bound, label %start

start:
  %sz = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %fsz = sitofp i32 %sz to double
  ; sz-1 is the upper bound of both FOR loops; the inner one re-evaluates it
  ; in PL/pgSQL, but it cannot fail there once it succeeded here
  %end = call i32 @int4mi(i32 %sz, i32 1)
  br label %y.cond

y.cond:
  %y = phi i32 [ 0, %start ], [ %y.next, %y.latch ]
  %cnt = phi i32 [ 0, %start ], [ %cnt.x, %y.latch ]
  %h = phi i64 [ 0, %start ], [ %h.x, %y.latch ]
  %y.more = icmp sle i32 %y, %end
  br i1 %y.more, label %y.body, label %done

y.body:
  %y.f = sitofp i32 %y to double
  %ci.0 = call double @f8_mul(double 2.0, double %y.f)
  %ci.1 = call double @f8_div(double %ci.0, double %fsz)
  %ci = call double @f8_mi(double %ci.1, double 1.0)
  br label %x.cond

x.cond:
  %x = phi i32 [ 0, %y.body ], [ %x.next, %x.latch ]
  %cnt.x = phi i32 [ %cnt, %y.body ], [ %cnt.next, %x.latch ]
  %h.x = phi i64 [ %h, %y.body ], [ %h.next, %x.latch ]
  %x.more = icmp sle i32 %x, %end
  br i1 %x.more, label %x.body, label %y.latch

x.body:
  %x.f = sitofp i32 %x to double
  %cr.0 = call double @f8_mul(double 2.0, double %x.f)
  %cr.1 = call double @f8_div(double %cr.0, double %fsz)
  %cr = call double @f8_mi(double %cr.1, double 1.5)
  br label %k.cond

k.cond:
  %k = phi i32 [ 0, %x.body ], [ %k.next, %k.body ]
  %zr = phi double [ 0.0, %x.body ], [ %zr.next, %k.body ]
  %zi = phi double [ 0.0, %x.body ], [ %zi.next, %k.body ]
  %tr = phi double [ 0.0, %x.body ], [ %tr.next, %k.body ]
  %ti = phi double [ 0.0, %x.body ], [ %ti.next, %k.body ]
  %k.more = icmp slt i32 %k, 50
  br i1 %k.more, label %k.cond2, label %k.done

k.cond2:
  %mag = call double @f8_pl(double %tr, double %ti)
  ; float8_le(mag, 4.0): the right side is never NaN, so this is plain ole
  %inside = fcmp ole double %mag, 4.0
  br i1 %inside, label %k.body, label %k.done

k.body:
  %zi.0 = call double @f8_mul(double 2.0, double %zr)
  %zi.1 = call double @f8_mul(double %zi.0, double %zi)
  %zi.next = call double @f8_pl(double %zi.1, double %ci)
  %zr.0 = call double @f8_mi(double %tr, double %ti)
  %zr.next = call double @f8_pl(double %zr.0, double %cr)
  %tr.next = call double @f8_mul(double %zr.next, double %zr.next)
  %ti.next = call double @f8_mul(double %zi.next, double %zi.next)
  %k.next = call i32 @int4pl(i32 %k, i32 1)
  call void @plllvm_cfi()
  br label %k.cond

k.done:
  %mag.end = call double @f8_pl(double %tr, double %ti)
  %in.set = fcmp ole double %mag.end, 4.0
  br i1 %in.set, label %hit, label %x.latch

hit:
  %cnt.inc = call i32 @int4pl(i32 %cnt.x, i32 1)
  %h.0 = call i64 @int8mul(i64 %h.x, i64 31)
  %x7 = call i32 @int4mul(i32 %x, i32 7)
  %x7.l = sext i32 %x7 to i64
  %h.1 = call i64 @int8pl(i64 %h.0, i64 %x7.l)
  %y.l = sext i32 %y to i64
  %h.2 = call i64 @int8pl(i64 %h.1, i64 %y.l)
  ; int8mod: the divisor is a nonzero constant other than -1
  %h.hit = srem i64 %h.2, 1000000007
  br label %x.latch

x.latch:
  %cnt.next = phi i32 [ %cnt.x, %k.done ], [ %cnt.inc, %hit ]
  %h.next = phi i64 [ %h.x, %k.done ], [ %h.hit, %hit ]
  ; x <= end <= INT_MAX - 1
  %x.next = add nsw i32 %x, 1
  call void @plllvm_cfi()
  br label %x.cond

y.latch:
  %y.next = add nsw i32 %y, 1
  call void @plllvm_cfi()
  br label %y.cond

done:
  %n = call i32 @pg_ltoa(i32 %cnt, ptr %buf)
  %slash = getelementptr inbounds i8, ptr %buf, i32 %n
  store i8 47, ptr %slash
  %h.at = getelementptr inbounds i8, ptr %slash, i32 1
  call i32 @pg_lltoa(i64 %h, ptr %h.at)
  %r = call i64 @plllvm_cstring_to_text(ptr %buf)
  ret i64 %r

null_bound:
  ; 22004 = MAKE_SQLSTATE('2','2','0','0','4')
  call void @plllvm_error(i32 67108994, ptr @msg.null_bound)
  unreachable
}

; integer operators with PostgreSQL's "integer/bigint out of range" errors

define internal i32 @int4pl(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}

define internal i32 @int4mi(i32 %a, i32 %b) alwaysinline {
  %r = call { i32, i1 } @llvm.ssub.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i32, i1 } %r, 0
  ret i32 %v
overflow:
  call void @plllvm_rt_int_overflow()
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
  call void @plllvm_rt_int_overflow()
  unreachable
}

define internal i64 @int8pl(i64 %a, i64 %b) alwaysinline {
  %r = call { i64, i1 } @llvm.sadd.with.overflow.i64(i64 %a, i64 %b)
  %ov = extractvalue { i64, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i64, i1 } %r, 0
  ret i64 %v
overflow:
  call void @plllvm_rt_bigint_overflow()
  unreachable
}

define internal i64 @int8mul(i64 %a, i64 %b) alwaysinline {
  %r = call { i64, i1 } @llvm.smul.with.overflow.i64(i64 %a, i64 %b)
  %ov = extractvalue { i64, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok
ok:
  %v = extractvalue { i64, i1 } %r, 0
  ret i64 %v
overflow:
  call void @plllvm_rt_bigint_overflow()
  unreachable
}

; float8 operators, as utils/float.h

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

define internal double @f8_mi(double %a, double %b) alwaysinline {
  %r = fsub double %a, %b
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
