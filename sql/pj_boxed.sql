--
-- pj_boxed: expressions that the compiler does not do, evaluated by the
-- executor on a copy of the planned tree
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- fib: every call is an expression the executor runs, and calls itself
CREATE FUNCTION pbx_fib(n int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN
  IF n < 2 THEN RETURN n; END IF;
  RETURN pbx_fib(n - 1) + pbx_fib(n - 2);
END $$;
SELECT pbx_fib(5);
SELECT pj_mark() \gset
SELECT pbx_fib(15);
-- 1,973 calls, 986 of them not leaves; the first of them translated
SELECT pj_delta(1973, 0, 986, 0, 1) \gset
SELECT pj_expect('pbx_fib(int)', 'compiled') \gset

-- what the executor keeps for a call goes with the transaction that made it
SELECT pbx_fib(10);
SELECT pbx_fib(11);
BEGIN; SELECT pbx_fib(12); SELECT pbx_fib(13); COMMIT;
BEGIN; SELECT pbx_fib(14); ROLLBACK;
SELECT pbx_fib(15);
BEGIN; SELECT pbx_fib(10); SAVEPOINT s; SELECT pbx_fib(11); ROLLBACK TO s; SELECT pbx_fib(12); COMMIT;
SELECT pj_expect('pbx_fib(int)', 'compiled') \gset

-- mandelbrot at small sizes: the loops are compiled, the result is a text
CREATE FUNCTION pbx_mandel(sz int) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE
  two CONSTANT float8 := 2.0;
  four CONSTANT float8 := 4.0;
  one CONSTANT float8 := 1.0;
  onehalf CONSTANT float8 := 1.5;
  fsz float8;
  x integer; y integer; k integer;
  cr float8; ci float8; zr float8; zi float8; tr float8; ti float8;
  cnt integer := 0;
  h bigint := 0;
BEGIN
  fsz := sz;
  FOR y IN 0..sz-1 LOOP
    ci := two * y / fsz - one;
    FOR x IN 0..sz-1 LOOP
      cr := two * x / fsz - onehalf;
      zr := 0; zi := 0; tr := 0; ti := 0; k := 0;
      WHILE k < 50 AND tr + ti <= four LOOP
        zi := two * zr * zi + ci;
        zr := tr - ti + cr;
        tr := zr * zr;
        ti := zi * zi;
        k := k + 1;
      END LOOP;
      IF tr + ti <= four THEN
        cnt := cnt + 1;
        h := (h * 31 + x * 7 + y) % 1000000007;
      END IF;
    END LOOP;
  END LOOP;
  RETURN cnt::text || '/' || h::text;
END $$;
SELECT pbx_mandel(16);
SELECT pj_mark() \gset
SELECT pbx_mandel(16), pbx_mandel(30), pbx_mandel(1), pbx_mandel(0);
SELECT pj_delta(4, 0, 4, 0, 1) \gset
SELECT pj_expect('pbx_mandel(int)', 'compiled') \gset

-- other values the executor returns: a text, a number, NULL
CREATE FUNCTION pbx_txt(x int) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN substr(x::text, 1, 2); END $$;
CREATE FUNCTION pbx_len(x int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE n int;
BEGIN n := length(x::text); RETURN n + 1; END $$;
CREATE FUNCTION pbx_nul(x int) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN CASE WHEN x > 0 THEN x::text END; END $$;
CREATE FUNCTION pbx_num(x int) RETURNS float8 LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN (x::numeric * 1.5)::float8; END $$;
CREATE FUNCTION pbx_numc(x int) RETURNS float8 LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN x::numeric * 1.5; END $$;
SELECT pbx_txt(12345), pbx_len(12345), pbx_nul(7), pbx_nul(-7) IS NULL, pbx_num(3), pbx_numc(3);
SELECT pbx_txt(678), pbx_len(1), pbx_nul(8), pbx_nul(-8) IS NULL, pbx_num(4), pbx_numc(4);
SELECT pbx_txt(1), pbx_len(22), pbx_nul(9), pbx_nul(-9) IS NULL, pbx_num(5), pbx_numc(5);
SELECT pj_expect('pbx_txt(int)', 'compiled') \gset
SELECT pj_expect('pbx_len(int)', 'compiled') \gset
SELECT pj_expect('pbx_nul(int)', 'compiled') \gset
SELECT pj_expect('pbx_num(int)', 'compiled') \gset
-- numeric into float8 is a cast that can raise: stock's own
SELECT pj_expect('pbx_numc(int)', 'declined:cast') \gset

-- results passed by reference outlive the next call of the same function
SELECT concat_ws('/', pbx_txt(12345), pbx_txt(678), pbx_txt(99), pbx_txt(4));
SELECT concat_ws('/', pbx_txt(s.i * 7), pbx_txt(s.i * 13)) AS pair FROM generate_series(100, 103) s(i);

-- a local read after the call that recurses: each level has its own parameters
CREATE FUNCTION pbx_rl(n int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE x int := n * 10;
BEGIN
  IF n = 0 THEN RETURN 0; END IF;
  x := x + pbx_rl(n - 1) * 3 + x;
  RETURN x + n;
END $$;
SELECT pbx_rl(3);
SELECT pbx_rl(4), pbx_rl(4), pbx_rl(5);
SELECT pj_expect('pbx_rl(int)', 'compiled') \gset

-- values read at the time of the call: now() is not baked in
CREATE FUNCTION pbx_now() RETURNS timestamptz LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN now(); END $$;
CREATE FUNCTION pbx_now2() RETURNS timestamptz LANGUAGE :pj_lang STABLE AS $$
DECLARE t timestamptz := now();
BEGIN RETURN t; END $$;
SELECT pbx_now() IS NOT NULL, pbx_now2() IS NOT NULL;
SELECT pbx_now() IS NOT NULL, pbx_now2() IS NOT NULL;
BEGIN; SELECT pbx_now() AS n1, pbx_now2() AS m1 \gset
SELECT pg_sleep(0.01);
COMMIT;
BEGIN; SELECT pbx_now() AS n2, pbx_now2() AS m2 \gset
SELECT pg_sleep(0.01);
COMMIT;
BEGIN; SELECT pbx_now() AS n3, pbx_now2() AS m3 \gset
COMMIT;
SELECT :'n1' <> :'n2' AND :'n2' <> :'n3' AS now_distinct,
       :'m1' <> :'m2' AND :'m2' <> :'m3' AS now2_distinct,
       :'n1' = :'m1' AS same_transaction;
SELECT pj_expect('pbx_now()', 'compiled') \gset
SELECT pj_expect('pbx_now2()', 'compiled') \gset

-- one expression re-harvested inside a transaction: the state of the old
-- code is not used by the new
CREATE FUNCTION pbx_h(n int) RETURNS int LANGUAGE plpgsql STABLE AS 'BEGIN RETURN n * 2; END';
CREATE FUNCTION pbx_l1(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pbx_h(n) + 1; END $$;
SELECT pbx_l1(1), pbx_l1(2);
SELECT pj_expect('pbx_l1(int)', 'compiled') \gset
SELECT pj_mark() \gset
BEGIN;
SELECT pbx_l1(3), pbx_l1(4);
DISCARD PLANS;
SELECT pbx_l1(5);
SELECT pbx_l1(6), pbx_l1(7), pbx_l1(8);
COMMIT;
-- 2 calls, a guard miss, one translation, 3 calls
SELECT pj_delta(5, 1, 5, 0, 1) \gset
SELECT pj_expect('pbx_l1(int)', 'compiled') \gset
SELECT pj_mark() \gset
BEGIN;
SELECT pbx_l1(1), pbx_l1(2);
ALTER FUNCTION pbx_h(int) COST 7;
SELECT pbx_l1(3);
SELECT pbx_l1(4), pbx_l1(5), pbx_l1(6);
COMMIT;
SELECT pj_delta(5, 1, 5, 0, 1) \gset
-- replaced with another first expression
BEGIN;
SELECT pbx_l1(1), pbx_l1(2);
CREATE OR REPLACE FUNCTION pbx_l1(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $f$
BEGIN RETURN pbx_h(n) + pbx_h(n + 1) + 7; END $f$;
SELECT pbx_l1(3);
SELECT pbx_l1(4), pbx_l1(5), pbx_l1(6);
COMMIT;
SELECT pj_expect('pbx_l1(int)', 'compiled') \gset

-- a VOLATILE function sees the rows its own statement inserted, through the
-- snapshot taken for a stable function
CREATE TABLE pbx_t (i int, c int);
CREATE FUNCTION pbx_cnt() RETURNS int LANGUAGE sql STABLE AS
  'SELECT count(*)::int FROM pbx_t';
CREATE FUNCTION pbx_fcnt() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pbx_cnt(); END $$;
CREATE FUNCTION pbx_fcnt_s() RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pbx_cnt(); END $$;
SELECT pbx_fcnt(), pbx_fcnt(), pbx_fcnt_s(), pbx_fcnt_s();
INSERT INTO pbx_t SELECT g, pbx_fcnt() FROM generate_series(1, 4) g;
SELECT * FROM pbx_t ORDER BY i;
TRUNCATE pbx_t;
INSERT INTO pbx_t SELECT g, pbx_fcnt_s() FROM generate_series(1, 4) g;
SELECT * FROM pbx_t ORDER BY i;
SELECT pj_expect('pbx_fcnt()', 'compiled') \gset
SELECT pj_expect('pbx_fcnt_s()', 'compiled') \gset

-- the first thing evaluated after a COMMIT has no snapshot yet
CREATE FUNCTION pbx_sn(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pbx_cnt() + n; END $$;
CREATE PROCEDURE pbx_p() LANGUAGE plpgsql AS $$
DECLARE a int; b int;
BEGIN
  a := pbx_sn(1);
  COMMIT;
  b := pbx_sn(2);
  RAISE NOTICE 'after commit: % %', a, b;
END $$;
SELECT pbx_sn(1), pbx_sn(2);
CALL pbx_p();
CALL pbx_p();
SELECT pj_expect('pbx_sn(int)', 'compiled') \gset

-- a call that cannot start again once the executor ran: the effects of the
-- stable function below happen once per call, in the call that plans the rest
CREATE SEQUENCE pbx_seq;
CREATE FUNCTION pbx_noisy(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  RAISE NOTICE 'noisy %', n;
  PERFORM nextval('pbx_seq');
  RETURN n;
END $$;
CREATE FUNCTION pbx_late(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  x := pbx_noisy(n);
  IF n > 0 THEN RETURN x + 1; END IF;
  RETURN x * 2 + 100;
END $$;
CREATE FUNCTION pbx_attempts() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE n bigint := 0;
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NOT NULL
     AND current_setting('debug_discard_caches')::int = 0 THEN
    EXECUTE 'SELECT attempts FROM plllvm_pj_stats()' INTO n;
  END IF;
  RETURN n;
END $$;
SET track_functions = 'pl';
SELECT pbx_late(1);
SELECT pbx_late(2);
SELECT pj_expect('pbx_late(int)', 'waiting') \gset
-- waiting costs the pre-check of each call, and no translation attempt
SELECT pbx_attempts() AS a1 \gset
SELECT pbx_late(3);
SELECT pbx_late(-1);
SELECT pj_expect('pbx_late(int)', 'waiting') \gset
SELECT pbx_attempts() = :a1 AS no_attempts;
BEGIN;
SELECT pbx_late(-2);
SELECT pg_stat_get_xact_function_calls('pbx_noisy(int)'::regprocedure) AS noisy_calls;
COMMIT;
SELECT pbx_late(4), pbx_late(-3);
SELECT pj_expect('pbx_late(int)', 'compiled') \gset
SELECT last_value FROM pbx_seq;
RESET track_functions;

-- the same for an effect before an expression that fails to plan
CREATE FUNCTION pbx_nofn(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  x := pbx_noisy(n);
  IF n > 0 THEN RETURN x; END IF;
  RETURN pbx_nofn_callee(x);
END $$;
SELECT pbx_nofn(1);
SELECT pbx_nofn(2);
SELECT pbx_nofn(3);
SELECT pbx_nofn(0);  -- fail
SELECT pbx_nofn(0);  -- fail
SELECT last_value FROM pbx_seq;
CREATE FUNCTION pbx_nofn_callee(n int) RETURNS int LANGUAGE sql IMMUTABLE AS 'SELECT n * 2';
SELECT pbx_nofn(0);
SELECT pbx_nofn(0);
SELECT pbx_nofn(5), pbx_nofn(0);
SELECT pj_expect('pbx_nofn(int)', 'compiled') \gset
SELECT last_value FROM pbx_seq;

-- a self-cancel in a function called from a boxed expression: the next
-- statement of the caller is where PL/pgSQL notices it
CREATE FUNCTION pbx_cancel() RETURNS int LANGUAGE sql STABLE AS
  'SELECT CASE WHEN pg_cancel_backend(pg_backend_pid()) THEN 1 ELSE 0 END';
CREATE FUNCTION pbx_sc(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int;
BEGIN
  IF n = 0 THEN i := pbx_cancel(); END IF;
  i := 1 / n;
  RETURN i;
END $$;
SELECT pbx_sc(1);
SELECT pbx_sc(2);
SELECT pbx_sc(0);  -- fail
SELECT pbx_sc(1), pbx_sc(2);
SELECT pj_expect('pbx_sc(int)', 'compiled') \gset

-- the privileges on what a boxed expression calls: PL/pgSQL checks when it
-- builds the state, and plpgsql_jit never lets more through
\set VERBOSITY terse
CREATE ROLE regress_pj_bx;
CREATE ROLE regress_pj_bo;
CREATE FUNCTION pbx_pg(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN RETURN n + 1; ELSE RETURN n * 2 + length(n::text); END IF;
END $$;
SELECT pbx_pg(1), pbx_pg(2), pbx_pg(-1), pbx_pg(-2), pbx_pg(3), pbx_pg(-3);
SELECT pj_expect('pbx_pg(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
BEGIN; SELECT pbx_pg(1); SET ROLE regress_pj_bx; SAVEPOINT s; SELECT pbx_pg(-1) AS pg_expect_denied; ROLLBACK TO s; ROLLBACK;
BEGIN; SET ROLE regress_pj_bx; SELECT pbx_pg(1) AS pg_unreached; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
SELECT pbx_pg(1), pbx_pg(-1);
SELECT pj_expect('pbx_pg(int)', 'compiled') \gset

-- an owner without the right, two frames deep: the inner frame is PL/pgSQL's,
-- and the outer's expression is busy there
CREATE FUNCTION pbx_rc(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 1; END IF;
  RETURN pbx_rc_sd(n - 1) * 2;
END $$;
CREATE FUNCTION pbx_rc_sd(n int) RETURNS int LANGUAGE :pj_lang STABLE SECURITY DEFINER AS $$
BEGIN RETURN pbx_rc(n); END $$;
ALTER FUNCTION pbx_rc_sd(int) OWNER TO regress_pj_bo;
SELECT pbx_rc(3), pbx_rc(3), pbx_rc(3);
SELECT pj_expect('pbx_rc(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
SELECT pbx_rc(2);  -- fail
SELECT pbx_rc(2);  -- fail
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
-- the same, with the state of the invoker built in this transaction by a
-- call with a NULL argument
CREATE FUNCTION pbx_rcm(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF m <= 0 THEN RETURN 1; END IF;
  RETURN pbx_rcm_sd(n, m - 1) * 2;
END $$;
CREATE FUNCTION pbx_rcm_sd(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE SECURITY DEFINER AS $$
BEGIN RETURN pbx_rcm(n, m); END $$;
ALTER FUNCTION pbx_rcm_sd(int, int) OWNER TO regress_pj_bo;
SELECT pbx_rcm(3, 2), pbx_rcm(3, 2), pbx_rcm(3, 2);
SELECT pj_expect('pbx_rcm(int,int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pbx_rcm(NULL, 1);
SAVEPOINT s;
SELECT pbx_rcm(1, 2);  -- fail
ROLLBACK TO s;
SELECT pbx_rcm(NULL, 1);
COMMIT;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
SELECT pbx_rcm(3, 2), pbx_rc(3);
SELECT pj_expect('pbx_rcm(int,int)', 'compiled') \gset
SELECT pj_expect('pbx_rc(int)', 'compiled') \gset

-- a recursion whose inner frame runs in PL/pgSQL (a NULL argument): the outer
-- frame's expression is busy there, and what that call builds is its own
CREATE ROLE regress_pj_qg;
CREATE FUNCTION pbx_fb(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE v int;
BEGIN
  IF m IS NULL THEN RETURN 0; END IF;
  IF n > 100 THEN RETURN v % 7; END IF;
  RETURN pbx_fb(n, NULL) + 1;
END $$;
SELECT pbx_fb(200, 1);
SELECT pbx_fb(1, 1), pbx_fb(1, 1), pbx_fb(1, 1), pbx_fb(1, 1);
REVOKE EXECUTE ON FUNCTION int4mod(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pbx_fb(1, 1);
SET ROLE regress_pj_qg;
SAVEPOINT s;
SELECT pbx_fb(200, 1) AS pbx_fb_expect_denied;
ROLLBACK TO s;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mod(int4, int4) TO PUBLIC;
-- and the flags of the outer expression are given back afterwards
BEGIN;
SELECT pbx_fb(1, 1);
SELECT pbx_fb(1, 1);
SELECT pj_expect('pbx_fb(int,int)', 'compiled') \gset
COMMIT;

-- the same through a SECURITY DEFINER owner without the right: the inner
-- frame, run in PL/pgSQL, reaches the outer frame's expression busy
CREATE ROLE regress_pj_qinv;
CREATE FUNCTION pbx_qc(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF m <= 0 THEN RETURN 1; END IF;
  RETURN pbx_qc_sd(n, m - 1) * 2;
END $$;
CREATE FUNCTION pbx_qc_sd(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE SECURITY DEFINER AS $$
BEGIN RETURN pbx_qc(NULL, m); END $$;
ALTER FUNCTION pbx_qc_sd(int, int) OWNER TO regress_pj_bo;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO regress_pj_qinv;
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_qinv;
SELECT pbx_qc(NULL, 1), pbx_qc(1, 1), pbx_qc(1, 1);
SELECT pbx_qc(1, 2);  -- fail
RESET ROLE;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
DROP OWNED BY regress_pj_qinv;
DROP ROLE regress_pj_qinv, regress_pj_qg;

DROP OWNED BY regress_pj_bx, regress_pj_bo;
DROP ROLE regress_pj_bx, regress_pj_bo;
