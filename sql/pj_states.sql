--
-- pj_states: how a plpgsql_jit function goes from state to state
--
-- Expected from plllvm, not from stock PL/pgSQL, and run in one variant only.
--
SET plllvm.regress_test_mode = on;

-- the answer for every reason to decline, and the path of each call
CREATE FUNCTION ps_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION ps_if(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN CASE WHEN n > 0 THEN RETURN 1; ELSE RETURN 2; END CASE; END $$;
CREATE FUNCTION ps_decl(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x numeric := n; BEGIN RETURN x; END $$;
CREATE FUNCTION ps_exc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; EXCEPTION WHEN others THEN RETURN 0; END $$;
CREATE FUNCTION ps_text(t text) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN 1; END $$;
CREATE FUNCTION ps_poly(a anyelement) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN 1; END $$;
CREATE FUNCTION ps_cast() RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN '12'::text; END $$;
CREATE FUNCTION ps_rnd() RETURNS float8 LANGUAGE plpgsql_jit AS $$
BEGIN RETURN random() * 0; END $$;
CREATE FUNCTION ps_sub(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN (SELECT n + 1); END $$;
CREATE FUNCTION ps_callee(n int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION ps_user(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN ps_callee(n); END $$;

SELECT ps_inc(1), ps_if(1), ps_decl(1), ps_exc(1), ps_text('a'), ps_poly(1),
       ps_cast(), ps_rnd(), ps_sub(1), ps_user(1);
SELECT p.proname, s.state, s.reason, s.last_path
  FROM pg_proc p, LATERAL plllvm_pj_status(p.oid::regprocedure) s
 WHERE p.proname LIKE 'ps\_%' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql_jit')
 ORDER BY 1;
SELECT ps_inc(1), ps_if(1), ps_decl(1), ps_exc(1), ps_text('a'), ps_poly(1),
       ps_cast(), ps_rnd(), ps_sub(1), ps_user(1);
SELECT p.proname, s.state, s.reason, s.last_path, s.calls, s.compiled_calls,
       s.translations
  FROM pg_proc p, LATERAL plllvm_pj_status(p.oid::regprocedure) s
 WHERE p.proname LIKE 'ps\_%' AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql_jit')
 ORDER BY 1;
-- a declined function keeps no code and no translation
SELECT s.exprs, s.unplanned, s.variants, s.native, s.translate_ms
  FROM plllvm_pj_status('ps_if(int)') s;
-- the compiled one has
SELECT s.exprs, s.unplanned, s.variants, s.native, s.boxed, s.restartable,
       s.translate_ms > 0 AS translate_ms
  FROM plllvm_pj_status('ps_inc(int)') s;
SELECT kind, translate_ms > 0 AS translate_ms, ir_instructions > 0 AS ir
  FROM plllvm_code_cache() WHERE kind = 'pj';
-- the symbol links the code to its function; a declined one has none
SELECT s.symbol IS NOT NULL AS has_symbol,
       (SELECT count(*) FROM plllvm_code_cache() c WHERE c.symbol = s.symbol) AS in_cache
  FROM plllvm_pj_status('ps_inc(int)') s;
SELECT s.symbol IS NULL AS declined_has_none FROM plllvm_pj_status('ps_if(int)') s;
-- the entry polls for interrupts
SELECT plllvm_pj_ir('ps_inc(int)') LIKE '%call void @plllvm_cfi()%' AS polls;
SELECT count(*) AS expr_modules FROM plllvm_code_cache() WHERE kind <> 'pj' AND translate_ms IS NOT NULL;

-- the IR is there for the variant of the session, and NULL otherwise
SELECT plllvm_pj_ir('ps_inc(int)') LIKE 'declare void @plllvm_cfi()%' AS ir,
       plllvm_pj_ir('ps_if(int)') IS NULL AS declined_has_none;

-- the options of the session select another variant of the same harvest
SELECT pj_mark() \gset
SET plllvm.pj_opt_level = 0;
SELECT ps_inc(5);
SELECT s.variants, s.translations, s.last_path FROM plllvm_pj_status('ps_inc(int)') s;
SELECT pj_delta(1, 0, 0, 0, 1);
SET plllvm.pj_opt_level = 3;
SELECT ps_inc(6);
SELECT ps_inc(7);
SELECT s.variants, s.translations, s.last_path FROM plllvm_pj_status('ps_inc(int)') s;
RESET plllvm.pj_opt_level;
SELECT ps_inc(8);
SELECT s.variants, s.translations, s.last_path FROM plllvm_pj_status('ps_inc(int)') s;
SELECT opt_level, kind FROM plllvm_code_cache() WHERE kind = 'pj' AND NOT retired
  AND ir_instructions > 0 ORDER BY gen;

-- a variant that fails to compile is marked, the others run
CREATE FUNCTION ps_mul(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n * 3; END $$;
SELECT ps_mul(1), ps_mul(2);
SET plllvm.pj_opt_level = 1;
SET plllvm.max_ir_instructions = 4;
SELECT ps_mul(3);
SELECT ps_mul(4);
SELECT s.variants, s.last_path FROM plllvm_pj_status('ps_mul(int)') s;
RESET plllvm.max_ir_instructions;
SELECT ps_mul(5);
SELECT s.variants, s.last_path FROM plllvm_pj_status('ps_mul(int)') s;
RESET plllvm.pj_opt_level;
SELECT ps_mul(6);
SELECT s.variants, s.state, s.last_path FROM plllvm_pj_status('ps_mul(int)') s;
SELECT failures FROM plllvm_pj_stats();

-- the first translation fails: the function is declined, with the reason
CREATE FUNCTION ps_big(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 2; END $$;
SELECT ps_big(1);
SET plllvm.max_ir_instructions = 4;
SELECT ps_big(2);
RESET plllvm.max_ir_instructions;
SELECT s.state, s.reason, s.last_path FROM plllvm_pj_status('ps_big(int)') s;
SELECT ps_big(3);
SELECT failures FROM plllvm_pj_stats();

-- an entry point with the wrong type, and a cast over the wrong representation
CREATE FUNCTION ps_sig(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 3; END $$;
SELECT ps_sig(1);
SET plllvm.debug_inject = pj_bad_signature;
SELECT ps_sig(2);
RESET plllvm.debug_inject;
SELECT s.state, s.reason FROM plllvm_pj_status('ps_sig(int)') s;
CREATE FUNCTION ps_rep(n int) RETURNS bigint LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n; END $$;
SELECT ps_rep(1);
SET plllvm.debug_inject = pj_bad_cast_repr;
SELECT ps_rep(2);
RESET plllvm.debug_inject;
SELECT s.state, s.reason FROM plllvm_pj_status('ps_rep(int)') s;
SELECT failures FROM plllvm_pj_stats();

-- the kill switch
SELECT pj_mark() \gset
SET plllvm.plpgsql_jit = off;
SELECT ps_inc(10), ps_mul(10);
SELECT pj_delta(0, 2, 0, 0, 0);
RESET plllvm.plpgsql_jit;
SELECT ps_inc(11), ps_mul(11);
SELECT pj_delta(2, 2, 0, 0, 0);

-- a canceled translation is not a failure, and the next call translates
CREATE FUNCTION ps_cancel(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 4; END $$;
SELECT ps_cancel(1);
SELECT failures AS failures_before FROM plllvm_pj_stats() \gset
SET plllvm.debug_inject = translate_cancel;
SELECT ps_cancel(2);  -- fail
RESET plllvm.debug_inject;
SELECT failures = :failures_before AS no_failure FROM plllvm_pj_stats();
SELECT s.state, s.last_path FROM plllvm_pj_status('ps_cancel(int)') s;
SELECT ps_cancel(3);
SELECT s.state, s.last_path FROM plllvm_pj_status('ps_cancel(int)') s;

-- another plugin in the PL/pgSQL slot: every call runs in PL/pgSQL
SELECT pj_mark() \gset
SET plllvm.debug_inject = foreign_plugin;
SELECT ps_inc(20), ps_inc(21);
RESET plllvm.debug_inject;
SELECT pj_delta(0, 2, 0, 0, 0);
SELECT plugin_fallbacks FROM plllvm_pj_stats();
SELECT ps_inc(22);
SELECT pj_delta(1, 2, 0, 0, 0);

-- replaced, dropped
CREATE OR REPLACE FUNCTION ps_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 100; END $$;
SELECT s.state, s.calls FROM plllvm_pj_status('ps_inc(int)') s;
SELECT ps_inc(1), ps_inc(2), ps_inc(3);
SELECT s.state, s.calls, s.last_path FROM plllvm_pj_status('ps_inc(int)') s;
DROP FUNCTION ps_inc(int);
CREATE FUNCTION ps_inc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 200; END $$;
SELECT s.state, s.calls FROM plllvm_pj_status('ps_inc(int)') s;
SELECT ps_inc(1), ps_inc(2), ps_inc(3);
SELECT s.state, s.calls, s.last_path FROM plllvm_pj_status('ps_inc(int)') s;

-- repeated plan flushes leave nothing behind
CREATE FUNCTION ps_flush(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 5; END $$;
SELECT ps_flush(1), ps_flush(2);
SELECT resident AS resident_before FROM plllvm_pj_stats() \gset
DO $$
BEGIN
  FOR i IN 1..50 LOOP
    DISCARD PLANS;
    PERFORM ps_flush(i);
    PERFORM ps_flush(i);
  END LOOP;
END
$$;
SELECT resident - :resident_before AS resident_growth FROM plllvm_pj_stats();
SELECT s.state, s.last_path FROM plllvm_pj_status('ps_flush(int)') s;

-- flat when a function thrashes: after 8 misses it stays interpreted
CREATE FUNCTION ps_thrash(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 6; END $$;
SELECT ps_thrash(1), ps_thrash(2);
DO $$
BEGIN
  FOR i IN 1..20 LOOP
    DISCARD PLANS;
    PERFORM ps_thrash(i);
    PERFORM ps_thrash(i);
  END LOOP;
END
$$;
SELECT s.state, s.reason, s.guard_misses FROM plllvm_pj_status('ps_thrash(int)') s;

-- the cap on resident compiled functions: no ERROR, the function stays in
-- PL/pgSQL and says so; a later call translates
\c
SET plllvm.max_resident_compiles = 1;
CREATE FUNCTION ps_c1(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION ps_c2(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 2; END $$;
SELECT ps_c1(1), ps_c2(1);
SELECT ps_c1(2), ps_c2(2);
SELECT ps_c1(3), ps_c2(3);
SELECT p.proname, s.state, s.last_path
  FROM pg_proc p, LATERAL plllvm_pj_status(p.oid::regprocedure) s
 WHERE p.proname IN ('ps_c1', 'ps_c2') ORDER BY 1;
SELECT capped, resident, translations, failures FROM plllvm_pj_stats();
SET plllvm.max_resident_compiles = 2;
SELECT ps_c2(4);
SELECT s.state, s.last_path FROM plllvm_pj_status('ps_c2(int)') s;
SELECT capped, resident, translations, failures FROM plllvm_pj_stats();

-- the code a function gives back does not count against the cap
SET plllvm.max_resident_compiles = 2;
DISCARD PLANS;
SELECT ps_c1(5);
SELECT ps_c1(6);
SELECT ps_c1(7);
SELECT s.state, s.last_path FROM plllvm_pj_status('ps_c1(int)') s;
SELECT capped FROM plllvm_pj_stats();

-- a session that cannot start LLVM: the translation fails, the function is
-- declined, and the results are PL/pgSQL's
\c
SET plllvm.types_bc_path = '/nonexistent';
CREATE FUNCTION ps_nobc(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN RETURN n + 7; END $$;
SELECT ps_nobc(1);
SELECT ps_nobc(2);
SELECT ps_nobc(3);
SELECT s.state, left(s.reason, 5) AS sqlstate FROM plllvm_pj_status('ps_nobc(int)') s;
SELECT failures FROM plllvm_pj_stats();

-- parallel: a worker never translates, a function marked PARALLEL SAFE
-- returns what PL/pgSQL returns
\c
CREATE FUNCTION ps_par(n int) RETURNS int LANGUAGE plpgsql_jit PARALLEL SAFE AS $$
BEGIN RETURN n + 8; END $$;
CREATE TABLE ps_big AS SELECT g FROM generate_series(1, 20000) g;
ANALYZE ps_big;
SELECT ps_par(1), ps_par(2), ps_par(3);
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;
SET debug_parallel_query = regress;
SELECT sum(ps_par(g)), count(*) FROM ps_big;
CREATE TABLE ps_ctas AS SELECT ps_par(g) AS v FROM ps_big;
SELECT sum(v), count(*) FROM ps_ctas;
RESET debug_parallel_query;
SELECT sum(ps_par(g)) FROM ps_big;
SELECT s.state FROM plllvm_pj_status('ps_par(int)') s;
DROP TABLE ps_ctas, ps_big;

-- a btree comparator written in plpgsql_jit: it runs under a page lock,
-- where nothing is translated
CREATE FUNCTION ps_cmp(a int, b int) RETURNS int LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN CASE WHEN a < b THEN -1 WHEN a > b THEN 1 ELSE 0 END; END $$;
CREATE FUNCTION ps_cmp2(a int, b int) RETURNS int LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a - b; END $$;
CREATE FUNCTION ps_lt(a int, b int) RETURNS bool LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a < b; END $$;
CREATE FUNCTION ps_le(a int, b int) RETURNS bool LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a <= b; END $$;
CREATE FUNCTION ps_eq(a int, b int) RETURNS bool LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a = b; END $$;
CREATE FUNCTION ps_ge(a int, b int) RETURNS bool LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a >= b; END $$;
CREATE FUNCTION ps_gt(a int, b int) RETURNS bool LANGUAGE plpgsql_jit IMMUTABLE AS $$
BEGIN RETURN a > b; END $$;
CREATE OPERATOR <<< (LEFTARG = int, RIGHTARG = int, FUNCTION = ps_lt, COMMUTATOR = >>>, NEGATOR = >>>=);
CREATE OPERATOR <<<= (LEFTARG = int, RIGHTARG = int, FUNCTION = ps_le, COMMUTATOR = >>>=, NEGATOR = >>>);
CREATE OPERATOR ===  (LEFTARG = int, RIGHTARG = int, FUNCTION = ps_eq, COMMUTATOR = ===);
CREATE OPERATOR >>>= (LEFTARG = int, RIGHTARG = int, FUNCTION = ps_ge, COMMUTATOR = <<<=, NEGATOR = <<<);
CREATE OPERATOR >>> (LEFTARG = int, RIGHTARG = int, FUNCTION = ps_gt, COMMUTATOR = <<<, NEGATOR = <<<=);
CREATE OPERATOR CLASS ps_ops FOR TYPE int USING btree AS
  OPERATOR 1 <<<, OPERATOR 2 <<<=, OPERATOR 3 ===, OPERATOR 4 >>>=, OPERATOR 5 >>>,
  FUNCTION 1 ps_cmp(int, int);
CREATE TABLE ps_idx (a int);
INSERT INTO ps_idx SELECT (g * 7919) % 1000 FROM generate_series(1, 1000) g;
CREATE INDEX ps_idx_a ON ps_idx (a ps_ops);
INSERT INTO ps_idx SELECT (g * 104729) % 1000 FROM generate_series(1, 500) g;
SET enable_seqscan = off;
SELECT count(*), min(a), max(a) FROM ps_idx WHERE a === 7;
SELECT count(*) FROM ps_idx WHERE a <<< 10;
RESET enable_seqscan;
SELECT s.state, s.last_path, s.calls > 1000 AS many_calls FROM plllvm_pj_status('ps_cmp(int,int)') s;
