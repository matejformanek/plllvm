--
-- Read-only SQL statements (plllvm_spi_prepare, plllvm_spi_select_into)
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE TABLE spi_t (i int PRIMARY KEY, s text, n numeric);
INSERT INTO spi_t VALUES (1, 'one', 1.5), (2, 'two', NULL), (3, NULL, 3);

-- fn runs q with its arguments and returns column 1 of the first row, NULL
-- without one, or with ret = 'rows' the number of rows.  reset resets the
-- scratch after the statement, wrap passes the value through a call site.
CREATE FUNCTION mk_spi(fn text, q text, argtypes text, coltypes text,
                       ret text DEFAULT 'value', reset bool DEFAULT false,
                       wrap text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $mk$
DECLARE
  ir text := '';
BEGIN
  SELECT string_agg(format(E'@%s = private constant [%s x i8] c"%s\\00"\n',
                           name, octet_length(val) + 1,
                           replace(replace(val, '\', '\5C'), '"', '\22')), '')
    INTO ir
    FROM (VALUES ('q.sql', q), ('q.args', argtypes), ('q.cols', coltypes)) v(name, val);
  IF wrap IS NOT NULL THEN
    ir := ir || '@"' || wrap || E'" = external global i8\n'
             || E'declare i64 @plllvm_call1(ptr, i64, i1, ptr)\n';
  END IF;
  ir := ir || $ir$@q = internal global ptr null
%struct.NullableDatum = type { i64, i8 }
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
declare i32 @plllvm_spi_select_into(ptr, ptr, ptr, ptr)
declare i32 @plllvm_nargs(ptr)
declare i64 @plllvm_arg_i64(ptr, i32)
declare i1 @plllvm_arg_isnull(ptr, i32)
declare i64 @plllvm_return_null(ptr)
declare void @plllvm_scratch_reset()
define i64 @f(ptr %fcinfo) {
entry:
  %args = alloca [100 x %struct.NullableDatum]
  %out = alloca [4 x %struct.NullableDatum]
  %n = call i32 @plllvm_nargs(ptr %fcinfo)
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %arg ]
  %more = icmp slt i32 %i, %n
  br i1 %more, label %arg, label %run
arg:
  %v = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 %i)
  %vn = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 %i)
  %p = getelementptr %struct.NullableDatum, ptr %args, i32 %i
  store i64 %v, ptr %p
  %pn = getelementptr %struct.NullableDatum, ptr %p, i32 0, i32 1
  %vn8 = zext i1 %vn to i8
  store i8 %vn8, ptr %pn
  %i.next = add i32 %i, 1
  br label %loop
run:
  %stmt = call ptr @plllvm_spi_prepare(ptr @q, ptr @q.sql, ptr @q.args, ptr @q.cols)
  %rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stmt, ptr %args, ptr %out)
$ir$;
  IF reset THEN
    ir := ir || E'  call void @plllvm_scratch_reset()\n';
  END IF;
  IF ret = 'rows' THEN
    ir := ir || E'  %r = sext i32 %rows to i64\n  ret i64 %r\n}\n';
  ELSE
    ir := ir || $ir$  %on = getelementptr %struct.NullableDatum, ptr %out, i32 0, i32 1
  %on8 = load i8, ptr %on
  %isnull = icmp ne i8 %on8, 0
  br i1 %isnull, label %null, label %value
null:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z
value:
  %r = load i64, ptr %out
$ir$ || CASE WHEN wrap IS NULL THEN E'  ret i64 %r\n}\n'
        ELSE '  %w = call i64 @plllvm_call1(ptr @"' || wrap
             || E'", i64 %r, i1 false, ptr null)\n  ret i64 %w\n}\n' END;
  END IF;
  EXECUTE format('CREATE OR REPLACE FUNCTION %s LANGUAGE plllvm AS %L', fn, ir);
END
$mk$;

CREATE FUNCTION sqlstate_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END
$$;

-- 1. SPI is connected only for a body that declares a plllvm_spi_ function
CREATE FUNCTION spi_probe0() RETURNS int LANGUAGE plllvm AS $$
@sql = private constant [9 x i8] c"SELECT 1\00"
declare i32 @SPI_execute(ptr, i1, i64)
define i64 @f(ptr %fcinfo) {
  %rc = call i32 @SPI_execute(ptr @sql, i1 true, i64 1)
  %r = sext i32 %rc to i64
  ret i64 %r
}
$$;
CREATE FUNCTION spi_probe1() RETURNS int LANGUAGE plllvm AS $$
@sql = private constant [9 x i8] c"SELECT 1\00"
declare i32 @SPI_execute(ptr, i1, i64)
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
define i64 @f(ptr %fcinfo) {
  %rc = call i32 @SPI_execute(ptr @sql, i1 true, i64 1)
  %r = sext i32 %rc to i64
  ret i64 %r
}
$$;
SELECT spi_probe0() AS unconnected, spi_probe1() AS select;
SELECT owner_oid, frame FROM plllvm_code_cache()
 WHERE owner_oid IN ('spi_probe0()'::regprocedure, 'spi_probe1()'::regprocedure)
 ORDER BY 1;

-- 2. select_into
SELECT spi_statements AS st0 FROM plllvm_session_info() \gset
SELECT mk_spi('spi_s(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text');
SELECT mk_spi('spi_n(i int) RETURNS numeric STABLE',
              'SELECT n FROM spi_t WHERE i = $1', 'int4', 'numeric');
SELECT mk_spi('spi_i2(i int) RETURNS int STABLE',
              'SELECT i * 2 FROM spi_t WHERE i = $1', 'int4', 'int4');
SELECT mk_spi('spi_rows(i int) RETURNS int STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text', ret => 'rows');
SELECT mk_spi('spi_isnull(i int) RETURNS bool STABLE',
              'SELECT $1 IS NULL', 'int4', 'bool');
SELECT i, spi_s(i), spi_n(i), spi_i2(i), spi_rows(i)
  FROM (VALUES (1), (2), (3), (4)) v(i);
SELECT spi_isnull(1) AS one, spi_isnull(NULL) AS null;

-- 3. by-reference results under the clobber of freed memory: SPI only, with
-- a call site, and with a scratch reset after the statement
SELECT length(string_agg(spi_s(i % 3 + 1), '')) FROM generate_series(1, 2000) i;
SELECT mk_spi('spi_up(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text',
              wrap => 'upper(text)');
SELECT bool_and(spi_up(i % 2 + 1) = CASE i % 2 WHEN 0 THEN 'ONE' ELSE 'TWO' END)
  FROM generate_series(1, 2000) i;
SELECT mk_spi('spi_s_reset(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text', reset => true);
SELECT bool_and(spi_s_reset(1) = 'one') FROM generate_series(1, 2000) i;

-- 4. a statement is prepared once per compile
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
SELECT spi_statements AS st0 FROM plllvm_session_info() \gset
SELECT mk_spi('spi_once(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text');
SELECT spi_once(1), spi_once(2), spi_once(3);
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
SELECT mk_spi('spi_once2(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text');
SELECT spi_once2(1);
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
SELECT mk_spi('spi_once(i int) RETURNS text STABLE',
              'SELECT s FROM spi_t WHERE i = $1', 'int4', 'text');
SELECT spi_once(1);
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
DISCARD PLANS;
SELECT spi_once(1);
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();

-- 5. the saved plan revalidates; a result of another type is refused
SELECT compiles AS c0 FROM plllvm_session_info() \gset
ALTER TABLE spi_t ADD COLUMN x int;
SELECT spi_s(1);
ALTER TABLE spi_t ALTER COLUMN s TYPE varchar;
SELECT spi_s(1);  -- fail
ALTER TABLE spi_t ALTER COLUMN s TYPE text;
SELECT spi_s(1);
CREATE TABLE spi_t_save AS SELECT i, s, n FROM spi_t;
DROP TABLE spi_t;
SELECT spi_s(1);  -- fail
CREATE TABLE spi_t (i int PRIMARY KEY, s text, n numeric);
INSERT INTO spi_t SELECT * FROM spi_t_save;
DROP TABLE spi_t_save;
SELECT spi_s(1);
SELECT compiles - :c0 AS recompiled FROM plllvm_session_info();

-- 6. read-only unless VOLATILE, as PL/pgSQL
CREATE TABLE spi_v (c int8);
SELECT mk_spi('spi_cnt_stab() RETURNS int8 STABLE',
              'SELECT count(*) FROM spi_v', '', 'int8');
SELECT mk_spi('spi_cnt_vol() RETURNS int8 VOLATILE',
              'SELECT count(*) FROM spi_v', '', 'int8');
CREATE FUNCTION pl_cnt_stab() RETURNS int8 LANGUAGE plpgsql STABLE
AS $$ BEGIN RETURN (SELECT count(*) FROM spi_v); END $$;
CREATE FUNCTION pl_cnt_vol() RETURNS int8 LANGUAGE plpgsql VOLATILE
AS $$ BEGIN RETURN (SELECT count(*) FROM spi_v); END $$;
CREATE FUNCTION seen(f text) RETURNS int8[] LANGUAGE plpgsql AS $$
DECLARE
  r int8[];
BEGIN
  TRUNCATE spi_v;
  EXECUTE format('INSERT INTO spi_v SELECT %s() FROM generate_series(1, 3)', f);
  SELECT array_agg(c ORDER BY c) INTO r FROM spi_v;
  RETURN r;
END
$$;
SELECT seen('spi_cnt_stab') AS ll_stable, seen('pl_cnt_stab') AS pl_stable,
       seen('spi_cnt_vol') AS ll_volatile, seen('pl_cnt_vol') AS pl_volatile;
-- recompiled
ALTER FUNCTION spi_cnt_stab() VOLATILE;
SELECT seen('spi_cnt_stab') AS ll_altered;

-- 7. one plain SELECT, also in VOLATILE functions
SELECT mk_spi('spi_bad() RETURNS int VOLATILE',
              'INSERT INTO spi_v VALUES (1) RETURNING 1', '', 'int4');
SELECT spi_bad();  -- fail
SELECT mk_spi('spi_bad() RETURNS int VOLATILE',
              'SELECT i FROM spi_t WHERE i = 1 FOR UPDATE', '', 'int4');
SELECT spi_bad();  -- fail
SELECT mk_spi('spi_bad() RETURNS int VOLATILE',
              'WITH d AS (DELETE FROM spi_v RETURNING 1) SELECT 1', '', 'int4');
SELECT spi_bad();  -- fail
SELECT mk_spi('spi_bad() RETURNS int VOLATILE',
              'SELECT 1; SELECT 2', '', 'int4');
SELECT spi_bad();  -- fail
-- below the top level, only SPI's read-only check applies
SELECT mk_spi('spi_sub() RETURNS int VOLATILE',
              'SELECT i FROM (SELECT i FROM spi_t WHERE i = 1 FOR UPDATE) s', '', 'int4');
SELECT spi_sub();
SELECT mk_spi('spi_sub() RETURNS int STABLE',
              'SELECT i FROM (SELECT i FROM spi_t WHERE i = 1 FOR UPDATE) s', '', 'int4');
SELECT spi_sub();  -- fail
-- no typmods: they would not be applied
SELECT mk_spi('spi_types(a numeric, b int) RETURNS numeric STABLE',
              'SELECT $1 + $2', 'numeric(5,2), int4', 'numeric');
SELECT spi_types(1.25, 2);  -- fail
SELECT mk_spi('spi_types(a numeric, b int) RETURNS numeric STABLE',
              'SELECT $1 + $2', 'numeric, int4', 'varchar(3)');
SELECT spi_types(1.25, 2);  -- fail
SELECT mk_spi('spi_types(a numeric, b int) RETURNS numeric STABLE',
              'SELECT $1::numeric(5,2) + $2', 'numeric, int4', 'numeric');
SELECT spi_types(1.255, 2);
SELECT mk_spi('spi_bad() RETURNS int STABLE', 'SELECT 1', '', 'nosuchtype');
SELECT spi_bad();  -- fail
SELECT mk_spi('spi_bad(a int) RETURNS int STABLE', 'SELECT $1', 'int4, numeric(5,2', 'int4');
SELECT spi_bad(1);  -- fail
SELECT mk_spi('spi_bad(a int) RETURNS int STABLE', 'SELECT $2', 'int4', 'int4');
SELECT spi_bad(1);  -- fail
SELECT mk_spi('spi_bad() RETURNS int STABLE', 'SELECT 1, 2', '', 'int4');
SELECT spi_bad();  -- fail

-- 8. errors
SELECT mk_spi('spi_div(a int) RETURNS int STABLE', 'SELECT 1 / $1', 'int4', 'int4');
SELECT spi_div(0);  -- fail
SELECT spi_statements AS st0 FROM plllvm_session_info() \gset
SELECT mk_spi('spi_syntax() RETURNS int STABLE', 'SELEC 1', '', 'int4');
SELECT spi_syntax();  -- fail
SELECT spi_syntax();  -- fail
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
-- an ERROR leaves no SPI level and no pin behind
DO $$
DECLARE
  n int := 0;
BEGIN
  FOR k IN 1..50 LOOP
    BEGIN
      PERFORM spi_div(0);
    EXCEPTION WHEN division_by_zero THEN
      n := n + 1;
    END;
  END LOOP;
  RAISE NOTICE 'caught %', n;
END
$$;
SELECT retired AS r0 FROM plllvm_session_info() \gset
SELECT mk_spi('spi_div(a int) RETURNS int STABLE', 'SELECT 2 / $1', 'int4', 'int4');
SELECT spi_div(1);
SELECT retired - :r0 AS retired FROM plllvm_session_info();

-- 9. nesting: one saved plan in recursion, and through PL/pgSQL
SELECT spi_statements AS st0 FROM plllvm_session_info() \gset
SELECT mk_spi('fib_spi(n int) RETURNS int STABLE',
              'SELECT CASE WHEN $1 < 2 THEN $1 ELSE fib_spi($1 - 1) + fib_spi($1 - 2) END',
              'int4', 'int4');
SELECT fib_spi(12);
SELECT spi_statements - :st0 AS prepared FROM plllvm_session_info();
CREATE FUNCTION pl_mid(i int) RETURNS text LANGUAGE plpgsql STABLE AS $$
DECLARE
  r text;
BEGIN
  SELECT spi_s(i) INTO r;
  RETURN r;
END
$$;
SELECT mk_spi('spi_outer(i int) RETURNS text STABLE',
              'SELECT pl_mid($1)', 'int4', 'text');
SELECT spi_outer(1), spi_outer(3) IS NULL AS null;
SET max_stack_depth = '100kB';
SELECT sqlstate_of('SELECT fib_spi(100000)');
RESET max_stack_depth;
SELECT fib_spi(5);

-- 10. cancel
SELECT mk_spi('spi_sleep() RETURNS int VOLATILE',
              'SELECT 1 FROM pg_sleep(10)', '', 'int4');
SET statement_timeout = '100ms';
SELECT spi_sleep();  -- fail
RESET statement_timeout;
SELECT spi_s(1);

-- 11. SECURITY DEFINER
CREATE ROLE regress_plllvm_spi;
CREATE TABLE spi_secret (v text);
INSERT INTO spi_secret VALUES ('hidden');
REVOKE ALL ON spi_secret FROM PUBLIC;
SELECT mk_spi('spi_secret_def() RETURNS text STABLE SECURITY DEFINER',
              'SELECT v FROM spi_secret', '', 'text');
SELECT mk_spi('spi_secret_inv() RETURNS text STABLE',
              'SELECT v FROM spi_secret', '', 'text');
SET ROLE regress_plllvm_spi;
SELECT spi_secret_def();
SELECT spi_secret_inv();  -- fail
RESET ROLE;

-- 12. the validator does not prepare
SELECT mk_spi('spi_later() RETURNS int STABLE', 'SELECT 1 FROM spi_later_t', '', 'int4');
CREATE TABLE spi_later_t AS SELECT 1 AS a;
SELECT spi_later();
SELECT ok, sqlstate, message
  FROM plllvm_jit_test((SELECT prosrc FROM pg_proc WHERE oid = 'spi_later()'::regprocedure),
                       2, codegen => false);

DROP TABLE spi_t, spi_v, spi_secret, spi_later_t;
DROP FUNCTION spi_probe0(), spi_probe1(), spi_s(int), spi_n(int), spi_i2(int),
  spi_rows(int), spi_isnull(int), spi_up(int), spi_s_reset(int), spi_once(int),
  spi_once2(int), spi_cnt_stab(), spi_cnt_vol(), pl_cnt_stab(), pl_cnt_vol(),
  seen(text), spi_bad(), spi_bad(int), spi_sub(), spi_types(numeric, int),
  spi_div(int), spi_syntax(), fib_spi(int), pl_mid(int), spi_outer(int),
  spi_sleep(), spi_secret_def(), spi_secret_inv(), spi_later(),
  mk_spi(text, text, text, text, text, bool, text), sqlstate_of(text);
DROP ROLE regress_plllvm_spi;
