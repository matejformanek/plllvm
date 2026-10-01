--
-- An LLVM fatal error ends only the session that hit it
--
LOAD 'plllvm';
CREATE EXTENSION dblink;

-- a crash restart would get a new checkpointer, plllvm_teardown compares
CREATE TABLE plllvm_fatal_mark AS
  SELECT pid AS ckpt_pid FROM pg_stat_activity
   WHERE backend_type = 'checkpointer';

SELECT pg_postmaster_start_time() AS start_time \gset

-- a connection made by the server does not see pg_regress's PGHOST/PGPORT
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset

-- run q in a second session with plllvm.debug_inject set; the first line
-- of the error, the rest is libpq's report of the lost connection
CREATE FUNCTION compile_injected(conn text, kind text, q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM * FROM dblink(conn, format($q$
    LOAD 'plllvm';
    SET plllvm.debug_inject = %L;
    %s
  $q$, kind, q)) AS t(r text);
  RETURN 'no error';
EXCEPTION WHEN OTHERS THEN
  RETURN split_part(SQLERRM, E'\n', 1);
END
$$;

SELECT compile_injected(:'conn', 'llvm_fatal',
  $$SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }')$$);
SELECT compile_injected(:'conn', 'bad_alloc',
  $$SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }')$$);

-- the same in the compile of the call handler
CREATE FUNCTION fatal_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
SELECT compile_injected(:'conn', 'llvm_fatal', 'SELECT fatal_f()');

-- neither the server nor this session went down
SELECT pg_postmaster_start_time() = :'start_time' AS no_restart;
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }');

DROP FUNCTION fatal_f();
DROP FUNCTION compile_injected(text, text, text);
DROP EXTENSION dblink;
