--
-- The validator: IR errors at CREATE FUNCTION, the signature checks, and
-- check_function_bodies
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;
\pset null '(null)'

-- a parse error points into the CREATE FUNCTION text
CREATE FUNCTION v_parse() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 %nope } $$;

CREATE FUNCTION v_parse() RETURNS int8 LANGUAGE plllvm AS $$
define i64 @f(ptr %fcinfo) {
  %a = bogus i64 1, 2
  ret i64 %a
}
$$;

-- the caret counts characters, not bytes
CREATE FUNCTION v_parse() RETURNS int8 LANGUAGE plllvm AS $$
; vrací přičtenou hodnotu
@s = private constant [3 x i8] c"ž\00" bogus
define i64 @f(ptr %fcinfo) { ret i64 0 }
$$;

-- the checks of the IR, also run before code generation
CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @g(ptr %fcinfo) { ret i64 0 } $$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm
AS $$ define i32 @f(ptr %fcinfo) { ret i32 0 } $$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
declare i64 @plllvm_arg_i32(ptr, i32)
define i64 @f(ptr %fcinfo) {
  %a = call i64 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  ret i64 %a
}
$$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
declare void @plllvm_nope()
define i64 @f(ptr %fcinfo) {
  call void @plllvm_nope()
  ret i64 0
}
$$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
declare void @no_such_function_anywhere()
define i64 @f(ptr %fcinfo) {
  call void @no_such_function_anywhere()
  ret i64 0
}
$$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
define void @plllvm_x() { ret void }
define i64 @f(ptr %fcinfo) { ret i64 0 }
$$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
define void @check_stack_depth() { ret void }
define i64 @f(ptr %fcinfo) { ret i64 0 }
$$;
\echo :LAST_ERROR_SQLSTATE

CREATE FUNCTION v_ir() RETURNS int8 LANGUAGE plllvm AS $$
define i64 @f(ptr %fcinfo) {
a:
  br label %b
c:
  %x = add i64 1, 2
  br label %b
b:
  ret i64 %x
}
$$;
\echo :LAST_ERROR_SQLSTATE

-- each SQL statement has a slot of its own, a global that only
-- plllvm_spi_prepare uses
CREATE FUNCTION v_slot() RETURNS int8 LANGUAGE plllvm STABLE AS $$
@q1 = private constant [9 x i8] c"SELECT 1\00"
@q2 = private constant [9 x i8] c"SELECT 2\00"
@int4 = private constant [5 x i8] c"int4\00"
@none = private constant [1 x i8] c"\00"
@q = internal global ptr null
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %s1 = call ptr @plllvm_spi_prepare(ptr @q, ptr @q1, ptr @none, ptr @int4)
  %s2 = call ptr @plllvm_spi_prepare(ptr @q, ptr @q2, ptr @none, ptr @int4)
  ret i64 0
}
$$;

CREATE FUNCTION v_slot() RETURNS int8 LANGUAGE plllvm STABLE AS $$
@q1 = private constant [9 x i8] c"SELECT 1\00"
@int4 = private constant [5 x i8] c"int4\00"
@none = private constant [1 x i8] c"\00"
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %slot = alloca ptr
  store ptr null, ptr %slot
  %s = call ptr @plllvm_spi_prepare(ptr %slot, ptr @q1, ptr @none, ptr @int4)
  ret i64 0
}
$$;

CREATE FUNCTION v_slot() RETURNS int8 LANGUAGE plllvm STABLE AS $$
@q1 = private constant [9 x i8] c"SELECT 1\00"
@int4 = private constant [5 x i8] c"int4\00"
@none = private constant [1 x i8] c"\00"
@q = internal global ptr null
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %s = call ptr @plllvm_spi_prepare(ptr @q, ptr @q1, ptr @none, ptr @int4)
  store ptr null, ptr @q
  ret i64 0
}
$$;

CREATE FUNCTION v_slot() RETURNS int8 LANGUAGE plllvm STABLE AS $$
@q = internal global ptr null
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %sql = getelementptr i8, ptr %fcinfo, i64 64
  %s = call ptr @plllvm_spi_prepare(ptr @q, ptr %sql, ptr %sql, ptr %sql)
  ret i64 0
}
$$;

CREATE FUNCTION v_slot() RETURNS int8 LANGUAGE plllvm STABLE AS $$
@q = internal global ptr null
@prepare = internal global ptr @plllvm_spi_prepare
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) { ret i64 0 }
$$;

-- what the handler cannot call, also with check_function_bodies = off
CREATE TYPE v_pair AS (a int4, b int4);
CREATE DOMAIN v_posint AS int4 CHECK (VALUE > 0);

CREATE PROCEDURE v_proc() LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_window() RETURNS int8 WINDOW LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_setof() RETURNS SETOF int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_trigger() RETURNS trigger LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_domain() RETURNS v_posint LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_row() RETURNS v_pair LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_out(a int4, OUT b int4) LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_anyarg(a anyelement) RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_rowarg(a v_pair) RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;

SET check_function_bodies = off;

CREATE FUNCTION v_setof() RETURNS SETOF int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;

-- a broken body is found at the first call, and stays not compiled
CREATE FUNCTION v_late() RETURNS int8 LANGUAGE plllvm AS $$
define i64 @f(ptr %fcinfo) {
  ret i64 %nope
}
$$;

RESET check_function_bodies;

SELECT * FROM plllvm_function_status('v_late()');
SELECT v_late();
SELECT * FROM plllvm_function_status('v_late()');

CREATE OR REPLACE FUNCTION v_late() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT * FROM plllvm_function_status('v_late()');
SELECT v_late();
SELECT * FROM plllvm_function_status('v_late()');

-- the strictness is in pg_proc: an ALTER makes the code stale
CREATE FUNCTION v_strict(x int8) RETURNS int8 LANGUAGE plllvm STRICT AS $$
declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i64 @plllvm_arg_i64(ptr, i32)

define i64 @f(ptr %fcinfo) {
entry:
  %isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %isnull, label %null, label %value
null:
  ret i64 -1
value:
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  ret i64 %x
}
$$;

SELECT v_strict(5), v_strict(NULL);
SELECT * FROM plllvm_function_status('v_strict(int8)');

ALTER FUNCTION v_strict(int8) CALLED ON NULL INPUT;
SELECT * FROM plllvm_function_status('v_strict(int8)');
SELECT v_strict(NULL);
SELECT * FROM plllvm_function_status('v_strict(int8)');

-- a constant argument number must be one of the function's
CREATE FUNCTION v_argno(x int8) RETURNS int8 LANGUAGE plllvm AS $$
declare i64 @plllvm_arg_i64(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 1)
  ret i64 %x
}
$$;
CREATE FUNCTION v_argno() RETURNS int8 LANGUAGE plllvm AS $$
declare zeroext i1 @plllvm_arg_isnull(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  ret i64 0
}
$$;
SET check_function_bodies = off;
CREATE FUNCTION v_argno(x int8) RETURNS int8 LANGUAGE plllvm AS $$
declare i64 @plllvm_arg_i64(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 -1)
  ret i64 %x
}
$$;
RESET check_function_bodies;
SELECT v_argno(1);
-- fcinfo->nargs is pronargs: VARIADIC is refused
CREATE FUNCTION v_variadic(VARIADIC "any") RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
CREATE FUNCTION v_variadic(VARIADIC int[]) RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;

DROP FUNCTION v_late();
DROP FUNCTION v_strict(int8);
DROP FUNCTION v_argno(int8);
DROP TYPE v_pair;
DROP DOMAIN v_posint;
