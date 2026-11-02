--
-- pj_execute_diff: where plpgsql_jit checks EXECUTE earlier than PL/pgSQL
--
-- Expected from plllvm, in one variant.  A compiled call builds no
-- ExprState, so a later call that PL/pgSQL runs, here because of a NULL
-- argument, builds it then and checks the right of the user it runs as.
-- PL/pgSQL would have built it at the first call of the transaction, and
-- returns what the comments say.
--
CREATE ROLE regress_pj_diff;
CREATE FUNCTION pdd_div(a int, b int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN a / b; END $$;
CREATE FUNCTION pdd_c1(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pdd_c2(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; END $$;
SELECT pdd_div(4, 2), pdd_div(4, 2), pdd_div(4, 2);
SELECT pdd_c1(1), pdd_c1(2), pdd_c1(3), pdd_c2(1), pdd_c2(2), pdd_c2(3);

REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pdd_div(4, 2);
SET ROLE regress_pj_diff;
SELECT pdd_div(NULL, 2) IS NULL;  -- PL/pgSQL: true
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;

-- the cast of two functions is one cached expression, checked by each
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN;
SELECT pdd_c1(5);
SET ROLE regress_pj_diff;
SELECT pdd_c2(6);  -- PL/pgSQL: 6
ROLLBACK;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;

DROP ROLE regress_pj_diff;
