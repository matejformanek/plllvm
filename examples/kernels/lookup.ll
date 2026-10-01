; lookup(n integer)    (bench/kernels/42_lookup.sql)
;
;   DECLARE
;     seed bigint := 777;
;     k integer; v_i_id integer;
;     v_price numeric(5,2); v_name varchar(24); v_qty integer;
;     acc numeric(16,2) := 0;
;     low integer := 0; vowel integer := 0;
;   BEGIN
;     FOR k IN 1..n LOOP
;       seed := (seed * 1103515245 + 12345) % 2147483648;
;       v_i_id := 1 + (seed % 10000)::integer;
;       SELECT i_price, i_name INTO v_price, v_name FROM item WHERE i_id = v_i_id;
;       SELECT s_quantity INTO v_qty FROM stock WHERE s_w_id = 1 AND s_i_id = v_i_id;
;       acc := acc + v_price * v_qty;
;       IF v_qty < 20 THEN
;         low := low + 1;
;       END IF;
;       IF position(substr(v_name, 1, 1) IN 'aeiou') > 0 THEN
;         vowel := vowel + 1;
;       END IF;
;     END LOOP;
;     RETURN acc::text || '/' || low || '/' || vowel;
;   END
;
; The statements run as PL/pgSQL's SELECT INTO, through
; @plllvm_spi_select_into; they are prepared when the loop is entered, as
; PL/pgSQL prepares at the first execution.  The numeric and text calls are
; those of bench/ctwins/ca/lookup.c.  The int8 LCG and the integer tests are
; native.  NULLs propagate as in PL/pgSQL, though the bench data has none.
;
; v_price and v_name are the kept columns of the last SELECT, freed before
; the next one; acc is a @plllvm_keep copy.  The scratch is reset after
; every statement, as PL/pgSQL's eval context.

@msg.null_bound = private unnamed_addr constant [39 x i8] c"upper bound of FOR loop cannot be null\00"
@q.item = private unnamed_addr constant [49 x i8] c"SELECT i_price, i_name FROM item WHERE i_id = $1\00"
@q.item.cols = private unnamed_addr constant [17 x i8] c"numeric, varchar\00"
@q.stock = private unnamed_addr constant [62 x i8] c"SELECT s_quantity FROM stock WHERE s_w_id = 1 AND s_i_id = $1\00"
@q.int4 = private unnamed_addr constant [5 x i8] c"int4\00"
@item = internal global ptr null
@stock = internal global ptr null

@"numeric(integer)" = external global i8
@"numeric_mul(numeric,numeric)" = external global i8
@"numeric_add(numeric,numeric)" = external global i8
@"numeric(numeric,integer)" = external global i8
@"substr(text,integer,integer)" = external global i8
@"position(text,text)" = external global i8
@"numeric_out(numeric)" = external global i8
@"int4out(integer)" = external global i8
@"textcat(text,text)" = external global i8

@"'0'::numeric(16,2)" = external global i8
@"'aeiou'::text" = external global i8
@"'/'::text" = external global i8

declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_return_null(ptr)
declare void @plllvm_cfi()
declare void @plllvm_error(i32, ptr) noreturn
declare void @plllvm_rt_int_overflow() noreturn
declare void @plllvm_rt_bigint_overflow() noreturn
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
declare i64 @plllvm_call3(ptr, i64, i1, i64, i1, i64, i1, ptr)
declare i64 @plllvm_const(ptr)
declare i64 @plllvm_cstring_to_text(ptr)
declare i64 @plllvm_keep(i64)
declare void @plllvm_free(i64)
declare void @plllvm_scratch_reset()
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
declare i32 @plllvm_spi_select_into(ptr, ptr, ptr, ptr)

declare { i32, i1 } @llvm.sadd.with.overflow.i32(i32, i32)
declare { i64, i1 } @llvm.sadd.with.overflow.i64(i64, i64)
declare { i64, i1 } @llvm.smul.with.overflow.i64(i64, i64)

; NullableDatum
%nd = type { i64, i8 }

define i64 @f(ptr %fcinfo) {
entry:
  %seed = alloca i64
  %acc = alloca %nd
  %low = alloca i32
  %vowel = alloca i32
  %isnull = alloca i1
  ; $1 = v_i_id; v_price, v_name; v_qty
  %args = alloca [1 x %nd]
  %item.out = alloca [2 x %nd]
  %stock.out = alloca [1 x %nd]
  %v_price = getelementptr %nd, ptr %item.out, i32 0
  %v_name = getelementptr %nd, ptr %item.out, i32 1
  call void @set_null(ptr %v_price)
  call void @set_null(ptr %v_name)
  call void @set_null(ptr %stock.out)

  store i64 777, ptr %seed
  %zero.16.2 = call i64 @plllvm_const(ptr @"'0'::numeric(16,2)")
  call void @set_null(ptr %acc)
  call void @assign(ptr %acc, i64 %zero.16.2, i1 false)
  store i32 0, ptr %low
  store i32 0, ptr %vowel

  %n.isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %n.isnull, label %null_bound, label %k.start

k.start:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %k.any = icmp sle i32 1, %n
  br i1 %k.any, label %prepare, label %done

prepare:
  %item.stmt = call ptr @plllvm_spi_prepare(ptr @item, ptr @q.item, ptr @q.int4, ptr @q.item.cols)
  %stock.stmt = call ptr @plllvm_spi_prepare(ptr @stock, ptr @q.stock, ptr @q.int4, ptr @q.int4)
  br label %k.body

k.body:
  %k = phi i32 [ 1, %prepare ], [ %k.next, %k.inc ]
  ; seed := (seed * 1103515245 + 12345) % 2147483648
  %seed.0 = load i64, ptr %seed
  %seed.1 = call i64 @int8mul(i64 %seed.0, i64 1103515245)
  %seed.2 = call i64 @int8pl(i64 %seed.1, i64 12345)
  %seed.3 = srem i64 %seed.2, 2147483648
  store i64 %seed.3, ptr %seed

  ; v_i_id := 1 + (seed % 10000)::integer
  %id.0 = srem i64 %seed.3, 10000
  %id.1 = call i32 @int84(i64 %id.0)
  %id = call i32 @int4pl(i32 1, i32 %id.1)
  %id.d = sext i32 %id to i64
  store %nd { i64 0, i8 0 }, ptr %args
  store i64 %id.d, ptr %args

  ; SELECT i_price, i_name INTO v_price, v_name FROM item WHERE i_id = v_i_id
  call void @free_kept(ptr %v_price)
  call void @free_kept(ptr %v_name)
  %item.rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %item.stmt, ptr %args, ptr %item.out)
  call void @plllvm_scratch_reset()

  ; SELECT s_quantity INTO v_qty FROM stock WHERE s_w_id = 1 AND s_i_id = v_i_id
  %stock.rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stock.stmt, ptr %args, ptr %stock.out)
  call void @plllvm_scratch_reset()

  ; acc := acc + v_price * v_qty, coerced to numeric(16,2)
  %price = load i64, ptr %v_price
  %price.n = call i1 @is_null(ptr %v_price)
  %qty.d = load i64, ptr %stock.out
  %qty.n = call i1 @is_null(ptr %stock.out)
  %a.0 = call i64 @plllvm_call1(ptr @"numeric(integer)", i64 %qty.d, i1 %qty.n, ptr %isnull)
  %a.0.n = load i1, ptr %isnull
  %a.1 = call i64 @plllvm_call2(ptr @"numeric_mul(numeric,numeric)", i64 %price, i1 %price.n, i64 %a.0, i1 %a.0.n, ptr %isnull)
  %a.1.n = load i1, ptr %isnull
  %acc.0 = load i64, ptr %acc
  %acc.0.n = call i1 @is_null(ptr %acc)
  %a.2 = call i64 @plllvm_call2(ptr @"numeric_add(numeric,numeric)", i64 %acc.0, i1 %acc.0.n, i64 %a.1, i1 %a.1.n, ptr %isnull)
  %a.2.n = load i1, ptr %isnull
  ; typmod ((16 << 16) | 2) + 4
  %a.3 = call i64 @plllvm_call2(ptr @"numeric(numeric,integer)", i64 %a.2, i1 %a.2.n, i64 1048582, i1 false, ptr %isnull)
  %a.3.n = load i1, ptr %isnull
  call void @assign(ptr %acc, i64 %a.3, i1 %a.3.n)

  ; IF v_qty < 20 THEN low := low + 1
  %qty = trunc i64 %qty.d to i32
  %qty.lt = icmp slt i32 %qty, 20
  %qty.nn = xor i1 %qty.n, true
  %c1 = and i1 %qty.nn, %qty.lt
  br i1 %c1, label %low.inc, label %c2

low.inc:
  %low.0 = load i32, ptr %low
  %low.1 = call i32 @int4pl(i32 %low.0, i32 1)
  store i32 %low.1, ptr %low
  br label %c2

c2:
  ; IF position(substr(v_name, 1, 1) IN 'aeiou') > 0 THEN vowel := vowel + 1
  %name = load i64, ptr %v_name
  %name.n = call i1 @is_null(ptr %v_name)
  %c2.0 = call i64 @plllvm_call3(ptr @"substr(text,integer,integer)", i64 %name, i1 %name.n, i64 1, i1 false, i64 1, i1 false, ptr %isnull)
  %c2.0.n = load i1, ptr %isnull
  %aeiou = call i64 @plllvm_const(ptr @"'aeiou'::text")
  %c2.1 = call i64 @plllvm_call2(ptr @"position(text,text)", i64 %aeiou, i1 false, i64 %c2.0, i1 %c2.0.n, ptr %isnull)
  %c2.1.n = load i1, ptr %isnull
  %pos = trunc i64 %c2.1 to i32
  %pos.gt = icmp sgt i32 %pos, 0
  %pos.nn = xor i1 %c2.1.n, true
  %c2.2 = and i1 %pos.nn, %pos.gt
  call void @plllvm_scratch_reset()
  br i1 %c2.2, label %vowel.inc, label %k.latch

vowel.inc:
  %vowel.0 = load i32, ptr %vowel
  %vowel.1 = call i32 @int4pl(i32 %vowel.0, i32 1)
  store i32 %vowel.1, ptr %vowel
  br label %k.latch

k.latch:
  call void @plllvm_cfi()
  ; the FOR ends at its bound before the counter could overflow
  %k.last = icmp eq i32 %k, %n
  br i1 %k.last, label %done, label %k.inc

k.inc:
  %k.next = add nsw i32 %k, 1
  br label %k.body

done:
  ; RETURN acc::text || '/' || low || '/' || vowel, NULL with acc
  %acc.r.n = call i1 @is_null(ptr %acc)
  br i1 %acc.r.n, label %null_result, label %result

result:
  %slash = call i64 @plllvm_const(ptr @"'/'::text")
  %acc.r = load i64, ptr %acc
  %acc.s = call i64 @plllvm_call1(ptr @"numeric_out(numeric)", i64 %acc.r, i1 false, ptr null)
  %acc.p = inttoptr i64 %acc.s to ptr
  %acc.t = call i64 @plllvm_cstring_to_text(ptr %acc.p)
  %r.1 = call i64 @textcat(i64 %acc.t, i64 %slash)
  %low.r = load i32, ptr %low
  %low.t = call i64 @int4text(i32 %low.r)
  %r.2 = call i64 @textcat(i64 %r.1, i64 %low.t)
  %r.3 = call i64 @textcat(i64 %r.2, i64 %slash)
  %vowel.r = load i32, ptr %vowel
  %vowel.t = call i64 @int4text(i32 %vowel.r)
  %r.4 = call i64 @textcat(i64 %r.3, i64 %vowel.t)
  ret i64 %r.4

null_result:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z

null_bound:
  ; 22004 = MAKE_SQLSTATE('2','2','0','0','4')
  call void @plllvm_error(i32 67108994, ptr @msg.null_bound)
  unreachable
}

define internal void @set_null(ptr %v) alwaysinline {
  store %nd { i64 0, i8 1 }, ptr %v
  ret void
}

define internal i1 @is_null(ptr %v) alwaysinline {
  %p = getelementptr %nd, ptr %v, i32 0, i32 1
  %b = load i8, ptr %p
  %r = icmp ne i8 %b, 0
  ret i1 %r
}

; a kept column of the last SELECT INTO
define internal void @free_kept(ptr %v) alwaysinline {
entry:
  %n = call i1 @is_null(ptr %v)
  br i1 %n, label %out, label %free
free:
  %d = load i64, ptr %v
  call void @plllvm_free(i64 %d)
  br label %out
out:
  ret void
}

; var := v, then the end of the statement
define internal void @assign(ptr %var, i64 %v, i1 %isnull) {
entry:
  call void @free_kept(ptr %var)
  br i1 %isnull, label %null, label %keep
keep:
  %new = call i64 @plllvm_keep(i64 %v)
  store %nd { i64 0, i8 0 }, ptr %var
  store i64 %new, ptr %var
  br label %reset
null:
  call void @set_null(ptr %var)
  br label %reset
reset:
  call void @plllvm_scratch_reset()
  ret void
}

define internal i64 @textcat(i64 %a, i64 %b) alwaysinline {
  %r = call i64 @plllvm_call2(ptr @"textcat(text,text)", i64 %a, i1 false, i64 %b, i1 false, ptr null)
  ret i64 %r
}

; textanycat's $2::text
define internal i64 @int4text(i32 %v) alwaysinline {
  %d = sext i32 %v to i64
  %s = call i64 @plllvm_call1(ptr @"int4out(integer)", i64 %d, i1 false, ptr null)
  %p = inttoptr i64 %s to ptr
  %t = call i64 @plllvm_cstring_to_text(ptr %p)
  ret i64 %t
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

define internal i32 @int84(i64 %a) alwaysinline {
  %v = trunc i64 %a to i32
  %back = sext i32 %v to i64
  %ok = icmp eq i64 %back, %a
  br i1 %ok, label %in, label %overflow
in:
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
