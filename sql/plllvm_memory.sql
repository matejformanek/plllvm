--
-- Compiled code is never freed: what a replace costs, and the cap
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
SELECT mem_f();

SELECT compiles AS compiles0, rss_bytes AS rss0 FROM plllvm_session_info() \gset

DO $$
BEGIN
  FOR i IN 1..500 LOOP
    EXECUTE format('CREATE OR REPLACE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm AS %L',
                   format('define i64 @f(ptr %%fcinfo) { ret i64 %s }', i));
    PERFORM mem_f();
  END LOOP;
END
$$;

-- a threshold for the test only, not a measurement
SELECT compiles - :compiles0 AS compiles,
       (rss_bytes - :rss0) / 500 < 262144 AS bounded
  FROM plllvm_session_info();
SELECT mem_f();
SELECT * FROM plllvm_function_status('mem_f()');

-- replaced code releases its call sites
SELECT rss_bytes AS rss1 FROM plllvm_session_info() \gset

DO $$
DECLARE
  ir CONSTANT text := '
@"int4pl(integer,integer)" = external global i8
@"int4mi(integer,integer)" = external global i8
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
  %a = call i64 @plllvm_call2(ptr @"int4pl(integer,integer)", i64 @@, i1 false, i64 1, i1 false, ptr null)
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

SELECT mem_s(), (rss_bytes - :rss1) / 100 < 262144 AS bounded
  FROM plllvm_session_info();
SELECT count(*) AS sites FROM pg_backend_memory_contexts
  WHERE name = 'PL/LLVM call site';

-- the cap counts retired code too
SELECT compiles + 1 AS cap FROM plllvm_session_info() \gset
SET plllvm.max_resident_compiles = :cap;

CREATE OR REPLACE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 -1 } $$;
SELECT mem_f();

CREATE OR REPLACE FUNCTION mem_f() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 -2 } $$;
SELECT mem_f();
\echo :LAST_ERROR_SQLSTATE
SELECT * FROM plllvm_function_status('mem_f()');

RESET plllvm.max_resident_compiles;
SELECT mem_f();
SELECT * FROM plllvm_function_status('mem_f()');

DROP FUNCTION mem_f(), mem_s();
