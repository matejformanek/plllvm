; inc(x integer) RETURNS integer    (ISP RAS 2020, q3)
;
;   RETURN x + 1;
;
; A NULL x returns NULL.

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_return_null(ptr)
declare void @plllvm_cfi()
declare void @plllvm_rt_int_overflow() noreturn

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %x.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %x.n, label %null, label %add

add:
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %r = call { i32, i1 } @llvm.sadd.with.overflow.i32(i32 %x, i32 1)
  %ov = extractvalue { i32, i1 } %r, 1
  br i1 %ov, label %overflow, label %ok

ok:
  %v = extractvalue { i32, i1 } %r, 0
  %d = sext i32 %v to i64
  ret i64 %d

null:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z

overflow:
  call void @plllvm_rt_int_overflow()
  unreachable
}
