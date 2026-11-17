--
-- pj_sql_sessions: a statement that writes, and what another session does
-- to its tables
--
-- Expected from plllvm, not from stock PL/pgSQL, and run in one variant only.
-- A compiled call locks the tables its INSERT, UPDATE and DELETE statements
-- write before it looks at their plans, so that a trigger, default or
-- constraint that another session committed is seen by the call and not by
-- SPI inside it.  Stock PL/pgSQL takes these locks when it reaches the
-- statement; rows that say 55P03 or 'ok' for a DDL of the other session differ
-- from it on purpose.
--
\set VERBOSITY terse
SET plllvm.regress_test_mode = on;
CREATE EXTENSION dblink;
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset
SELECT dblink_connect('other', :'conn');
SELECT dblink_exec('other', 'SET lock_timeout = ''100ms''');

-- the SQLSTATE of a command of the other session, or ok
CREATE FUNCTION psc_other(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN
  PERFORM dblink_exec('other', q);
  RETURN 'ok';
EXCEPTION WHEN others THEN RETURN SQLSTATE;
END $$;
CREATE FUNCTION psc_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', new.a; RETURN new; END $$;

-- P3: a trigger that the other session committed after the last call is
-- seen by the next one, which the interpreter runs.  The mark is taken inside
-- the transaction, before the DDL, so that nothing between the DDL and the
-- call takes a lock that would deliver it.
CREATE TABLE psc_t (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psc_w(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  INSERT INTO psc_t VALUES (n);
  RETURN n;
END $$;
SELECT psc_w(1), psc_w(2), psc_w(3);
SELECT pj_expect('psc_w(integer)', 'compiled') \gset
BEGIN;
SELECT pj_mark() \gset
SELECT dblink_exec('other', 'CREATE TRIGGER psc_t_i BEFORE INSERT ON psc_t FOR EACH ROW EXECUTE FUNCTION psc_fn()');
SELECT psc_w(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
COMMIT;
SELECT psc_w(5);
SELECT psc_w(6);
SELECT pj_expect('psc_w(integer)', 'declined:relation:trigger') \gset
SELECT * FROM psc_t ORDER BY a;

-- P10: the search_path of the call names another table once the other session
-- has made the schema of the user; the call sees it before it runs
CREATE TABLE psp_t (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psp_w(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  INSERT INTO psp_t VALUES (n);
  RETURN n;
END $$;
SET search_path = "$user", public;
SELECT psp_w(1), psp_w(2), psp_w(3);
SELECT pj_expect('psp_w(integer)', 'compiled') \gset
BEGIN;
SELECT pj_mark() \gset
SELECT dblink_exec('other', format('CREATE SCHEMA %I; CREATE TABLE %I.psp_t (a int); CREATE TRIGGER psp_t_i BEFORE INSERT ON %I.psp_t FOR EACH ROW EXECUTE FUNCTION public.psc_fn()', current_user, current_user, current_user));
SELECT psp_w(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
-- (the new schema stales the plan: the lock delivers it, and the entry sees a
-- stale plan of a write, not a path that differs)
SELECT pj_expect('psp_w(integer)', 'interpreted:stale plan') \gset
COMMIT;
SELECT psp_w(5);
SELECT psp_w(6);
SELECT count(*) FROM public.psp_t;
SELECT format('SELECT count(*) FROM %I.psp_t', current_user) AS q \gset
:q;
RESET search_path;
SELECT format('DROP SCHEMA %I CASCADE', current_user) AS q \gset
:q;

-- P4: the entry lock on a table the function writes, reached or not.  Stock
-- takes the lock only at the statement, so the DDL of the other session
-- succeeds there.
CREATE TABLE psl_t (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psl_f(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  IF n > 1000 THEN
    INSERT INTO psl_t VALUES (n);
  END IF;
  RETURN n;
END $$;
SELECT psl_f(2000), psl_f(2001), psl_f(2002), psl_f(1);
SELECT pj_expect('psl_f(integer)', 'compiled') \gset
BEGIN;
SELECT psl_f(1);
-- 55P03 here, ok on stock
SELECT psc_other('CREATE TRIGGER psl_t_i BEFORE INSERT ON psl_t FOR EACH ROW EXECUTE FUNCTION psc_fn()');
ROLLBACK;
SELECT psc_other('DROP TRIGGER IF EXISTS psl_t_i ON psl_t');

-- P4b: a table that the other session holds is no wait for the call: it goes
-- to the interpreter, call after call, and is not declined
SELECT dblink_exec('other', 'BEGIN');
SELECT dblink_exec('other', 'LOCK TABLE psl_t IN SHARE MODE');
SET lock_timeout = '200ms';
SELECT psl_f(1);
SELECT pj_expect('psl_f(integer)', 'interpreted:lock') \gset
SELECT psl_f(1), psl_f(1), psl_f(1), psl_f(1), psl_f(1);
SELECT psl_f(1), psl_f(1), psl_f(1), psl_f(1), psl_f(1);
SELECT pj_expect('psl_f(integer)', 'interpreted:lock') \gset
RESET lock_timeout;
SELECT dblink_exec('other', 'ROLLBACK');
SELECT psl_f(1), psl_f(1);
SELECT pj_expect('psl_f(integer)', 'compiled') \gset

-- P4c: a table that is only read takes no lock at the entry
CREATE TABLE psl_t2 (a int) WITH (autovacuum_enabled = false);
INSERT INTO psl_t2 VALUES (1);
CREATE FUNCTION psl_r(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
DECLARE x int;
BEGIN
  IF n > 1000 THEN
    SELECT a INTO x FROM psl_t2 WHERE a = 1;
  END IF;
  RETURN n;
END $$;
SELECT psl_r(2000), psl_r(2001), psl_r(2002), psl_r(1);
SELECT pj_expect('psl_r(integer)', 'compiled') \gset
BEGIN;
SELECT psl_r(1);
SELECT psc_other('ALTER TABLE psl_t2 ADD COLUMN z int');
ROLLBACK;

-- a write through a view: the view stays among the relations of the query and
-- is locked by SPI inside the call, where what another session committed is
-- delivered.  The base table is locked first, by a statement of the caller.
CREATE TABLE psv_b (a int) WITH (autovacuum_enabled = false);
CREATE VIEW psv_v AS SELECT a FROM psv_b;
CREATE FUNCTION psv_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'instead of %', new.a; INSERT INTO psv_b VALUES (new.a + 100); RETURN new; END $$;
CREATE FUNCTION psv_w(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  INSERT INTO psv_v VALUES (n);
  RETURN n;
END $$;
SELECT psv_w(1), psv_w(2), psv_w(3);
SELECT pj_expect('psv_w(integer)', 'declined:relation:view') \gset
BEGIN;
INSERT INTO psv_b VALUES (0);
SELECT pj_mark() \gset
SELECT dblink_exec('other', 'CREATE TRIGGER psv_v_t INSTEAD OF INSERT ON psv_v FOR EACH ROW EXECUTE FUNCTION psv_fn()');
SELECT psv_w(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
COMMIT;
SELECT psv_w(5);
SELECT * FROM psv_b ORDER BY a;

-- the same through a rule whose action selects: the original relations are
-- copied into the SELECT of the action, with the view among them
CREATE TABLE psw_b (a int) WITH (autovacuum_enabled = false);
CREATE VIEW psw_v AS SELECT a FROM psw_b;
CREATE RULE psw_v_i AS ON INSERT TO psw_v DO INSTEAD INSERT INTO psw_b SELECT new.a;
CREATE FUNCTION psw_w(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  INSERT INTO psw_v VALUES (n);
  RETURN n;
END $$;
SELECT psw_w(1), psw_w(2), psw_w(3);
SELECT pj_expect('psw_w(integer)', 'declined:relation:view') \gset
BEGIN;
INSERT INTO psw_b VALUES (0);
SELECT pj_mark() \gset
SELECT dblink_exec('other', 'DROP RULE psw_v_i ON psw_v; CREATE TRIGGER psw_v_t INSTEAD OF INSERT ON psw_v FOR EACH ROW EXECUTE FUNCTION psv_fn()');
SELECT psw_w(4);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
COMMIT;
SELECT psw_w(5);
SELECT * FROM psw_b ORDER BY a;

-- a plain table that gets a rule whose action selects: the statement is then
-- one SELECT with no result relation and the table among its relations, with
-- the lock of a write.  The call that finds the plan stale is the interpreter's;
-- the rule goes and a trigger comes from the other session before the next.
CREATE TABLE psx_t (a int) WITH (autovacuum_enabled = false);
CREATE FUNCTION psx_try(q text) RETURNS text LANGUAGE plpgsql AS $$
BEGIN EXECUTE q; RETURN 'ok';
EXCEPTION WHEN others THEN RETURN SQLSTATE; END $$;
CREATE FUNCTION psx_w(n int) RETURNS int LANGUAGE plpgsql_jit AS $$
BEGIN
  INSERT INTO psx_t VALUES (n);
  RETURN n;
END $$;
SELECT psx_w(1), psx_w(2), psx_w(3);
SELECT pj_expect('psx_w(integer)', 'compiled') \gset
CREATE RULE psx_r AS ON INSERT TO psx_t DO INSTEAD SELECT new.a;
SELECT psx_try('SELECT psx_w(4)');
BEGIN;
SELECT pj_mark() \gset
SELECT dblink_exec('other', 'DROP RULE psx_r ON psx_t; CREATE TRIGGER psx_t_i BEFORE INSERT ON psx_t FOR EACH ROW EXECUTE FUNCTION psc_fn()');
SELECT psx_w(6);
SELECT pj_delta(0, 1, NULL, 0, 0, NULL, 0);
COMMIT;
SELECT psx_w(7);
-- (the plan of the rule is walked at the entry: a miss, not a run)
SELECT pj_expect('psx_w(integer)', 'interpreted:guard miss') \gset
SELECT psx_w(8);
SELECT * FROM psx_t ORDER BY a;
-- (pg_class says that the table has rules until a VACUUM, so the reason is the rule's)
SELECT pj_expect('psx_w(integer)', 'declined:relation:rule') \gset

SELECT dblink_disconnect('other');
DROP EXTENSION dblink;
