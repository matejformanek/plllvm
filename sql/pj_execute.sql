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
CREATE FUNCTION pjg_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pjg_div(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN a / b; END $$;
SELECT pjg_inc(1), pjg_inc(2), pjg_inc(3), pjg_div(4, 2), pjg_div(4, 2), pjg_div(4, 2);
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- inside a transaction: once the ExprState exists, the revoke is not seen
SELECT pjg_inc(1);
BEGIN;
SET ROLE regress_pj_guard;
SELECT pjg_inc(10);
RESET ROLE;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_guard;
SELECT pjg_inc(11);
RESET ROLE;
COMMIT;
SET ROLE regress_pj_guard;
SELECT pjg_inc(12);  -- fail
RESET ROLE;
GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC;
BEGIN;
REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC;
SET ROLE regress_pj_guard;
SELECT pjg_inc(13);  -- fail
ROLLBACK;
SELECT pjg_inc(14);
SET ROLE regress_pj_guard;
SELECT pjg_inc(15);
RESET ROLE;
SELECT pj_expect('pjg_inc(int)', 'compiled') \gset

-- an error in the expression: PL/pgSQL builds the ExprState again
REVOKE EXECUTE ON FUNCTION int4div(int4, int4) FROM PUBLIC;
BEGIN;
SELECT pjg_div(4, 2);
SAVEPOINT s;
SELECT pjg_div(1, 0);  -- fail
ROLLBACK TO s;
SET ROLE regress_pj_guard;
-- PL/pgSQL adds a context line for the expression it evaluated in an
-- ExprState that failed, until the transaction ends
\set VERBOSITY terse
SELECT pjg_div(6, 2);  -- fail
\set VERBOSITY default
ROLLBACK;
GRANT EXECUTE ON FUNCTION int4div(int4, int4) TO PUBLIC;
SELECT pj_expect('pjg_div(int,int)', 'interpreted:execute') \gset

DROP ROLE regress_pj_guard;
