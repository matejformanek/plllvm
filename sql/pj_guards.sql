--
-- pj_guards: compiled code is run only while what it was made from holds
--
-- Each change below makes the next call, or the next few, run in PL/pgSQL;
-- the results are PL/pgSQL's whatever the path.  pj_expect reads the path.
-- Under debug_discard_caches every plan is stale and nothing runs compiled,
-- so pj_expect and pj_delta are silent there.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- translation attempts since pj_mark, which pj_delta does not read; stock
-- has no plllvm_pj_stats(), hence EXECUTE
CREATE FUNCTION pjg_attempts(want int8) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  cur jsonb;
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NULL
     OR current_setting('debug_discard_caches')::int > 0
     OR NOT current_setting('plllvm.plpgsql_jit')::bool THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT row_to_json(s)::jsonb FROM plllvm_pj_stats() s' INTO cur;
  IF (cur->>'attempts')::int8 - (current_setting('pj.mark')::jsonb->>'attempts')::int8
     <> want THEN
    RAISE EXCEPTION 'pjg_attempts: % attempts, expected %',
      (cur->>'attempts')::int8 - (current_setting('pj.mark')::jsonb->>'attempts')::int8, want;
  END IF;
END
$$;

CREATE FUNCTION pjg_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1; END $$;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- DISCARD PLANS: the plan the code was made from is gone
DISCARD PLANS;
SELECT pjg_inc(1);
SELECT pj_expect('pjg_inc(int)', 'interpreted:guard miss') \gset
SELECT pjg_inc(2);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- replaced, with another body
CREATE OR REPLACE FUNCTION pjg_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 100; END $$;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- a replacement that is rolled back: the old definition is back, and the
-- entry, the struct and its plans may be the same objects as before
BEGIN;
CREATE OR REPLACE FUNCTION pjg_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1000; END $$;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
ROLLBACK;
SELECT pjg_inc(1);
SELECT pjg_inc(2);
SELECT pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- the same for a change of attributes only
BEGIN;
ALTER FUNCTION pjg_inc(int) COST 7;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
ROLLBACK;
SELECT pjg_inc(1);
SELECT pjg_inc(2);
SELECT pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset
ALTER FUNCTION pjg_inc(int) COST 7;
SELECT pjg_inc(1);
SELECT pjg_inc(2);
SELECT pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset
ALTER FUNCTION pjg_inc(int) SET extra_float_digits = 1;
SELECT pjg_inc(1);
SELECT pjg_inc(2);
SELECT pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- dropped and created again, with the same text
DROP FUNCTION pjg_inc(int);
CREATE FUNCTION pjg_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 100; END $$;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- two tenants alternate the search_path, which the plans depend on; each
-- call replans in PL/pgSQL, and nothing is translated
CREATE SCHEMA pjg_ta;
CREATE SCHEMA pjg_tb;
CREATE FUNCTION pjg_tenant(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 2; END $$;
SET search_path = pjg_ta, public;
SELECT pjg_tenant(1), pjg_tenant(2), pjg_tenant(3);
SELECT pj_expect('pjg_tenant(int)', 'compiled') \gset
SET search_path = pjg_tb, public;
SELECT pjg_tenant(1);
SELECT pj_expect('pjg_tenant(int)', 'interpreted:guard miss') \gset
SET search_path = pjg_ta, public;
SELECT pjg_tenant(1);
SELECT pj_expect('pjg_tenant(int)', 'interpreted:unplanned') \gset
SELECT pj_mark() \gset
SELECT pjg_tenant(i), current_setting('search_path') FROM generate_series(1, 2) i;
SELECT pj_delta(NULL, NULL, NULL, 0, 1) \gset
SELECT pj_expect('pjg_tenant(int)', 'compiled') \gset
SELECT pj_mark() \gset
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    IF i % 2 = 0 THEN
      SET LOCAL search_path = pjg_ta, public;
    ELSE
      SET LOCAL search_path = pjg_tb, public;
    END IF;
    PERFORM pjg_tenant(i);
  END LOOP;
END
$$;
SELECT pj_delta(0, 20, NULL, 0, 0) \gset
SELECT pjg_attempts(0) \gset
SELECT pj_expect('pjg_tenant(int)', 'interpreted:unplanned') \gset
RESET search_path;

-- the tenants in pairs: each pair translates once
SELECT pj_mark() \gset
DO $$
BEGIN
  FOR i IN 1..8 LOOP
    IF (i - 1) / 2 % 2 = 0 THEN
      SET LOCAL search_path = pjg_ta, public;
    ELSE
      SET LOCAL search_path = pjg_tb, public;
    END IF;
    PERFORM pjg_tenant(i);
  END LOOP;
END
$$;
SELECT pj_delta(5, 3, NULL, 0, 4) \gset
RESET search_path;
SELECT pjg_tenant(5);
SELECT pjg_tenant(6);

-- EXECUTE on a function the code calls: PL/pgSQL checks it, and raises
CREATE ROLE regress_pj_guard;
GRANT USAGE ON SCHEMA pjg_ta TO regress_pj_guard;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3);
SET ROLE regress_pj_guard;
SELECT pjg_inc(4);
RESET ROLE;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SELECT pjg_inc(5);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset
SET ROLE regress_pj_guard;
SELECT pjg_inc(6);  -- fail
RESET ROLE;
SELECT pj_expect('pjg_inc(int)', 'interpreted:execute') \gset
SET ROLE regress_pj_guard;
SELECT pjg_inc(7);  -- fail
RESET ROLE;
GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC;
SET ROLE regress_pj_guard;
SELECT pjg_inc(8);
SELECT pjg_inc(9);
RESET ROLE;
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- one cast, in the other direction: a function whose cast cannot change
CREATE FUNCTION pjg_widen(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN RETURN n; END $$;
SELECT pjg_widen(1), pjg_widen(2), pjg_widen(2147483647);
DISCARD PLANS;
SELECT pjg_widen(1), pjg_widen(2), pjg_widen(2147483647);
SELECT pj_expect('pjg_widen(int)', 'compiled') \gset

-- an SQL function the planner inlined: the code is made from its body
CREATE FUNCTION pjg_f(n int) RETURNS int LANGUAGE sql AS 'SELECT $1';
CREATE FUNCTION pjg_h06(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pjg_f(n); END $$;
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);
SELECT pj_expect('pjg_h06(int)', 'compiled') \gset
CREATE OR REPLACE FUNCTION pjg_f(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 100';
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);
SELECT pj_expect('pjg_h06(int)', 'compiled') \gset
ALTER FUNCTION pjg_f(int) COST 7;
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);
ALTER FUNCTION pjg_f(int) SET extra_float_digits = 1;
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);
ALTER FUNCTION pjg_f(int) VOLATILE;
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);
SELECT pj_expect('pjg_h06(int)', 'declined:volatile callee') \gset
DROP FUNCTION pjg_f(int);
SELECT pjg_h06(1);  -- fail
SELECT pjg_h06(1);  -- fail
CREATE FUNCTION pjg_f(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 5';
SELECT pjg_h06(1), pjg_h06(2), pjg_h06(3);

-- the same name in two schemas of the search_path
CREATE SCHEMA pjg_s1;
CREATE SCHEMA pjg_s2;
CREATE FUNCTION pjg_s1.pjg_g(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 1';
CREATE FUNCTION pjg_s2.pjg_g(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 2';
CREATE FUNCTION pjg_h07(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pjg_g(n); END $$;
SET search_path = pjg_s1, public;
SELECT pjg_h07(10), pjg_h07(10), pjg_h07(10);
SET search_path = pjg_s2, public;
SELECT pjg_h07(10), pjg_h07(10), pjg_h07(10);
SET search_path = pjg_s1, public;
SELECT pjg_h07(10), pjg_h07(10), pjg_h07(10);
RESET search_path;
SELECT pjg_h07(10);  -- fail
DROP SCHEMA pjg_s1, pjg_s2 CASCADE;

-- a cast created or dropped between calls: the function is not compiled,
-- since the cast it first had is an I/O conversion, and PL/pgSQL sees the new
CREATE FUNCTION pjg_bf(b bool) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN b; END $$;
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
SELECT pj_expect('pjg_bf(bool)', 'declined:cast') \gset
CREATE FUNCTION pjg_castf(bool) RETURNS float8 LANGUAGE sql AS 'SELECT 42.5::float8';
CREATE CAST (bool AS float8) WITH FUNCTION pjg_castf(bool) AS ASSIGNMENT;
SELECT pjg_bf(true), pjg_bf(false);
SELECT pjg_bf(true), pjg_bf(false);
DROP CAST (bool AS float8);
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
DROP FUNCTION pjg_castf(bool);

DROP SCHEMA pjg_ta, pjg_tb CASCADE;
DROP ROLE regress_pj_guard;
