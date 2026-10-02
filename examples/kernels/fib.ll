; fib(n integer) RETURNS integer
;
;   IF n < 2 THEN RETURN n; END IF;
;   RETURN fib(n - 1) + fib(n - 2);
;
; The recursion is a native call to @fib, not a call through fmgr.
; NULL n: in PL/pgSQL "n < 2" is NULL and n - 1 is NULL again, so it recurses
; until "stack depth limit exceeded".  We raise that error straight away.

@msg.stack = private unnamed_addr constant [27 x i8] c"stack depth limit exceeded\00"

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_check_stack()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_int_overflow() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %n.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %n.isnull, label %null, label %run

run:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %r = call i32 @fib(i32 %n)
  %datum = sext i32 %r to i64
  ret i64 %datum

null:
  ; 54001 = MAKE_SQLSTATE('5','4','0','0','1')
  call void @plllvm_error(i32 16777477, ptr @msg.stack)
  unreachable
}

define internal i32 @fib(i32 %n) {
entry:
  call void @plllvm_check_stack()
  call void @plllvm_cfi()
  %small = icmp slt i32 %n, 2
  br i1 %small, label %base, label %recurse

base:
  ret i32 %n

recurse:
  ; n >= 2 here, so neither subtraction can overflow
  %n1 = sub nsw i32 %n, 1
  %n2 = sub nsw i32 %n, 2
  %a = call i32 @fib(i32 %n1)
  %b = call i32 @fib(i32 %n2)
  %sum = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %a, i32 %b)
  %ov = extractvalue { i32, i1 } %sum, 1
  br i1 %ov, label %overflow, label %ok

ok:
  %r = extractvalue { i32, i1 } %sum, 0
  ret i32 %r

overflow:
  call void @plllvm_int_overflow()
  unreachable
}
