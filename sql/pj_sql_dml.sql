--
-- pj_sql_dml: INSERT, UPDATE and DELETE of a plpgsql_jit function, through SPI
--
-- A command that writes, and a RETURNING into scalars, run in compiled code on
-- the plan PL/pgSQL prepared, if no trigger, rule, cascade or partition of the
-- table they write is code that compiled code cannot see.  Every value, FOUND,
-- message and CONTEXT is stock PL/pgSQL's, and so is each table afterwards.
-- Rows that name a path (pj_expect) are silent on stock.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE TABLE psd_t (a int PRIMARY KEY, b text, c int DEFAULT 7) WITH (autovacuum_enabled = false);
INSERT INTO psd_t SELECT i, 'row' || i, i FROM generate_series(1, 6) i;
ANALYZE psd_t;
-- the table, printed after a call
\set dt 'SELECT coalesce(string_agg(x::text, '' '' ORDER BY x.a), ''-'') AS psd_t FROM psd_t x'

-- the SQLSTATE, message, hint and context of an error, caught
CREATE FUNCTION psd_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; c text; h text; d text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          c = PG_EXCEPTION_CONTEXT, h = PG_EXCEPTION_HINT,
                          d = PG_EXCEPTION_DETAIL;
  RETURN st || ' ' || m || E'\n' || coalesce(d, '') || E'\n'
         || coalesce(h, '') || E'\n' || c;
END $$;

-- FOUND after each command, and the table
CREATE FUNCTION psd_found(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r text;
BEGIN
  INSERT INTO psd_t VALUES (n, 'new' || n, DEFAULT);
  r := found::text;
  UPDATE psd_t SET b = 'upd' WHERE a = n;
  r := r || found::text;
  UPDATE psd_t SET b = 'upd' WHERE a = n + 1000;
  r := r || found::text;
  DELETE FROM psd_t WHERE a = n;
  r := r || found::text;
  DELETE FROM psd_t WHERE a = n;
  r := r || found::text;
  INSERT INTO psd_t SELECT 5000, 'x', 1 WHERE false;
  r := r || found::text;
  INSERT INTO psd_t VALUES (1, 'dup', 1) ON CONFLICT DO NOTHING;
  r := r || found::text;
  INSERT INTO psd_t VALUES (2, 'dup', 1) ON CONFLICT (a) DO UPDATE SET c = psd_t.c + 100;
  RETURN r || found::text;
END $$;
SELECT psd_found(10);
:dt;
SELECT psd_found(11);
:dt;
SELECT psd_found(12);
:dt;
SELECT psd_found(13);
:dt;
SELECT pj_expect('psd_found(integer)', 'compiled') \gset

-- a function that is not VOLATILE may not write: SPI's error, the table unchanged
CREATE FUNCTION psd_stable(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
BEGIN
  INSERT INTO psd_t VALUES (n, 'stable', 0);
  RETURN n;
END $$;
SELECT psd_try('SELECT psd_stable(50)');
SELECT psd_try('SELECT psd_stable(51)');
SELECT psd_try('SELECT psd_stable(52)');
:dt;
-- the error came from SPI, in compiled code
SELECT pj_expect('psd_stable(integer)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT psd_try('SELECT psd_stable(53)');
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 1);

-- a serial column: the default is nextval(), a pinned built-in; RETURNING INTO
CREATE TABLE psd_s (id serial PRIMARY KEY, v text, w int DEFAULT 5);
\set ds 'SELECT coalesce(string_agg(x::text, '' '' ORDER BY x.id), ''-'') AS psd_s FROM psd_s x'
CREATE FUNCTION psd_serial(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int;
BEGIN
  INSERT INTO psd_s (v) VALUES ('s' || n) RETURNING id INTO i;
  RETURN i;
END $$;
SELECT psd_serial(1);
:ds;
SELECT psd_serial(2);
:ds;
SELECT psd_serial(3);
:ds;
SELECT psd_serial(4);
:ds;
SELECT pj_expect('psd_serial(integer)', 'compiled') \gset

-- a foreign key: the check of the row inserted is internal code, and so is the
-- restriction on the table it points to
CREATE TABLE psd_p (id int PRIMARY KEY);
INSERT INTO psd_p VALUES (1), (2), (3);
CREATE TABLE psd_c (id serial PRIMARY KEY, pid int REFERENCES psd_p);
\set dc 'SELECT coalesce(string_agg(x::text, '' '' ORDER BY x.id), ''-'') AS psd_c FROM psd_c x'
CREATE FUNCTION psd_fk(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int;
BEGIN
  INSERT INTO psd_c (pid) VALUES (n) RETURNING id INTO i;
  RETURN i;
END $$;
CREATE FUNCTION psd_fk_del(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE c bigint;
BEGIN
  DELETE FROM psd_p WHERE id = n;
  SELECT count(*) INTO c FROM psd_p;
  RETURN c;
END $$;
SELECT psd_fk(1);
:dc;
SELECT psd_fk(2);
:dc;
SELECT psd_fk(2);
:dc;
SELECT psd_try('SELECT psd_fk(9)');
:dc;
SELECT psd_try('SELECT psd_fk_del(1)');
SELECT psd_try('SELECT psd_fk_del(3)');
SELECT psd_try('SELECT psd_fk_del(3)');
SELECT psd_try('SELECT psd_fk_del(1)');
SELECT id FROM psd_p ORDER BY id;
SELECT pj_expect('psd_fk(integer)', 'compiled') \gset
SELECT pj_expect('psd_fk_del(integer)', 'compiled') \gset

-- RESTRICT is a check too, and so is a deferrable unique constraint
CREATE TABLE psd_pr (id int PRIMARY KEY);
INSERT INTO psd_pr SELECT i FROM generate_series(1, 5) i;
CREATE TABLE psd_cr (id serial PRIMARY KEY,
                     pid int REFERENCES psd_pr ON DELETE RESTRICT ON UPDATE RESTRICT);
INSERT INTO psd_cr (pid) VALUES (1);
CREATE FUNCTION psd_restrict(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  DELETE FROM psd_pr WHERE id = n;
  UPDATE psd_pr SET id = id + 100 WHERE id = n + 1;
  RETURN n;
END $$;
SELECT psd_restrict(2);
SELECT psd_restrict(3);
SELECT psd_restrict(4);
SELECT psd_try('SELECT psd_restrict(0)');
SELECT psd_try('SELECT psd_restrict(1)');
SELECT id FROM psd_pr ORDER BY id;
SELECT pj_expect('psd_restrict(integer)', 'compiled') \gset
CREATE TABLE psd_u (a int, UNIQUE (a) DEFERRABLE INITIALLY IMMEDIATE);
CREATE FUNCTION psd_uniq(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_u VALUES (n);
  RETURN n;
END $$;
SELECT psd_uniq(1);
SELECT psd_uniq(2);
SELECT psd_uniq(3);
SELECT psd_try('SELECT psd_uniq(2)');
SELECT * FROM psd_u ORDER BY a;
SELECT pj_expect('psd_uniq(integer)', 'compiled') \gset

-- the table a statement writes decides: a cascade, a trigger, a rule, a
-- partitioned table, children.  Each is PL/pgSQL's, with its own effects.
CREATE TABLE psd_pc (id int PRIMARY KEY);
INSERT INTO psd_pc SELECT i FROM generate_series(1, 6) i;
CREATE TABLE psd_cc (id serial PRIMARY KEY, pid int REFERENCES psd_pc ON DELETE CASCADE);
INSERT INTO psd_cc (pid) SELECT i % 6 + 1 FROM generate_series(1, 12) i;
\set dcc 'SELECT (SELECT count(*) FROM psd_pc) AS parents, (SELECT count(*) FROM psd_cc) AS children'
CREATE FUNCTION psd_casc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  DELETE FROM psd_pc WHERE id = n;
  RETURN n;
END $$;
SELECT psd_casc(1);
:dcc;
SELECT psd_casc(2);
:dcc;
SELECT psd_casc(3);
:dcc;
SELECT psd_casc(4);
:dcc;
SELECT pj_expect('psd_casc(integer)', 'declined:relation:cascade') \gset

CREATE TABLE psd_tr (a int, b text);
CREATE FUNCTION psd_tr_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; new.b := new.b || '!'; RETURN new; END $$;
CREATE TRIGGER psd_tr_i BEFORE INSERT ON psd_tr
  FOR EACH ROW EXECUTE FUNCTION psd_tr_fn();
CREATE FUNCTION psd_trg(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_tr VALUES (n, 'x');
  RETURN n;
END $$;
SELECT psd_trg(1);
SELECT psd_trg(2);
SELECT psd_trg(3);
SELECT psd_trg(4);
SELECT * FROM psd_tr ORDER BY a;
SELECT pj_expect('psd_trg(integer)', 'declined:relation:trigger') \gset

CREATE TABLE psd_ru (a int);
CREATE TABLE psd_ru_log (a int);
CREATE RULE psd_ru_r AS ON INSERT TO psd_ru DO ALSO INSERT INTO psd_ru_log VALUES (new.a * 10);
CREATE FUNCTION psd_rule(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_ru VALUES (n);
  RETURN n;
END $$;
SELECT psd_rule(1);
SELECT psd_rule(2);
SELECT psd_rule(3);
SELECT psd_rule(4);
SELECT * FROM psd_ru ORDER BY a;
SELECT * FROM psd_ru_log ORDER BY a;
SELECT pj_expect('psd_rule(integer)', 'declined:relation:rule') \gset

CREATE TABLE psd_pt (a int, b text) PARTITION BY RANGE (a);
CREATE TABLE psd_pt1 PARTITION OF psd_pt FOR VALUES FROM (0) TO (100);
CREATE TABLE psd_pt2 PARTITION OF psd_pt FOR VALUES FROM (100) TO (200);
CREATE FUNCTION psd_part(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_pt VALUES (n, 'p');
  UPDATE psd_pt SET b = 'q' WHERE a = n;
  RETURN n;
END $$;
SELECT psd_part(1);
SELECT psd_part(101);
SELECT psd_part(2);
SELECT psd_part(102);
SELECT tableoid::regclass, * FROM psd_pt ORDER BY a;
SELECT pj_expect('psd_part(integer)', 'declined:relation:partitioned') \gset

CREATE TABLE psd_inh (a int, b text);
CREATE TABLE psd_inh_c (c int) INHERITS (psd_inh);
INSERT INTO psd_inh VALUES (1, 'parent');
INSERT INTO psd_inh_c VALUES (2, 'child', 0);
CREATE FUNCTION psd_inhf(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  UPDATE psd_inh SET b = b || '+' WHERE a >= n;
  RETURN n;
END $$;
SELECT psd_inhf(1);
SELECT psd_inhf(2);
SELECT psd_inhf(1);
SELECT psd_inhf(2);
SELECT tableoid::regclass, * FROM psd_inh ORDER BY a;
SELECT pj_expect('psd_inhf(integer)', 'declined:relation:inheritance') \gset
-- a child with no children of its own is a table like any other
CREATE FUNCTION psd_inhc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  UPDATE psd_inh_c SET b = b || '*' WHERE a >= n;
  RETURN n;
END $$;
SELECT psd_inhc(1);
SELECT psd_inhc(2);
SELECT psd_inhc(1);
SELECT psd_inhc(2);
SELECT tableoid::regclass, * FROM psd_inh ORDER BY a;
SELECT pj_expect('psd_inhc(integer)', 'compiled') \gset

-- a view: its base table is the one written, a trigger on the view is not code
-- we can see
CREATE TABLE psd_vb (a int PRIMARY KEY, b text);
CREATE VIEW psd_vw AS SELECT a, b FROM psd_vb WHERE a > 0;
CREATE FUNCTION psd_view(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_vw VALUES (n, 'v');
  UPDATE psd_vw SET b = 'w' WHERE a = n;
  RETURN n;
END $$;
SELECT psd_view(1);
SELECT psd_view(2);
SELECT psd_view(3);
SELECT psd_view(4);
SELECT * FROM psd_vb ORDER BY a;
SELECT pj_expect('psd_view(integer)', 'compiled') \gset
CREATE VIEW psd_vi AS SELECT a, b FROM psd_vb;
CREATE FUNCTION psd_vi_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'instead of %', new.a; INSERT INTO psd_vb VALUES (new.a + 100, new.b); RETURN new; END $$;
CREATE TRIGGER psd_vi_t INSTEAD OF INSERT ON psd_vi
  FOR EACH ROW EXECUTE FUNCTION psd_vi_fn();
CREATE FUNCTION psd_viewi(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_vi VALUES (n, 'i');
  RETURN n;
END $$;
SELECT psd_viewi(1);
SELECT psd_viewi(2);
SELECT psd_viewi(3);
SELECT psd_viewi(4);
SELECT * FROM psd_vb ORDER BY a;
SELECT pj_expect('psd_viewi(integer)', 'declined:relation:kind') \gset

-- a view with a rule: the action of the rule writes the base table, and the
-- view stays among the relations of the query, locked for the write
CREATE TABLE psd_vrb (a int PRIMARY KEY, b text) WITH (autovacuum_enabled = false);
CREATE VIEW psd_vr AS SELECT a, b FROM psd_vrb;
CREATE RULE psd_vr_i AS ON INSERT TO psd_vr DO INSTEAD INSERT INTO psd_vrb VALUES (new.a, new.b);
CREATE FUNCTION psd_viewr(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_vr VALUES (n, 'r');
  RETURN n;
END $$;
SELECT psd_viewr(1);
SELECT psd_viewr(2);
SELECT psd_viewr(3);
SELECT psd_viewr(4);
SELECT * FROM psd_vrb ORDER BY a;

-- MERGE stays PL/pgSQL's
CREATE TABLE psd_mg (a int PRIMARY KEY, b text);
INSERT INTO psd_mg VALUES (1, 'one');
CREATE FUNCTION psd_merge(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  MERGE INTO psd_mg m USING (SELECT n AS a) s ON m.a = s.a
    WHEN MATCHED THEN UPDATE SET b = m.b || '+'
    WHEN NOT MATCHED THEN INSERT VALUES (s.a, 'new');
  RETURN n;
END $$;
SELECT psd_merge(1);
SELECT psd_merge(1);
SELECT psd_merge(2);
SELECT psd_merge(2);
SELECT * FROM psd_mg ORDER BY a;
SELECT pj_expect('psd_merge(integer)', 'declined:statement:SQL statement') \gset

-- a data-modifying CTE: the relation rule is for the result relation of each
-- command in it, the top level or not
CREATE TABLE psd_w (a int, b text);
INSERT INTO psd_w SELECT i, 'x' FROM generate_series(1, 12) i;
CREATE TABLE psd_wt (a int, b text);
INSERT INTO psd_wt SELECT i, 'y' FROM generate_series(1, 12) i;
CREATE FUNCTION psd_wt_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', old.a; RETURN old; END $$;
CREATE TRIGGER psd_wt_d BEFORE DELETE ON psd_wt
  FOR EACH ROW EXECUTE FUNCTION psd_wt_fn();
\set dw 'SELECT (SELECT string_agg(a::text, '','' ORDER BY a) FROM psd_w) AS psd_w, (SELECT string_agg(a::text, '','' ORDER BY a) FROM psd_wt) AS psd_wt'
CREATE FUNCTION psd_cte(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE c bigint;
BEGIN
  WITH d AS (DELETE FROM psd_w WHERE a = n RETURNING *) SELECT count(*) INTO c FROM d;
  RETURN c;
END $$;
CREATE FUNCTION psd_cte_t(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE c bigint;
BEGIN
  WITH d AS (DELETE FROM psd_wt WHERE a = n RETURNING *) SELECT count(*) INTO c FROM d;
  RETURN c;
END $$;
CREATE FUNCTION psd_cte_move(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  WITH d AS (DELETE FROM psd_wt WHERE a = n RETURNING *)
    INSERT INTO psd_w SELECT a + 100, b FROM d;
  RETURN n;
END $$;
SELECT psd_cte(1);
SELECT psd_cte(2);
SELECT psd_cte(3);
SELECT psd_cte(1);
:dw;
SELECT psd_cte_t(1);
SELECT psd_cte_t(2);
SELECT psd_cte_t(3);
SELECT psd_cte_t(1);
:dw;
SELECT psd_cte_move(4);
SELECT psd_cte_move(5);
SELECT psd_cte_move(6);
SELECT psd_cte_move(4);
:dw;
SELECT pj_expect('psd_cte(integer)', 'compiled') \gset
SELECT pj_expect('psd_cte_t(integer)', 'declined:relation:trigger') \gset
SELECT pj_expect('psd_cte_move(integer)', 'declined:relation:trigger') \gset

-- RETURNING INTO: no row, one row, two rows
CREATE FUNCTION psd_ret(n int, w int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int; y text; r text;
BEGIN
  UPDATE psd_t SET b = 'ret' WHERE a BETWEEN n AND n + w RETURNING a, b INTO x, y;
  RETURN coalesce(x::text, '-') || '/' || coalesce(y, '-') || '/' || found::text;
END $$;
CREATE FUNCTION psd_ret_strict(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  INSERT INTO psd_t VALUES (n, 'strict', 1) ON CONFLICT DO NOTHING RETURNING a INTO STRICT x;
  RETURN x;
END $$;
SELECT psd_ret(1, 0);
:dt;
SELECT psd_ret(100, 0);
:dt;
SELECT psd_ret(2, 0);
:dt;
SELECT psd_ret(3, 0);
:dt;
SELECT psd_try('SELECT psd_ret(2, 1)');
:dt;
SELECT psd_try('SELECT psd_ret(4, 2)');
:dt;
SELECT psd_ret_strict(60), psd_ret_strict(61), psd_ret_strict(62);
SELECT psd_try('SELECT psd_ret_strict(60)');
:dt;
SELECT pj_expect('psd_ret(integer,integer)', 'compiled') \gset
SELECT pj_expect('psd_ret_strict(integer)', 'compiled') \gset

-- RETURNING with no INTO has no destination
CREATE FUNCTION psd_noret(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  DELETE FROM psd_t WHERE a = n RETURNING a;
  RETURN n;
END $$;
SELECT psd_try('SELECT psd_noret(60)');
SELECT psd_try('SELECT psd_noret(61)');
SELECT psd_try('SELECT psd_noret(62)');
:dt;

-- a savepoint of the caller, rolled back around a call
BEGIN;
SAVEPOINT s1;
SELECT psd_serial(10);
SELECT psd_found(20);
:ds;
ROLLBACK TO s1;
:ds;
SELECT psd_serial(11);
:ds;
COMMIT;
:ds;
:dt;
-- and the error of a statement, caught in the caller's block
CREATE FUNCTION psd_catch(n int) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM psd_serial(n);
  PERFORM psd_fk(n + 1000);
  RETURN 'no error';
EXCEPTION WHEN foreign_key_violation THEN RETURN 'caught';
END $$;
SELECT psd_catch(1);
SELECT psd_catch(2);
SELECT psd_catch(3);
SELECT psd_catch(4);
:ds;
:dc;

-- a call inside a call, both with a statement of their own: a VOLATILE callee
-- of an expression is not admitted, so the function is PL/pgSQL's
CREATE FUNCTION psd_rec(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE r int;
BEGIN
  INSERT INTO psd_s (v) VALUES ('rec' || n);
  IF n > 0 THEN
    r := psd_rec(n - 1);
  END IF;
  UPDATE psd_s SET w = w + 1 WHERE v = 'rec' || n;
  RETURN n;
END $$;
SELECT psd_rec(2);
SELECT psd_rec(2);
SELECT psd_rec(3);
SELECT psd_rec(3);
:ds;
SELECT pj_expect('psd_rec(integer)', 'declined:volatile callee') \gset

-- an expression after a statement sees what the statement wrote
CREATE FUNCTION psd_cnt() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT count(*) FROM psd_s $$;
CREATE FUNCTION psd_see(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a bigint; b bigint; c bigint;
BEGIN
  a := psd_cnt();
  INSERT INTO psd_s (v) VALUES ('see' || n);
  b := psd_cnt();
  SELECT count(*) INTO c FROM psd_s;
  RETURN a || '/' || b || '/' || c;
END $$;
SELECT psd_see(1);
SELECT psd_see(2);
SELECT psd_see(3);
SELECT psd_see(4);
SELECT pj_expect('psd_see(integer)', 'compiled') \gset

-- the table truncated between calls: the plan is stale, and a statement that
-- writes is looked at again (at most one call by the interpreter)
CREATE TABLE psd_tt (a int, b text) WITH (autovacuum_enabled = false);
\set dtt 'SELECT coalesce(string_agg(x::text, '' '' ORDER BY x.a), ''-'') AS psd_tt FROM psd_tt x'
CREATE FUNCTION psd_trunc(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  INSERT INTO psd_tt VALUES (n, 'x');
  UPDATE psd_tt SET b = 'y' WHERE a = n RETURNING a INTO c;
  RETURN c;
END $$;
SELECT psd_trunc(1);
SELECT psd_trunc(2);
SELECT psd_trunc(3);
SELECT psd_trunc(4);
:dtt;
SELECT pj_expect('psd_trunc(integer)', 'compiled') \gset
TRUNCATE psd_tt;
SELECT pj_mark() \gset
SELECT psd_trunc(5);
SELECT psd_trunc(6);
-- one call by the interpreter, then compiled again, with no translation
SELECT pj_delta(1, 1, NULL, 0, 0);
SELECT psd_trunc(7);
:dtt;
SELECT pj_expect('psd_trunc(integer)', 'compiled') \gset
TRUNCATE psd_tt;
SELECT psd_trunc(8);
SELECT psd_trunc(9);
:dtt;

-- a default that changes between calls is code the plan did not have: the
-- statement is translated again, and then declined.  Not a call that runs it
-- on a plan that SPI analyses inside the call.
CREATE TABLE psd_dv (a int, b int DEFAULT 0) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_vol() RETURNS int LANGUAGE plpgsql VOLATILE AS $$
BEGIN RAISE NOTICE 'default'; RETURN 42; END $$;
CREATE FUNCTION psd_dvi(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_dv (a) VALUES (n);
  RETURN n;
END $$;
\set ddv 'SELECT coalesce(string_agg(x::text, '' '' ORDER BY x.a), ''-'') AS psd_dv FROM psd_dv x'
SELECT psd_dvi(1);
SELECT psd_dvi(2);
SELECT psd_dvi(3);
:ddv;
SELECT pj_expect('psd_dvi(integer)', 'compiled') \gset
ALTER TABLE psd_dv ALTER COLUMN b SET DEFAULT psd_vol();
SELECT pj_mark() \gset
SELECT psd_dvi(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0, 0, 0) \gset
SELECT psd_dvi(5);
SELECT psd_dvi(6);
:ddv;
SELECT pj_expect('psd_dvi(integer)', 'declined:volatile callee') \gset

-- a rule that makes the statement nothing: no relation shows in the plan, and
-- so nothing makes it stale when the rule goes and a trigger comes (PL/pgSQL
-- goes on doing nothing too); after DISCARD PLANS the statement is looked at
-- again, as one that writes
CREATE TABLE psd_nt (a int) WITH (autovacuum_enabled = false);
CREATE RULE psd_nt_r AS ON INSERT TO psd_nt DO INSTEAD NOTHING;
CREATE FUNCTION psd_nt_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; RETURN new; END $$;
CREATE FUNCTION psd_nothing(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_nt VALUES (n);
  RETURN n;
END $$;
SELECT psd_nothing(1);
SELECT psd_nothing(2);
SELECT psd_nothing(3);
SELECT pj_expect('psd_nothing(integer)', 'compiled') \gset
DROP RULE psd_nt_r ON psd_nt;
CREATE TRIGGER psd_nt_t BEFORE INSERT ON psd_nt
  FOR EACH ROW EXECUTE FUNCTION psd_nt_fn();
-- the plan names no relation, so only this makes it stale
DISCARD PLANS;
SELECT pj_mark() \gset
SELECT psd_nothing(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0, 0, 0) \gset
SELECT psd_nothing(5);
SELECT psd_nothing(6);
SELECT * FROM psd_nt ORDER BY a;
-- (pg_class still says that the table has rules, until a VACUUM)
SELECT pj_expect('psd_nothing(integer)', 'declined:relation:rule') \gset

-- a function with the shape of a transaction: a SELECT INTO that needs a cast
-- makes the function PL/pgSQL's, statements that write and all
CREATE TABLE psd_o (id int PRIMARY KEY, nm varchar(16), d1 varchar(24), d2 varchar(24),
                    q int, price numeric(5,2));
INSERT INTO psd_o SELECT i, 'n' || i, 'a' || i, 'b' || i, 10 * i, i * 1.5 FROM generate_series(1, 5) i;
CREATE TABLE psd_ol (o int, line int, dist char(24), amount numeric(6,2));
CREATE FUNCTION psd_order(n int) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE v_dist char(24); v_q int; v_price numeric(5,2); v_amount numeric(6,2);
BEGIN
  SELECT CASE n % 2 WHEN 0 THEN d1 ELSE d2 END, q, price
    INTO v_dist, v_q, v_price FROM psd_o WHERE id = n;
  UPDATE psd_o SET q = v_q - 1 WHERE id = n;
  v_amount := v_q * v_price;
  INSERT INTO psd_ol VALUES (n, 1, v_dist, v_amount);
  RETURN v_amount;
END $$;
SELECT psd_order(1);
SELECT psd_order(2);
SELECT psd_order(3);
SELECT psd_order(1);
SELECT * FROM psd_ol ORDER BY o, amount;
SELECT id, q FROM psd_o ORDER BY id;
SELECT pj_expect('psd_order(integer)', 'declined:cast') \gset

-- a table truncated and analysed in each round (the reset of a benchmark):
-- the plan of the statement is stale, the interpreter runs the call that
-- finds it so and plans it again, and the next call is compiled again, with
-- no translation.  The counters are read over the rounds.
CREATE TABLE psd_rs (a int, b text) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_reset(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  INSERT INTO psd_rs VALUES (n, 'x');
  UPDATE psd_rs SET b = 'y' WHERE a = n RETURNING a INTO c;
  RETURN c;
END $$;
SELECT psd_reset(1), psd_reset(2), psd_reset(3);
SELECT pj_expect('psd_reset(integer)', 'compiled') \gset
-- (a statement of its own for each: in one transaction the plan is not stale)
-- 12 rounds of TRUNCATE, ANALYZE and 5 calls
SELECT pj_mark() \gset
\o /dev/null
SELECT CASE s WHEN 1 THEN 'TRUNCATE psd_rs' WHEN 2 THEN 'ANALYZE psd_rs'
              ELSE format('SELECT psd_reset(%s)', i * 10 + s) END
  FROM generate_series(1, 12) i, generate_series(1, 7) s ORDER BY i, s \gexec
\o
SELECT count(*), sum(a) FROM psd_rs;
SELECT pj_delta(48, 12, NULL, 0, 0);
SELECT pj_expect('psd_reset(integer)', 'compiled') \gset
-- 20 rounds of ANALYZE alone and 2 calls
SELECT pj_mark() \gset
\o /dev/null
SELECT CASE s WHEN 1 THEN 'ANALYZE psd_rs' ELSE format('SELECT psd_reset(%s)', 1000 + i * 10 + s) END
  FROM generate_series(1, 20) i, generate_series(1, 3) s ORDER BY i, s \gexec
\o
SELECT count(*), sum(a) FROM psd_rs;
SELECT pj_delta(20, 20, NULL, 0, 0);
-- 20 rounds of TRUNCATE and 2 calls: one translation per round, if the plan
-- of a write were to demote the function
SELECT pj_mark() \gset
\o /dev/null
SELECT CASE s WHEN 1 THEN 'TRUNCATE psd_rs' ELSE format('SELECT psd_reset(%s)', 2000 + i * 10 + s) END
  FROM generate_series(1, 20) i, generate_series(1, 3) s ORDER BY i, s \gexec
\o
SELECT count(*), sum(a) FROM psd_rs;
SELECT pj_delta(20, 20, NULL, 0, 0);
SELECT pj_expect('psd_reset(integer)', 'compiled') \gset
-- a call after each reset and none between: the interpreter runs each, the
-- function is not translated again and not declined, and runs no compiled call
CREATE TABLE psd_rs1 (a int, b text) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_reset1(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  INSERT INTO psd_rs1 VALUES (n, 'x');
  UPDATE psd_rs1 SET b = 'y' WHERE a = n RETURNING a INTO c;
  RETURN c;
END $$;
SELECT psd_reset1(1), psd_reset1(2), psd_reset1(3);
SELECT pj_expect('psd_reset1(integer)', 'compiled') \gset
SELECT pj_mark() \gset
\o /dev/null
SELECT CASE s WHEN 1 THEN 'TRUNCATE psd_rs1' ELSE format('SELECT psd_reset1(%s)', 10 + i) END
  FROM generate_series(1, 40) i, generate_series(1, 2) s ORDER BY i, s \gexec
\o
SELECT count(*), sum(a) FROM psd_rs1;
SELECT pj_delta(0, 40, NULL, 0, 0);
SELECT pj_expect('psd_reset1(integer)', 'interpreted:stale plan') \gset

-- what a plan made again shows is looked at before the code runs on it: a
-- trigger, or a VOLATILE check, that came in since is code the function must
-- leave to PL/pgSQL
CREATE TABLE psd_dd (a int, b int);
CREATE TABLE psd_dc (a int, b int);
CREATE FUNCTION psd_ddt(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_dd VALUES (n, n);
  RETURN n;
END $$;
CREATE FUNCTION psd_ddc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  UPDATE psd_dc SET b = b + 1 WHERE a = n;
  RETURN n;
END $$;
CREATE FUNCTION psd_dd_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; RETURN new; END $$;
CREATE FUNCTION psd_dd_v(n int) RETURNS bool LANGUAGE plpgsql VOLATILE AS $$
BEGIN RAISE NOTICE 'check %', n; RETURN true; END $$;
INSERT INTO psd_dc SELECT i, i FROM generate_series(1, 7) i;
SELECT psd_ddt(1), psd_ddt(2), psd_ddt(3);
SELECT psd_ddc(1), psd_ddc(2), psd_ddc(3);
SELECT pj_expect('psd_ddt(integer)', 'compiled') \gset
SELECT pj_expect('psd_ddc(integer)', 'compiled') \gset
CREATE TRIGGER psd_dd_t BEFORE INSERT ON psd_dd
  FOR EACH ROW EXECUTE FUNCTION psd_dd_fn();
ALTER TABLE psd_dc ADD CONSTRAINT psd_dc_c CHECK (psd_dd_v(b)) NOT VALID;
SELECT psd_ddt(4);
SELECT psd_ddt(5);
SELECT psd_ddt(6);
SELECT psd_ddt(7);
SELECT psd_ddc(4);
SELECT psd_ddc(5);
SELECT psd_ddc(6);
SELECT psd_ddc(7);
SELECT * FROM psd_dd ORDER BY a;
SELECT * FROM psd_dc ORDER BY a;
SELECT pj_expect('psd_ddt(integer)', 'declined:relation:trigger') \gset
SELECT pj_expect('psd_ddc(integer)', 'declined:relation:check') \gset

-- a plan made again that fails in planning leaves a valid plan with the same
-- generation: the code must not run on it before the facts are looked at
CREATE TABLE psd_rz (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_rz_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; RETURN new; END $$;
CREATE FUNCTION psd_raise(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_rz VALUES (100 / n);
  RETURN n;
END $$;
SET plan_cache_mode = force_custom_plan;
SELECT psd_raise(1), psd_raise(2), psd_raise(3);
SELECT pj_expect('psd_raise(integer)', 'compiled') \gset
CREATE TRIGGER psd_rz_t BEFORE INSERT ON psd_rz
  FOR EACH ROW EXECUTE FUNCTION psd_rz_fn();
SELECT psd_try('SELECT psd_raise(0)');
SELECT pj_mark() \gset
SELECT psd_raise(1);
SELECT pj_delta(0, 1, NULL, 0, 0);
SELECT psd_raise(2);
SELECT psd_raise(3);
SELECT psd_raise(4);
SELECT pj_expect('psd_raise(integer)', 'declined:relation:trigger') \gset
RESET plan_cache_mode;
SELECT * FROM psd_rz ORDER BY a;

-- a call with a NULL argument goes to the interpreter, which analyses the
-- statement again; its planning fails, and the trigger that came with the DDL
-- is in the plan that the next compiled call finds valid
CREATE TABLE psd_nr (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_nr_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; RETURN new; END $$;
CREATE FUNCTION psd_nullre(n int, h int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_nr VALUES (100 / n);
  RETURN n;
END $$;
SET plan_cache_mode = force_custom_plan;
SELECT psd_nullre(1, 1), psd_nullre(2, 1), psd_nullre(3, 1);
SELECT pj_expect('psd_nullre(integer,integer)', 'compiled') \gset
CREATE TRIGGER psd_nr_t BEFORE INSERT ON psd_nr
  FOR EACH ROW EXECUTE FUNCTION psd_nr_fn();
SELECT psd_try('SELECT psd_nullre(0, NULL)');
SELECT pj_mark() \gset
SELECT psd_nullre(1, 1);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
SELECT psd_nullre(2, 1);
SELECT psd_nullre(3, 1);
SELECT psd_nullre(4, 1);
SELECT pj_expect('psd_nullre(integer,integer)', 'declined:relation:trigger') \gset
RESET plan_cache_mode;
SELECT * FROM psd_nr ORDER BY a;

-- planning is the statement's own, once per execution: a STABLE function that
-- says when it runs at planning gives the notices of stock, under custom plans
-- and under the automatic choice
CREATE FUNCTION psd_pn(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'pn %', n; RETURN n; END $$;
CREATE TABLE psd_p5 (a int, b int) WITH (autovacuum_enabled = false);
INSERT INTO psd_p5 SELECT i, 0 FROM generate_series(1, 4) i;
CREATE FUNCTION psd_plan(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  UPDATE psd_p5 SET b = b + 1 WHERE a = psd_pn(n);
  RETURN n;
END $$;
SET plan_cache_mode = force_custom_plan;
SELECT psd_plan(1);
SELECT psd_plan(2);
SELECT psd_plan(3);
SELECT psd_plan(4);
SELECT psd_plan(1);
SELECT psd_plan(2);
SELECT psd_plan(3);
RESET plan_cache_mode;
SELECT psd_plan(1);
SELECT psd_plan(2);
SELECT psd_plan(3);
SELECT psd_plan(4);
SELECT psd_plan(1);
SELECT psd_plan(2);
SELECT psd_plan(3);
SELECT psd_plan(4);
SELECT * FROM psd_p5 ORDER BY a;
SELECT pj_expect('psd_plan(integer)', 'compiled') \gset

-- a function of a CHECK constraint that becomes VOLATILE between calls is
-- no dependency of the plan: the walk at the next entry finds it
CREATE FUNCTION psd_cf(n int) RETURNS bool LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN n > 0; END $$;
CREATE TABLE psd_cft (a int CHECK (psd_cf(a))) WITH (autovacuum_enabled = false);
CREATE FUNCTION psd_cff(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_cft VALUES (n);
  RETURN n;
END $$;
SELECT psd_cff(1), psd_cff(2), psd_cff(3);
SELECT pj_expect('psd_cff(integer)', 'compiled') \gset
ALTER FUNCTION psd_cf(int) VOLATILE;
SELECT pj_mark() \gset
SELECT psd_cff(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
SELECT psd_cff(5);
SELECT psd_cff(6);
SELECT * FROM psd_cft ORDER BY a;
SELECT pj_expect('psd_cff(integer)', 'declined:relation:check') \gset

-- a CHECK constraint or a domain with a VOLATILE function is code the plan
-- does not show: the interpreter's.  A constraint of immutable and STABLE
-- functions is not.
CREATE FUNCTION psd_chk_v(n int) RETURNS bool LANGUAGE plpgsql VOLATILE AS $$
BEGIN RAISE NOTICE 'check %', n; RETURN n > 0; END $$;
CREATE FUNCTION psd_chk_s(n int) RETURNS bool LANGUAGE sql STABLE AS $$ SELECT n > 0 $$;
CREATE TABLE psd_ck (a int CHECK (a < 1000), b int CHECK (psd_chk_s(b)));
CREATE TABLE psd_ckv (a int, b int CHECK (psd_chk_v(b)));
CREATE DOMAIN psd_domv AS int CHECK (psd_chk_v(VALUE));
CREATE DOMAIN psd_doms AS int CHECK (VALUE > 0 AND psd_chk_s(VALUE));
CREATE DOMAIN psd_domd AS psd_domv;
CREATE TABLE psd_cd (a psd_doms, b int);
CREATE TABLE psd_cdv (a psd_domv, b int);
CREATE TABLE psd_cdd (a psd_domd, b int);
CREATE TABLE psd_ckd (a int, b int CHECK ((b::psd_domv) > 0));
CREATE FUNCTION psd_ck(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_ck VALUES (n, n + 1);
  RETURN n;
END $$;
CREATE FUNCTION psd_ckv(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_ckv VALUES (n, n + 1);
  RETURN n;
END $$;
CREATE FUNCTION psd_cd(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_cd VALUES (n, n);
  UPDATE psd_cd SET a = n + 1000 WHERE b = n;
  RETURN n;
END $$;
CREATE FUNCTION psd_cdd(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_cdd VALUES (n, n);
  RETURN n;
END $$;
CREATE FUNCTION psd_ckd(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_ckd VALUES (n, n);
  RETURN n;
END $$;
CREATE FUNCTION psd_cdv(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  INSERT INTO psd_cdv VALUES (n, n);
  RETURN n;
END $$;
SELECT psd_ck(1), psd_ck(2), psd_ck(3), psd_try('SELECT psd_ck(5000)');
SELECT psd_ckv(1), psd_ckv(2), psd_ckv(3), psd_try('SELECT psd_ckv(-4)');
SELECT psd_cd(1), psd_cd(2), psd_cd(3), psd_try('SELECT psd_cd(-1)');
SELECT psd_cdv(1), psd_cdv(2), psd_cdv(3), psd_try('SELECT psd_cdv(-1)');
SELECT psd_cdd(1), psd_cdd(2), psd_cdd(3), psd_try('SELECT psd_cdd(-1)');
SELECT psd_ckd(1), psd_ckd(2), psd_ckd(3), psd_try('SELECT psd_ckd(-1)');
SELECT * FROM psd_ck ORDER BY a;
SELECT * FROM psd_ckv ORDER BY a;
SELECT * FROM psd_cd ORDER BY a;
SELECT * FROM psd_cdv ORDER BY a;
SELECT * FROM psd_cdd ORDER BY a;
SELECT * FROM psd_ckd ORDER BY a;
SELECT pj_expect('psd_ck(integer)', 'compiled') \gset
SELECT pj_expect('psd_ckv(integer)', 'declined:relation:check') \gset
SELECT pj_expect('psd_cd(integer)', 'compiled') \gset
SELECT pj_expect('psd_cdv(integer)', 'declined:relation:check') \gset
SELECT pj_expect('psd_cdd(integer)', 'declined:relation:check') \gset
SELECT pj_expect('psd_ckd(integer)', 'declined:relation:check') \gset

-- a PARALLEL SAFE function with a write in a branch that no call takes, run
-- in the workers of a parallel query: the entry lock is no error there
CREATE TABLE psd_pwt (a int) WITH (autovacuum_enabled = false);
CREATE TABLE psd_pwb AS SELECT i AS a FROM generate_series(1, 5000) i;
ANALYZE psd_pwb;
CREATE FUNCTION psd_pw(n int) RETURNS int LANGUAGE :pj_lang PARALLEL SAFE AS $$
BEGIN
  IF n < 0 THEN
    INSERT INTO psd_pwt VALUES (n);
  END IF;
  RETURN n;
END $$;
SELECT psd_pw(-1), psd_pw(-2), psd_pw(-3);
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SET max_parallel_workers_per_gather = 2;
SET debug_parallel_query = on;
SELECT sum(psd_pw(a)) FROM psd_pwb;
SELECT sum(psd_pw(a)) FROM psd_pwb;
SELECT sum(psd_pw(a)) FROM psd_pwb;
RESET debug_parallel_query;
RESET max_parallel_workers_per_gather;
RESET min_parallel_table_scan_size;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
SELECT * FROM psd_pwt ORDER BY a;

-- memory: 10^4 statements that write, read inside the loop
CREATE TABLE psd_m (a int PRIMARY KEY, b int) WITH (autovacuum_enabled = false);
INSERT INTO psd_m SELECT i, 0 FROM generate_series(1, 20) i;
CREATE FUNCTION psd_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;
CREATE FUNCTION psd_loop(n int, probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE m bigint := 0; x int;
BEGIN
  FOR i IN 1..n LOOP
    UPDATE psd_m SET b = b + 1 WHERE a = i % 20 + 1 RETURNING b INTO x;
    IF i = probe THEN m := psd_mem(); END IF;
  END LOOP;
  RETURN m;
END $$;
SELECT psd_loop(3, 1) > 0, psd_loop(3, 2) > 0;
SELECT psd_loop(3, 1) > 0, psd_loop(3, 2) > 0;
SELECT psd_loop(3, 1) > 0, psd_loop(3, 2) > 0;
SELECT psd_loop(1000, 1000) AS m1 \gset
SELECT pj_mark() \gset
SELECT psd_loop(10000, 10000) - :m1 < 262144 AS flat;
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 10000);
SELECT sum(b) FROM psd_m;
SELECT pj_expect('psd_loop(integer,integer)', 'compiled') \gset
