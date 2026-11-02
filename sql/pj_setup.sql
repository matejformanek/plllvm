--
-- pj_setup: the helpers of the pj_ tests
--
-- Silent on success, and on stock PL/pgSQL (no plllvm.plpgsql_jit) they do
-- nothing, so a pj_ file has one expected output for plpgsql and plpgsql_jit.
-- Under debug_discard_caches every plan is stale and nothing compiled runs, so
-- they do nothing there either.
--

-- pj_expect: the last_path of fn must be path (plllvm_pj_status); with
-- plllvm.plpgsql_jit off, nothing may have run compiled.  EXECUTE, because
-- stock has no plllvm_pj_ functions.
CREATE FUNCTION pj_expect(fn regprocedure, path text) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  got text;
  n int8;
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NULL
     OR current_setting('debug_discard_caches')::int > 0 THEN
    RETURN;
  END IF;

  IF NOT current_setting('plllvm.plpgsql_jit')::bool THEN
    EXECUTE 'SELECT compiled_calls FROM plllvm_pj_stats()' INTO n;
    IF n <> 0 THEN
      RAISE EXCEPTION 'pj_expect(%): % compiled calls with plllvm.plpgsql_jit off', fn, n;
    END IF;
    RETURN;
  END IF;

  EXECUTE 'SELECT min(last_path) FROM plllvm_pj_status($1)' INTO got USING fn;
  IF got IS DISTINCT FROM path THEN
    RAISE EXCEPTION 'pj_expect(%): expected %, got %', fn, path, got;
  END IF;
END
$$;

-- pj_mark and pj_delta: the change of the counters of plllvm_pj_stats()
-- since the last pj_mark; NULL asserts nothing.  The mark is a GUC, not a
-- temp table: the first temp table of a session changes its search_path,
-- and plans made before it are stale.
CREATE FUNCTION pj_mark() RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NULL
     OR current_setting('debug_discard_caches')::int > 0 THEN
    RETURN;
  END IF;
  EXECUTE $q$SELECT set_config('pj.mark', row_to_json(s)::text, false)
               FROM plllvm_pj_stats() s$q$;
END
$$;

CREATE FUNCTION pj_delta(compiled_calls int8, interpreted_calls int8,
                         boxed_evals int8, deopts int8, translations int8)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  cur jsonb;
  mark jsonb;
  want record;
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NULL
     OR current_setting('debug_discard_caches')::int > 0 THEN
    RETURN;
  END IF;

  mark := current_setting('pj.mark')::jsonb;
  EXECUTE 'SELECT row_to_json(s)::jsonb FROM plllvm_pj_stats() s' INTO cur;
  -- with plllvm.plpgsql_jit off, only that nothing compiled
  FOR want IN
    SELECT k, CASE WHEN current_setting('plllvm.plpgsql_jit')::bool THEN n
                   WHEN k IN ('compiled_calls', 'translations') THEN 0
              END AS n
      FROM (VALUES ('compiled_calls', compiled_calls),
                   ('interpreted_calls', interpreted_calls),
                   ('boxed_evals', boxed_evals),
                   ('deopts', deopts),
                   ('translations', translations)) v(k, n)
  LOOP
    CONTINUE WHEN want.n IS NULL;
    IF (cur->>want.k)::int8 - (mark->>want.k)::int8 <> want.n THEN
      RAISE EXCEPTION 'pj_delta: % changed by %, expected %', want.k,
        (cur->>want.k)::int8 - (mark->>want.k)::int8, want.n;
    END IF;
  END LOOP;
END
$$;
