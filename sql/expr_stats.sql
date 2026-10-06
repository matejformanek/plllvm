--
-- expr_stats: the counters of plllvm_expr_stats() after a loop, in every
-- variant of make installcheck-expr
--
-- Each column is true in every variant, so one expected output fits all of
-- them.  Under debug_discard_caches every evaluation replans and gets a
-- new ExprState, which never reaches its second evaluation, so there only
-- plllvm.expr_eager installs code, from the cache after the first, and
-- the code never runs: the next evaluation has a new ExprState again.
--
LOAD 'plllvm';

CREATE FUNCTION es_loop(n int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE
  s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    s := s + i;
  END LOOP;
  RETURN s;
END
$$;

-- twice: the second call finds the program in the cache
SELECT es_loop(10);
SELECT es_loop(10);

SELECT state = CASE WHEN s.jit THEN 'active' ELSE 'off' END AS state_ok,
       CASE WHEN NOT s.jit THEN installed = 0
            WHEN s.eager OR NOT s.discard THEN installed > 0
            ELSE true
       END AS installed_ok,
       (compiled_evals > 0) = (s.jit AND s.eager AND NOT s.discard)
         AS compiled_evals_ok,
       failures = 0 AS no_failures,
       capped = 0 AS not_capped
  FROM plllvm_expr_stats(),
       (SELECT current_setting('plllvm.expr_jit')::bool AS jit,
               current_setting('plllvm.expr_eager')::bool AS eager,
               current_setting('debug_discard_caches')::int > 0 AS discard) s;

DROP FUNCTION es_loop(int);
