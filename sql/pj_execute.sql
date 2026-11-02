--
-- pj_execute: the EXECUTE right on what compiled code calls
--
-- PL/pgSQL checks it when it builds the ExprState, the first time in a
-- transaction, and again after an error in that expression.  Not run under
-- debug_discard_caches, where every evaluation builds one.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE ROLE regress_pj_guard;
CREATE FUNCTION pjx_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pjx_div(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN a / b; END $$;
SELECT pjx_inc(1), pjx_inc(2), pjx_inc(3), pjx_div(4, 2), pjx_div(4, 2), pjx_div(4, 2);
SELECT pj_expect('pjx_inc(int)', 'compiled') \gset

-- inside a transaction: once the ExprState exists, the revoke is not seen
SELECT pjx_inc(1);
BEGIN;
SET ROLE regress_pj_guard;
SELECT pjx_inc(10);
RESET ROLE;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_guard;
SELECT pjx_inc(11);
RESET ROLE;
COMMIT;
SET ROLE regress_pj_guard;
SELECT pjx_inc(12);  -- fail
RESET ROLE;
GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC;
BEGIN;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_guard;
SELECT pjx_inc(13);  -- fail
ROLLBACK;
SELECT pjx_inc(14);
SET ROLE regress_pj_guard;
SELECT pjx_inc(15);
RESET ROLE;
SELECT pj_expect('pjx_inc(int)', 'compiled') \gset

-- an error in the expression: PL/pgSQL builds the ExprState again
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pjx_div(4, 2);
SAVEPOINT s;
SELECT pjx_div(1, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_guard;
-- PL/pgSQL adds a context line for the expression it evaluated in an
-- ExprState that failed, until the transaction ends
\set VERBOSITY terse
SELECT pjx_div(6, 2);  -- fail
\set VERBOSITY default
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
SELECT pj_expect('pjx_div(int,int)', 'interpreted:execute') \gset

-- a cast the first call did not reach, a role without it, a call that does
CREATE FUNCTION pjx_a(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN RETURN CASE WHEN n > 0 THEN n END; END $$;
SELECT pjx_a(1), pjx_a(2), pjx_a(3);
SELECT pj_expect('pjx_a(int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
BEGIN;
SELECT pjx_a(-1) IS NULL;
SET ROLE regress_pj_guard;
SELECT pjx_a(1);  -- fail
ROLLBACK;
GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC;

-- an expression aborted by the interpreter: it is checked at every evaluation
CREATE FUNCTION pjx_b(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN a / COALESCE(b, 0); END $$;
SELECT pjx_b(4, 2), pjx_b(4, 2), pjx_b(4, 2);
SELECT pj_expect('pjx_b(int,int)', 'compiled') \gset
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pjx_b(4, 2);
SAVEPOINT s;
SELECT pjx_b(4, NULL);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_guard;
\set VERBOSITY terse
SELECT pjx_b(6, 2);  -- fail
\set VERBOSITY default
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;

DROP ROLE regress_pj_guard;
