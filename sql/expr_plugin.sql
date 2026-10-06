--
-- The PL/pgSQL plugin of plllvm.expr_jit: trampolines fire, nothing is
-- compiled yet
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE FUNCTION ep_loop(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    s := s + i;
  END LOOP;
  RETURN s;
END
$$;

-- one evaluation of "x + 1" per call
CREATE FUNCTION ep_once(x int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  RETURN x + 1;
END
$$;

CREATE FUNCTION ep_fired() RETURNS int8 LANGUAGE sql
RETURN (SELECT fired FROM plllvm_expr_stats());

SELECT ep_fired() AS f0 \gset

-- off by default
SELECT state, fired, installed, compiled, declined, failures, capped,
       programs, compiled_evals
  FROM plllvm_expr_stats();
SELECT ep_loop(10);
SELECT ep_fired() = :f0 AS unchanged;

-- superuser only
CREATE ROLE regress_plllvm_expr;
SET ROLE regress_plllvm_expr;
SET plllvm.expr_jit = on;  -- fail
RESET ROLE;
DROP ROLE regress_plllvm_expr;

SET plllvm.expr_jit = on;
SELECT state FROM plllvm_expr_stats();

-- "s := s + i" fires at its second evaluation
SELECT ep_loop(10);
SELECT ep_fired() - :f0 AS fired;

-- at most once per ExprState and transaction
SELECT ep_fired() AS f0 \gset
SELECT ep_loop(1000);
SELECT ep_fired() - :f0 AS fired;

-- an expression evaluated once per transaction never fires
SELECT ep_fired() AS f0 \gset
SELECT ep_once(1);
SELECT ep_once(2);
SELECT ep_fired() - :f0 AS fired;

-- twice in one transaction, it does
BEGIN;
SELECT ep_once(1);
SELECT ep_once(2);
COMMIT;
SELECT ep_fired() - :f0 AS fired;

-- plllvm.expr_eager fires at the first evaluation
SELECT ep_fired() AS f0 \gset
SET plllvm.expr_eager = on;
SELECT ep_once(1);
SELECT ep_fired() - :f0 AS fired;
RESET plllvm.expr_eager;

-- off again: trampolines already installed do not count
SELECT ep_fired() AS f0 \gset
BEGIN;
SELECT ep_once(1);
SET LOCAL plllvm.expr_jit = off;
SELECT ep_once(2);
COMMIT;
SELECT state, ep_fired() - :f0 AS fired FROM plllvm_expr_stats();

-- an ExprState built while off gets no trampoline, even in a function
-- that started while on
CREATE FUNCTION ep_switch() RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  s int := 0;
BEGIN
  FOR i IN 1..3 LOOP
    PERFORM set_config('plllvm.expr_jit',
                       CASE WHEN i = 1 THEN 'off' ELSE 'on' END, true);
    s := s + i;
  END LOOP;
  RETURN s;
END
$$;

SELECT ep_fired() AS f0 \gset
SELECT ep_switch();
SELECT ep_fired() - :f0 AS fired;

-- a parallel worker leaves its expressions alone
CREATE FUNCTION ep_worker(n int) RETURNS TABLE(in_worker bool, fired int8)
LANGUAGE plpgsql PARALLEL SAFE AS $$
BEGIN
  PERFORM ep_loop(n);
  RETURN QUERY
    SELECT pg_backend_pid() <> current_setting('ep.leader')::int,
           s.fired FROM plllvm_expr_stats() s;
END
$$;

SELECT set_config('ep.leader', pg_backend_pid()::text, false) IS NOT NULL;
SET debug_parallel_query = on;
SELECT * FROM ep_worker(10);
RESET debug_parallel_query;
SELECT ep_fired() AS f0 \gset
SELECT in_worker, fired > :f0 AS fired FROM ep_worker(10);

RESET plllvm.expr_jit;
SELECT state FROM plllvm_expr_stats();

DROP FUNCTION ep_worker(int), ep_switch(), ep_fired(), ep_once(int), ep_loop(int);

-- A build that raises an ERROR does so once: without a usable
-- plllvm_types.bc, the session builds nothing more until the path is set.
\c
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;
SET plllvm.types_bc_path = '/nonexistent/plllvm_types.bc';
SET plllvm.expr_jit = on;

CREATE FUNCTION ep_sum(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    s := s + i;
  END LOOP;
  RETURN s;
END
$$;

DO $$
BEGIN
  PERFORM ep_sum(10);
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'first build: %', SQLSTATE;
END
$$;
SELECT ep_sum(10);
SELECT installed, failures FROM plllvm_expr_stats();

RESET plllvm.types_bc_path;
SELECT ep_sum(10);
SELECT installed > 0 AS installed, failures FROM plllvm_expr_stats();

DROP FUNCTION ep_sum(int);
