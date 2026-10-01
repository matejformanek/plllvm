--
-- Calls of other functions and constants.  The output is the same under
-- debug_discard_caches (make installcheck-discard), so only results and
-- booleans are printed.
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

-- fn returns callee(its n arguments); a NULL result is returned as NULL,
-- or without null_flag raised by the call helper
CREATE FUNCTION mk_ll(fn text, rettype text, callee text, n int,
                      null_flag bool DEFAULT true, opts text DEFAULT '')
RETURNS void LANGUAGE plpgsql AS $mk$
DECLARE
  site text := '@"' || replace(callee, '"', '\22') || '"';
  types text := '';
  args text := '';
  body text := '';
BEGIN
  FOR i IN 0 .. n - 1 LOOP
    types := types || ', i64, i1';
    args := args || ', i64 %a' || i || ', i1 %n' || i;
    body := body || '  %a' || i || ' = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 ' || i || E')\n'
                 || '  %n' || i || ' = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 ' || i || E')\n';
  END LOOP;
  EXECUTE format('CREATE OR REPLACE FUNCTION %s RETURNS %s LANGUAGE plllvm %s AS %L',
    fn, rettype, opts,
    site || E' = external global i8\n'
    || 'declare i64 @plllvm_call' || n || '(ptr' || types || E', ptr)\n'
    || E'declare i64 @plllvm_arg_i64(ptr, i32)\n'
    || E'declare i1 @plllvm_arg_isnull(ptr, i32)\n'
    || E'declare i64 @plllvm_return_null(ptr)\n'
    || E'define i64 @f(ptr %fcinfo) {\n  %isnull = alloca i1\n' || body
    || '  %r = call i64 @plllvm_call' || n || '(ptr ' || site || args
    || CASE WHEN null_flag
         THEN E', ptr %isnull)\n  %rn = load i1, ptr %isnull\n'
              || E'  br i1 %rn, label %null, label %ok\nok:\n  ret i64 %r\n'
              || E'null:\n  %z = call i64 @plllvm_return_null(ptr %fcinfo)\n  ret i64 %z\n}'
         ELSE E', ptr null)\n  ret i64 %r\n}' END);
END
$mk$;

-- fn returns the constant k
CREATE FUNCTION mk_k(fn text, rettype text, k text)
RETURNS void LANGUAGE plpgsql AS $mk$
DECLARE
  g text := '@"' || replace(replace(k, '\', '\5C'), '"', '\22') || '"';
BEGIN
  EXECUTE format('CREATE OR REPLACE FUNCTION %s RETURNS %s LANGUAGE plllvm AS %L',
    fn, rettype,
    g || E' = external global i8\ndeclare i64 @plllvm_const(ptr)\n'
    || E'define i64 @f(ptr %fcinfo) {\n  %k = call i64 @plllvm_const(ptr ' || g
    || E')\n  ret i64 %k\n}');
END
$mk$;

-- 1. results by value and by reference
SELECT mk_ll('c_add(a int, b int)', 'int', 'int4pl(integer,integer)', 2);
SELECT c_add(40, 2), c_add(NULL, 2) IS NULL AS strict;
SELECT mk_ll('c_nadd(a numeric, b numeric)', 'numeric', 'numeric_add(numeric,numeric)', 2);
SELECT c_nadd(1.5, 2.25);
SELECT sum(c_nadd(i, 0.5)) FROM generate_series(1, 1000) i;

-- 2. names resolve under the function's path, not the caller's
CREATE SCHEMA s1;
CREATE SCHEMA s2;
CREATE FUNCTION s1.g(int) RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE FUNCTION s2.g(int) RETURNS int LANGUAGE sql AS 'SELECT 2';
SELECT mk_ll('s1.use_g(x int)', 'int', 'g(integer)', 1);
SELECT mk_ll('s1.use_g2(x int)', 'int', 'g(integer)', 1,
             opts => 'SET search_path = s2');
SET search_path = s2, public;
SELECT s1.use_g(0), s1.use_g2(0);
SET search_path = '';
SELECT s1.use_g(0);
DISCARD ALL;
SET plllvm.regress_test_mode = on;
SELECT s1.use_g(0), s1.use_g2(0);
\set VERBOSITY terse
SELECT mk_ll('use_g(x int)', 'int', 'g(integer)', 1);
\set VERBOSITY default

-- pg_temp comes last, a temporary type does not shadow a catalog one
CREATE TYPE pg_temp.point AS (x int);
SELECT mk_k('c_point()', 'pg_catalog.point', '''(1,2)''::point');
SELECT c_point();
DROP TYPE pg_temp.point;

-- 3. rejected at CREATE FUNCTION
\set VERBOSITY terse
SELECT mk_ll('c_bad(x int)', 'int', 'int4pl(integer,integer)', 1);
CREATE FUNCTION c_bad() RETURNS int8 LANGUAGE plllvm AS $$
@"int4pl(integer,integer)" = external global i8
define i64 @f(ptr %fcinfo) {
  %p = ptrtoint ptr @"int4pl(integer,integer)" to i64
  ret i64 %p
}
$$;
CREATE FUNCTION c_bad() RETURNS int8 LANGUAGE plllvm AS $$
@"int4abs(integer)" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
  %a = call i64 @plllvm_call1(ptr @"int4abs(integer)", i64 1, i1 false, ptr null)
  %b = call i64 @plllvm_call2(ptr @"int4abs(integer)", i64 1, i1 false, i64 2, i1 false, ptr null)
  ret i64 %b
}
$$;
CREATE PROCEDURE c_proc() LANGUAGE sql AS '';
SELECT mk_ll('c_bad()', 'int', 'c_proc()', 0);
SELECT mk_ll('c_bad(a int, b int)', 'int', 'generate_series(integer,integer)', 2);
SELECT mk_ll('c_bad(a int, b int)', 'int', 'array_length(anyarray,integer)', 2);
SELECT mk_ll('c_bad(a text, b text)', 'text', 'concat_ws(text,"any")', 2);
CREATE FUNCTION c_rec(OUT a int, OUT b int) LANGUAGE sql AS 'SELECT 1, 2';
SELECT mk_ll('c_bad()', 'int', 'c_rec()', 0);
CREATE DOMAIN c_posint AS int CHECK (VALUE > 0);
SELECT mk_k('c_bad()', 'int8', '''abc''::numeric');
SELECT mk_k('c_bad()', 'int8', '''2026-01-01''::date');
SELECT mk_k('c_bad()', 'int8', '''1''::c_posint');
SELECT mk_k('c_bad()', 'int8', '''x''::nosuchtype');
SELECT mk_k('c_bad()', 'int8', '''abc::int');
\set VERBOSITY default
SELECT mk_k('c_ktext()', 'text', '''(x)''::text');
SELECT mk_k('c_knum()', 'numeric', '''0''::numeric(18,2)');
SELECT c_ktext(), c_knum();

-- an unknown callee, at CREATE and with check_function_bodies off at the
-- first call
CREATE FUNCTION c_unknown(x int) RETURNS int LANGUAGE plllvm AS $$
@"nosuch(integer)" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
  %r = call i64 @plllvm_call1(ptr @"nosuch(integer)", i64 0, i1 false, ptr null)
  ret i64 %r
}
$$;
SET check_function_bodies = off;
CREATE FUNCTION c_unknown(x int) RETURNS int LANGUAGE plllvm AS $$
@"nosuch(integer)" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
define i64 @f(ptr %fcinfo) {
  %r = call i64 @plllvm_call1(ptr @"nosuch(integer)", i64 0, i1 false, ptr null)
  ret i64 %r
}
$$;
RESET check_function_bodies;
SELECT c_unknown(1);

-- 4. NULL arguments and results
CREATE FUNCTION n_strict(x int) RETURNS int LANGUAGE plpgsql STRICT AS $$
BEGIN RAISE NOTICE 'n_strict(%)', x; RETURN x; END $$;
CREATE FUNCTION n_lax(x int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'n_lax(%)', x; RETURN coalesce(x, -1); END $$;
SELECT mk_ll('c_strict(x int)', 'int', 'n_strict(integer)', 1);
SELECT mk_ll('c_lax(x int)', 'int', 'n_lax(integer)', 1);
SELECT mk_ll('c_nonull(x int)', 'int', 'n_strict(integer)', 1, false);
SELECT c_strict(NULL) IS NULL AS null_result;
SELECT c_lax(NULL);
SELECT c_nonull(1);
SELECT c_nonull(NULL);

-- 5. SECURITY DEFINER, and its new owner
CREATE ROLE regress_plllvm_owner1;
CREATE ROLE regress_plllvm_owner2;
CREATE FUNCTION who() RETURNS name LANGUAGE sql SECURITY DEFINER
AS 'SELECT current_user';
ALTER FUNCTION who() OWNER TO regress_plllvm_owner1;
SELECT mk_ll('c_who()', 'name', 'who()', 0);
SELECT c_who();
ALTER FUNCTION who() OWNER TO regress_plllvm_owner2;
SELECT c_who();

-- 6. the callee's SET
CREATE FUNCTION wm() RETURNS text LANGUAGE sql
AS $$SELECT current_setting('work_mem')$$;
SELECT mk_ll('c_wm()', 'text', 'wm()', 0);
SELECT c_wm() = current_setting('work_mem') AS session_value;
ALTER FUNCTION wm() SET work_mem = '1234kB';
SELECT c_wm();
ALTER FUNCTION wm() RESET work_mem;
SELECT c_wm() = current_setting('work_mem') AS session_value;

-- 7. a replaced callee, also in another language
CREATE FUNCTION rp(x int) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN x + 1; END';
SELECT mk_ll('c_rp(x int)', 'int', 'rp(integer)', 1);
SELECT c_rp(1);
CREATE OR REPLACE FUNCTION rp(x int) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN x + 2; END';
SELECT c_rp(1);
CREATE OR REPLACE FUNCTION rp(x int) RETURNS int LANGUAGE sql AS 'SELECT x + 3';
SELECT c_rp(1);

-- 8. a callee made strict
ALTER FUNCTION n_lax(int) STRICT;
SELECT c_lax(NULL) IS NULL AS null_result;

-- 9. EXECUTE, checked per user and after any change of roles
CREATE ROLE regress_plllvm_user;
CREATE ROLE regress_plllvm_grp;
CREATE ROLE regress_plllvm_su SUPERUSER;
CREATE FUNCTION priv(x int) RETURNS int LANGUAGE sql AS 'SELECT x * 10';
SELECT mk_ll('c_priv(x int)', 'int', 'priv(integer)', 1);

-- (a) revoked from and granted to PUBLIC
SET ROLE regress_plllvm_user;
SELECT c_priv(1);
RESET ROLE;
REVOKE EXECUTE ON FUNCTION priv(int) FROM PUBLIC;
SET ROLE regress_plllvm_user;
SELECT c_priv(1);
RESET ROLE;
GRANT EXECUTE ON FUNCTION priv(int) TO PUBLIC;
SET ROLE regress_plllvm_user;
SELECT c_priv(1);
RESET ROLE;

-- (b) through a group
REVOKE EXECUTE ON FUNCTION priv(int) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION priv(int) TO regress_plllvm_grp;
GRANT regress_plllvm_grp TO regress_plllvm_user;
SET ROLE regress_plllvm_user;
SELECT c_priv(2);
RESET ROLE;
REVOKE regress_plllvm_grp FROM regress_plllvm_user;
SET ROLE regress_plllvm_user;
SELECT c_priv(2);
RESET ROLE;

-- (c) as a superuser that stops being one
SET ROLE regress_plllvm_su;
SELECT c_priv(3);
RESET ROLE;
ALTER ROLE regress_plllvm_su NOSUPERUSER;
SET ROLE regress_plllvm_su;
SELECT c_priv(3);
RESET ROLE;

-- (d) SET ROLE alone
SELECT c_priv(4);
SET ROLE regress_plllvm_user;
SELECT c_priv(4);
RESET ROLE;
SELECT c_priv(4);

-- 10. sites are bound by OID: a renamed callee is still called, a new
-- compile does not find it
CREATE FUNCTION rn(x int) RETURNS int LANGUAGE sql AS 'SELECT x';
SELECT mk_ll('c_rn(x int)', 'int', 'rn(integer)', 1);
SELECT c_rn(5);
ALTER FUNCTION rn(int) RENAME TO rn2;
SELECT c_rn(5);
\set VERBOSITY terse
SELECT mk_ll('c_rn(x int)', 'int', 'rn(integer)', 1);
\set VERBOSITY default

-- 11. a dropped callee is looked up again by its signature
CREATE FUNCTION dr(x int) RETURNS int LANGUAGE sql AS 'SELECT x + 100';
SELECT mk_ll('c_dr(x int)', 'int', 'dr(integer)', 1);
SELECT c_dr(1);
DROP FUNCTION dr(int);
SELECT c_dr(1);
CREATE FUNCTION dr(x int) RETURNS int LANGUAGE sql AS 'SELECT x + 200';
SELECT c_dr(1);
DROP FUNCTION dr(int);
CREATE FUNCTION dr(x int) RETURNS int8 LANGUAGE sql AS 'SELECT x + 300';
SELECT c_dr(1);

-- 12. ERRORs in the callee leave no busy site and no memory behind
SELECT mk_ll('div0(x int, y int)', 'int', 'int4div(integer,integer)', 2);
SELECT div0(6, 3);
SELECT sum(total_bytes) AS bytes0 FROM pg_backend_memory_contexts
WHERE name LIKE 'plllvm%' OR name LIKE 'PL/LLVM%' \gset
DO $$
DECLARE
  n int := 0;
BEGIN
  FOR i IN 1..50 LOOP
    BEGIN
      PERFORM div0(i, 0);
    EXCEPTION WHEN division_by_zero THEN
      n := n + 1;
    END;
  END LOOP;
  RAISE NOTICE 'caught %', n;
END
$$;
SELECT busy FROM plllvm_call_sites() WHERE owner = 'div0(int,int)'::regprocedure;
SELECT count(*) AS scratch FROM pg_backend_memory_contexts
WHERE name = 'PL/LLVM scratch';
SELECT sum(total_bytes) = :bytes0 AS same_bytes FROM pg_backend_memory_contexts
WHERE name LIKE 'plllvm%' OR name LIKE 'PL/LLVM%';
SELECT state FROM plllvm_function_status('div0(int,int)');

-- 13. recursion through a site gets a fresh FmgrInfo
CREATE FUNCTION sqlrec(n int) RETURNS int LANGUAGE sql AS 'SELECT 0';
SELECT mk_ll('via_site(n int)', 'int', 'sqlrec(integer)', 1);
CREATE OR REPLACE FUNCTION sqlrec(n int) RETURNS int LANGUAGE sql
AS 'SELECT CASE WHEN n > 0 THEN via_site(n - 1) + 1 ELSE 0 END';
SELECT via_site(5);
SELECT reentries, busy FROM plllvm_call_sites()
WHERE owner = 'via_site(int)'::regprocedure;

-- 14. collation: the input collation, else the argument type's
SELECT mk_ll('lower_ll(t text)', 'text', 'lower(text)', 1);
SELECT lower_ll('ÉA' COLLATE "C"), lower_ll('ÉA' COLLATE pg_c_utf8);
SELECT compiles FROM plllvm_function_status('lower_ll(text)');
CREATE FUNCTION lower_const() RETURNS text LANGUAGE plllvm AS $$
@"lower(text)" = external global i8
@"'ÉA'::text" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_const(ptr)
define i64 @f(ptr %fcinfo) {
  %k = call i64 @plllvm_const(ptr @"'ÉA'::text")
  %r = call i64 @plllvm_call1(ptr @"lower(text)", i64 %k, i1 false, ptr null)
  ret i64 %r
}
$$;
SELECT lower_const() = lower('ÉA') AS default_collation;

-- 15. only call, text and memory helpers need a frame
CREATE FUNCTION c_seven() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 7 } $$;
SELECT mk_k('c_kint()', 'int', '''7''::integer');
SELECT c_seven(), c_kint();
SELECT owner_oid, frame, resolve_ms >= 0 AS resolve_ms
FROM plllvm_code_cache()
WHERE owner_oid IN ('c_seven()'::regprocedure, 'c_kint()'::regprocedure,
                    'c_add(int,int)'::regprocedure)
ORDER BY owner_oid::text;

DROP FUNCTION mk_ll(text, text, text, int, bool, text), mk_k(text, text, text);
DROP FUNCTION c_add(int, int), c_nadd(numeric, numeric), c_point(),
  c_ktext(), c_knum(), c_unknown(int), c_strict(int), c_lax(int), c_nonull(int),
  c_who(), c_wm(), c_rp(int), c_priv(int), c_rn(int), c_dr(int), div0(int, int),
  via_site(int), lower_ll(text), lower_const(), c_seven(), c_kint();
DROP FUNCTION n_strict(int), n_lax(int), who(), wm(), rp(int), priv(int),
  rn2(int), dr(int), sqlrec(int), c_rec();
DROP PROCEDURE c_proc();
DROP DOMAIN c_posint;
DROP SCHEMA s1, s2 CASCADE;
DROP ROLE regress_plllvm_owner1, regress_plllvm_owner2, regress_plllvm_user,
  regress_plllvm_grp, regress_plllvm_su;
