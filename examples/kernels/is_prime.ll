; is_prime(n integer) RETURNS boolean    (ISP RAS 2020, q1)
;
;   idx := 2;
;   LOOP
;     IF idx > n/2 THEN RETURN TRUE; END IF;
;     IF mod(n, idx) = 0 THEN RETURN FALSE; END IF;
;     idx := idx + 1;
;   END LOOP;
;
; n/2 is computed once: it cannot fail and n does not change.
; mod(n, idx) needs neither the zero nor the -1 check of int4mod, idx >= 2.
; NULL n: both IFs are NULL, so PL/pgSQL counts idx up to INT_MAX and
; "idx + 1" fails with "integer out of range".  We raise that error at once.

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_rt_int_overflow() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %n.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %n.isnull, label %overflow, label %start

start:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %half = sdiv i32 %n, 2
  br label %loop

loop:
  %idx = phi i32 [ 2, %start ], [ %idx.next, %latch ]
  %past = icmp sgt i32 %idx, %half
  br i1 %past, label %prime, label %test

test:
  %rem = srem i32 %n, %idx
  %divides = icmp eq i32 %rem, 0
  br i1 %divides, label %composite, label %step

step:
  %add = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %idx, i32 1)
  %ov = extractvalue { i32, i1 } %add, 1
  br i1 %ov, label %overflow, label %latch

latch:
  %idx.next = extractvalue { i32, i1 } %add, 0
  call void @plllvm_cfi()
  br label %loop

prime:
  ret i64 1

composite:
  ret i64 0

overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}
