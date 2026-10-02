--
-- Replacing and dropping PL/LLVM functions: retired code, stale entries,
-- replaces during a call
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

-- every replace compiles anew and retires the old code
CREATE FUNCTION lc_cyc() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT lc_cyc();
CREATE OR REPLACE FUNCTION lc_cyc() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 2 } $$;
SELECT lc_cyc();
CREATE OR REPLACE FUNCTION lc_cyc() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 3 } $$;
SELECT lc_cyc();
CREATE OR REPLACE FUNCTION lc_cyc() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 4 } $$;
SELECT lc_cyc();

SELECT * FROM plllvm_function_status('lc_cyc()');
SELECT count(DISTINCT symbol) AS symbols, count(*) FILTER (WHERE retired) AS retired
  FROM plllvm_code_cache() WHERE owner_oid = 'lc_cyc()'::regprocedure;

-- a rolled back replace leaves a stale entry; the next call recompiles
CREATE FUNCTION lc_tx() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT lc_tx();

BEGIN;
CREATE OR REPLACE FUNCTION lc_tx() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 2 } $$;
SELECT lc_tx();
ROLLBACK;

SELECT * FROM plllvm_function_status('lc_tx()');
SELECT lc_tx();
SELECT * FROM plllvm_function_status('lc_tx()');

BEGIN;
SAVEPOINT s;
CREATE OR REPLACE FUNCTION lc_tx() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 2 } $$;
SELECT lc_tx();
ROLLBACK TO s;
SELECT * FROM plllvm_function_status('lc_tx()');
SELECT lc_tx();
COMMIT;
SELECT * FROM plllvm_function_status('lc_tx()');

-- DROP
SELECT 'lc_tx()'::regprocedure::oid AS oid \gset
DROP FUNCTION lc_tx();
SELECT * FROM plllvm_function_status(:'oid');

-- another language in between keeps its own cache entry
CREATE FUNCTION lc_lang() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT lc_lang();
CREATE OR REPLACE FUNCTION lc_lang() RETURNS int8 LANGUAGE plpgsql
AS $$ BEGIN RETURN 2; END $$;
SELECT lc_lang();
SELECT * FROM plllvm_function_status('lc_lang()');
CREATE OR REPLACE FUNCTION lc_lang() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 3 } $$;
SELECT lc_lang();
SELECT * FROM plllvm_function_status('lc_lang()');

-- a failed recompile under a prepared statement
CREATE FUNCTION lc_prep() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
PREPARE lc_p AS SELECT lc_prep();
EXECUTE lc_p;

SET check_function_bodies = off;
CREATE OR REPLACE FUNCTION lc_prep() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @g(ptr %fcinfo) { ret i64 0 } $$;
RESET check_function_bodies;

EXECUTE lc_p;
SELECT * FROM plllvm_function_status('lc_prep()');

CREATE OR REPLACE FUNCTION lc_prep() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 2 } $$;
EXECUTE lc_p;
SELECT * FROM plllvm_function_status('lc_prep()');
DEALLOCATE lc_p;

--
-- Replaces while the function runs.  lc_rec(1) runs SQL through SPI, the
-- SQL replaces lc_rec and calls the new code; the running code finishes,
-- and retires itself when it returns.
--
CREATE FUNCTION lc_rec(n int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)
declare i32 @SPI_connect()
declare i32 @SPI_exec(ptr, i64)
declare i32 @SPI_finish()

@q = private constant [29 x i8] c"SELECT lc_replace_and_call()\00"

define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %spi = icmp eq i32 %n, 1
  br i1 %spi, label %reenter, label %done
reenter:
  call i32 @SPI_connect()
  call i32 @SPI_exec(ptr @q, i64 0)
  call i32 @SPI_finish()
  br label %done
done:
  ret i64 1
}
$$;

CREATE FUNCTION lc_replace_and_call() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  CREATE OR REPLACE FUNCTION lc_rec(n int4) RETURNS int8 LANGUAGE plllvm STRICT
  AS 'define i64 @f(ptr %fcinfo) { ret i64 2 }';
  RAISE NOTICE 'new code returns %', lc_rec(0);
END
$$;

SELECT lc_rec(1);
SELECT * FROM plllvm_function_status('lc_rec(int4)');

-- the same, with the replace rolled back
CREATE FUNCTION lc_rec2(n int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)
declare i32 @SPI_connect()
declare i32 @SPI_exec(ptr, i64)
declare i32 @SPI_finish()

@q = private constant [29 x i8] c"SELECT lc_replace_and_undo()\00"

define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %spi = icmp eq i32 %n, 1
  br i1 %spi, label %reenter, label %done
reenter:
  call i32 @SPI_connect()
  call i32 @SPI_exec(ptr @q, i64 0)
  call i32 @SPI_finish()
  br label %done
done:
  ret i64 1
}
$$;

CREATE FUNCTION lc_replace_and_undo() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  CREATE OR REPLACE FUNCTION lc_rec2(n int4) RETURNS int8 LANGUAGE plllvm STRICT
  AS 'define i64 @f(ptr %fcinfo) { ret i64 2 }';
  RAISE NOTICE 'new code returns %', lc_rec2(0);
  RAISE EXCEPTION 'undo';
EXCEPTION WHEN raise_exception THEN
  NULL;
END
$$;

SELECT lc_rec2(1);
SELECT * FROM plllvm_function_status('lc_rec2(int4)');
SELECT lc_rec2(0);
SELECT * FROM plllvm_function_status('lc_rec2(int4)');

-- replaced through SPI but not called: the next row recompiles the entry
-- of the same call site in place
CREATE FUNCTION lc_f(n int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)
declare i32 @SPI_connect()
declare i32 @SPI_exec(ptr, i64)
declare i32 @SPI_finish()

@q = private constant [20 x i8] c"SELECT lc_replace()\00"

define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %spi = icmp eq i32 %n, 1
  br i1 %spi, label %reenter, label %done
reenter:
  call i32 @SPI_connect()
  call i32 @SPI_exec(ptr @q, i64 0)
  call i32 @SPI_finish()
  br label %done
done:
  ret i64 1
}
$$;

CREATE FUNCTION lc_replace() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  CREATE OR REPLACE FUNCTION lc_f(n int4) RETURNS int8 LANGUAGE plllvm STRICT
  AS 'define i64 @f(ptr %fcinfo) { ret i64 2 }';
END
$$;

SELECT lc_f(i) FROM generate_series(1, 3) i;
SELECT * FROM plllvm_function_status('lc_f(int4)');

-- replaced through SPI and the new code called there: funccache forgets
-- the entry of the running call, and the next row of the same call site
-- uses the new entry instead of compiling next to it
CREATE FUNCTION lc_dup_body(r int) RETURNS void LANGUAGE plpgsql AS $q$
BEGIN
  EXECUTE format('CREATE OR REPLACE FUNCTION lc_dup(n int4) RETURNS int8
    LANGUAGE plllvm STRICT AS %L', $ir$
declare i32 @plllvm_arg_i32(ptr, i32)
declare i32 @SPI_connect()
declare i32 @SPI_exec(ptr, i64)
declare i32 @SPI_finish()

@q = private constant [33 x i8] c"SELECT lc_dup_body(2), lc_dup(0)\00"

define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %spi = icmp eq i32 %n, 1
  br i1 %spi, label %reenter, label %done
reenter:
  call i32 @SPI_connect()
  call i32 @SPI_exec(ptr @q, i64 0)
  call i32 @SPI_finish()
  br label %done
done:
  ret i64 $ir$ || r || E'\n}');
END
$q$;

SELECT lc_dup_body(1);
SELECT n, lc_dup(n) FROM (VALUES (1), (0), (1), (0)) v(n);
SELECT * FROM plllvm_function_status('lc_dup(int4)');

-- a function that drops itself while it runs: its code is retired in the
-- next transaction
CREATE FUNCTION lc_dropper() RETURNS int8 LANGUAGE plpgsql AS $$
BEGIN
  DROP FUNCTION lc_drop_self();
  RETURN 1;
END
$$;

CREATE FUNCTION lc_drop_self() RETURNS int8 LANGUAGE plllvm AS $$
@"lc_dropper()" = external global i8
declare i64 @plllvm_call0(ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %r = call i64 @plllvm_call0(ptr @"lc_dropper()", ptr null)
  ret i64 %r
}
$$;

SELECT 'lc_drop_self()'::regprocedure::oid AS oid \gset
SELECT lc_drop_self();
SELECT * FROM plllvm_function_status(:'oid');

-- not while the DROP may still roll back
CREATE FUNCTION lc_rb() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;
SELECT lc_rb();
SELECT 'lc_rb()'::regprocedure::oid AS oid \gset
BEGIN;
DROP FUNCTION lc_rb();
SELECT * FROM plllvm_function_status(:'oid');
ROLLBACK;
SELECT * FROM plllvm_function_status(:'oid');
SELECT lc_rb();

DROP FUNCTION lc_cyc(), lc_lang(), lc_prep(), lc_rec(int4), lc_rec2(int4),
  lc_f(int4), lc_dup(int4), lc_rb(), lc_dropper();
DROP FUNCTION lc_replace_and_call(), lc_replace_and_undo(), lc_replace(),
  lc_dup_body(int);
