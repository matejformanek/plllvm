; gt(x integer, y integer) RETURNS boolean    (ISP RAS 2020, q2-q4)
;
;   IF x > y THEN
;     RETURN TRUE;
;   ELSE
;     RETURN FALSE;
;   END IF;
;
; A NULL argument makes the condition NULL, so the ELSE branch runs.

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()

define i64 @f(ptr %fcinfo) {
entry:
  call void @plllvm_cfi()
  %x.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %y.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 1)
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %y = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 1)
  %null = or i1 %x.n, %y.n
  %known = xor i1 %null, true
  %gt = icmp sgt i32 %x, %y
  %r = and i1 %known, %gt
  %d = zext i1 %r to i64
  ret i64 %d
}
