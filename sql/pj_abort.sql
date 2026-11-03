--
-- pj_abort: errors in boxed evaluations, in frames of a recursion, caught
-- by PL/pgSQL, with savepoints and cursors in between
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pba_id(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pba_f(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pba_id(n) + 10 / n; END $$;
CREATE FUNCTION pba_try(n int) RETURNS text LANGUAGE plpgsql AS $$
BEGIN RETURN pba_f(n)::text;
EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
SELECT pba_f(1), pba_f(2), pba_f(5);
SELECT pj_expect('pba_f(int)', 'compiled') \gset

-- an error at the bottom of a recursion of boxed expressions, caught, then
-- the same function and another
CREATE FUNCTION pba_deep(n int, bad int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN 10 / bad; END IF;
  RETURN pba_deep(n - 1, bad) + 1;
END $$;
CREATE FUNCTION pba_catch(n int) RETURNS text LANGUAGE plpgsql AS $$
BEGIN PERFORM pba_deep(n, 0); RETURN 'no';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
SELECT pba_deep(5, 1), pba_deep(5, 1), pba_deep(6, 1);
SELECT pba_catch(50), pba_catch(2), pba_catch(50);
SELECT pba_deep(20, 1), pba_deep(30, 1);
SELECT pj_expect('pba_deep(int,int)', 'compiled') \gset
CREATE FUNCTION pba_fib(n int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN
  IF n < 2 THEN RETURN n; END IF;
  RETURN pba_fib(n - 1) + pba_fib(n - 2);
END $$;
SELECT pba_fib(10), pba_fib(10);
SELECT pba_catch(10), pba_fib(20);
SELECT pj_expect('pba_fib(int)', 'compiled') \gset

-- a savepoint around the failure, in one transaction
BEGIN;
SELECT pba_f(1);
SAVEPOINT a;
SELECT pba_f(2);
SAVEPOINT b;
SELECT pba_f(0);  -- fail
ROLLBACK TO b;
SELECT pba_f(3);
ROLLBACK TO a;
SELECT pba_f(4);
COMMIT;
SELECT pba_f(5);
SELECT pj_expect('pba_f(int)', 'compiled') \gset

-- a suspended portal runs the function between other calls of it
BEGIN;
DECLARE pba_c CURSOR FOR SELECT i, pba_f(i) FROM generate_series(1, 8) i;
FETCH 2 FROM pba_c;
SELECT pba_f(9);
SAVEPOINT s;
SELECT pba_try(0), pba_try(1);
ROLLBACK TO s;
FETCH 3 FROM pba_c;
SELECT pba_f(10), pba_try(0);
FETCH ALL FROM pba_c;
COMMIT;
SELECT pj_expect('pba_f(int)', 'interpreted:in use') \gset

-- an error inside a function that is not inlined, called by a boxed
-- expression, caught a hundred times in one transaction
CREATE FUNCTION pba_sqlerr(n int) RETURNS int LANGUAGE sql STABLE AS
  'SELECT 10 / n FROM generate_series(1, 1)';
CREATE FUNCTION pba_g(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pba_sqlerr(n) + 1; END $$;
SELECT pba_g(1), pba_g(2), pba_g(5);
DO $$
DECLARE c int := 0; s int := 0;
BEGIN
  FOR i IN 1..100 LOOP
    BEGIN PERFORM pba_g(0); EXCEPTION WHEN division_by_zero THEN c := c + 1; END;
    s := s + pba_g(5);
  END LOOP;
  RAISE NOTICE 'caught % sum %', c, s;
END $$;
SELECT pba_g(1), pba_g(0) IS NULL;  -- fail
SELECT pba_g(2), pba_g(4);
SELECT pj_expect('pba_g(int)', 'compiled') \gset

-- many caught errors in one transaction leave nothing behind
CREATE FUNCTION pba_total() RETURNS bigint LANGUAGE sql AS
  $$ SELECT sum(total_bytes) FROM pg_backend_memory_contexts $$;
CREATE FUNCTION pba_many(k int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE c int := 0;
BEGIN
  FOR i IN 1..k LOOP
    BEGIN PERFORM pba_f(0); EXCEPTION WHEN division_by_zero THEN c := c + 1; END;
  END LOOP;
  RETURN c;
END $$;
SELECT pba_many(10);
SELECT pba_total() AS before \gset
SELECT pba_many(10000);
SELECT pba_total() - :before < 1048576 AS flat;
SELECT pj_expect('pba_f(int)', 'interpreted:in use') \gset

-- the stack of context lines of an error four calls deep: one per call, and
-- the extra "PL/pgSQL expression" line of the interpreter's recursion is the
-- only difference allowed
CREATE FUNCTION pba_ctx(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN 1 / pba_id(0); END IF;
  RETURN pba_ctx(n - 1) + 1;
END $$;
CREATE FUNCTION pba_ctx_n(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE ctx text;
BEGIN
  PERFORM pba_ctx(n);
  RETURN -1;
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS ctx = PG_EXCEPTION_CONTEXT;
  RETURN (SELECT count(*)::int FROM regexp_split_to_table(ctx, E'\n') l
           WHERE l !~ '^PL/pgSQL expression ".*"$');
END $$;
SELECT pba_ctx(1) IS NULL;  -- fail
SELECT pba_ctx(1) IS NULL;  -- fail
SELECT pba_ctx_n(3), pba_ctx_n(3), pba_ctx_n(0);
SELECT pj_expect('pba_ctx(int)', 'interpreted:in use') \gset

-- an error in a boxed branch after the privilege was lost
\set VERBOSITY terse
CREATE ROLE regress_pj_ab;
CREATE FUNCTION pba_h(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF a > 100 THEN RETURN a / b + length(a::text); END IF;
  RETURN a * b;
END $$;
SELECT pba_h(200, 2), pba_h(1, 2), pba_h(200, 2), pba_h(1, 2);
SELECT pj_expect('pba_h(int,int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pba_h(200, 2);
SAVEPOINT s;
SELECT pba_h(200, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_ab;
SELECT pba_h(200, 2);  -- fail
ROLLBACK;
BEGIN; SET ROLE regress_pj_ab; SELECT pba_h(1, 2) AS unreached; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
SELECT pba_h(200, 2), pba_h(1, 2);
SELECT pj_expect('pba_h(int,int)', 'compiled') \gset
DROP ROLE regress_pj_ab;

-- a hash function that raises while the table of an IN list is built: the
-- half-built state is not used again
\set VERBOSITY default
CREATE FUNCTION pba_eq(a int, b int) RETURNS bool LANGUAGE sql IMMUTABLE AS 'SELECT a = b';
CREATE FUNCTION pba_hash(a int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF current_setting('pba.fail', true) = 'on' AND a = 5 THEN
    RAISE EXCEPTION 'hash failed';
  END IF;
  RETURN a;
END $$;
CREATE OPERATOR === (LEFTARG = int, RIGHTARG = int, FUNCTION = pba_eq, COMMUTATOR = ===, HASHES);
CREATE OPERATOR FAMILY pba_fam USING hash;
CREATE OPERATOR CLASS pba_cls FOR TYPE int USING hash FAMILY pba_fam AS
  OPERATOR 1 ===, FUNCTION 1 pba_hash(int);
CREATE FUNCTION pba_fh(n int) RETURNS bool LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN n === ANY('{1,2,3,4,5,6,7,8,9,10}'::int[]); END $$;
SELECT pba_fh(1), pba_fh(7), pba_fh(77);
SELECT set_config('pba.fail', 'on', false);
BEGIN;
SAVEPOINT s;
SELECT pba_fh(7) AS hash_fails;  -- fail
ROLLBACK TO s;
SELECT set_config('pba.fail', 'off', true);
SELECT pba_fh(7) AS after_failure;
SELECT pba_fh(77);
COMMIT;
SELECT pj_expect('pba_fh(int)', 'interpreted:in use') \gset
RESET pba.fail;
DROP FUNCTION pba_fh(int);
DROP OPERATOR FAMILY pba_fam USING hash CASCADE;
DROP OPERATOR === (int, int);

-- a failed hash table in a frame nested in one that runs the same expression,
-- caught between them: the next nested frame builds the table again
CREATE FUNCTION pba_wr2(n int) RETURNS bool LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN pba_fr(n);
EXCEPTION WHEN division_by_zero THEN PERFORM set_config('pba.fail', 'off', true); RETURN false; END $$;
CREATE FUNCTION pba_hash2(a int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF current_setting('pba.fail', true) = 'on' AND a = 5 THEN
    RAISE EXCEPTION 'hash failed' USING ERRCODE = '22012';
  END IF;
  RETURN a;
END $$;
CREATE OPERATOR ==== (LEFTARG = int, RIGHTARG = int, FUNCTION = pba_eq, COMMUTATOR = ====, HASHES);
CREATE OPERATOR FAMILY pba_fam2 USING hash;
CREATE OPERATOR CLASS pba_cls2 FOR TYPE int USING hash FAMILY pba_fam2 AS
  OPERATOR 1 ====, FUNCTION 1 pba_hash2(int);
CREATE FUNCTION pba_fr(n int) RETURNS bool LANGUAGE :pj_lang STABLE AS $$
BEGIN
  RETURN CASE WHEN n > 0 THEN pba_wr2(n - 1) OR pba_wr2(n - 1)
              ELSE (7 - n) ==== ANY('{1,2,3,4,5,6,7,8,9,10}'::int[]) END;
END $$;
SELECT pba_fr(0), pba_fr(1), pba_fr(1), pba_fr(1);
SELECT pj_expect('pba_fr(int)', 'compiled') \gset
BEGIN;
SET LOCAL pba.fail = on;
SELECT pba_fr(1) AS second_nested_after_failed_build;
SELECT pj_expect('pba_fr(int)', 'compiled') \gset
COMMIT;
RESET pba.fail;

-- an error in a function called through a site, caught by a function that
-- loops between two frames of the one that calls it
CREATE FUNCTION pba_ca(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 10 / n; END IF;
  RETURN pba_cb(n - 1) + 1;
END $$;
CREATE FUNCTION pba_cb(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
DECLARE r int := 0;
BEGIN
  FOR i IN 1..3 LOOP
    BEGIN r := r + pba_ca(n); EXCEPTION WHEN division_by_zero THEN r := r - 1; END;
  END LOOP;
  RETURN r;
END $$;
SELECT pba_ca(1), pba_ca(1), pba_ca(2), pba_ca(3);
-- an error that stopped an expression in this transaction sends what follows
-- to PL/pgSQL, which takes its SPI path for it
SELECT pj_expect('pba_ca(int)', 'interpreted:in use') \gset
SELECT pba_ca(4), pba_ca(2);
BEGIN;
SELECT pba_ca(2);
SAVEPOINT s;
SELECT pba_ca(0);  -- fail
ROLLBACK TO s;
SELECT pba_ca(3);
COMMIT;
SELECT pba_ca(5);

-- an error in a function that is not inlined, called through a site: the
-- level of the frame is deleted, and the next call builds its sites again
CREATE TABLE pba_ct (i int);
INSERT INTO pba_ct VALUES (1), (2);
CREATE FUNCTION pba_sq(n int) RETURNS int LANGUAGE sql STABLE AS
  'SELECT (10 / (count(*) - $1))::int FROM pba_ct';
CREATE FUNCTION pba_sf(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pba_sq(n) + 1; END $$;
CREATE FUNCTION pba_st(n int) RETURNS text LANGUAGE plpgsql AS $$
BEGIN RETURN pba_sf(n)::text; EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
SELECT pba_sf(1), pba_sf(3), pba_sf(1);
SELECT pj_expect('pba_sf(int)', 'compiled') \gset
SELECT pba_st(2), pba_st(1), pba_st(2), pba_st(3);
SELECT (SELECT string_agg(pba_st(i), ',') FROM generate_series(1, 100) i) IS NOT NULL AS caught_100;
SELECT pba_sf(1), pba_sf(3);
SELECT pj_expect('pba_sf(int)', 'compiled') \gset
