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

DROP FUNCTION v_late();
DROP FUNCTION v_strict(int8);
DROP TYPE v_pair;
DROP DOMAIN v_posint;
