--
-- pj_language: functions in LANGUAGE plpgsql_jit
--
-- plpgsql_jit has PL/pgSQL's syntax, so everything here must give
-- PL/pgSQL's output.  PJ_LANG=plpgsql_jit makes make installcheck-pj run it
-- in that language; without it the functions are plpgsql, and that run made
-- the expected file.  pj_language_1.out is for plpgsql_jit being untrusted
-- (a role without USAGE cannot create a function).  A function is called
-- several times where it matters: the handler treats the first, the second
-- and later calls differently.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
SET pj.lang = :'pj_lang';

CREATE ROLE regress_pj_owner;
CREATE ROLE regress_pj_user;
GRANT CREATE ON SCHEMA public TO regress_pj_owner, regress_pj_user;

-- create, call, replace, drop
CREATE FUNCTION pjl_add(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN a + b;
END
$$;
SELECT pjl_add(i, 10) FROM generate_series(1, 4) i;
SELECT pjl_add(1, 2), pjl_add(3, 4);
CREATE OR REPLACE FUNCTION pjl_add(a int, b int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN a * b;
END
$$;
SELECT pjl_add(i, 10) FROM generate_series(1, 4) i;
DROP FUNCTION pjl_add(int, int);
SELECT pjl_add(1, 2);  -- fail

-- a call that replaces its own function, while its frame runs
CREATE FUNCTION pjl_swap(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE
  r text;
BEGIN
  IF n = 0 THEN
    RETURN 'leaf old';
  END IF;
  EXECUTE format($f$CREATE OR REPLACE FUNCTION pjl_swap(n int) RETURNS text
                    LANGUAGE %s AS 'BEGIN RETURN ''leaf new''; END'$f$,
                 current_setting('pj.lang'));
  r := pjl_swap(0);
  RETURN 'outer old, ' || r;
END
$$;
SELECT pjl_swap(0);
SELECT pjl_swap(1);
SELECT pjl_swap(0);

-- the validator: PL/pgSQL's own
CREATE FUNCTION pjl_bad() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETRN 1;
END
$$;  -- fail
CREATE FUNCTION pjl_bad(c cstring) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN 1;
END
$$;  -- fail
SET check_function_bodies = off;
CREATE FUNCTION pjl_late() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETRN 1;
END
$$;
RESET check_function_bodies;
SELECT pjl_late();  -- fail
SELECT pjl_late();  -- fail

-- errors and their CONTEXT
CREATE FUNCTION pjl_raise(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 1 THEN
    RAISE EXCEPTION 'pjl_raise %', n USING ERRCODE = 'P0042';
  END IF;
  RETURN n;
END
$$;
SELECT pjl_raise(1);
SELECT pjl_raise(2);  -- fail
SELECT pjl_raise(2);  -- fail
SELECT pjl_raise(3);  -- fail

-- DO
DO LANGUAGE :pj_lang $$
BEGIN
  RAISE NOTICE 'in a DO block';
END
$$;

-- trigger and event trigger
CREATE TABLE pjl_t (a int, b text);
CREATE FUNCTION pjl_trg() RETURNS trigger LANGUAGE :pj_lang AS $$
BEGIN
  NEW.b := coalesce(NEW.b, '') || '/' || TG_OP || '/' || TG_NARGS;
  RETURN NEW;
END
$$;
CREATE TRIGGER pjl_trg BEFORE INSERT OR UPDATE ON pjl_t
  FOR EACH ROW EXECUTE FUNCTION pjl_trg('x');
INSERT INTO pjl_t SELECT i, 'r' || i FROM generate_series(1, 3) i;
UPDATE pjl_t SET b = b || '!' WHERE a > 1;
SELECT * FROM pjl_t ORDER BY a;

CREATE FUNCTION pjl_evt() RETURNS event_trigger LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE 'event %, tag %', TG_EVENT, TG_TAG;
END
$$;
CREATE EVENT TRIGGER pjl_evt ON ddl_command_end EXECUTE FUNCTION pjl_evt();
CREATE TABLE pjl_t2 (a int);
DROP TABLE pjl_t2;
DROP EVENT TRIGGER pjl_evt;

-- procedures: INOUT, and transaction control, which needs a non-atomic call
CREATE PROCEDURE pjl_proc(INOUT x int) LANGUAGE :pj_lang AS $$
BEGIN
  x := x * 2;
END
$$;
CALL pjl_proc(21);
CALL pjl_proc(21);
CALL pjl_proc(21);

CREATE PROCEDURE pjl_commit(n int) LANGUAGE :pj_lang AS $$
BEGIN
  FOR i IN 1..n LOOP
    INSERT INTO pjl_t VALUES (100 + i, 'commit');
    COMMIT;
    INSERT INTO pjl_t VALUES (200 + i, 'rollback');
    ROLLBACK;
  END LOOP;
END
$$;
CALL pjl_commit(2);
CALL pjl_commit(2);
CALL pjl_commit(2);
SELECT a, b FROM pjl_t WHERE a > 3 ORDER BY a;
DELETE FROM pjl_t WHERE a > 3;

-- STRICT, NULL arguments, OUT parameters, sets
CREATE FUNCTION pjl_strict(a int) RETURNS int STRICT LANGUAGE :pj_lang AS $$
BEGIN
  RETURN a + 1;
END
$$;
CREATE FUNCTION pjl_nullable(a int) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  RETURN coalesce(a::text, 'null');
END
$$;
SELECT pjl_strict(NULL), pjl_nullable(NULL), pjl_strict(1), pjl_nullable(1);
SELECT pjl_strict(NULL), pjl_nullable(NULL), pjl_strict(1), pjl_nullable(1);

CREATE FUNCTION pjl_out(a int, OUT b int, OUT c text) LANGUAGE :pj_lang AS $$
BEGIN
  b := a * 2;
  c := 'x' || a;
END
$$;
SELECT * FROM pjl_out(4);
SELECT * FROM pjl_out(5);
SELECT (pjl_out(i)).c FROM generate_series(1, 3) i;

CREATE FUNCTION pjl_series(n int) RETURNS SETOF int LANGUAGE :pj_lang AS $$
BEGIN
  FOR i IN 1..n LOOP
    RETURN NEXT i * i;
  END LOOP;
END
$$;
SELECT * FROM pjl_series(4);
SELECT * FROM pjl_series(3);
SELECT sum(s) FROM generate_series(1, 3) g, LATERAL pjl_series(g) s;

-- polymorphic: one function, a compile per resolved type
CREATE FUNCTION pjl_poly(a anyelement, b anyelement) RETURNS anyarray
LANGUAGE :pj_lang AS $$
BEGIN
  RETURN ARRAY[a, b];
END
$$;
SELECT pjl_poly(1, 2), pjl_poly('a'::text, 'b'), pjl_poly(1.5, 2.5);
SELECT pjl_poly(1, 2), pjl_poly('a'::text, 'b'), pjl_poly(1.5, 2.5);
SELECT pjl_poly(1, 2), pjl_poly('a'::text, 'b'), pjl_poly(1.5, 2.5);

-- plpgsql and plpgsql_jit calling each other, and themselves
CREATE FUNCTION pjl_ping(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n <= 0 THEN
    RETURN 0;
  END IF;
  RETURN 1 + pjl_pong(n - 1);
END
$$;
CREATE FUNCTION pjl_pong(n int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  IF n <= 0 THEN
    RETURN 0;
  END IF;
  RETURN 1 + pjl_ping(n - 1);
END
$$;
SELECT pjl_ping(10), pjl_pong(10);
SELECT pjl_ping(10), pjl_pong(11);

CREATE FUNCTION pjl_fact(n int) RETURNS numeric LANGUAGE :pj_lang AS $$
BEGIN
  IF n <= 1 THEN
    RETURN 1;
  END IF;
  RETURN n * pjl_fact(n - 1);
END
$$;
SELECT pjl_fact(20);
SELECT pjl_fact(25);

-- an error caught three frames up
CREATE FUNCTION pjl_deep(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n = 0 THEN
    RETURN 1 / n;
  END IF;
  RETURN pjl_deep(n - 1);
END
$$;
CREATE FUNCTION pjl_catch() RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  PERFORM pjl_deep(3);
  RETURN 'no error';
EXCEPTION WHEN division_by_zero THEN
  RETURN 'caught ' || SQLERRM;
END
$$;
SELECT pjl_catch();
SELECT pjl_catch();
SELECT pjl_catch();

-- SECURITY DEFINER runs as the owner
CREATE FUNCTION pjl_definer() RETURNS text SECURITY DEFINER LANGUAGE :pj_lang AS $$
BEGIN
  RETURN current_user;
END
$$;
ALTER FUNCTION pjl_definer() OWNER TO regress_pj_owner;
SET ROLE regress_pj_user;
SELECT pjl_definer(), current_user;
SELECT pjl_definer(), current_user;
RESET ROLE;

-- plpgsql_jit is untrusted, so only a superuser can create a function in it;
-- plpgsql, trusted, lets everybody (hence pj_language_1.out)
SET ROLE regress_pj_user;
CREATE FUNCTION pjl_user() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN 1;
END
$$;
RESET ROLE;
DROP FUNCTION IF EXISTS pjl_user();

-- clean up
DROP OWNED BY regress_pj_owner, regress_pj_user;
DROP TABLE pjl_t;
DROP PROCEDURE pjl_proc(int), pjl_commit(int);
DROP FUNCTION pjl_swap(int), pjl_late(), pjl_raise(int), pjl_trg(), pjl_evt(),
  pjl_strict(int), pjl_nullable(int),
  pjl_out(int), pjl_series(int), pjl_poly(anyelement, anyelement),
  pjl_ping(int), pjl_pong(int), pjl_fact(int), pjl_deep(int), pjl_catch();
DROP ROLE regress_pj_owner;
DROP ROLE regress_pj_user;
