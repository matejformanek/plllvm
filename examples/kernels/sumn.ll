; sumn(n integer) RETURNS integer    (ISP RAS 2020, q4)
;
;   sum := 0; idx := 0;
;   LOOP
;     IF idx > n THEN
;       RETURN sum;
;     END IF;
;     sum := sum + idx;
;     idx := idx + 1;
;   END LOOP;
;
; NULL n: the IF is never true, so the loop runs until "sum + idx" fails
; with "integer out of range" at idx 65536, as in PL/pgSQL.

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_rt_int_overflow() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %n.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %n.known = xor i1 %n.n, true
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  br label %loop

loop:
  %idx = phi i32 [ 0, %entry ], [ %idx.next, %latch ]
  %sum = phi i32 [ 0, %entry ], [ %sum.next, %latch ]
  %gt = icmp sgt i32 %idx, %n
  %past = and i1 %n.known, %gt
  br i1 %past, label %done, label %body

body:
  %s = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %sum, i32 %idx)
  %s.ov = extractvalue { i32, i1 } %s, 1
  br i1 %s.ov, label %overflow, label %step

step:
  %sum.next = extractvalue { i32, i1 } %s, 0
  %i = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %idx, i32 1)
  %i.ov = extractvalue { i32, i1 } %i, 1
  br i1 %i.ov, label %overflow, label %latch

latch:
  %idx.next = extractvalue { i32, i1 } %i, 0
  call void @plllvm_cfi()
  br label %loop

done:
  %d = sext i32 %sum to i64
  ret i64 %d

overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}
