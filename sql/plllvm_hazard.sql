--
-- Tests that crash the server when their fix regresses (installcheck-hazard,
-- on a throwaway cluster only)
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

-- a by-reference result that is a null pointer, not a NULL
CREATE FUNCTION hz_upper(t text) RETURNS text LANGUAGE plllvm AS $$
@"upper(text)" = external global i8
declare i64 @plllvm_arg_i64(ptr, i32)
declare i1 @plllvm_arg_isnull(ptr, i32)
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
  %isnull = alloca i1
  %t = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %r = call i64 @plllvm_call1(ptr @"upper(text)", i64 %t, i1 %n, ptr %isnull)
  ret i64 %r
}
$$;
SELECT hz_upper('a');
SELECT hz_upper(NULL);  -- fail

-- without a frame
CREATE FUNCTION hz_zero() RETURNS text LANGUAGE plllvm AS $$
define i64 @f(ptr %fcinfo) {
  ret i64 0
}
$$;
SELECT hz_zero();  -- fail

-- plllvm_free of a NULL column
CREATE TABLE hz_t (i int, s text);
INSERT INTO hz_t VALUES (1, 'one');
CREATE FUNCTION hz_free(i int) RETURNS int LANGUAGE plllvm STRICT STABLE AS $$
@q.sql = private constant [32 x i8] c"SELECT s FROM hz_t WHERE i = $1\00"
@q.args = private constant [5 x i8] c"int4\00"
@q.cols = private constant [5 x i8] c"text\00"
@q = internal global ptr null
%struct.NullableDatum = type { i64, i8 }
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
declare i32 @plllvm_spi_select_into(ptr, ptr, ptr, ptr)
declare i64 @plllvm_arg_i64(ptr, i32)
declare void @plllvm_free(i64)
define i64 @f(ptr %fcinfo) {
  %args = alloca %struct.NullableDatum
  %out = alloca %struct.NullableDatum
  %i = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  store %struct.NullableDatum zeroinitializer, ptr %args
  store i64 %i, ptr %args
  %stmt = call ptr @plllvm_spi_prepare(ptr @q, ptr @q.sql, ptr @q.args, ptr @q.cols)
  %rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stmt, ptr %args, ptr %out)
  %v = load i64, ptr %out
  call void @plllvm_free(i64 %v)
  %r = sext i32 %rows to i64
  ret i64 %r
}
$$;
SELECT hz_free(1), hz_free(2);

--
-- Freed code.  Each row of hz_rb must run the original body: row 1 replaces
-- the function under the running call, calls the new code and rolls the
-- replace back, which makes the old row current again; row 2 compiles
-- hz_g, which frees released code.  The entry of the first call must not
-- match the old row and run its freed code.
--
CREATE FUNCTION hz_g() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;

CREATE FUNCTION hz_undo() RETURNS int8 LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    CREATE OR REPLACE FUNCTION hz_rb(n int4) RETURNS int8 LANGUAGE plllvm
    STRICT AS 'define i64 @f(ptr %fcinfo) { ret i64 2 }';
    RAISE NOTICE 'new code returns %', hz_rb(0);
    RAISE EXCEPTION 'undo';
  EXCEPTION WHEN raise_exception THEN
    NULL;
  END;
  RETURN 0;
END
$$;

CREATE FUNCTION hz_rb(n int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
@"hz_undo()" = external global i8
@"hz_g()" = external global i8
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_call0(ptr, ptr)
define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  switch i32 %n, label %done [ i32 1, label %undo
                               i32 2, label %compile ]
undo:
  call i64 @plllvm_call0(ptr @"hz_undo()", ptr null)
  br label %done
compile:
  call i64 @plllvm_call0(ptr @"hz_g()", ptr null)
  br label %done
done:
  ret i64 1
}
$$;

SELECT i, hz_rb(i) FROM generate_series(1, 3) i;
SELECT * FROM plllvm_function_status('hz_rb(int4)');

--
-- Recursion, with replaces and compiles at the bottom, and a compile in
-- hz_deep(1) after its call returned: no code that a call runs is freed.
-- hz_deep(n) returns hz_deep(n - 1) + 1, and hz_deep(0) what hz_swap()
-- returns.
--
CREATE FUNCTION hz_g2() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION hz_g3() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;

CREATE FUNCTION hz_swap() RETURNS int8 LANGUAGE plpgsql AS $$
DECLARE
  r int8;
BEGIN
  CREATE OR REPLACE FUNCTION hz_deep(n int4) RETURNS int8 LANGUAGE plllvm
  STRICT AS 'define i64 @f(ptr %fcinfo) { ret i64 999 }';
  r := hz_deep(-1);
  CREATE OR REPLACE FUNCTION hz_deep(n int4) RETURNS int8 LANGUAGE plllvm
  STRICT AS 'define i64 @f(ptr %fcinfo) { ret i64 1000 }';
  r := hz_deep(-1) + hz_g2();
  RETURN r;
END
$$;

CREATE FUNCTION hz_deep(n int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
@"hz_deep(integer)" = external global i8
@"hz_swap()" = external global i8
@"hz_g3()" = external global i8
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_call0(ptr, ptr)
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %bottom = icmp eq i32 %n, 0
  br i1 %bottom, label %swap, label %recurse
swap:
  %s = call i64 @plllvm_call0(ptr @"hz_swap()", ptr null)
  ret i64 %s
recurse:
  %m = sub i32 %n, 1
  %m64 = sext i32 %m to i64
  %r = call i64 @plllvm_call1(ptr @"hz_deep(integer)", i64 %m64, i1 false, ptr null)
  %one = icmp eq i32 %n, 1
  br i1 %one, label %compile, label %done
compile:
  %z = call i64 @plllvm_call0(ptr @"hz_g3()", ptr null)
  br label %done
done:
  %r1 = add i64 %r, 1
  ret i64 %r1
}
$$;

SELECT hz_deep(5);
SELECT * FROM plllvm_function_status('hz_deep(int4)');
SELECT hz_deep(5);
SELECT * FROM plllvm_function_status('hz_deep(int4)');

DROP FUNCTION hz_rb(int4), hz_undo(), hz_g(), hz_deep(int4), hz_swap(),
  hz_g2(), hz_g3();
