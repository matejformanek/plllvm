; loop(n integer) RETURNS integer
;
;   i := 0;
;   WHILE i < n LOOP i := i + 1; END LOOP;
;   RETURN i;
;
; NULL n: "i < NULL" is not true, so the body never runs and 0 comes back.

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_int_overflow() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %n.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %n.isnull, label %done, label %start

start:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  br label %cond

cond:
  %i = phi i32 [ 0, %start ], [ %i.next, %latch ]
  %more = icmp slt i32 %i, %n
  br i1 %more, label %body, label %done

body:
  %add = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %i, i32 1)
  %ov = extractvalue { i32, i1 } %add, 1
  br i1 %ov, label %overflow, label %latch

latch:
  %i.next = extractvalue { i32, i1 } %add, 0
  call void @plllvm_cfi()
  br label %cond

done:
  %result = phi i32 [ 0, %entry ], [ %i, %cond ]
  %datum = sext i32 %result to i64
  ret i64 %datum

overflow:
  call void @plllvm_int_overflow()
  unreachable
}
