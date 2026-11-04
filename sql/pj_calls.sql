--
-- pj_calls: functions called from compiled code through sites, which are
-- built as the executor builds an ExprState, and the conversions through
-- the I/O functions
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set VERBOSITY terse

-- a call keeps its node: a VARIADIC array, and the types of a polymorphic
-- function, are read from it
CREATE FUNCTION pc_concat(n int) RETURNS text LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN concat(VARIADIC '{a,b}'::text[]) || n::text; END $$;
CREATE FUNCTION pc_format(n int) RETURNS text LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN format('%s-%s', VARIADIC '{a,b}'::text[]) || n::text; END $$;
CREATE FUNCTION pc_append(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN array_length(array_append('{1,2}'::int[], n), 1); END $$;
CREATE FUNCTION pc_id(x anyelement) RETURNS anyelement LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pc_any(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_id(n) + 1; END $$;
SELECT pc_concat(1), pc_format(2), pc_append(3), pc_any(4);
SELECT pj_mark() \gset
SELECT pc_concat(1), pc_format(2), pc_append(3), pc_any(4);
SELECT pc_concat(5), pc_format(6), pc_append(7), pc_any(8);
SELECT pj_delta(8, 0, 0, 0, 4) \gset
SELECT pj_expect('pc_concat(int)', 'compiled') \gset
SELECT pj_expect('pc_format(int)', 'compiled') \gset
SELECT pj_expect('pc_append(int)', 'compiled') \gset
SELECT pj_expect('pc_any(int)', 'compiled') \gset

-- a strict function is not called with a NULL, a function that is not is;
-- the property is read when the call is made
CREATE FUNCTION pc_cal(x int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN coalesce(x, 0) + 7; END $$;
CREATE FUNCTION pc_st(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE v int;
BEGIN
  IF n > 0 THEN v := n; END IF;
  RETURN coalesce(pc_cal(v), -1);
END $$;
SELECT pc_st(1), pc_st(1), pc_st(0), pc_st(2);
SELECT pj_expect('pc_st(int)', 'compiled') \gset
ALTER FUNCTION pc_cal(int) STRICT;
SELECT pc_st(1), pc_st(1), pc_st(0), pc_st(2);
SELECT pj_expect('pc_st(int)', 'compiled') \gset
ALTER FUNCTION pc_cal(int) CALLED ON NULL INPUT;
SELECT pc_st(1), pc_st(1), pc_st(0), pc_st(2);
SELECT pj_expect('pc_st(int)', 'compiled') \gset

-- a site belongs to the transaction, as an ExprState does: track_functions is
-- read when it is built, so a call is counted or not for the whole transaction
CREATE FUNCTION pc_tr(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_cal(n) + 1; END $$;
SELECT pc_tr(1), pc_tr(2);
SELECT pj_expect('pc_tr(int)', 'compiled') \gset
SET track_functions = none;
BEGIN;
SELECT pc_tr(1), pc_tr(2);
SELECT pg_stat_get_xact_function_calls('pc_cal(int)'::regprocedure) AS cal_none;
COMMIT;
SET track_functions = pl;
BEGIN;
SELECT pc_tr(1), pc_tr(2);
SELECT pg_stat_get_xact_function_calls('pc_cal(int)'::regprocedure) AS cal_pl;
SELECT pc_tr(3);
SELECT pg_stat_get_xact_function_calls('pc_cal(int)'::regprocedure) AS cal_pl_3;
COMMIT;
SET track_functions = none;
BEGIN;
SELECT pc_tr(1), pc_tr(2);
SELECT pg_stat_get_xact_function_calls('pc_cal(int)'::regprocedure) AS cal_none_again;
COMMIT;
RESET track_functions;
SELECT pj_expect('pc_tr(int)', 'compiled') \gset

-- the sites of a function that is replaced in a transaction are not the new
-- one's: the callee, and the function itself with its calls renumbered
CREATE FUNCTION pc_lh(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n * 2; END $$;
CREATE FUNCTION pc_l1(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_lh(n) + 1; END $$;
SELECT pc_l1(1), pc_l1(2);
SELECT pj_expect('pc_l1(int)', 'compiled') \gset
BEGIN;
SELECT pc_l1(3), pc_l1(4);
CREATE OR REPLACE FUNCTION pc_lh(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n * 3; END $$;
SELECT pc_l1(5);
SELECT pc_l1(6), pc_l1(7), pc_l1(8);
COMMIT;
SELECT pj_expect('pc_l1(int)', 'compiled') \gset
BEGIN;
SELECT pc_l1(1), pc_l1(2);
CREATE OR REPLACE FUNCTION pc_l1(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $f$
BEGIN RETURN pc_lh(n) + pc_lh(n + 1) + 7; END $f$;
SELECT pc_l1(3);
SELECT pc_l1(4), pc_l1(5), pc_l1(6);
COMMIT;
BEGIN;
SELECT pc_l1(1), pc_l1(2);
DISCARD PLANS;
SELECT pc_l1(3), pc_l1(4), pc_l1(5);
ALTER FUNCTION pc_lh(int) COST 7;
SELECT pc_l1(6), pc_l1(7), pc_l1(8);
COMMIT;
SELECT pj_expect('pc_l1(int)', 'compiled') \gset

-- the privileges on what a compiled function calls: PL/pgSQL checks when it
-- builds the state of an expression, and plpgsql_jit never lets more through;
-- a function it may not call that the call does not reach is stock's answer
CREATE ROLE regress_pj_c;
CREATE FUNCTION pc_d1(x int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN x * 3; END $$;
CREATE FUNCTION pc_rv(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n > 0 THEN RETURN n + 1; END IF;
  RETURN pc_d1(n) + 2;
END $$;
SELECT pc_rv(1), pc_rv(0), pc_rv(2), pc_rv(-1);
SELECT pj_expect('pc_rv(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION pc_d1(int) FROM PUBLIC;
BEGIN;
SET ROLE regress_pj_c;
SELECT pc_rv(1) AS unreached;
SAVEPOINT s;
SELECT pc_rv(0) AS reached;
ROLLBACK TO s;
ROLLBACK;
GRANT EXECUTE ON FUNCTION pc_d1(int) TO PUBLIC;
SELECT pc_rv(1), pc_rv(0), pc_rv(2), pc_rv(-1);
SELECT pj_expect('pc_rv(int)', 'compiled') \gset

-- an outer function it may not call does not run an inner one first
CREATE FUNCTION pc_inner(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'inner %', n; RETURN n; END $$;
CREATE FUNCTION pc_outer(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pc_pn(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_outer(pc_inner(n)); END $$;
SELECT pc_pn(1), pc_pn(2);
SELECT pj_expect('pc_pn(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION pc_outer(int) FROM PUBLIC;
BEGIN;
SET ROLE regress_pj_c;
SAVEPOINT s;
SELECT pc_pn(3) AS outer_denied;
ROLLBACK TO s;
ROLLBACK;
GRANT EXECUTE ON FUNCTION pc_outer(int) TO PUBLIC;
SELECT pc_pn(4), pc_pn(5), pc_pn(6);
SELECT pj_expect('pc_pn(int)', 'compiled') \gset

-- a callee that is SECURITY DEFINER, and a recursion through one whose owner
-- has no right to a function the frames below use
CREATE ROLE regress_pj_co;
CREATE FUNCTION pc_sd(n int) RETURNS int LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN RETURN n * 2; END $$;
ALTER FUNCTION pc_sd(int) OWNER TO regress_pj_co;
CREATE FUNCTION pc_usesd(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_sd(n) + 1; END $$;
SELECT pc_usesd(1), pc_usesd(2), pc_usesd(3);
SELECT pj_expect('pc_usesd(int)', 'compiled') \gset
CREATE FUNCTION pc_rc(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 1; END IF;
  RETURN pc_rc_sd(n - 1) * 2;
END $$;
CREATE FUNCTION pc_rc_sd(n int) RETURNS int LANGUAGE :pj_lang STABLE SECURITY DEFINER AS $$
BEGIN RETURN pc_rc(n); END $$;
ALTER FUNCTION pc_rc_sd(int) OWNER TO regress_pj_co;
SELECT pc_rc(3), pc_rc(3), pc_rc(3);
SELECT pj_expect('pc_rc(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
BEGIN;
SAVEPOINT s;
SELECT pc_rc(2) AS owner_denied;
ROLLBACK TO s;
COMMIT;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
-- the same with the state of the invoker built in this transaction by a call
-- with a NULL argument
CREATE FUNCTION pc_rcm(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF m <= 0 THEN RETURN 1; END IF;
  RETURN pc_rcm_sd(n, m - 1) * 2;
END $$;
CREATE FUNCTION pc_rcm_sd(n int, m int) RETURNS int LANGUAGE :pj_lang STABLE SECURITY DEFINER AS $$
BEGIN RETURN pc_rcm(n, m); END $$;
ALTER FUNCTION pc_rcm_sd(int, int) OWNER TO regress_pj_co;
SELECT pc_rcm(3, 2), pc_rcm(3, 2), pc_rcm(3, 2);
SELECT pj_expect('pc_rcm(int,int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pc_rcm(NULL, 1);
SAVEPOINT s;
SELECT pc_rcm(1, 2) AS nested_denied;
ROLLBACK TO s;
SELECT pc_rcm(NULL, 1);
COMMIT;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
SELECT pc_rcm(3, 2), pc_rc(3);
SELECT pj_expect('pc_rcm(int,int)', 'compiled') \gset
SELECT pj_expect('pc_rc(int)', 'compiled') \gset
DROP OWNED BY regress_pj_co;
DROP ROLE regress_pj_co;

-- recursion: 200 frames deep, a text built from two I/O conversions, and the
-- error of a recursion nothing stops
CREATE FUNCTION pc_depth(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 0; END IF;
  RETURN pc_depth(n - 1) + 1;
END $$;
SELECT pc_depth(5), pc_depth(5), pc_depth(200);
SELECT pj_expect('pc_depth(int)', 'compiled') \gset
CREATE FUNCTION pc_cat(cnt int, h bigint) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN cnt::text || '/' || h::text; END $$;
-- an immutable function with constant arguments is run by the planner
SELECT pc_cat(a, b) FROM (VALUES (1, 2::bigint), (10, 2000000000000), (-5, -7)) v(a, b);
SELECT pj_mark() \gset
SELECT pc_cat(a, b) FROM (VALUES (1, 2::bigint), (10, 2000000000000), (-5, -7)) v(a, b);
SELECT pj_delta(3, 0, 0, 0, 0) \gset
SELECT pj_expect('pc_cat(int,bigint)', 'compiled') \gset
CREATE FUNCTION pc_inf(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_inf(n + 1) + 1; END $$;
SELECT pc_inf(1) IS NULL AS inf_unwarmed;
DO $$
BEGIN
  PERFORM pc_inf(1);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pc_inf: %', SQLSTATE;
END $$;
SELECT pj_expect('pc_inf(int)', 'compiled') \gset
DO $$
BEGIN
  PERFORM pc_inf(1);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'pc_inf again: %', SQLSTATE;
END $$;
SELECT pc_depth(100);

-- a call in a branch the expression does not take: nothing was built for it
CREATE FUNCTION pc_br(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n > 0 AND length(n::text) > 1 THEN RETURN 1; END IF;
  RETURN CASE WHEN n > 5 THEN pc_cal(n) ELSE n * 2 END + coalesce(n, length(pc_cal(n)::text));
END $$;
SELECT pc_br(0), pc_br(0), pc_br(-3), pc_br(7), pc_br(12), pc_br(3);
SELECT pc_br(0), pc_br(-3), pc_br(1);
SELECT pj_expect('pc_br(int)', 'compiled') \gset

-- an I/O conversion of a NULL is a NULL: the input function is strict
CREATE FUNCTION pc_ion(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE v int;
BEGIN
  IF n > 0 THEN v := n * 100; END IF;
  RETURN coalesce(length(v::text), -1) + coalesce((v::text)::int, 0);
END $$;
SELECT pc_ion(1), pc_ion(0), pc_ion(1), pc_ion(0), pc_ion(7);
SELECT pj_expect('pc_ion(int)', 'compiled') \gset

-- the settings an output function reads are read at each call
CREATE FUNCTION pc_f8(x float8) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN length(x::text); END $$;
CREATE FUNCTION pc_dt(x date) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN length(x::text) * 100 + length((x + 1)::text); END $$;
SELECT pc_f8(0.1), pc_f8(1.0 / 3), pc_dt('2026-11-03'), pc_dt('2026-12-31');
SET extra_float_digits = 3;
SELECT pc_f8(0.1), pc_f8(1.0 / 3);
SET extra_float_digits = -3;
SELECT pc_f8(0.1), pc_f8(1.0 / 3);
RESET extra_float_digits;
SET datestyle = 'German';
SELECT pc_dt('2026-11-03'), pc_dt('2026-12-31');
SET datestyle = 'SQL, MDY';
SELECT pc_dt('2026-11-03'), pc_dt('2026-12-31');
RESET datestyle;
SELECT pj_expect('pc_f8(float8)', 'compiled') \gset
SELECT pj_expect('pc_dt(date)', 'compiled') \gset

-- an input function that raises: the error and its context are stock's
CREATE FUNCTION pc_bad(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN (n::text || 'x')::int; END $$;
SELECT pc_bad(1);
SELECT pc_bad(2);
SELECT pj_expect('pc_bad(int)', 'compiled') \gset
\set VERBOSITY default
SELECT pc_bad(3);
\set VERBOSITY terse

-- the snapshot of a function that is not STABLE: a call that needs one is the
-- executor's, as the expression of a VOLATILE function that calls a STABLE one
CREATE TABLE pc_t (i int);
CREATE FUNCTION pc_cnt() RETURNS int LANGUAGE sql STABLE AS
  'SELECT count(*)::int FROM pc_t';
CREATE FUNCTION pc_ins(n int) RETURNS int LANGUAGE sql AS
  'INSERT INTO pc_t VALUES ($1) RETURNING $1';
CREATE FUNCTION pc_vol(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pc_cnt() + n; END $$;
CREATE FUNCTION pc_stable(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_cnt() + n; END $$;
SELECT pc_vol(0), pc_stable(0);
SELECT pc_vol(0), pc_stable(0);
SELECT pj_mark() \gset
SELECT pc_vol(0), pc_stable(0);
SELECT pj_delta(2, 0, 1, 0, 0) \gset
INSERT INTO pc_t SELECT pc_ins(g) FROM generate_series(1, 3) g;
SELECT pc_vol(0), pc_stable(0);
-- the rows a statement of its own inserted are seen by the first, not the second
INSERT INTO pc_t SELECT g + pc_vol(0) FROM generate_series(1, 4) g;
INSERT INTO pc_t SELECT g + pc_stable(0) FROM generate_series(1, 4) g;
SELECT i FROM pc_t ORDER BY ctid;
SELECT pj_expect('pc_vol(int)', 'compiled') \gset
SELECT pj_expect('pc_stable(int)', 'compiled') \gset

-- what a compiled function does not call: a volatile function, in the body or
-- itself
CREATE FUNCTION pc_target(n int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RETURN n + 100; END $$;
CREATE SCHEMA pc_s1;
CREATE FUNCTION pc_s1.pc_target(n int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pc_c(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    s := s + pc_target(i);
    IF i = 3 THEN s := s + length(set_config('search_path', 'pc_s1', true)) * 0; END IF;
  END LOOP;
  RETURN s;
END $$;
SELECT pc_c(5);
SELECT pc_c(5);
SELECT pc_c(0);
SELECT pc_c(5);
SELECT pj_expect('pc_c(int)', 'declined:volatile callee') \gset
-- also when the caller is not VOLATILE, which needs no snapshot of its own
CREATE FUNCTION pc_vh(n int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pc_stv(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN pc_vh(n) * 2; END $$;
SELECT pc_stv(1), pc_stv(2), pc_stv(3);
SELECT pj_expect('pc_stv(int)', 'declined:volatile callee') \gset
CREATE FUNCTION pc_fibv(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n < 2 THEN RETURN n; END IF;
  RETURN pc_fibv(n - 1) + pc_fibv(n - 2);
END $$;
SELECT pc_fibv(10), pc_fibv(10), pc_fibv(15);
SELECT pj_expect('pc_fibv(int)', 'declined:volatile callee') \gset
CREATE FUNCTION pc_helper() RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE 'CREATE OR REPLACE FUNCTION pc_gen() RETURNS int LANGUAGE sql AS $f$ SELECT 41 $f$';
  RETURN 1;
END $$;
CREATE FUNCTION pc_gen() RETURNS int LANGUAGE sql AS 'SELECT 40';
CREATE FUNCTION pc_user(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pc_helper() + n; END $$;
SELECT pc_user(1), pc_user(2);
SELECT pj_expect('pc_user(int)', 'declined:volatile callee') \gset

-- a self-cancel in a function called through a site: the next statement of the
-- caller is where PL/pgSQL notices it
CREATE FUNCTION pc_cancel() RETURNS int LANGUAGE sql STABLE AS
  'SELECT CASE WHEN pg_cancel_backend(pg_backend_pid()) THEN 1 ELSE 0 END';
CREATE FUNCTION pc_sc(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE i int;
BEGIN
  IF n = 0 THEN i := pc_cancel(); END IF;
  RETURN n + 10;
END $$;
SELECT pc_sc(1);
\set VERBOSITY default
SELECT pc_sc(0);  -- fail
SELECT pc_sc(2), pc_sc(3);
SELECT pc_sc(0);  -- fail
\set VERBOSITY terse
SELECT pc_sc(1), pc_sc(2);
SELECT pj_expect('pc_sc(int)', 'compiled') \gset

-- user code ran before an expression that is not planned yet: the function
-- waits in PL/pgSQL, where one call is one run of the callee
CREATE FUNCTION pc_wi(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'callee %', n; RETURN n; END $$;
CREATE FUNCTION pc_wait(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE v int;
BEGIN
  v := pc_wi(n);
  IF n > 100 THEN RETURN v + 1000; END IF;
  RETURN v;
END $$;
SELECT pc_wait(1), pc_wait(2), pc_wait(3);
SELECT pc_wait(200), pc_wait(4), pc_wait(5);
SELECT pj_expect('pc_wait(int)', 'compiled') \gset

-- a STABLE built-in that runs SQL is no leaf: user code may run in it, so a
-- later deopt must not run the effect a second time
CREATE TABLE pc_log (x int);
CREATE FUNCTION pc_side() RETURNS int LANGUAGE plpgsql VOLATILE AS $$
BEGIN INSERT INTO pc_log VALUES (1); RETURN 1; END $$;
CREATE VIEW pc_vw AS SELECT pc_side() AS x;
CREATE FUNCTION pc_ld(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $f$
BEGIN
  IF table_to_xml('pc_vw'::regclass, true, false, '') IS NULL THEN RETURN -1; END IF;
  IF n > 100 THEN RETURN n + 1; END IF;
  RETURN 0;
END $f$;
SELECT pc_ld(1), pc_ld(1), pc_ld(1);
SELECT count(*) AS log_after_three FROM pc_log;
SELECT pc_ld(101);
SELECT count(*) AS log_after_four FROM pc_log;

-- a polymorphic callee read after the function was planned again
CREATE FUNCTION pc_pid(x anyelement) RETURNS anyelement LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pc_prec(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n <= 0 THEN RETURN 0; END IF;
  RETURN pc_pid(pc_prec(n - 1)) + 1;
END $$;
SELECT pc_prec(5), pc_prec(6);
BEGIN;
SELECT pc_prec(7);
DISCARD PLANS;
SELECT pc_prec(8), pc_prec(9);
COMMIT;
SELECT pj_expect('pc_prec(int)', 'compiled') \gset

DROP OWNED BY regress_pj_c;
DROP ROLE regress_pj_c;
