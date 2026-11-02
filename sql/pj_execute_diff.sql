--
-- pj_execute_diff: where plpgsql_jit checks EXECUTE earlier than PL/pgSQL
--
-- Expected from plllvm, in one variant.  A compiled call builds no ExprState
-- of PL/pgSQL's, and checks EXECUTE for itself whenever the user or the
-- privileges changed, so a privilege lost inside a transaction takes effect at
-- the next call, where PL/pgSQL may keep using its stale state.  Each comment
-- says what PL/pgSQL returns.
--
\set VERBOSITY terse
CREATE ROLE regress_pj_r1;
CREATE ROLE regress_pj_r2;
CREATE ROLE regress_pj_grp;
CREATE ROLE regress_pj_def;
-- compiled call as the owner, then a role: the call checks, the role has no right (stock: 3, the state of the first call)
CREATE FUNCTION n1(a int, b int) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN a / COALESCE(b, 0); END';
SELECT n1(4,2), n1(4,2), n1(4,2);
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
BEGIN;
SELECT n1(4,2) AS su_compiled;
SET ROLE regress_pj_r1;
SELECT n1(6,2) AS n1b_sticky_ok;
SAVEPOINT s; SELECT n1(4,NULL) AS n1b_22012_or_42501; ROLLBACK TO s;
SELECT n1(6,2) AS n1b_stock_denied;
ROLLBACK;
-- as N1b, with the interpreted failure under the role first (stock: 22012 then 3)
BEGIN;
SELECT n1(4,2) AS su_compiled;
SET ROLE regress_pj_r1;
SAVEPOINT s; SELECT n1(4,NULL) AS n1c_22012_or_42501; ROLLBACK TO s;
SELECT n1(6,2) AS n1c_stock_denied;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
-- a compiled failure at one opt level makes the next call under a role without the right check (stock: 3)
CREATE FUNCTION n3(a int, b int) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN a / b; END';
SELECT n3(4,2), n3(4,2), n3(4,2);
SET plllvm.pj_opt_level = 0; SELECT n3(4,2); RESET plllvm.pj_opt_level; 
REVOKE EXECUTE ON FUNCTION int4div(int4,int4) FROM PUBLIC;
BEGIN;
SELECT n3(4,2) AS su;
SET ROLE regress_pj_r1;
SELECT n3(6,2) AS n3_sticky_v2;
RESET ROLE; SET LOCAL plllvm.pj_opt_level = 0; SET ROLE regress_pj_r1;
SELECT n3(6,2) AS n3_sticky_v0;
SAVEPOINT s; SELECT n3(1,0) AS n3_22012; ROLLBACK TO s;
SELECT n3(6,2) AS n3_v0_denied;
RESET ROLE; SET LOCAL plllvm.pj_opt_level = 2; SET ROLE regress_pj_r1;
SELECT n3(6,2) AS n3_stock_denied;
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4,int4) TO PUBLIC;
-- a call under a role that had the right, then the privilege revoked from its group (stock: the value)
CREATE FUNCTION m1(n int) RETURNS bigint LANGUAGE plpgsql_jit AS 'BEGIN RETURN CASE WHEN n > 0 THEN n END; END';
SELECT m1(1), m1(2), m1(3);
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION int8(int4) TO regress_pj_grp;
GRANT regress_pj_grp TO regress_pj_r1;
BEGIN; SET ROLE regress_pj_r1; SELECT m1(1) AS m3a; RESET ROLE; REVOKE EXECUTE ON FUNCTION int8(int4) FROM regress_pj_grp; SET ROLE regress_pj_r1; SELECT m1(2) AS m3_val; SET ROLE regress_pj_r2; SELECT m1(3) AS m3_val2; ROLLBACK;
REVOKE regress_pj_grp FROM regress_pj_r1;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;
-- a SECURITY DEFINER caller reached the function, then the invoker calls it directly (stock: 6)
CREATE FUNCTION d2i(a int) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN a * 3; END';
GRANT EXECUTE ON FUNCTION int4mul(int4,int4) TO PUBLIC;
SELECT d2i(1), d2i(2), d2i(3);
CREATE FUNCTION d2o(a int) RETURNS int LANGUAGE plpgsql SECURITY DEFINER AS 'BEGIN RETURN d2i(a); END';
REVOKE EXECUTE ON FUNCTION int4mul(int4,int4) FROM PUBLIC;
BEGIN; SET ROLE regress_pj_r1; SELECT d2i(1) AS d2_denied_direct; ROLLBACK;
BEGIN; SET ROLE regress_pj_r1; SELECT d2o(1) AS d2_via_definer; SELECT d2i(2) AS d2_sticky; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4mul(int4,int4) TO PUBLIC;
-- a call, SET SESSION AUTHORIZATION to a role without the right (stock: the value)
CREATE FUNCTION sa(a int, b int) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN a % b; END';
SELECT sa(4,3), sa(4,3), sa(4,3);
REVOKE EXECUTE ON FUNCTION int4mod(int4,int4) FROM PUBLIC;
BEGIN; SELECT sa(4,3) AS sa_su; SET SESSION AUTHORIZATION regress_pj_r1; SELECT sa(5,3) AS sa_sticky; RESET SESSION AUTHORIZATION; SAVEPOINT s; SELECT sa(1,0); ROLLBACK TO s; SET SESSION AUTHORIZATION regress_pj_r1; SELECT sa(5,3) AS sa_denied_after_abort; ROLLBACK;
RESET SESSION AUTHORIZATION;
BEGIN; SET ROLE regress_pj_r1; SELECT sa(5,3) AS sa_first_rr_denied; ROLLBACK;
SET ROLE regress_pj_r1; SELECT sa(5,3) AS sa_autocommit_denied; RESET ROLE; SELECT sa(5,3) AS sa_su2;
GRANT EXECUTE ON FUNCTION int4mod(int4,int4) TO PUBLIC;
-- a call as the owner, then a role without the cast (stock: 2)
CREATE FUNCTION f1(n bigint) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN n; END';
CREATE FUNCTION f2(n bigint) RETURNS int LANGUAGE plpgsql_jit AS 'BEGIN RETURN n; END';
SELECT f1(1), f1(2), f1(3), f2(1), f2(2), f2(3);
REVOKE EXECUTE ON FUNCTION int4(int8) FROM PUBLIC;
BEGIN; SELECT f1(1) AS a1; SET ROLE regress_pj_r1; SELECT f1(2) AS a2_stock_value; ROLLBACK;
-- as the case before, with a second function with the same cast (stock: 2)
BEGIN; SELECT f1(1) AS b1; SELECT f2(1) AS b2; SET ROLE regress_pj_r1; SELECT f1(2) AS b3_stock_value; ROLLBACK;
GRANT EXECUTE ON FUNCTION int4(int8) TO PUBLIC;

-- compiled calls, the privilege revoked in the transaction after a call
-- (stock: 111, its ExprState is trusted; here the next call checks)
CREATE FUNCTION pdd_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 1; END $$;
SELECT pdd_inc(1), pdd_inc(2), pdd_inc(3);
BEGIN;
SET ROLE regress_pj_r1;
SELECT pdd_inc(10);
RESET ROLE;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_r1;
SELECT pdd_inc(11);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC;

-- a compiled call, then a role without the function, and a NULL argument
-- (stock: 2 and NULL; the call that runs in PL/pgSQL builds its state then)
CREATE FUNCTION pdd_div(a int, b int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN a / b; END $$;
SELECT pdd_div(4, 2), pdd_div(4, 2), pdd_div(4, 2);
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pdd_div(4, 2);
SET ROLE regress_pj_r1;
SELECT pdd_div(8, 2);  -- fail
ROLLBACK;
BEGIN;
SELECT pdd_div(4, 2);
SET ROLE regress_pj_r1;
SELECT pdd_div(NULL, 2) IS NULL;  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;

-- the cast of two functions with one cast key (stock: 6)
CREATE FUNCTION pdd_c1(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pdd_c2(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; END $$;
SELECT pdd_c1(1), pdd_c1(2), pdd_c1(3), pdd_c2(1), pdd_c2(2), pdd_c2(3);
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN;
SELECT pdd_c1(5);
SET ROLE regress_pj_r1;
SELECT pdd_c2(6);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;

DROP OWNED BY regress_pj_r1, regress_pj_r2, regress_pj_def, regress_pj_grp;
DROP ROLE regress_pj_r1, regress_pj_r2, regress_pj_def, regress_pj_grp;
