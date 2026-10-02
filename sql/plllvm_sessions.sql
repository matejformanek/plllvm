--
-- Another session changes what this session has compiled or bound
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;
CREATE EXTENSION dblink;

-- a connection made by the server does not see pg_regress's PGHOST/PGPORT
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset
SELECT dblink_connect('other', :'conn');

-- 1. a function compiled here, replaced and dropped there
CREATE FUNCTION ss_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT ss_f();
SELECT 'ss_f()'::regprocedure::oid AS ss_f_oid \gset

SELECT dblink_exec('other', $$CREATE OR REPLACE FUNCTION ss_f() RETURNS int8
  LANGUAGE plllvm AS 'define i64 @f(ptr %fcinfo) { ret i64 2 }'$$);
SELECT * FROM plllvm_function_status('ss_f()');
SELECT ss_f();
SELECT * FROM plllvm_function_status('ss_f()');

SELECT dblink_exec('other', 'DROP FUNCTION ss_f()');
SELECT * FROM plllvm_function_status(:'ss_f_oid');
SELECT ss_f();  -- fail

-- 2. a call site bound here, its callee changed there
CREATE FUNCTION ss_g(x int) RETURNS int LANGUAGE sql AS 'SELECT x + 1';

-- ss_c(x) returns ss_g(x), NULL as NULL
CREATE FUNCTION ss_c(x int) RETURNS int LANGUAGE plllvm AS $$
@"ss_g(integer)" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_arg_i64(ptr, i32)
declare i1 @plllvm_arg_isnull(ptr, i32)
declare i64 @plllvm_return_null(ptr)

define i64 @f(ptr %fcinfo) {
  %isnull = alloca i1
  %a = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %n = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  %r = call i64 @plllvm_call1(ptr @"ss_g(integer)", i64 %a, i1 %n, ptr %isnull)
  %rn = load i1, ptr %isnull
  br i1 %rn, label %null, label %ok
ok:
  ret i64 %r
null:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z
}
$$;
SELECT ss_c(1), ss_c(NULL) IS NULL AS null_result;

-- (a) replaced, also in another language
SELECT dblink_exec('other',
  $$CREATE OR REPLACE FUNCTION ss_g(x int) RETURNS int LANGUAGE sql AS 'SELECT x + 2'$$);
SELECT ss_c(1);
SELECT dblink_exec('other',
  $$CREATE OR REPLACE FUNCTION ss_g(x int) RETURNS int LANGUAGE plpgsql
    AS 'BEGIN RETURN coalesce(x, 0) + 3; END'$$);
SELECT ss_c(1), ss_c(NULL);

-- (b) altered: made strict
SELECT dblink_exec('other', 'ALTER FUNCTION ss_g(int) STRICT');
SELECT ss_c(1), ss_c(NULL) IS NULL AS null_result;

-- (c) EXECUTE revoked and granted again
CREATE ROLE regress_plllvm_sess;
SELECT dblink_exec('other', 'REVOKE EXECUTE ON FUNCTION ss_g(int) FROM PUBLIC');
SET ROLE regress_plllvm_sess;
SELECT ss_c(1);  -- fail
RESET ROLE;
SELECT dblink_exec('other', 'GRANT EXECUTE ON FUNCTION ss_g(int) TO PUBLIC');
SET ROLE regress_plllvm_sess;
SELECT ss_c(1);
RESET ROLE;

-- (d) dropped, then created again
SELECT dblink_exec('other', 'DROP FUNCTION ss_g(int)');
SELECT ss_c(1);  -- fail
SELECT dblink_exec('other',
  $$CREATE FUNCTION ss_g(x int) RETURNS int LANGUAGE sql AS 'SELECT -x'$$);
SELECT ss_c(1);

-- 3. the other session calls the same functions with its own code
SELECT * FROM dblink('other', 'SELECT ss_c(5)') AS t(r int);

SELECT dblink_disconnect('other');
DROP FUNCTION ss_c(int), ss_g(int);
DROP ROLE regress_plllvm_sess;
DROP EXTENSION dblink;
