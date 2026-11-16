--
-- pj_sql: SQL statements of a plpgsql_jit function
--
-- PERFORM, and a statement with no INTO, run in compiled code through SPI, on
-- the plan PL/pgSQL prepared.  Every value, message and CONTEXT is stock
-- PL/pgSQL's.  Rows that name a path (pj_expect) are silent on stock.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE TABLE psq_t (a int PRIMARY KEY, b text, c float8);
INSERT INTO psq_t SELECT i, 'row' || i, i / 2.0 FROM generate_series(1, 20) i;
ANALYZE psq_t;
CREATE TABLE psq_one (a int);
INSERT INTO psq_one VALUES (1);
ANALYZE psq_one;

-- the SQLSTATE, message and context of an error, caught
CREATE FUNCTION psq_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; c text; h text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          c = PG_EXCEPTION_CONTEXT, h = PG_EXCEPTION_HINT;
  RETURN st || ' ' || m || E'\n' || coalesce(h, '') || E'\n' || c;
END $$;

-- a callee that says when it runs
CREATE FUNCTION psq_noisy(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'noisy %', n; RETURN n; END $$;

-- FOUND after PERFORM, and PERFORM of a plain value
CREATE FUNCTION psq_perform(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r text;
BEGIN
  PERFORM 1 FROM psq_t WHERE a = n;
  r := found::text;
  PERFORM 1 FROM psq_t WHERE a > n AND a < n + 3;
  r := r || found::text;
  PERFORM n;
  RETURN r || found::text;
END $$;
SELECT psq_perform(1), psq_perform(19), psq_perform(25);
SELECT psq_perform(1), psq_perform(19), psq_perform(25);
SELECT psq_perform(1), psq_perform(19), psq_perform(25);
SELECT pj_expect('psq_perform(integer)', 'compiled') \gset

-- a callee that is not VOLATILE is allowed, and runs once per statement
CREATE FUNCTION psq_callee(n int) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM psq_noisy(n);
  PERFORM psq_noisy(n + 1) FROM psq_one;
  RETURN 'done';
END $$;
SELECT psq_callee(1);
SELECT psq_callee(2);
SELECT psq_callee(3);
SELECT pj_expect('psq_callee(integer)', 'compiled') \gset

-- an error inside the statement has SPI's line above PL/pgSQL's
CREATE FUNCTION psq_err(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 / n FROM psq_one;
  RETURN n;
END $$;
SELECT psq_err(1), psq_err(2);
SELECT psq_err(1), psq_err(2);
SELECT psq_try('SELECT psq_err(0)');
SELECT psq_try('SELECT psq_err(0)');
SELECT psq_err(3);
SELECT pj_expect('psq_err(integer)', 'compiled') \gset

-- PERFORM of a SELECT INTO creates the table, and PL/pgSQL says so
CREATE FUNCTION psq_selinto(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM n INTO psq_made;
  RETURN n;
END $$;
SELECT psq_try('SELECT psq_selinto(1)');
SELECT psq_try('SELECT psq_selinto(2)');
SELECT psq_try('SELECT psq_selinto(3)');
SELECT to_regclass('psq_made');

-- a statement with no INTO may return no tuples: a SELECT may not
CREATE FUNCTION psq_noint(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN
    SELECT n;
  END IF;
  RETURN n;
END $$;
SELECT psq_noint(0), psq_noint(0);
SELECT psq_noint(0), psq_noint(0);
SELECT psq_try('SELECT psq_noint(1)');
SELECT psq_try('SELECT psq_noint(1)');
SELECT psq_noint(0);
SELECT pj_expect('psq_noint(integer)', 'compiled') \gset

-- what the parameters carry: every kind of variable the statement reads
CREATE FUNCTION psq_vars(v_i int, v_b bigint, v_f float8, v_t text, v_ok bool,
                         v_arr int[], v_n numeric) RETURNS text
LANGUAGE :pj_lang AS $$
DECLARE r text := '';
BEGIN
  PERFORM 1 FROM psq_t WHERE a <= v_i AND a::bigint <= v_b AND c <= v_f
    AND b <> v_t AND v_ok AND a = ANY (v_arr) AND a::numeric <= v_n;
  r := r || found::text;
  PERFORM 1 FROM psq_t WHERE a = v_arr[1] AND b = v_t;
  r := r || found::text;
  PERFORM count(*) FROM psq_t;
  r := r || found::text;
  v_t := v_t || '!';
  PERFORM 1 FROM psq_t WHERE b = v_t;
  RETURN r || found::text;
END $$;
SELECT psq_vars(5, 5, 2.5, 'row9', true, ARRAY[1, 5, 9], 5.5),
       psq_vars(3, 9, 9.5, 'row3', true, ARRAY[3], 4),
       psq_vars(5, 5, 2.5, 'row9', false, ARRAY[1, 5, 9], 5.5);
SELECT psq_vars(5, 5, 2.5, 'row9', true, ARRAY[1, 5, 9], 5.5),
       psq_vars(3, 9, 9.5, 'row3', true, ARRAY[3], 4),
       psq_vars(5, 5, 2.5, 'row9', false, ARRAY[1, 5, 9], 5.5);
SELECT psq_vars(5, 5, 2.5, 'row9', true, ARRAY[1, 5, 9], 5.5),
       psq_vars(3, 9, 9.5, 'row3', true, ARRAY[3], 4),
       psq_vars(5, 5, 2.5, 'row9', false, ARRAY[1, 5, 9], 5.5);
SELECT pj_expect('psq_vars(integer,bigint,double precision,text,boolean,integer[],numeric)', 'compiled') \gset

-- a loop variable, a local and FOUND are parameters too
CREATE FUNCTION psq_locals(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE hit int := 0; s text := 'row';
BEGIN
  FOR i IN 1..n LOOP
    PERFORM 1 FROM psq_t WHERE a = i AND b = s || i;
    IF found THEN hit := hit + 1; END IF;
    PERFORM 1 WHERE found;
    IF found THEN hit := hit + 10; END IF;
  END LOOP;
  RETURN hit::text;
END $$;
SELECT psq_locals(5), psq_locals(25);
SELECT psq_locals(5), psq_locals(25);
SELECT psq_locals(5), psq_locals(25);
SELECT pj_expect('psq_locals(integer)', 'compiled') \gset

-- variable_conflict: error and use_variable are compiled, use_column is not
CREATE FUNCTION psq_conf_error(a int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_t WHERE psq_t.a = psq_conf_error.a;
  RETURN found;
END $$;
CREATE FUNCTION psq_conf_amb(a int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_t WHERE a = 1;
  RETURN found;
END $$;
CREATE FUNCTION psq_conf_var(a int) RETURNS bool LANGUAGE :pj_lang AS $$
#variable_conflict use_variable
BEGIN
  PERFORM 1 FROM psq_t WHERE a = 1;
  RETURN found;
END $$;
CREATE FUNCTION psq_conf_col(a int) RETURNS bool LANGUAGE :pj_lang AS $$
#variable_conflict use_column
BEGIN
  PERFORM 1 FROM psq_t WHERE a = 1;
  RETURN found;
END $$;
SELECT psq_conf_error(1), psq_conf_error(30);
SELECT psq_conf_error(1), psq_conf_error(30);
SELECT psq_conf_error(1), psq_conf_error(30);
SELECT psq_try('SELECT psq_conf_amb(1)');
SELECT psq_try('SELECT psq_conf_amb(1)');
SELECT psq_conf_var(1), psq_conf_var(30);
SELECT psq_conf_var(1), psq_conf_var(30);
SELECT psq_conf_var(1), psq_conf_var(30);
SELECT psq_conf_col(1), psq_conf_col(30);
SELECT psq_conf_col(1), psq_conf_col(30);
SELECT psq_conf_col(1), psq_conf_col(30);
SELECT pj_expect('psq_conf_error(integer)', 'compiled') \gset
SELECT pj_expect('psq_conf_var(integer)', 'compiled') \gset
SELECT pj_expect('psq_conf_col(integer)', 'declined:variable_conflict') \gset

-- plan identity: the custom and generic plans of the statement are PL/pgSQL's,
-- so a call that PL/pgSQL runs and one that we run count towards the same
-- five custom plans.  Planning 1 / n for n = 0 raises, a generic plan does not.
CREATE FUNCTION psq_g3(n int, h int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 / n FROM psq_t WHERE false;
  RETURN found;
END $$;
-- h NULL goes to PL/pgSQL
SELECT psq_g3(1, NULL), psq_g3(1, 1), psq_g3(1, NULL), psq_g3(1, 1), psq_g3(1, NULL);
SELECT psq_g3(0, 1);
CREATE FUNCTION psq_g3b(n int, h int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 / n FROM psq_t WHERE false;
  RETURN found;
END $$;
SELECT psq_g3b(1, 1);
SELECT psq_g3b(1, 1);
SELECT psq_g3b(1, 1);
SELECT psq_g3b(1, 1);
SELECT psq_g3b(1, 1);
SELECT psq_g3b(0, 1);
CREATE FUNCTION psq_g3c(n int, h int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 / n FROM psq_t WHERE false;
  RETURN found;
END $$;
SELECT psq_g3c(1, NULL), psq_g3c(1, 1), psq_g3c(1, 1), psq_g3c(1, NULL), psq_g3c(1, 1);
SELECT psq_g3c(0, 1);
-- the controls: custom plans always raise, generic plans never
CREATE FUNCTION psq_g3d(n int, h int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 / n FROM psq_t WHERE false;
  RETURN found;
END $$;
SET plan_cache_mode = force_custom_plan;
SELECT psq_g3d(1, 1), psq_g3d(1, NULL), psq_g3d(1, 1);
SELECT psq_g3d(0, 1);
SET plan_cache_mode = force_generic_plan;
SELECT psq_g3d(0, 1);
RESET plan_cache_mode;
SELECT pj_expect('psq_g3(integer,integer)', 'compiled') \gset

-- a statement with no parameter has no parameter list: its plan is generic,
-- made once, and a stable function in it runs at planning once
CREATE FUNCTION psq_quiet() RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'planning or running'; RETURN 1; END $$;
CREATE FUNCTION psq_np() RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM count(*) FROM psq_one WHERE a = psq_quiet();
  RETURN found;
END $$;
SELECT psq_np();
SELECT psq_np();
SELECT psq_np();
SELECT psq_np();
SELECT psq_np();
SELECT psq_np();
SELECT pj_expect('psq_np()', 'compiled') \gset

-- what happens to the plan between calls changes no value, and no call leaves
-- the compiled code: SPI plans again by itself
CREATE TABLE psq_b1 (a int, b text);
INSERT INTO psq_b1 SELECT i, 'v' || i FROM generate_series(1, 50) i;
ANALYZE psq_b1;
CREATE FUNCTION psq_b1(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_b1 WHERE a = n;
  RETURN found;
END $$;
SELECT psq_b1(1), psq_b1(2);
SELECT psq_b1(1), psq_b1(2);
SELECT psq_b1(1), psq_b1(2);
SELECT pj_expect('psq_b1(integer)', 'compiled') \gset
SELECT pj_mark() \gset
-- TRUNCATE and ANALYZE: the plan is invalid at the next call
TRUNCATE psq_b1;
SELECT psq_b1(1), psq_b1(2);
INSERT INTO psq_b1 SELECT i, 'v' || i FROM generate_series(1, 50) i;
ANALYZE psq_b1;
SELECT psq_b1(1), psq_b1(2);
-- an index changes the plan
CREATE INDEX psq_b1_a ON psq_b1 (a);
SELECT psq_b1(1), psq_b1(2);
ANALYZE psq_b1;
SELECT psq_b1(3), psq_b1(99);
DISCARD PLANS;
SELECT psq_b1(3), psq_b1(99);
DROP INDEX psq_b1_a;
SELECT psq_b1(3), psq_b1(99);
SELECT pj_expect('psq_b1(integer)', 'compiled') \gset
SELECT pj_delta(12, 0, NULL, 0, 0);

-- a column added or a table replaced: the next call goes on, or says why not
ALTER TABLE psq_b1 ADD COLUMN c int DEFAULT 7;
SELECT psq_b1(3), psq_b1(99);
ALTER TABLE psq_b1 DROP COLUMN b;
SELECT psq_b1(3), psq_b1(99);
SELECT psq_b1(3), psq_b1(99);
SELECT pj_expect('psq_b1(integer)', 'compiled') \gset
-- a column the statement names goes
CREATE FUNCTION psq_b1c(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_b1 WHERE c = n;
  RETURN found;
END $$;
SELECT psq_b1c(7), psq_b1c(8);
SELECT psq_b1c(7), psq_b1c(8);
SELECT psq_b1c(7), psq_b1c(8);
ALTER TABLE psq_b1 RENAME COLUMN c TO d;
SELECT psq_try('SELECT psq_b1c(7)');
SELECT psq_try('SELECT psq_b1c(7)');
ALTER TABLE psq_b1 RENAME COLUMN d TO c;
SELECT psq_b1c(7), psq_b1c(8);
SELECT psq_b1c(7), psq_b1c(8);

-- the callee changes between calls: a VOLATILE one is not admitted
CREATE FUNCTION psq_vol(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'vol %', n; RETURN n; END $$;
CREATE FUNCTION psq_use_vol(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_one WHERE a = psq_vol(n);
  RETURN found;
END $$;
SELECT psq_use_vol(1), psq_use_vol(2);
SELECT psq_use_vol(1), psq_use_vol(2);
SELECT psq_use_vol(1), psq_use_vol(2);
SELECT pj_expect('psq_use_vol(integer)', 'compiled') \gset
SELECT pj_mark() \gset
ALTER FUNCTION psq_vol(int) VOLATILE;
SELECT psq_use_vol(1), psq_use_vol(2);
-- neither call ran the statement compiled
SELECT pj_delta(0, 2, NULL, 0, NULL, NULL, 0);
SELECT psq_use_vol(1), psq_use_vol(2);
SELECT pj_expect('psq_use_vol(integer)', 'declined:volatile callee') \gset

-- a view redefined between calls
CREATE VIEW psq_v AS SELECT a, b FROM psq_t WHERE a < 10;
CREATE FUNCTION psq_view(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_v WHERE a = n;
  RETURN found;
END $$;
SELECT psq_view(5), psq_view(15);
SELECT psq_view(5), psq_view(15);
SELECT psq_view(5), psq_view(15);
CREATE OR REPLACE VIEW psq_v AS SELECT a, b FROM psq_t WHERE a < 18;
SELECT psq_view(5), psq_view(15);
SELECT psq_view(5), psq_view(15);
CREATE OR REPLACE VIEW psq_v AS SELECT a, b FROM psq_t WHERE a < 10 AND psq_vol(a) > 0;
SELECT psq_view(5), psq_view(15);
SELECT psq_view(5), psq_view(15);
SELECT psq_view(5), psq_view(15);
SELECT pj_expect('psq_view(integer)', 'declined:volatile callee') \gset

-- tenants: the same name resolves to another callee after a search_path change
CREATE SCHEMA psq_a;
CREATE SCHEMA psq_b;
CREATE FUNCTION psq_a.callee(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'a %', n; RETURN n; END $$;
CREATE FUNCTION psq_b.callee(n int) RETURNS int LANGUAGE plpgsql VOLATILE AS $$
BEGIN RAISE NOTICE 'b %', n; RETURN n; END $$;
CREATE FUNCTION psq_tenant(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_one WHERE a = callee(n);
  RETURN found;
END $$;
SET search_path = psq_a, public;
SELECT psq_tenant(1), psq_tenant(2);
SELECT psq_tenant(1), psq_tenant(2);
SELECT psq_tenant(1), psq_tenant(2);
SELECT pj_expect('psq_tenant(integer)', 'compiled') \gset
SET search_path = psq_b, public;
SELECT psq_tenant(1), psq_tenant(2);
SELECT psq_tenant(1), psq_tenant(2);
SELECT psq_tenant(1), psq_tenant(2);
SELECT pj_expect('psq_tenant(integer)', 'declined:volatile callee') \gset
SET search_path = public;
DROP SCHEMA psq_a CASCADE;
DROP SCHEMA psq_b CASCADE;

-- admission: set_config is volatile and not admitted; a sequence function is
CREATE FUNCTION psq_cfg(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM set_config('psq.x', n::text, false);
  RETURN n;
END $$;
SELECT psq_cfg(1), psq_cfg(2);
SELECT psq_cfg(1), psq_cfg(2);
SELECT psq_cfg(3);
SELECT current_setting('psq.x');
SELECT pj_expect('psq_cfg(integer)', 'declined:volatile callee') \gset
CREATE SEQUENCE psq_s;
CREATE FUNCTION psq_seq(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  PERFORM nextval('psq_s');
  PERFORM nextval('psq_s') FROM generate_series(1, n);
  RETURN n;
END $$;
SELECT psq_seq(1), psq_seq(2);
SELECT psq_seq(1), psq_seq(2);
SELECT psq_seq(3);
SELECT last_value FROM psq_s;
SELECT pj_expect('psq_seq(integer)', 'compiled') \gset

-- statements that write are not compiled, and are as PL/pgSQL runs them: a
-- plain command, and a data-modifying CTE on a table with a trigger
CREATE TABLE psq_trg (a int, b text);
INSERT INTO psq_trg SELECT i, 'x' FROM generate_series(1, 5) i;
CREATE FUNCTION psq_trg_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', old.a; RETURN old; END $$;
CREATE TRIGGER psq_trg_d BEFORE DELETE ON psq_trg
  FOR EACH ROW EXECUTE FUNCTION psq_trg_fn();
CREATE FUNCTION psq_cte(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  WITH d AS (DELETE FROM psq_trg WHERE a = n RETURNING *) SELECT count(*) FROM d;
  RETURN n;
END $$;
SELECT psq_try('SELECT psq_cte(1)');
SELECT psq_try('SELECT psq_cte(2)');
SELECT psq_try('SELECT psq_cte(3)');
SELECT count(*) FROM psq_trg;
SELECT pj_expect('psq_cte(integer)', 'declined:statement:SQL statement') \gset
CREATE FUNCTION psq_dml(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  UPDATE psq_trg SET b = 'y' WHERE a = n;
  RETURN n;
END $$;
SELECT psq_dml(4), psq_dml(5);
SELECT psq_dml(4), psq_dml(5);
SELECT psq_dml(4), psq_dml(5);
SELECT pj_expect('psq_dml(integer)', 'declined:statement:SQL statement') \gset
SELECT * FROM psq_trg ORDER BY a;

-- privileges are the executor's: a table, and a callee, taken away
CREATE ROLE regress_psq_u;
CREATE TABLE psq_priv (a int);
INSERT INTO psq_priv VALUES (1), (2);
CREATE FUNCTION psq_gone(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION psq_def(n int) RETURNS int LANGUAGE plpgsql STABLE SECURITY DEFINER AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION psq_priv(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_priv WHERE a = n;
  RETURN found;
END $$;
CREATE FUNCTION psq_priv_fn(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM psq_gone(n);
  PERFORM psq_def(n);
  RETURN true;
END $$;
GRANT SELECT ON psq_priv TO regress_psq_u;
GRANT EXECUTE ON FUNCTION psq_priv(int), psq_priv_fn(int), psq_def(int) TO regress_psq_u;
SET ROLE regress_psq_u;
SELECT psq_priv(1), psq_priv(3), psq_priv_fn(1);
SELECT psq_priv(1), psq_priv(3), psq_priv_fn(1);
SELECT psq_priv(1), psq_priv(3), psq_priv_fn(1);
RESET ROLE;
SELECT pj_expect('psq_priv(integer)', 'compiled') \gset
REVOKE SELECT ON psq_priv FROM regress_psq_u;
REVOKE EXECUTE ON FUNCTION psq_gone(int) FROM PUBLIC;
SET ROLE regress_psq_u;
SELECT psq_try('SELECT psq_priv(1)');
SELECT psq_try('SELECT psq_priv(1)');
SELECT psq_try('SELECT psq_priv_fn(1)');
SELECT psq_try('SELECT psq_priv_fn(1)');
RESET ROLE;
GRANT SELECT ON psq_priv TO regress_psq_u;
SET ROLE regress_psq_u;
SELECT psq_priv(1), psq_priv(3);
SELECT psq_priv(1), psq_priv(3);
RESET ROLE;

-- a statement not planned yet leaves the call to PL/pgSQL, with nothing run
-- twice: the NOTICEs are the callee's, and a call compiled before the branch
-- was reached would repeat them
CREATE FUNCTION psq_wait(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0;
BEGIN
  FOR i IN 1..n LOOP s := s + i; END LOOP;
  PERFORM psq_noisy(s);
  IF n > 100 THEN
    PERFORM psq_noisy(n) FROM psq_one;
  END IF;
  RETURN s;
END $$;
SELECT psq_wait(3);
SELECT psq_wait(3);
SELECT psq_wait(3);
SELECT pj_expect('psq_wait(integer)', 'waiting') \gset
SELECT pj_mark() \gset
SELECT psq_wait(200);
SELECT psq_wait(200);
SELECT psq_wait(3);
SELECT psq_wait(200);
SELECT pj_expect('psq_wait(integer)', 'compiled') \gset
SELECT pj_delta(NULL, NULL, NULL, 0, NULL);

-- recursion through a statement: the frames are each their own
CREATE FUNCTION psq_rec(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  IF n > 0 THEN
    PERFORM psq_rec(n - 1);
  END IF;
  RETURN n;
END $$;
SELECT psq_rec(3), psq_rec(4);
SELECT psq_rec(20), psq_rec(3);
SELECT psq_rec(20), psq_rec(3);
SELECT pj_expect('psq_rec(integer)', 'compiled') \gset

-- a cancel inside the statement is SPI's, and the call is left as stock's
CREATE FUNCTION psq_sleep(n float8) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM pg_sleep(n);
  RETURN 1;
END $$;
SELECT psq_sleep(0), psq_sleep(0.001);
SELECT psq_sleep(0), psq_sleep(0.001);
SET statement_timeout = '100ms';
SELECT psq_sleep(5);
RESET statement_timeout;
SELECT psq_sleep(0);
SELECT pj_expect('psq_sleep(double precision)', 'compiled') \gset

-- the tuple tables go with each statement: memory read inside the loop does
-- not grow with the number of statements run
CREATE FUNCTION psq_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;
CREATE FUNCTION psq_loop(n int, probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE m bigint := 0;
BEGIN
  FOR i IN 1..n LOOP
    PERFORM 1 FROM psq_t WHERE a > i % 20;
    IF i = probe THEN m := psq_mem(); END IF;
  END LOOP;
  RETURN m;
END $$;
SELECT psq_loop(3, 1) > 0, psq_loop(3, 2) > 0;
SELECT psq_loop(3, 1) > 0, psq_loop(3, 2) > 0;
SELECT psq_loop(3, 1) > 0, psq_loop(3, 2) > 0;
SELECT psq_loop(1000, 1000) AS m1 \gset
SELECT psq_loop(20000, 20000) - :m1 < 262144 AS flat;
SELECT pj_expect('psq_loop(integer,integer)', 'compiled') \gset

-- parallel query inside a statement: the parameters of the list are serialized
-- (PERFORM fetches all rows, so the plan may use workers)
CREATE TABLE psq_big AS
  SELECT i AS a, 'text' || (i % 7) AS b FROM generate_series(1, 20000) i;
ANALYZE psq_big;
CREATE FUNCTION psq_par(n int, t text) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM 1 FROM psq_big WHERE a < n AND b <> t;
  RETURN found;
END $$;
CREATE FUNCTION psq_workers() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE w bigint;
BEGIN
  PERFORM pg_stat_force_next_flush();
  SELECT parallel_workers_launched INTO w FROM pg_stat_database WHERE datname = current_database();
  RETURN w;
END $$;
SET debug_parallel_query = regress;
SELECT psq_par(100, 'text3'), psq_par(1, 'text3');
SELECT psq_par(100, 'text3'), psq_par(1, 'text3');
SELECT psq_workers() AS w0 \gset
SELECT psq_par(100, 'text3'), psq_par(1, 'text3');
SELECT psq_workers() - :w0 >= 2 AS launched;
RESET debug_parallel_query;
SELECT pj_expect('psq_par(integer,text)', 'compiled') \gset
