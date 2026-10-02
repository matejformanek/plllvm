; line_net(qty integer, price numeric, disc numeric, tax numeric,
;          region integer) RETURNS numeric    (bench/kernels/43_rowudf.sql)
;
;   DECLARE
;     gross numeric;
;     net numeric;
;   BEGIN
;     gross := qty * price;
;     IF qty >= 50 THEN
;       gross := gross * 0.95;
;     ELSIF qty >= 20 THEN
;       gross := gross * 0.98;
;     END IF;
;     net := round(gross * (1 - disc) * (1 + tax), 2);
;     IF region = 3 THEN
;       net := net + 1.50;
;     END IF;
;     RETURN net;
;   END
;
; The per-row UDF of the rowudf query, called from SQL:
;
;   SELECT sum(line_net(qty, price, disc, tax, region)) FROM udf_rows
;
; The numeric calls are those of bench/ctwins/ca/line_net.c, in its order;
; the 1 of "1 - disc" and "1 + tax" is a numeric constant, as the planner
; folds numeric(1).  The integer tests are native.  The function is not
; STRICT: a NULL goes through the strict numeric functions as NULL, and a
; NULL qty or region fails its IF.
;
; There is no loop, so the intermediate values stay in the scratch until it
; is deleted after the call; nothing is kept.

@"numeric(integer)" = external global i8
@"numeric_mul(numeric,numeric)" = external global i8
@"numeric_sub(numeric,numeric)" = external global i8
@"numeric_add(numeric,numeric)" = external global i8
@"round(numeric,integer)" = external global i8

@"'0.95'::numeric" = external global i8
@"'0.98'::numeric" = external global i8
@"'1'::numeric" = external global i8
@"'1.50'::numeric" = external global i8

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_arg_i64(ptr, i32)
declare i64 @plllvm_return_null(ptr)
declare void @plllvm_cfi()
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
declare i64 @plllvm_const(ptr)

define i64 @f(ptr %fcinfo) {
entry:
  %isnull = alloca i1
  call void @plllvm_cfi()
  %qty.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %qty = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %price.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 1)
  %price = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 1)
  %disc.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 2)
  %disc = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 2)
  %tax.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 3)
  %tax = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 3)
  %region.n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 4)
  %region = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 4)

  ; gross := qty * price
  %qty.d = sext i32 %qty to i64
  %g.0 = call i64 @plllvm_call1(ptr @"numeric(integer)", i64 %qty.d, i1 %qty.n, ptr %isnull)
  %g.0.n = load i1, ptr %isnull
  %g.1 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %g.0, i1 %g.0.n, i64 %price, i1 %price.n, ptr %isnull)
  %g.1.n = load i1, ptr %isnull

  ; IF qty >= 50 THEN ... ELSIF qty >= 20 THEN ... END IF
  %qty.nn = xor i1 %qty.n, true
  %ge50 = icmp sge i32 %qty, 50
  %c50 = and i1 %qty.nn, %ge50
  br i1 %c50, label %by95, label %elsif

elsif:
  %ge20 = icmp sge i32 %qty, 20
  %c20 = and i1 %qty.nn, %ge20
  br i1 %c20, label %by98, label %net

by95:
  ; gross := gross * 0.95
  %k95 = call i64 @plllvm_const(ptr @"'0.95'::numeric")
  %g.95 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %g.1, i1 %g.1.n, i64 %k95, i1 false, ptr %isnull)
  %g.95.n = load i1, ptr %isnull
  br label %net

by98:
  ; gross := gross * 0.98
  %k98 = call i64 @plllvm_const(ptr @"'0.98'::numeric")
  %g.98 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %g.1, i1 %g.1.n, i64 %k98, i1 false, ptr %isnull)
  %g.98.n = load i1, ptr %isnull
  br label %net

net:
  %gross = phi i64 [ %g.1, %elsif ], [ %g.95, %by95 ], [ %g.98, %by98 ]
  %gross.n = phi i1 [ %g.1.n, %elsif ], [ %g.95.n, %by95 ], [ %g.98.n, %by98 ]

  ; net := round(gross * (1 - disc) * (1 + tax), 2)
  %one = call i64 @plllvm_const(ptr @"'1'::numeric")
  %n.0 = call i64 @plllvm_call2(ptr @"numeric_sub(numeric,numeric)", i64 %one, i1 false, i64 %disc, i1 %disc.n, ptr %isnull)
  %n.0.n = load i1, ptr %isnull
  %n.1 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %gross, i1 %gross.n, i64 %n.0, i1 %n.0.n, ptr %isnull)
  %n.1.n = load i1, ptr %isnull
  %n.2 = call i64 @plllvm_call2(ptr @"numeric_add(numeric,numeric)", i64 %one, i1 false, i64 %tax, i1 %tax.n, ptr %isnull)
  %n.2.n = load i1, ptr %isnull
  %n.3 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %n.1, i1 %n.1.n, i64 %n.2, i1 %n.2.n, ptr %isnull)
  %n.3.n = load i1, ptr %isnull
  %n.4 = call i64 @plllvm_call2(ptr @"round(numeric,integer)", i64 %n.3, i1 %n.3.n, i64 2, i1 false, ptr %isnull)
  %n.4.n = load i1, ptr %isnull

  ; IF region = 3 THEN net := net + 1.50
  %region.nn = xor i1 %region.n, true
  %eq3 = icmp eq i32 %region, 3
  %c3 = and i1 %region.nn, %eq3
  br i1 %c3, label %plus, label %return

plus:
  %k150 = call i64 @plllvm_const(ptr @"'1.50'::numeric")
  %n.5 = call i64 @plllvm_call2(ptr @"numeric_add(numeric,numeric)", i64 %n.4, i1 %n.4.n, i64 %k150, i1 false, ptr %isnull)
  %n.5.n = load i1, ptr %isnull
  br label %return

return:
  ; RETURN net
  %r = phi i64 [ %n.4, %net ], [ %n.5, %plus ]
  %r.n = phi i1 [ %n.4.n, %net ], [ %n.5.n, %plus ]
  br i1 %r.n, label %null_result, label %result

result:
  ret i64 %r

null_result:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z
}
