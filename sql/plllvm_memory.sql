--
-- Replaced code is freed: what a replace costs, and the cap
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
SELECT mem_f();

-- the bytes of plllvm's own memory contexts
CREATE FUNCTION mem_plllvm_bytes() RETURNS int8 LANGUAGE sql AS $$
  SELECT sum(total_bytes)::int8 FROM pg_backend_memory_contexts
   WHERE name LIKE 'plllvm - %' OR name LIKE 'PL/LLVM %'
$$;

SELECT compiles AS compiles0, mem_plllvm_bytes() AS ctx0,
       rss_bytes IS NOT NULL AS have_rss, rss_bytes AS rss0
  FROM plllvm_session_info() \gset

DO $$
BEGIN
  FOR i IN 1..500 LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm AS %L',
                   format('define i64 @f(ptr %%fcinfo) { ret i64 %s }', i));
    PERFORM mem_f();
  END LOOP;
END
$$;

SELECT compiles - :compiles0 AS compiles, mem_plllvm_bytes() = :ctx0 AS flat
  FROM plllvm_session_info();

-- the code itself lies outside the contexts, so where rss_bytes is known
-- (macOS) it is bounded too; the output is the same where it is not.  A
-- threshold for the test only, not a measurement.
\if :have_rss
SELECT (rss_bytes - :rss0) / 500 < 262144 AS bounded
  FROM plllvm_session_info() \gset
\if :bounded
\else
\echo 'the RSS grew by 256 kB or more per replace'
\endif
\endif
SELECT mem_f();
SELECT * FROM plllvm_function_status('mem_f()');

-- replaced code frees its call sites and constants
CREATE FUNCTION mem_ctx(name text) RETURNS TABLE(n int8, bytes int8)
LANGUAGE sql AS $$
  SELECT count(*), coalesce(sum(total_bytes), 0)
    FROM pg_backend_memory_contexts WHERE pg_backend_memory_contexts.name = $1
$$;

DO $$
DECLARE
  ir CONSTANT text := '
@"int4pl(integer,integer)" = external global i8
@"int4mi(integer,integer)" = external global i8
@"''1''::integer" = external global i8
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
declare i64 @plllvm_const(ptr)
define i64 @f(ptr %fcinfo) {
  %one = call i64 @plllvm_const(ptr @"''1''::integer")
  %a = call i64 @plllvm_call2(ptr @"int4pl(integer,integer)", i64 @@, i1 false, i64 %one, i1 false, ptr null)
  %b = call i64 @plllvm_call2(ptr @"int4mi(integer,integer)", i64 %a, i1 false, i64 1, i1 false, ptr null)
  ret i64 %b
}';
BEGIN
  FOR i IN 1..100 LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION mem_s() RETURNS int LANGUAGE plllvm AS %L',
                   replace(ir, '@@', i::text));
    PERFORM mem_s();
  END LOOP;
END
$$;

SELECT mem_s();
SELECT n AS sites FROM mem_ctx('PL/LLVM call site');
SELECT n AS data FROM mem_ctx('PL/LLVM module data');

-- replaced code frees its statements
CREATE TABLE mem_t (i int);
INSERT INTO mem_t VALUES (1);

CREATE FUNCTION mem_q_ir(k int) RETURNS text LANGUAGE sql AS $f$
SELECT format($ir$
@q.sql = private constant [20 x i8] c"SELECT i FROM mem_t\00"
@q.args = private constant [1 x i8] zeroinitializer
@q.cols = private constant [5 x i8] c"int4\00"
@q = internal global ptr null
%%struct.NullableDatum = type { i64, i8 }
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
declare i32 @plllvm_spi_select_into(ptr, ptr, ptr, ptr)
define i64 @f(ptr %%fcinfo) {
  %%out = alloca %%struct.NullableDatum
  %%stmt = call ptr @plllvm_spi_prepare(ptr @q, ptr @q.sql, ptr @q.args, ptr @q.cols)
  %%rows = call i32 @plllvm_spi_select_into(ptr %%fcinfo, ptr %%stmt, ptr null, ptr %%out)
  %%v = load i64, ptr %%out
  %%r = add i64 %%v, %s
  ret i64 %%r
}$ir$, k)
$f$;

DO $$
BEGIN
  FOR i IN 1..10 LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION mem_q() RETURNS int8 LANGUAGE plllvm AS %L',
                   mem_q_ir(i));
    PERFORM mem_q();
  END LOOP;
END
$$;
SELECT bytes AS spi0, spi_statements AS st0
  FROM mem_ctx('plllvm - spi context'), plllvm_session_info() \gset

DO $$
BEGIN
  FOR i IN 1..500 LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION mem_q() RETURNS int8 LANGUAGE plllvm AS %L',
                   mem_q_ir(i));
    PERFORM mem_q();
  END LOOP;
END
$$;
SELECT mem_q();
SELECT bytes = :spi0 AS flat, spi_statements - :st0 AS prepared
  FROM mem_ctx('plllvm - spi context'), plllvm_session_info();

-- the cap counts resident code only: the code of live functions
SELECT compiles - retired + 1 AS cap FROM plllvm_session_info() \gset
SET plllvm.max_resident_compiles = :cap;

CREATE FUNCTION mem_c1() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT mem_c1();

CREATE FUNCTION mem_c2() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 2 } $$;
SELECT mem_c2();
\echo :LAST_ERROR_SQLSTATE
SELECT * FROM plllvm_function_status('mem_c2()');

CREATE OR REPLACE FUNCTION mem_c1() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 -1 } $$;
SELECT mem_c1();
SELECT * FROM plllvm_function_status('mem_c1()');

RESET plllvm.max_resident_compiles;
SELECT mem_c2();
SELECT * FROM plllvm_function_status('mem_c2()');

DROP FUNCTION mem_f(), mem_plllvm_bytes(), mem_s(), mem_q(), mem_q_ir(int), mem_ctx(text),
  mem_c1(), mem_c2();
DROP TABLE mem_t;
