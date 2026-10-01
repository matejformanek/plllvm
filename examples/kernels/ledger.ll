; ledger(nloans integer, months integer)    (bench/kernels/20_ledger.sql)
;
;   DECLARE
;     k integer; mth integer;
;     seed bigint := 42;
;     principal numeric(12,2);
;     balance numeric(12,2);
;     payment numeric(12,2);
;     interest numeric(12,2);
;     princ_part numeric(12,2);
;     fee numeric(12,2);
;     rate numeric(10,6);
;     mrate numeric(14,10);
;     f numeric(24,12);
;     total_interest numeric(18,2) := 0;
;     total_paid numeric(18,2) := 0;
;     nfees integer := 0;
;   BEGIN
;     FOR k IN 1..nloans LOOP
;       seed := (seed * 1103515245 + 12345) % 2147483648;
;       principal := 5000 + (seed % 495001);
;       rate := 0.02 + (seed % 800) / 10000.0;
;       mrate := rate / 12;
;       f := 1;
;       FOR mth IN 1..months LOOP
;         f := round(f * (1 + mrate), 12);
;       END LOOP;
;       payment := round(principal * mrate * f / (f - 1), 2);
;       balance := principal;
;       FOR mth IN 1..months LOOP
;         interest := round(balance * mrate, 2);
;         IF mth = months OR payment - interest > balance THEN
;           princ_part := balance;
;         ELSE
;           princ_part := payment - interest;
;         END IF;
;         IF (k + mth) % 13 = 0 THEN
;           fee := round(balance * 0.0015, 2) + 5.00;
;           nfees := nfees + 1;
;         ELSE
;           fee := 0;
;         END IF;
;         balance := balance - princ_part;
;         total_interest := total_interest + interest + fee;
;         total_paid := total_paid + princ_part + interest + fee;
;         EXIT WHEN balance <= 0;
;       END LOOP;
;     END LOOP;
;     RETURN total_interest::text || '/' || total_paid::text || '/' || nfees::text;
;   END
;
; The numeric calls are those of bench/ctwins/ca/ledger.c, in its order: a
; store into a numeric(p,s) variable calls numeric(numeric,integer) with the
; typmod ((p << 16) | s) + 4, as the parser's length coercion does.  The int8
; LCG and the integer tests are native.
;
; Variables live in allocas, as PL/pgSQL datums do.  A numeric variable holds a
; @plllvm_keep copy and @assign frees the one it replaces, then resets the
; scratch: PL/pgSQL's datum context plus eval context.

@msg.null_bound = private unnamed_addr constant [39 x i8] c"upper bound of FOR loop cannot be null\00"

@"numeric_add(numeric,numeric)" = external global i8
@"numeric_sub(numeric,numeric)" = external global i8
@"numeric_mul(numeric,numeric)" = external global i8
@"numeric_div(numeric,numeric)" = external global i8
@"round(numeric,integer)" = external global i8
@"numeric(numeric,integer)" = external global i8
@"numeric(bigint)" = external global i8
@"numeric_gt(numeric,numeric)" = external global i8
@"numeric_le(numeric,numeric)" = external global i8
@"numeric_out(numeric)" = external global i8
@"int4out(integer)" = external global i8
@"textcat(text,text)" = external global i8

@"'10000.0'::numeric" = external global i8
@"'0.02'::numeric" = external global i8
@"'12'::numeric" = external global i8
@"'1'::numeric" = external global i8
@"'0.0015'::numeric" = external global i8
@"'5.00'::numeric" = external global i8
@"'0'::numeric" = external global i8
@"'0'::numeric(18,2)" = external global i8
@"'1'::numeric(24,12)" = external global i8
@"'0'::numeric(12,2)" = external global i8
@"'/'::text" = external global i8

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare void @plllvm_cfi()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_rt_int_overflow() noreturn
declare void @plllvm_rt_bigint_overflow() noreturn
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
declare i64 @plllvm_const(ptr)
declare i64 @plllvm_cstring_to_text(ptr)
declare i64 @plllvm_keep(i64)
declare void @plllvm_free(i64)
declare void @plllvm_scratch_reset()

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)

define i64 @f(ptr %fcinfo) {
entry:
  %seed = alloca i64
  %principal = alloca i64
  %balance = alloca i64
  %payment = alloca i64
  %interest = alloca i64
  %princ_part = alloca i64
  %fee = alloca i64
  %rate = alloca i64
  %mrate = alloca i64
  %f = alloca i64
  %total_interest = alloca i64
  %total_paid = alloca i64
  %nfees = alloca i32
  ; 0: not assigned yet, nothing to free
  store i64 0, ptr %principal
  store i64 0, ptr %balance
  store i64 0, ptr %payment
  store i64 0, ptr %interest
  store i64 0, ptr %princ_part
  store i64 0, ptr %fee
  store i64 0, ptr %rate
  store i64 0, ptr %mrate
  store i64 0, ptr %f
  store i64 0, ptr %total_interest
  store i64 0, ptr %total_paid

  store i64 42, ptr %seed
  %zero.18.2 = call i64 @plllvm_const(ptr @"'0'::numeric(18,2)")
  call void @assign(ptr %total_interest, i64 %zero.18.2)
  call void @assign(ptr %total_paid, i64 %zero.18.2)
  store i32 0, ptr %nfees

  %nloans.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %nloans.isnull, label %null_bound, label %k.start

k.start:
  %nloans = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %k.any = icmp sle i32 1, %nloans
  br i1 %k.any, label %k.body, label %done

k.body:
  %k = phi i32 [ 1, %k.start ], [ %k.next, %k.inc ]
  ; seed := (seed * 1103515245 + 12345) % 2147483648
  %seed.0 = load i64, ptr %seed
  %seed.1 = call i64 @int8mul(i64 %seed.0, i64 1103515245)
  %seed.2 = call i64 @int8pl(i64 %seed.1, i64 12345)
  %seed.3 = srem i64 %seed.2, 2147483648
  store i64 %seed.3, ptr %seed

  ; principal := 5000 + (seed % 495001)
  %pr.0 = srem i64 %seed.3, 495001
  %pr.1 = call i64 @int8pl(i64 5000, i64 %pr.0)
  %pr.2 = call i64 @plllvm_call1(ptr @"numeric(bigint)", i64 %pr.1, i1 false, ptr null)
  %pr.3 = call i64 @num_typmod(i64 %pr.2, i64 786438)     ; (12,2)
  call void @assign(ptr %principal, i64 %pr.3)

  ; rate := 0.02 + (seed % 800) / 10000.0
  %rt.0 = srem i64 %seed.3, 800
  %rt.1 = call i64 @plllvm_call1(ptr @"numeric(bigint)", i64 %rt.0, i1 false, ptr null)
  %c.10000 = call i64 @plllvm_const(ptr @"'10000.0'::numeric")
  %rt.2 = call i64 @num_div(i64 %rt.1, i64 %c.10000)
  %c.0.02 = call i64 @plllvm_const(ptr @"'0.02'::numeric")
  %rt.3 = call i64 @num_add(i64 %c.0.02, i64 %rt.2)
  %rt.4 = call i64 @num_typmod(i64 %rt.3, i64 655370)     ; (10,6)
  call void @assign(ptr %rate, i64 %rt.4)

  ; mrate := rate / 12
  %rate.0 = load i64, ptr %rate
  %c.12 = call i64 @plllvm_const(ptr @"'12'::numeric")
  %mr.0 = call i64 @num_div(i64 %rate.0, i64 %c.12)
  %mr.1 = call i64 @num_typmod(i64 %mr.0, i64 917518)     ; (14,10)
  call void @assign(ptr %mrate, i64 %mr.1)

  ; f := 1
  %c.f = call i64 @plllvm_const(ptr @"'1'::numeric(24,12)")
  call void @assign(ptr %f, i64 %c.f)

  ; months is read only here, as PL/pgSQL reads it only at the FOR
  %months.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 1)
  br i1 %months.isnull, label %null_bound, label %f.start

f.start:
  %months = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 1)
  %c.1 = call i64 @plllvm_const(ptr @"'1'::numeric")
  %f.any = icmp sle i32 1, %months
  br i1 %f.any, label %f.body, label %payment.calc

f.body:
  %fm = phi i32 [ 1, %f.start ], [ %fm.next, %f.latch ]
  ; f := round(f * (1 + mrate), 12)
  %mrate.f = load i64, ptr %mrate
  %f.0 = call i64 @num_add(i64 %c.1, i64 %mrate.f)
  %f.cur = load i64, ptr %f
  %f.1 = call i64 @num_mul(i64 %f.cur, i64 %f.0)
  %f.2 = call i64 @num_round(i64 %f.1, i64 12)
  %f.3 = call i64 @num_typmod(i64 %f.2, i64 1572880)     ; (24,12)
  call void @assign(ptr %f, i64 %f.3)
  call void @plllvm_cfi()
  ; the FOR ends at its bound before the counter could overflow
  %fm.last = icmp eq i32 %fm, %months
  br i1 %fm.last, label %payment.calc, label %f.latch

f.latch:
  %fm.next = add nsw i32 %fm, 1
  br label %f.body

payment.calc:
  ; payment := round(principal * mrate * f / (f - 1), 2)
  %principal.0 = load i64, ptr %principal
  %mrate.0 = load i64, ptr %mrate
  %f.end = load i64, ptr %f
  %py.0 = call i64 @num_mul(i64 %principal.0, i64 %mrate.0)
  %py.1 = call i64 @num_mul(i64 %py.0, i64 %f.end)
  %py.2 = call i64 @num_sub(i64 %f.end, i64 %c.1)
  %py.3 = call i64 @num_div(i64 %py.1, i64 %py.2)
  %py.4 = call i64 @num_round(i64 %py.3, i64 2)
  %py.5 = call i64 @num_typmod(i64 %py.4, i64 786438)     ; (12,2)
  call void @assign(ptr %payment, i64 %py.5)

  ; balance := principal
  call void @assign(ptr %balance, i64 %principal.0)
  br i1 %f.any, label %m.body, label %k.latch

m.body:
  %mth = phi i32 [ 1, %payment.calc ], [ %mth.next, %m.latch ]
  ; interest := round(balance * mrate, 2)
  %balance.0 = load i64, ptr %balance
  %mrate.1 = load i64, ptr %mrate
  %in.0 = call i64 @num_mul(i64 %balance.0, i64 %mrate.1)
  %in.1 = call i64 @num_round(i64 %in.0, i64 2)
  %in.2 = call i64 @num_typmod(i64 %in.1, i64 786438)     ; (12,2)
  call void @assign(ptr %interest, i64 %in.2)

  ; IF mth = months OR payment - interest > balance, short-circuit as
  ; EEOP_BOOL_OR_STEP; no operand can be NULL
  %mth.last = icmp eq i32 %mth, %months
  br i1 %mth.last, label %pp.balance, label %c1.gt

c1.gt:
  %payment.0 = load i64, ptr %payment
  %interest.0 = load i64, ptr %interest
  %c1.0 = call i64 @num_sub(i64 %payment.0, i64 %interest.0)
  %c1 = call i1 @num_gt(i64 %c1.0, i64 %balance.0)
  call void @plllvm_scratch_reset()
  br i1 %c1, label %pp.balance, label %pp.part

pp.balance:
  ; princ_part := balance
  call void @assign(ptr %princ_part, i64 %balance.0)
  br label %c2

pp.part:
  ; princ_part := payment - interest
  %pp.0 = call i64 @num_sub(i64 %payment.0, i64 %interest.0)
  %pp.1 = call i64 @num_typmod(i64 %pp.0, i64 786438)     ; (12,2)
  call void @assign(ptr %princ_part, i64 %pp.1)
  br label %c2

c2:
  ; IF (k + mth) % 13 = 0
  %c2.0 = call i32 @int4pl(i32 %k, i32 %mth)
  %c2.1 = srem i32 %c2.0, 13
  %c2.2 = icmp eq i32 %c2.1, 0
  br i1 %c2.2, label %fee.calc, label %fee.zero

fee.calc:
  ; fee := round(balance * 0.0015, 2) + 5.00
  %c.0.0015 = call i64 @plllvm_const(ptr @"'0.0015'::numeric")
  %fe.0 = call i64 @num_mul(i64 %balance.0, i64 %c.0.0015)
  %fe.1 = call i64 @num_round(i64 %fe.0, i64 2)
  %c.5.00 = call i64 @plllvm_const(ptr @"'5.00'::numeric")
  %fe.2 = call i64 @num_add(i64 %fe.1, i64 %c.5.00)
  %fe.3 = call i64 @num_typmod(i64 %fe.2, i64 786438)     ; (12,2)
  call void @assign(ptr %fee, i64 %fe.3)
  ; nfees := nfees + 1
  %nfees.0 = load i32, ptr %nfees
  %nfees.1 = call i32 @int4pl(i32 %nfees.0, i32 1)
  store i32 %nfees.1, ptr %nfees
  br label %balance.calc

fee.zero:
  ; fee := 0
  %c.fee = call i64 @plllvm_const(ptr @"'0'::numeric(12,2)")
  call void @assign(ptr %fee, i64 %c.fee)
  br label %balance.calc

balance.calc:
  ; balance := balance - princ_part
  %princ_part.0 = load i64, ptr %princ_part
  %ba.0 = call i64 @num_sub(i64 %balance.0, i64 %princ_part.0)
  %ba.1 = call i64 @num_typmod(i64 %ba.0, i64 786438)     ; (12,2)
  call void @assign(ptr %balance, i64 %ba.1)

  ; total_interest := total_interest + interest + fee
  %ti.0 = load i64, ptr %total_interest
  %interest.1 = load i64, ptr %interest
  %fee.0 = load i64, ptr %fee
  %ti.1 = call i64 @num_add(i64 %ti.0, i64 %interest.1)
  %ti.2 = call i64 @num_add(i64 %ti.1, i64 %fee.0)
  %ti.3 = call i64 @num_typmod(i64 %ti.2, i64 1179654)    ; (18,2)
  call void @assign(ptr %total_interest, i64 %ti.3)

  ; total_paid := total_paid + princ_part + interest + fee
  %tp.0 = load i64, ptr %total_paid
  %tp.1 = call i64 @num_add(i64 %tp.0, i64 %princ_part.0)
  %tp.2 = call i64 @num_add(i64 %tp.1, i64 %interest.1)
  %tp.3 = call i64 @num_add(i64 %tp.2, i64 %fee.0)
  %tp.4 = call i64 @num_typmod(i64 %tp.3, i64 1179654)    ; (18,2)
  call void @assign(ptr %total_paid, i64 %tp.4)

  ; EXIT WHEN balance <= 0
  %balance.1 = load i64, ptr %balance
  %c.0 = call i64 @plllvm_const(ptr @"'0'::numeric")
  %exit = call i1 @num_le(i64 %balance.1, i64 %c.0)
  call void @plllvm_scratch_reset()
  call void @plllvm_cfi()
  br i1 %exit, label %k.latch, label %m.test

m.test:
  br i1 %mth.last, label %k.latch, label %m.latch

m.latch:
  %mth.next = add nsw i32 %mth, 1
  br label %m.body

k.latch:
  call void @plllvm_cfi()
  %k.last = icmp eq i32 %k, %nloans
  br i1 %k.last, label %done, label %k.inc

k.inc:
  %k.next = add nsw i32 %k, 1
  br label %k.body

done:
  ; RETURN total_interest::text || '/' || total_paid::text || '/' || nfees::text
  %slash = call i64 @plllvm_const(ptr @"'/'::text")
  %ti = load i64, ptr %total_interest
  %ti.s = call i64 @plllvm_call1(ptr @"numeric_out(numeric)", i64 %ti, i1 false, ptr null)
  %ti.p = inttoptr i64 %ti.s to ptr
  %ti.t = call i64 @plllvm_cstring_to_text(ptr %ti.p)
  %r.1 = call i64 @textcat(i64 %ti.t, i64 %slash)
  %tp = load i64, ptr %total_paid
  %tp.s = call i64 @plllvm_call1(ptr @"numeric_out(numeric)", i64 %tp, i1 false, ptr null)
  %tp.p = inttoptr i64 %tp.s to ptr
  %tp.t = call i64 @plllvm_cstring_to_text(ptr %tp.p)
  %r.2 = call i64 @textcat(i64 %r.1, i64 %tp.t)
  %r.3 = call i64 @textcat(i64 %r.2, i64 %slash)
  %nf = load i32, ptr %nfees
  %nf.d = sext i32 %nf to i64
  %nf.s = call i64 @plllvm_call1(ptr @"int4out(integer)", i64 %nf.d, i1 false, ptr null)
  %nf.p = inttoptr i64 %nf.s to ptr
  %nf.t = call i64 @plllvm_cstring_to_text(ptr %nf.p)
  %r.4 = call i64 @textcat(i64 %r.3, i64 %nf.t)
  ret i64 %r.4

null_bound:
  ; 22004 = MAKE_SQLSTATE('2','2','0','0','4')
  call void @plllvm_error(i32 67108994, ptr @msg.null_bound)
  unreachable
}

; var := v, then the end of the statement
define internal void @assign(ptr %var, i64 %v) {
entry:
  %new = call i64 @plllvm_keep(i64 %v)
  %old = load i64, ptr %var
  store i64 %new, ptr %var
  %had = icmp ne i64 %old, 0
  br i1 %had, label %free, label %reset
free:
  call void @plllvm_free(i64 %old)
  br label %reset
reset:
  call void @plllvm_scratch_reset()
  ret void
}

; numeric operators through their sites; the operands are never NULL

define internal i64 @num_add(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_add(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
}

define internal i64 @num_sub(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_sub(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
}

define internal i64 @num_mul(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
}

define internal i64 @num_div(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_div(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
}

define internal i64 @num_round(i64 %a, i64 %scale) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"round(numeric,integer)", i64 %a, i1 false, i64 %scale, i1 false, ptr null)
  ret i64 %r
}

define internal i64 @num_typmod(i64 %a, i64 %typmod) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric(numeric,integer)", i64 %a, i1 false, i64 %typmod, i1 false, ptr null)
  ret i64 %r
}

define internal i1 @num_gt(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_gt(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  %b.r = icmp ne i64 %r, 0
  ret i1 %b.r
}

define internal i1 @num_le(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"numeric_le(numeric,numeric)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  %b.r = icmp ne i64 %r, 0
  ret i1 %b.r
}

define internal i64 @textcat(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"textcat(text,text)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
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
