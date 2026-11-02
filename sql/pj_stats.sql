--
-- pj_stats: the counters of plllvm_pj_stats() and plllvm_pj_status() after
-- calls of a plpgsql_jit function, in every variant of make installcheck-pj
--
-- Counters are per backend and pg_regress starts one per file, so the numbers
-- are exact.  Each column is true in every variant: plllvm.plpgsql_jit and
-- debug_discard_caches change what a correct run looks like.  The second call
-- translates the function and the others run its code, unless the plpgsql_jit
-- is off, or every plan is stale, as under debug_discard_caches: then no call
-- runs compiled, and the calls wait for a plan they can use.
--
LOAD 'plllvm';

CREATE FUNCTION ps_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  RETURN n + 1;
END
$$;

SELECT pj_mark() \gset
SELECT ps_inc(1);
SELECT ps_inc(2);
SELECT ps_inc(3);
SELECT ps_inc(4);
SELECT pj_delta(3, 1, 0, 0, 1) \gset
SELECT pj_expect('ps_inc(int)', 'compiled') \gset

SELECT calls = 4 AS calls_ok,
       calls = compiled_calls + deopts + interpreted_calls AS balanced,
       (compiled_calls > 0) = s.compiles AS compiled_ok,
       translations = s.compiles::int AND attempts = translations AND
         resident = translations AS translated_ok,
       declines + guard_misses + null_args + plugin_fallbacks + capped +
       failures + deopts + boxed_evals + peak_tuple_bytes = 0 AS rest_ok
  FROM plllvm_pj_stats(),
       (SELECT current_setting('plllvm.plpgsql_jit')::bool AND
               current_setting('debug_discard_caches')::int = 0 AS compiles) s;

-- an entry exists only for a call that went through the handler's own
-- compile: with the kill switch off there is none
SELECT count(*) = current_setting('plllvm.plpgsql_jit')::bool::int AS entries_ok,
       coalesce(bool_and(CASE WHEN s.compiles THEN
                  state = 'compiled' AND reason IS NULL AND calls = 4 AND
                  compiled_calls = 3 AND translations = 1 AND
                  last_path = 'compiled' AND exprs = 1 AND unplanned = 0 AND
                  variants = 1 AND native AND NOT boxed AND restartable
                ELSE
                  state = 'seen' AND calls = 4 AND compiled_calls = 0 AND
                  translations = 0 AND last_path = 'interpreted:unplanned' AND
                  exprs IS NULL AND native IS NULL END),
                NOT current_setting('plllvm.plpgsql_jit')::bool) AS status_ok
  FROM plllvm_pj_status('ps_inc(int)'),
       (SELECT current_setting('plllvm.plpgsql_jit')::bool AND
               current_setting('debug_discard_caches')::int = 0 AS compiles) s;

-- the entry goes with the definition
CREATE OR REPLACE FUNCTION ps_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  RETURN n + 2;
END
$$;
SELECT ps_inc(1);
SELECT count(*) = current_setting('plllvm.plpgsql_jit')::bool::int AS entries_ok,
       coalesce(bool_and(state = 'seen' AND calls = 1),
                NOT current_setting('plllvm.plpgsql_jit')::bool) AS fresh_ok
  FROM plllvm_pj_status('ps_inc(int)');

DROP FUNCTION ps_inc(int);
