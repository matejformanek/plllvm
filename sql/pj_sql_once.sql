--
-- pj_sql_once: what a compiled call does with the plan of its SQL statements
--
-- Expected from plllvm, not from stock PL/pgSQL, and run in one variant only.
-- A compiled call runs a statement on the plan PL/pgSQL prepared, and SPI may
-- analyse it again inside the call; these rows pin what the code then checks
-- (sql_rewalks, sql_stale, sql_execs) and the differences it states.
--
SET plllvm.regress_test_mode = on;
\set VERBOSITY terse

CREATE TABLE pso_t (a int PRIMARY KEY, b text);
INSERT INTO pso_t SELECT i, 'row' || i FROM generate_series(1, 20) i;
ANALYZE pso_t;
CREATE TABLE pso_one (a int);
INSERT INTO pso_one VALUES (1);
ANALYZE pso_one;

-- the SQLSTATE and message of an error, caught
CREATE FUNCTION pso_try(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE q; RETURN 'ok';
EXCEPTION WHEN others THEN RETURN SQLSTATE || ' ' || SQLERRM; END $$;

-- the shadow estate: a statement analysed again inside the call reads the
-- variables through the hooks of PL/pgSQL.  pj_sql_replan analyses it again at
-- every execution; it resets every plan, so a function with an expression of
-- its own would miss at its next call, and this one returns its argument.
CREATE FUNCTION pso_shadow(n int, t text) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM 1 / (n - a) FROM pso_one WHERE tag <> t;
  RETURN n;
END $$;
ALTER TABLE pso_one ADD COLUMN tag text DEFAULT 'y';
SELECT pso_shadow(5, 'x'), pso_shadow(6, 'x'), pso_shadow(7, 'x');
SELECT pj_expect('pso_shadow(integer,text)', 'compiled') \gset
SET plllvm.debug_inject = pj_sql_replan;
SELECT pj_mark() \gset
SELECT pso_shadow(5, 'x'), pso_shadow(6, 'x'), pso_shadow(7, 'y');
SELECT pso_try('SELECT pso_shadow(1, ''x'')');
SELECT pj_delta(4, 0, NULL, 0, 0, NULL, 4, 0, 4);
RESET plllvm.debug_inject;

-- an error inside the statement, then an interpreted call that analyses the
-- statement again: the estate the hooks read is the interpreter's again
CREATE FUNCTION pso_g8(n int, h int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM 10 / (a - n) FROM pso_one;
  RETURN n;
END $$;
SELECT pso_g8(2, 1), pso_g8(3, 1), pso_g8(4, 1);
SELECT pj_expect('pso_g8(integer,integer)', 'compiled') \gset
SELECT pso_try('SELECT pso_g8(1, 1)');
SELECT pso_g8(2, 1);
DISCARD PLANS;
SELECT pso_g8(2, NULL);
SELECT pso_g8(2, 1);
-- the statement fails in the analysis it does inside the call
ALTER TABLE pso_one RENAME a TO b;
SELECT pso_try('SELECT pso_g8(2, 1)');
SELECT pso_try('SELECT pso_g8(2, NULL)');
ALTER TABLE pso_one RENAME b TO a;
SELECT pso_g8(2, 1), pso_g8(2, NULL), pso_g8(3, 1);
SELECT pj_expect('pso_g8(integer,integer)', 'compiled') \gset

-- A statement analysed again at each of 200 executions of one call is walked
-- once, at the entry of the call: what SPI makes of it inside the call is
-- walked at the next entry
CREATE FUNCTION pso_rewalk(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  FOR i IN 1..n LOOP
    PERFORM 1 FROM pso_t WHERE a = i;
  END LOOP;
  RETURN n;
END $$;
SELECT pso_rewalk(3), pso_rewalk(3), pso_rewalk(3), pso_rewalk(3);
SELECT pj_expect('pso_rewalk(integer)', 'compiled') \gset
SET plllvm.debug_inject = pj_sql_replan;
SELECT pj_mark() \gset
SELECT pso_rewalk(200);
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 200, 0, 1);
RESET plllvm.debug_inject;

-- P-IBETWEEN: an interpreted call analyses the statement again between two
-- compiled ones, after the callee became VOLATILE.  The compiled call does
-- not run the statement on that plan: the entry rechecks it.
CREATE FUNCTION pso_callee(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pso_ib(n int, h int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM pso_callee(n) FROM pso_one;
  RETURN n;
END $$;
SELECT pso_ib(1, 1), pso_ib(2, 1), pso_ib(3, 1);
SELECT pj_expect('pso_ib(integer,integer)', 'compiled') \gset
ALTER FUNCTION pso_callee(int) VOLATILE;
SELECT pso_ib(4, NULL);
SELECT pj_mark() \gset
SELECT pso_ib(5, 1);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, NULL, 1, NULL);
SELECT pj_expect('pso_ib(integer,integer)', 'interpreted:guard miss') \gset
SELECT pso_ib(6, 1);
SELECT pj_expect('pso_ib(integer,integer)', 'declined:volatile callee') \gset
SELECT pso_ib(7, 1);

-- an interpreted call whose planning fails, between two compiled ones: the
-- statement was analysed again after the callee became VOLATILE, the plan
-- that failed to build leaves the new query list valid, and the entry walks it
CREATE FUNCTION pso_cal2(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pso_ibr(n int, h int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM pso_cal2(100 / n) FROM pso_one;
  RETURN n;
END $$;
SET plan_cache_mode = force_custom_plan;
SELECT pso_ibr(1, 1), pso_ibr(2, 1), pso_ibr(3, 1);
SELECT pj_expect('pso_ibr(integer,integer)', 'compiled') \gset
ALTER FUNCTION pso_cal2(int) VOLATILE;
SELECT pso_try('SELECT pso_ibr(0, NULL)');
SELECT pj_mark() \gset
SELECT pso_ibr(1, 1);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
SELECT pso_ibr(2, 1);
SELECT pso_ibr(3, 1);
SELECT pj_expect('pso_ibr(integer,integer)', 'declined:volatile callee') \gset
RESET plan_cache_mode;

-- N-SQL: a function replaced inside the statement stales the plan of a later
-- expression of the call; the call goes on with the tree it has, and the next
-- one translates again.  PL/pgSQL plans the expression again at its next
-- evaluation, so the call that replaces pso_g answers 101 where the compiled
-- one answers 1; the call after it is PL/pgSQL's, and answers 101.
CREATE FUNCTION pso_g(n int) RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT n + 0 $$;
CREATE FUNCTION pso_redef(k int) RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN
  EXECUTE format('CREATE OR REPLACE FUNCTION pso_g(n int) RETURNS int LANGUAGE sql IMMUTABLE AS %L',
                 'SELECT n + ' || k);
END $$;
CREATE FUNCTION pso_mis(k int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF k > 50 THEN PERFORM pso_redef(k); END IF;
  RETURN k;
END $$;
CREATE FUNCTION pso_nsql(k int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM pso_mis(k) FROM pso_one;
  RETURN pso_g(1);
END $$;
SELECT pso_nsql(1), pso_nsql(2), pso_nsql(3);
SELECT pj_expect('pso_nsql(integer)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pso_nsql(100);
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 1, 1, 1);
SELECT pso_nsql(2);
SELECT pj_expect('pso_nsql(integer)', 'interpreted:guard miss') \gset
SELECT pso_nsql(3), pso_nsql(4), pso_nsql(5);
SELECT pj_expect('pso_nsql(integer)', 'compiled') \gset

-- T2 after a statement: a privilege lost inside the statement is raised at
-- once at the next function the code calls, 42501; PL/pgSQL keeps the state it
-- built in the transaction and answers 201.
CREATE ROLE regress_pso_r1;
CREATE FUNCTION pso_rev(k int) RETURNS void LANGUAGE plpgsql VOLATILE SECURITY DEFINER AS $$
BEGIN
  IF k > 100 THEN
    EXECUTE 'REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC';
  END IF;
END $$;
CREATE FUNCTION pso_revw(k int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN PERFORM pso_rev(k); RETURN 1; END $$;
CREATE FUNCTION pso_t2(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  PERFORM pso_revw(n) FROM pso_one;
  RETURN n + 1;
END $$;
GRANT EXECUTE ON FUNCTION pso_t2(int) TO regress_pso_r1;
GRANT SELECT ON pso_one TO regress_pso_r1;
SELECT pso_t2(1), pso_t2(2), pso_t2(3);
SELECT pj_expect('pso_t2(integer)', 'compiled') \gset
BEGIN;
SET ROLE regress_pso_r1;
SELECT pso_t2(1);
SELECT pso_try('SELECT pso_t2(200)');
RESET ROLE;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC;
DROP OWNED BY regress_pso_r1;
DROP ROLE regress_pso_r1;

-- (g) through a statement: a callee that catches an error is reached by a
-- statement of a compiled frame
CREATE SEQUENCE pso_s1;
CREATE FUNCTION pso_side() RETURNS void LANGUAGE plpgsql VOLATILE AS $$
BEGIN PERFORM nextval('pso_s1'); END $$;
CREATE FUNCTION pso_ge(n int, m int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 1; END IF;
  PERFORM pso_gw(n - 1, m - 1) FROM pso_one;
  RETURN 100 / m;
END $$;
CREATE FUNCTION pso_gw(n int, m int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF n = 1 THEN PERFORM pso_side(); END IF;
  RETURN pso_ge(n, m);
EXCEPTION WHEN division_by_zero THEN RETURN -1;
END $$;
SELECT pso_ge(2, 5);
SELECT pso_ge(2, 5);
SELECT pso_ge(2, 5);
SELECT setval('pso_s1', 1, false);
SELECT pso_ge(3, 1);
SELECT nextval('pso_s1') AS next_value;

-- SELECT INTO: a column whose type changes between calls is converted to the
-- variable's type by the cast PL/pgSQL would use.  The call that sees the new
-- type converts at run time and finds the statement no longer what it was
-- admitted as (sql_stale 1); the next call goes to PL/pgSQL, the one after is
-- translated again and declined, the cast being none no more.
CREATE TABLE pso_alt (a int, b int, c int);
INSERT INTO pso_alt VALUES (1, 10, 100), (2, 20, 200);
CREATE FUNCTION pso_l4(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x int;
BEGIN
  SELECT b INTO x FROM pso_alt WHERE a = n;
  RETURN x;
END $$;
CREATE FUNCTION pso_l4b(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x int;
BEGIN
  SELECT c INTO x FROM pso_alt WHERE a = n;
  RETURN x;
END $$;
SELECT pso_l4(1), pso_l4(2), pso_l4(3);
SELECT pso_l4(1), pso_l4(2), pso_l4(3);
SELECT pso_l4b(1), pso_l4b(2), pso_l4b(3);
SELECT pso_l4b(1), pso_l4b(2), pso_l4b(3);
SELECT pj_expect('pso_l4(integer)', 'compiled') \gset
SELECT pj_expect('pso_l4b(integer)', 'compiled') \gset
ALTER TABLE pso_alt ALTER COLUMN b TYPE text USING b::text;
ALTER TABLE pso_alt ALTER COLUMN c TYPE bigint;
SELECT pj_mark() \gset
SELECT pso_l4(1);
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 1, 0, 0);
SELECT pso_l4(2);
SELECT pj_expect('pso_l4(integer)', 'interpreted:guard miss') \gset
SELECT pso_l4(2), pso_l4(3);
SELECT pj_expect('pso_l4(integer)', 'declined:cast') \gset
SELECT pj_mark() \gset
SELECT pso_l4b(2);
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 1, 0, 0);
SELECT pso_l4b(1), pso_l4b(2), pso_l4b(3);
SELECT pj_expect('pso_l4b(integer)', 'declined:cast') \gset
-- a conversion that fails, in the call that converts: PL/pgSQL's error
CREATE TABLE pso_alt2 (a int, b int);
INSERT INTO pso_alt2 VALUES (1, 10);
CREATE FUNCTION pso_l4c(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x int;
BEGIN
  SELECT b INTO x FROM pso_alt2 WHERE a = n;
  RETURN x;
END $$;
SELECT pso_l4c(1), pso_l4c(1), pso_l4c(1);
SELECT pj_expect('pso_l4c(integer)', 'compiled') \gset
ALTER TABLE pso_alt2 ALTER COLUMN b TYPE text USING b::text;
INSERT INTO pso_alt2 VALUES (2, 'x');
SELECT pso_try('SELECT pso_l4c(2)');
SELECT pso_l4c(1);
SELECT pso_l4c(1);

-- the extra checks are read at the first INTO of a call: a function that the
-- statement calls and that sets them is not seen by the INTO after it.
-- PL/pgSQL reads them at each statement, and raises P0003 at the second one;
-- the compiled call answers, and the next call, which reads them at its first
-- INTO, raises there.
CREATE FUNCTION pso_cfg(v text) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN PERFORM set_config('plpgsql.extra_errors', v, false); RETURN 1; END $$;
CREATE FUNCTION pso_xc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x int; y int; c int;
BEGIN
  SELECT a INTO x FROM pso_t WHERE a > n;
  SELECT pso_cfg('too_many_rows') INTO c FROM pso_one;
  SELECT a INTO y FROM pso_t WHERE a > n;
  RETURN x + y;
END $$;
SELECT pso_try('SELECT pso_xc(19)');
RESET plpgsql.extra_errors;
SELECT pso_try('SELECT pso_xc(19)');
RESET plpgsql.extra_errors;
SELECT pso_try('SELECT pso_xc(19)');
RESET plpgsql.extra_errors;
SELECT pj_expect('pso_xc(integer)', 'compiled') \gset
SELECT pso_try('SELECT pso_xc(3)');
SELECT pso_try('SELECT pso_xc(3)');
RESET plpgsql.extra_errors;

-- A variant for another code generation (pj_codegen) of a function that is
-- translated has its own wait: the function has a statement in a branch no
-- call has taken, which the first variant leaves to a deopt, and the variant
-- that runs expressions in the executor cannot.  With the tables reset before
-- every call it is translated after the call that takes the branch, which plans
-- the statement.
CREATE TABLE pso_rs (a int);
INSERT INTO pso_rs VALUES (1), (2);
CREATE FUNCTION pso_rs_reset() RETURNS void LANGUAGE plpgsql AS $$
BEGIN TRUNCATE pso_rs; INSERT INTO pso_rs VALUES (1), (2); ANALYZE pso_rs; END $$;
CREATE FUNCTION pso_cg(n int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
DECLARE x int := 0;
BEGIN
  IF n > 1000 THEN
    SELECT a INTO x FROM pso_rs WHERE a = 1;
  END IF;
  RETURN x + n;
END $$;
SELECT pso_cg(1), pso_cg(2), pso_cg(3);
SELECT pj_expect('pso_cg(integer)', 'compiled') \gset
SET plllvm.pj_codegen = boxed;
SELECT pso_cg(1);
SELECT pj_expect('pso_cg(integer)', 'waiting') \gset
SELECT pso_rs_reset();
SELECT pso_cg(2000);
SELECT pso_rs_reset();
SELECT pso_cg(2000);
SELECT pso_rs_reset();
SELECT pj_mark() \gset
SELECT pso_cg(1);
SELECT pj_expect('pso_cg(integer)', 'compiled') \gset
SELECT pj_delta(1, 0, NULL, 0, 0);
RESET plllvm.pj_codegen;
