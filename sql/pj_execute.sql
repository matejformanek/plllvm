--
-- pj_execute: the EXECUTE right on what compiled code calls
--
-- PL/pgSQL checks it when it builds the ExprState, the first time in a
-- transaction, and again after an error in that expression.  Compiled code
-- must never be more permissive; where it is stricter the sequence is in
-- pj_execute_diff.  Not run under debug_discard_caches, where every
-- evaluation builds an ExprState.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

\set VERBOSITY terse
CREATE ROLE regress_pj_r1;
CREATE ROLE regress_pj_r2;
CREATE ROLE regress_pj_def;
CREATE ROLE regress_pj_grp;
-- a cast the first call did not reach, then a role without it
CREATE FUNCTION xa(n int) RETURNS bigint LANGUAGE :pj_lang AS 'BEGIN RETURN CASE WHEN n > 0 THEN n END; END';
SELECT xa(1), xa(2), xa(3);
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN; SELECT xa(-1) IS NULL; SET ROLE regress_pj_r1; SELECT xa(1) AS xa_expect_denied; ROLLBACK;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;
-- an expression the interpreter aborted, then a role without the function
CREATE FUNCTION xb(a int, b int) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN a / COALESCE(b, 0); END';
SELECT xb(4,2), xb(4,2), xb(4,2);
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
BEGIN; SELECT xb(4,2); SAVEPOINT s; SELECT xb(4,NULL); ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT xb(6,2) AS xb_expect_denied; ROLLBACK;
-- the interpreter built the state as another user; an abort; a role without the function
CREATE FUNCTION n1(a int, b int) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN a / COALESCE(b, 0); END';
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
SELECT n1(4,2), n1(4,2), n1(4,2);
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
BEGIN;
SELECT n1(NULL,NULL) IS NULL AS built_by_su;
SET ROLE regress_pj_r1;
SELECT n1(6,2) AS n1_sticky_ok;
SAVEPOINT s; SELECT n1(4,NULL) AS n1_22012; ROLLBACK TO s;
SELECT n1(6,2) AS n1_stock_denied;
ROLLBACK;
-- the same, with the privilege lost in the transaction
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
BEGIN;
SET ROLE regress_pj_r1;
SELECT n1(NULL,NULL) IS NULL AS built_by_rr;
RESET ROLE;
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
SET ROLE regress_pj_r1;
SELECT n1(6,2) AS n1d_sticky_ok;
SAVEPOINT s; SELECT n1(4,NULL) AS n1d_22012; ROLLBACK TO s;
SELECT n1(6,2) AS n1d_stock_denied;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
-- a cast that failed in another function with its cast key
CREATE FUNCTION n2f(n bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN n; END';
CREATE FUNCTION n2g(n bigint) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN n; END';
SELECT n2f(1), n2f(2), n2f(3);
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN;
SELECT n2f(1) AS su_ok;
SAVEPOINT s; SELECT n2g(99999999999) AS n2g_22003; ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT n2f(2) AS n2_stock_denied;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;
-- a cast that failed in an interpreted call of the function itself
CREATE FUNCTION n2b(n bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN COALESCE(n, 99999999999); END';
SELECT n2b(1), n2b(2), n2b(3);
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN;
SELECT n2b(1) AS su_ok;
SAVEPOINT s; SELECT n2b(NULL) AS n2b_22003; ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT n2b(2) AS n2b_stock_denied;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;
-- a membership lost in the transaction, the cast not reached
CREATE FUNCTION m1(n int) RETURNS bigint LANGUAGE :pj_lang AS 'BEGIN RETURN CASE WHEN n > 0 THEN n END; END';
SELECT m1(1), m1(2), m1(3);
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION int8(int4) TO regress_pj_grp;
GRANT regress_pj_grp TO regress_pj_r1;
BEGIN; SET ROLE regress_pj_r1; SELECT m1(-1) IS NULL AS m1a; RESET ROLE; REVOKE regress_pj_grp FROM regress_pj_r1; SET ROLE regress_pj_r1; SELECT m1(1) AS m1_denied; ROLLBACK;
-- a privilege revoked from the group in the transaction, the cast not reached
BEGIN; SET ROLE regress_pj_r1; SELECT m1(-1) IS NULL AS m2a; RESET ROLE; REVOKE EXECUTE ON FUNCTION int8(int4) FROM regress_pj_grp; SET ROLE regress_pj_r1; SELECT m1(1) AS m2_denied; ROLLBACK;
-- a savepoint that undoes the REVOKE, and the role
BEGIN; SAVEPOINT a; REVOKE EXECUTE ON FUNCTION int8(int4) FROM regress_pj_grp; SET ROLE regress_pj_r1; SAVEPOINT b; SELECT m1(1) AS m4_denied; ROLLBACK TO a; SET ROLE regress_pj_r1; SELECT m1(2) AS m4_ok; ROLLBACK;
REVOKE regress_pj_grp FROM regress_pj_r1; GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC; REVOKE EXECUTE ON FUNCTION int8(int4) FROM regress_pj_grp;
-- SECURITY DEFINER whose owner lost the right
CREATE FUNCTION d1(a int, b int) RETURNS int LANGUAGE :pj_lang SECURITY DEFINER AS 'BEGIN RETURN a * b; END';
SELECT d1(1,2), d1(1,2), d1(1,2);
REVOKE EXECUTE ON FUNCTION int4mul(int4,int4) FROM PUBLIC;
SET ROLE regress_pj_r1; SELECT d1(3,4) AS d1_su_definer; RESET ROLE;
ALTER FUNCTION d1(int,int) OWNER TO regress_pj_def;
SELECT d1(3,4) AS d1_denied;
SELECT d1(3,4) AS d1_denied2;
BEGIN; SET ROLE regress_pj_r1; SELECT d1(3,4) AS d1_denied3; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mul(int4,int4) TO regress_pj_def;
SELECT d1(3,4), d1(3,4), d1(3,4);
GRANT EXECUTE ON FUNCTION int4mul(int4,int4) TO PUBLIC;
-- DISCARD PLANS inside the transaction
CREATE FUNCTION dp(a int) RETURNS bigint LANGUAGE :pj_lang AS 'BEGIN RETURN a * 2; END';
SELECT dp(1), dp(2), dp(3);
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;
REVOKE EXECUTE ON FUNCTION int4mul(int4,int4) FROM PUBLIC;
BEGIN; SELECT dp(1) AS dp_su; DISCARD PLANS; SET ROLE regress_pj_r1; SELECT dp(2) AS dp_denied; ROLLBACK;
BEGIN; SELECT dp(1) AS dp_su; DISCARD PLANS; SELECT dp(2) AS dp_su2; SET ROLE regress_pj_r1; SELECT dp(3) AS dp_sticky; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mul(int4,int4) TO PUBLIC;
-- a caller with an exception block around a failing call
CREATE FUNCTION ne(a int, b int) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN a / COALESCE(b,0); END';
SELECT ne(4,2), ne(4,2), ne(4,2);
CREATE FUNCTION nec(a int, b int) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN ne(a,b)::text; EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
SELECT nec(4,2) AS nec_su_none;
BEGIN; SELECT ne(NULL,NULL) IS NULL AS built; SET ROLE regress_pj_r1; SELECT nec(6,2) AS nec_val; SELECT nec(6,NULL) AS nec_22012; SELECT nec(6,2) AS nec_stock_42501; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
-- the first call after translation, then a role without the function
CREATE FUNCTION fc(a int) RETURNS bigint LANGUAGE :pj_lang AS 'BEGIN RETURN a + 7; END';
REVOKE EXECUTE ON FUNCTION int4pl(int4,int4) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN; SELECT fc(1) AS fc1; SET ROLE regress_pj_r1; SELECT fc(2) AS fc2_sticky; SELECT fc(3) AS fc3_sticky; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4pl(int4,int4) TO PUBLIC;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;
-- a cast that failed in a function with the same cast key
CREATE FUNCTION f1(n bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN n; END';
CREATE FUNCTION f2(n bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN n; END';
SELECT f1(1), f1(2), f1(3), f2(1), f2(2), f2(3);
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN; SELECT f1(1) AS su; SELECT f2(1) AS su2; SAVEPOINT s; SELECT f2(99999999999) AS f2_22003; ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT f1(2) AS n2c_stock_denied; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;
-- a SECURITY DEFINER wrapper that builds, a caller that catches
CREATE FUNCTION g(a int, b int) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN a / COALESCE(b, 0); END';
SELECT g(4,2), g(4,2), g(4,2);
CREATE FUNCTION g_def() RETURNS bool LANGUAGE plpgsql SECURITY DEFINER AS 'BEGIN RETURN g(NULL, NULL) IS NULL; END';
CREATE FUNCTION g_c(a int, b int) RETURNS text LANGUAGE plpgsql AS $$ BEGIN RETURN g(a,b)::text; EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
SET ROLE regress_pj_r1;
SELECT g_c(6,2) AS rr_alone_denied;
BEGIN; SELECT g_def() AS definer_built; SELECT g_c(6,2) AS v1; SELECT g_c(6,NULL) AS e1; SELECT g_c(6,2) AS n1e_stock_42501; ROLLBACK;
RESET ROLE;
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;

REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
-- a call as the owner, then a role without the cast
BEGIN; SELECT f1(1) AS a1; SET ROLE regress_pj_r1; SELECT f1(2) AS a2_stock_value; ROLLBACK;
-- the same, with a second function with the same cast
BEGIN; SELECT f1(1) AS b1; SELECT f2(1) AS b2; SET ROLE regress_pj_r1; SELECT f1(2) AS b3_stock_value; ROLLBACK;
-- a cast that failed in another function, a role without the cast
BEGIN; SELECT f1(1) AS c1; SAVEPOINT s; SELECT f2(99999999999) AS c2; ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT f1(2) AS c3_stock_denied; ROLLBACK;
-- a cast that failed in the function itself, a role without the cast
BEGIN; SELECT f1(1) AS d1; SAVEPOINT s; SELECT f1(99999999999) AS d2; ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT f1(2) AS d3_stock_denied; ROLLBACK;
-- a plain plpgsql function with the same cast key failed
CREATE FUNCTION g(n bigint) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN n; END';
BEGIN; SELECT f1(1) AS e1; SAVEPOINT s; SELECT g(99999999999) AS e2; ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT f1(2) AS e3_stock_denied; ROLLBACK;
-- a failed cast, a rolled-back savepoint, the other function
BEGIN; SELECT f1(1) AS f1; SAVEPOINT s; SELECT f2(99999999999) AS f2; ROLLBACK TO s; SET ROLE regress_pj_r1; SELECT f1(2) AS f3_stock_denied; ROLLBACK;


-- an expression that failed in compiled code, and a cast that failed in PL/pgSQL
CREATE FUNCTION pc_div(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN a / COALESCE(b, 0); END $$;
CREATE FUNCTION pf_div(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN COALESCE(a, 1) / COALESCE(b, 1); END $$;
CREATE FUNCTION pe_cast(a bigint, b bigint) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN COALESCE(a, b); END $$;
CREATE FUNCTION pe_plain(x bigint) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RETURN x; END $$;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
SELECT pc_div(4, 2), pc_div(4, 2), pc_div(4, 2), pf_div(4, 2), pf_div(4, 2), pf_div(4, 2);
SELECT pe_cast(1, 1), pe_cast(2, 2), pe_cast(3, 3);
SELECT pj_expect('pc_div(int,int)', 'compiled') \gset
SELECT pj_expect('pf_div(int,int)', 'compiled') \gset
SELECT pj_expect('pe_cast(bigint,bigint)', 'declined:cast') \gset
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO regress_pj_r2;
-- interpreted build, a failure in compiled code, a role without the function
BEGIN;
SELECT pc_div(NULL, NULL) IS NULL;
SAVEPOINT s;
SELECT pc_div(1, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT pc_div(6, 2);  -- fail
ROLLBACK;
-- the same, with a role that may execute it in between
BEGIN;
SAVEPOINT s;
SELECT pc_div(1, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r2;
SELECT pc_div(NULL, NULL) IS NULL;
SET ROLE regress_pj_r1;
SELECT pc_div(6, 2);  -- fail
ROLLBACK;
-- both operands defaulted
BEGIN;
SELECT pf_div(NULL, NULL);
SAVEPOINT s;
SELECT pf_div(1, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT pf_div(NULL, 2);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
-- a cast that failed, and a plain function with its cast key
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN;
SELECT pe_plain(1);
SELECT pe_cast(NULL, 1);
SAVEPOINT s;
SELECT pe_cast(99999999999, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT pe_cast(5, 0);  -- fail
ROLLBACK;
BEGIN;
SELECT pe_cast(NULL, 1);
SAVEPOINT s;
SELECT pe_cast(99999999999, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT pe_plain(2);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;

-- a DO block reaches the cast key between a failure and a role without the cast
CREATE FUNCTION da_f(a bigint, b bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN COALESCE(a, b); END';
CREATE FUNCTION da_pl(x bigint) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN x; END';
SELECT da_f(1,1), da_f(2,2), da_f(3,3);
SELECT pj_expect('da_f(bigint,bigint)', 'declined:cast') \gset
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN;
SELECT da_pl(1);
SAVEPOINT s;
SELECT da_pl(99999999999);  -- fail
ROLLBACK TO s;
DO $$ DECLARE b bigint := 1; BEGIN FOR i IN b..b LOOP NULL; END LOOP; END $$;
SET ROLE regress_pj_r1;
SELECT da_pl(2);  -- fail
ROLLBACK;
BEGIN;
SELECT da_f(NULL, 1);
SAVEPOINT s;
SELECT da_f(99999999999, 0);  -- fail
ROLLBACK TO s;
DO $$ DECLARE b bigint := 1; BEGIN FOR i IN b..b LOOP NULL; END LOOP; END $$;
SET ROLE regress_pj_r1;
SELECT da_f(5, 0);  -- fail
ROLLBACK;
BEGIN;
SELECT da_pl(1);
SAVEPOINT s;
SELECT da_f(99999999999, 0);  -- fail
ROLLBACK TO s;
DO $$ DECLARE x int; BEGIN SELECT 1::bigint INTO x; END $$;
SET ROLE regress_pj_r1;
SELECT da_pl(2);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;

-- plain plpgsql functions stay what they are after a failure of ours
CREATE SCHEMA pjx_s;
CREATE TABLE pjx_s.t(x int);
INSERT INTO pjx_s.t VALUES (1);
GRANT SELECT ON pjx_s.t TO regress_pj_r1;
CREATE FUNCTION pjx_gq() RETURNS int LANGUAGE plpgsql AS 'DECLARE r int; BEGIN SELECT x INTO r FROM pjx_s.t; RETURN r; END';
CREATE FUNCTION pjx_hb(x float8) RETURNS money LANGUAGE plpgsql AS 'BEGIN RETURN x; END';
CREATE FUNCTION pjx_pd(a int, b int) RETURNS int LANGUAGE plpgsql AS 'BEGIN RETURN a / b; END';
CREATE FUNCTION pjx_inn(a int) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN a + 1; END';
CREATE FUNCTION pjx_fail(n bigint) RETURNS int LANGUAGE :pj_lang AS 'BEGIN RETURN n; END';
SELECT pjx_gq() AS as_su;
SET ROLE regress_pj_r1;
SELECT pjx_gq() AS as_role;
RESET ROLE;
SELECT pjx_fail(99999999999);  -- fail
SET ROLE regress_pj_r1;
SELECT pjx_gq() AS as_role_again;
RESET ROLE;
SELECT pjx_hb(5) AS io;
CREATE CAST (float8 AS money) WITHOUT FUNCTION AS ASSIGNMENT;
SELECT pjx_hb(5) AS stale;
SELECT pjx_fail(99999999999);  -- fail
SELECT pjx_hb(5) AS stale_after_failure;
DROP CAST (float8 AS money);
SELECT pjx_inn(1), pjx_inn(2), pjx_inn(3);
SELECT pjx_pd(4, 2), pjx_pd(4, 2);
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pjx_pd(4, 2);
SAVEPOINT s;
SELECT pjx_fail(99999999999);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_r1;
SELECT pjx_pd(8, 2);
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
-- an innocent compiled function, with failing neighbours in a loop
CREATE FUNCTION pjx_many() RETURNS int LANGUAGE plpgsql AS $$
DECLARE n int := 0; x int;
BEGIN
  FOR i IN 1..30 LOOP
    BEGIN PERFORM pjx_fail(99999999999); EXCEPTION WHEN numeric_value_out_of_range THEN n := n + 1; END;
    x := pjx_inn(i); x := pjx_inn(i); x := pjx_inn(i);
  END LOOP;
  RETURN n;
END $$;
SELECT pjx_many();
SELECT pj_expect('pjx_inn(int)', 'compiled') \gset
DROP SCHEMA pjx_s CASCADE;

-- a branch the call did not reach, then a role without its function: the
-- call is PL/pgSQL's, which raises only if it reaches the branch
CREATE FUNCTION pg_if(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN RETURN n + 1; ELSE RETURN n * 2; END IF;
END $$;
SELECT pg_if(1), pg_if(2), pg_if(-1), pg_if(-2), pg_if(3), pg_if(-3);
REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC;
BEGIN; SELECT pg_if(1); SET ROLE regress_pj_r1; SELECT pg_if(-1) AS pg_if_expect_denied; ROLLBACK;
BEGIN; SET ROLE regress_pj_r1; SELECT pg_if(1) AS pg_if_unreached; SELECT pg_if(-1) AS pg_if_expect_denied; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC;
SELECT pg_if(1), pg_if(-1);
SELECT pj_expect('pg_if(int)', 'compiled') \gset

-- an error in the branch, caught, then a role without the function
CREATE FUNCTION ph_f(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF a > 100 THEN RETURN a / b; END IF;
  RETURN a * b;
END $$;
SELECT ph_f(200, 2), ph_f(1, 2), ph_f(200, 2), ph_f(1, 2);
BEGIN; SELECT ph_f(200, 2); SAVEPOINT s; SELECT ph_f(200, 0) AS ph_22012; ROLLBACK TO s; SELECT ph_f(200, 2); ROLLBACK;
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN; SELECT ph_f(200, 2); SAVEPOINT s; SELECT ph_f(200, 0) AS ph_22012; ROLLBACK TO s;
SET ROLE regress_pj_r1; SELECT ph_f(200, 2) AS ph_expect_denied; ROLLBACK;
BEGIN; SET ROLE regress_pj_r1; SELECT ph_f(1, 2) AS ph_unreached; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;

-- the cast of a NULL is checked as any other: the conversion of a NULL
-- constant in a declaration, and of a NULL bound of a FOR
CREATE FUNCTION pn_decl() RETURNS int8 LANGUAGE :pj_lang AS $$
DECLARE x int8 := NULL::int4;
BEGIN RETURN x; END $$;
SELECT pn_decl() IS NULL, pn_decl() IS NULL, pn_decl() IS NULL;
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN; SET ROLE regress_pj_r1; SELECT pn_decl() AS pn_decl_expect_denied; ROLLBACK;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;
SELECT pn_decl() IS NULL;
SELECT pj_expect('pn_decl()', 'compiled') \gset
CREATE FUNCTION pn_for() RETURNS int LANGUAGE :pj_lang AS $$
DECLARE n int := 0;
BEGIN
  FOR i IN NULL::bigint..3 LOOP n := n + 1; END LOOP;
  RETURN n;
END $$;
SELECT pn_for();  -- fail
SELECT pn_for();  -- fail
SELECT pn_for();  -- fail
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN; SET ROLE regress_pj_r1; SELECT pn_for() AS pn_for_expect_denied; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;
SELECT pn_for();  -- fail

-- the hash function of a hashed IN list is checked when PL/pgSQL builds the
-- expression, in the first transaction that reaches it
CREATE FUNCTION pxs_in(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN n IN (1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11); END $$;
SELECT pxs_in(1), pxs_in(2), pxs_in(3);
REVOKE EXECUTE ON FUNCTION hashint4(int4) FROM PUBLIC;
BEGIN; SET ROLE regress_pj_r1; SELECT pxs_in(1) AS pxs_in_expect_denied; ROLLBACK;
BEGIN; SELECT pxs_in(1) AS pxs_in_su; ROLLBACK;
GRANT EXECUTE ON FUNCTION hashint4(int4) TO PUBLIC;
SELECT pxs_in(1), pxs_in(20);
SELECT pj_expect('pxs_in(int)', 'compiled') \gset

-- a function dropped by a callee in the middle of a call, not reached by this
-- call: nothing is denied, and the call that reaches it fails as before
CREATE FUNCTION pxd_h(n int) RETURNS int LANGUAGE sql STABLE AS 'SELECT n + 1 FROM generate_series(1, 1)';
CREATE FUNCTION pxd_v(f int) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN IF f > 0 THEN EXECUTE 'DROP FUNCTION pxd_h(int)'; END IF; RETURN 0; END $$;
CREATE FUNCTION pxd_s(f int) RETURNS int LANGUAGE plpgsql STABLE AS $$ BEGIN RETURN pxd_v(f); END $$;
CREATE FUNCTION pxd_c(n int, f int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int;
BEGIN
  i := pxd_s(f);
  IF n > 100 THEN RETURN pxd_h(n); END IF;
  RETURN n;
END $$;
SET ROLE regress_pj_r1;
SELECT pxd_c(200, 0), pxd_c(1, 0), pxd_c(200, 0), pxd_c(1, 0), pxd_c(200, 0);
RESET ROLE;
SELECT pj_expect('pxd_c(int,int)', 'compiled') \gset
SET ROLE regress_pj_r1;
BEGIN;
SELECT pxd_c(1, 1) AS pxd_unreached;
ROLLBACK;
BEGIN;
SAVEPOINT s;
SELECT pxd_c(200, 1) AS pxd_reached;  -- fail
ROLLBACK TO s;
ROLLBACK;
RESET ROLE;

-- the I/O functions of a conversion are not checked by PL/pgSQL, so a role
-- without them runs the call too
CREATE FUNCTION pxs_io(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN length(n::text) + n; END $$;
SELECT pxs_io(1), pxs_io(22), pxs_io(333);
REVOKE EXECUTE ON FUNCTION int4out(int4) FROM PUBLIC;
BEGIN; SET ROLE regress_pj_r1; SELECT pxs_io(4444) AS pxs_io_ok; ROLLBACK;
SET ROLE regress_pj_r1;
SELECT pxs_io(5), pxs_io(66);
RESET ROLE;
SELECT pj_expect('pxs_io(int)', 'compiled') \gset
GRANT EXECUTE ON FUNCTION int4out(int4) TO PUBLIC;

DROP OWNED BY regress_pj_r1, regress_pj_r2, regress_pj_def, regress_pj_grp;
DROP ROLE regress_pj_r1, regress_pj_r2, regress_pj_def, regress_pj_grp;
