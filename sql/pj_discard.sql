--
-- pj_discard: cache flushes under compiled code
--
-- Expected from plllvm, and run in one variant only: under
-- debug_discard_caches every plan is stale at every evaluation, so the
-- code is left at once and the call runs in PL/pgSQL, with the same result.
-- Nothing may fail, and the code runs again once the flushes stop.
--
SET plllvm.regress_test_mode = on;

CREATE FUNCTION pd_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pd_big(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n * 2; END $$;
SELECT pd_inc(1), pd_inc(2), pd_inc(3), pd_big(1), pd_big(2), pd_big(3);
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_inc(int)') s;

SELECT compiled_calls AS before_compiled FROM plllvm_pj_stats() \gset
SET debug_discard_caches = 1;
SELECT pd_inc(4), pd_inc(5), pd_big(4), pd_big(5);
SELECT pd_inc(6), pd_big(6);
SET debug_discard_caches = 0;
SELECT failures, capped, compiled_calls >= :before_compiled AS compiled_kept,
       guard_misses > 0 AS guarded
  FROM plllvm_pj_stats();

SELECT pd_inc(7), pd_inc(8), pd_big(7), pd_big(8);
SELECT pd_inc(9), pd_inc(10), pd_big(9), pd_big(10);
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_inc(int)') s;
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_big(int)') s;
SELECT failures FROM plllvm_pj_stats();

-- an inlined callee replaced: as stock, with and without flushes
CREATE FUNCTION pd_f2(n int) RETURNS int LANGUAGE sql AS 'SELECT $1';
CREATE FUNCTION pd_h06(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN pd_f2(n); END $$;
SET debug_discard_caches = 1;
SELECT pd_h06(1), pd_h06(2), pd_h06(3);
CREATE OR REPLACE FUNCTION pd_f2(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 100';
SELECT pd_h06(1), pd_h06(2), pd_h06(3);
SET debug_discard_caches = 0;

-- a cast created between calls is seen at once under flushes
CREATE FUNCTION pd_bf(b bool) RETURNS float8 LANGUAGE plpgsql_jit AS $$
BEGIN RETURN b; END $$;
SET debug_discard_caches = 1;
SELECT pd_bf(true);  -- fail
SELECT pd_bf(true);  -- fail
CREATE FUNCTION pd_castf(bool) RETURNS float8 LANGUAGE sql AS 'SELECT 42.5::float8';
CREATE CAST (bool AS float8) WITH FUNCTION pd_castf(bool) AS ASSIGNMENT;
SELECT pd_bf(true), pd_bf(false);
DROP CAST (bool AS float8);
SELECT pd_bf(true);  -- fail
SET debug_discard_caches = 0;

-- a flush while the arguments are evaluated, before the compiled call
CREATE FUNCTION pd_flush(n int) RETURNS int LANGUAGE sql AS $$
SELECT set_config('debug_discard_caches', '1', true)::int + n $$;
SELECT pd_inc(pd_flush(1)), pd_inc(pd_flush(2));
SET debug_discard_caches = 0;
SELECT pd_inc(11), pd_inc(12), pd_inc(13);
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_inc(int)') s;
SELECT failures FROM plllvm_pj_stats();

-- a flush in the middle of a compiled call, by a function labelled
-- IMMUTABLE: the plans of the function are stale for what follows, and the
-- code and its sites go on
CREATE FUNCTION pd_fl(n int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN PERFORM set_config('debug_discard_caches', '1', true); RETURN n; END $$;
CREATE FUNCTION pd_sites(n int) RETURNS int LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN pd_fl(n) + length(n::text) + length((n * 7)::text); END $$;
SET debug_discard_caches = 0;
SELECT pd_sites(g) FROM generate_series(1, 3) g;
SELECT pd_sites(g) FROM generate_series(4, 8) g;
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_sites(int)') s;
SET debug_discard_caches = 0;
SELECT pd_sites(g) FROM generate_series(1, 3) g;
SELECT pd_sites(g) FROM generate_series(9, 12) g;
SELECT s.state, s.last_path FROM plllvm_pj_status('pd_sites(int)') s;
SELECT failures FROM plllvm_pj_stats();
