--
-- pj_into: SELECT expression INTO a variable
--
-- PL/pgSQL evaluates such a query as an expression, without SPI, when it is
-- one.  Whatever else is SELECT INTO goes to SPI and is not compiled.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- the SQLSTATE, message and context of an error, caught
CREATE FUNCTION pi_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; c text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          c = PG_EXCEPTION_CONTEXT;
  RETURN st || ' ' || m || E'\n' || c;
END $$;

-- targets by value and by reference, STRICT, and FOUND
CREATE FUNCTION pi_basic(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int; t text; b bigint; ok bool; f float8; w numeric;
BEGIN
  SELECT n * 2 INTO a;
  SELECT 'v' || a::text INTO t;
  SELECT a + 1 INTO b;
  SELECT a > 3 INTO ok;
  SELECT b * 1.5::float8 INTO STRICT f;
  SELECT n INTO w;
  RETURN a || t || b || ok || f || w || found;
END $$;
SELECT pi_basic(1), pi_basic(5), pi_basic(NULL);
SELECT pi_basic(1), pi_basic(5);
SELECT pi_basic(1), pi_basic(5);
SELECT pj_expect('pi_basic(integer)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pi_basic(v) FROM unnest(ARRAY[1, 2, 3, 4]) v;
SELECT pj_delta(4, 0, NULL, 0, 0);

-- FOUND is true after it, and false after an empty FOR
CREATE FUNCTION pi_found(n int) RETURNS bool LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  FOR i IN 1..n LOOP a := i; END LOOP;
  IF n = 0 THEN
    IF found THEN RETURN NULL; END IF;
  END IF;
  SELECT n INTO a;
  RETURN found;
END $$;
SELECT pi_found(0), pi_found(2);
SELECT pi_found(0), pi_found(2);
SELECT pj_expect('pi_found(integer)', 'compiled') \gset

-- a NOT NULL target: the error comes from the assignment, after the query
CREATE FUNCTION pi_notnull(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int NOT NULL := 1;
BEGIN
  SELECT nullif(n, 5) INTO a;
  RETURN a;
END $$;
SELECT pi_notnull(4), pi_notnull(6);
SELECT pi_notnull(4), pi_notnull(6);
SELECT pi_notnull(5);  -- fail
SELECT pi_notnull(5);  -- fail
SELECT pi_notnull(4), pi_notnull(6);
SELECT pi_notnull(4), pi_notnull(6);
SELECT pj_expect('pi_notnull(integer)', 'compiled') \gset
SELECT pi_try('SELECT pi_notnull(5)');

-- the value is converted to the type of the target as an assignment does:
-- a widening is compiled, a narrowing is PL/pgSQL's
CREATE FUNCTION pi_wide(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE a bigint;
BEGIN
  SELECT n + 1 INTO a;
  RETURN a;
END $$;
CREATE FUNCTION pi_narrow(n bigint) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT n + 1 INTO a;
  RETURN a;
END $$;
CREATE FUNCTION pi_numeric(n numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE a numeric(10,2);
BEGIN
  SELECT n * 3 INTO a;
  RETURN a;
END $$;
CREATE FUNCTION pi_varchar(n int) RETURNS varchar LANGUAGE :pj_lang AS $$
DECLARE a varchar(3);
BEGIN
  SELECT n::text INTO a;
  RETURN a;
END $$;
SELECT pi_wide(1), pi_wide(2), pi_narrow(1), pi_narrow(2),
       pi_numeric(1.111), pi_numeric(2), pi_varchar(1), pi_varchar(22);
SELECT pi_wide(1), pi_wide(2), pi_narrow(1), pi_narrow(2),
       pi_numeric(1.111), pi_numeric(2), pi_varchar(1), pi_varchar(22);
SELECT pj_expect('pi_wide(integer)', 'compiled') \gset
SELECT pj_expect('pi_narrow(bigint)', 'declined:cast') \gset
SELECT pj_expect('pi_numeric(numeric)', 'compiled') \gset
SELECT pj_expect('pi_varchar(integer)', 'declined:cast') \gset

-- an overflow of numeric(10,2) is raised from the statement: PL/pgSQL has left
-- the query by then, so the context has no SQL line, and the failure names no
-- expression.  In an assignment the cast is part of the expression, which is
-- named.
CREATE FUNCTION pi_overflow(n numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE a numeric(10,2);
BEGIN
  SELECT n * 1000000 INTO a;
  RETURN a;
END $$;
CREATE FUNCTION pi_overflow_assign(n numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE a numeric(10,2);
BEGIN
  a := n * 1000000;
  RETURN a;
END $$;
SELECT pi_overflow(1), pi_overflow(2);
SELECT pi_overflow(1), pi_overflow(2);
SELECT pi_overflow_assign(1), pi_overflow_assign(2);
SELECT pi_overflow_assign(1), pi_overflow_assign(2);
SELECT pi_overflow(1000);  -- fail
SELECT pi_overflow(1000);  -- fail
BEGIN;
SELECT pi_overflow(1);
SELECT pi_try('SELECT pi_overflow(1000)');
SELECT pi_overflow(1);
SELECT pj_expect('pi_overflow(numeric)', 'compiled') \gset
COMMIT;
BEGIN;
SELECT pi_overflow_assign(1);
SELECT pi_try('SELECT pi_overflow_assign(1000)');
SELECT pi_overflow_assign(1);
SELECT pj_expect('pi_overflow_assign(numeric)', 'interpreted:in use') \gset
COMMIT;

-- an error of the query has it in the context, then the line of the function
CREATE FUNCTION pi_err(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT 100 / n INTO a;
  RETURN a;
END $$;
SELECT pi_err(1), pi_err(2);
SELECT pi_err(1), pi_err(2);
SELECT pi_err(0);  -- fail
SELECT pi_err(0);  -- fail
SELECT pi_try('SELECT pi_err(0)');
SELECT pi_err(1), pi_err(2);
SELECT pi_err(1), pi_err(2);
SELECT pj_expect('pi_err(integer)', 'compiled') \gset
BEGIN;
SELECT pi_try('SELECT pi_err(0)');
SELECT pi_err(1);
SELECT pj_expect('pi_err(integer)', 'interpreted:in use') \gset
COMMIT;

-- a callee that fails or sends a message runs inside the query
CREATE FUNCTION pi_callee(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF n < 0 THEN RAISE EXCEPTION 'negative %', n; END IF;
  RAISE NOTICE 'callee %', n;
  RETURN n + 1;
END $$;
CREATE FUNCTION pi_call(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT pi_callee(n) INTO a;
  RETURN a;
END $$;
\set SHOW_CONTEXT always
SELECT pi_call(1), pi_call(2);
SELECT pi_call(1), pi_call(2);
SELECT pi_call(3);
SELECT pi_call(-1);  -- fail
\set SHOW_CONTEXT errors
SELECT pj_expect('pi_call(integer)', 'compiled') \gset

-- a callee that the user may not run: PL/pgSQL's own error
CREATE ROLE regress_pj_i1;
CREATE FUNCTION pi_secret(n int) RETURNS int LANGUAGE sql STABLE AS $$ SELECT n + 1 $$;
CREATE FUNCTION pi_priv(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT pi_secret(n) INTO a;
  RETURN a;
END $$;
GRANT EXECUTE ON FUNCTION pi_priv(int) TO regress_pj_i1;
SELECT pi_priv(1), pi_priv(2);
SELECT pi_priv(1), pi_priv(2);
SET ROLE regress_pj_i1;
SELECT pi_priv(1);
SELECT pi_priv(2);
RESET ROLE;
SELECT pi_priv(3);
REVOKE EXECUTE ON FUNCTION pi_secret(int) FROM PUBLIC;
SELECT pi_priv(4);
SELECT pi_priv(5);
SET ROLE regress_pj_i1;
SELECT pi_priv(6);  -- fail
SELECT pi_priv(7);  -- fail
RESET ROLE;
SELECT pi_priv(8);

-- not an expression: a FROM, two targets, a record, no INTO; these stay SPI's
CREATE TABLE pi_t(a int);
INSERT INTO pi_t VALUES (1), (2);
CREATE FUNCTION pi_from(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT max(pi_t.a) + n INTO a FROM pi_t;
  RETURN a;
END $$;
CREATE FUNCTION pi_two(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int; b int;
BEGIN
  SELECT n, n + 1 INTO a, b;
  RETURN a + b;
END $$;
CREATE FUNCTION pi_rec(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE r record;
BEGIN
  SELECT n AS x INTO r;
  RETURN r.x;
END $$;
CREATE FUNCTION pi_sql(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  SELECT n;
  RETURN n;
END $$;
SELECT pi_from(1), pi_two(1), pi_rec(1);
SELECT pi_from(1), pi_two(1), pi_rec(1);
SELECT pj_expect('pi_from(integer)', 'declined:not simple') \gset
SELECT pj_expect('pi_two(integer)', 'declined:statement:SQL statement') \gset
SELECT pj_expect('pi_rec(integer)', 'declined:datum:record') \gset

-- a query with a FROM in an arm that has not run is not planned yet: the
-- function is translated, runs, and is declined once the arm has run
CREATE FUNCTION pi_late(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int := 0;
BEGIN
  IF n > 100 THEN
    SELECT max(pi_t.a) INTO a FROM pi_t;
  END IF;
  RETURN a + n;
END $$;
SELECT pi_late(1), pi_late(2);
SELECT pi_late(1), pi_late(2);
SELECT pj_expect('pi_late(integer)', 'compiled') \gset
SELECT pi_late(1000);
SELECT pj_expect('pi_late(integer)', 'deopt') \gset
SELECT pi_late(1), pi_late(1000);
SELECT pj_expect('pi_late(integer)', 'declined:not simple') \gset

-- with a call that has an effect, it waits for the arm instead
CREATE FUNCTION pi_wait(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int := 0;
BEGIN
  IF n > 100 THEN
    SELECT max(pi_t.a) INTO a FROM pi_t;
  END IF;
  RETURN a + pi_callee(n);
END $$;
SELECT pi_wait(1), pi_wait(2);
SELECT pi_wait(1), pi_wait(2);
SELECT pj_expect('pi_wait(integer)', 'waiting') \gset

-- a query that was not simple when it was planned stays so: PL/pgSQL runs it
-- through SPI at every call, the replaced callee included
CREATE FUNCTION pi_callee2() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 1 / 0 $$;
CREATE FUNCTION pi_simplecaller() RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int;
BEGIN
  SELECT pi_callee2() INTO a;
  RETURN a;
END $$;
SELECT pi_simplecaller();  -- fail
CREATE OR REPLACE FUNCTION pi_callee2() RETURNS int LANGUAGE sql IMMUTABLE AS $$ SELECT 2 + 2 $$;
SELECT pi_simplecaller();
SELECT pi_simplecaller();
SELECT pi_simplecaller();
SELECT pj_expect('pi_simplecaller()', 'declined:not simple') \gset

-- the memory of a text target is released at each assignment
CREATE FUNCTION pi_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;
CREATE FUNCTION pi_loop(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE t text; s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    SELECT repeat('x', i % 50) INTO t;
    s := s + length(t);
  END LOOP;
  RETURN s;
END $$;
SELECT pi_loop(10), pi_loop(10);
SELECT pi_loop(10);
SELECT pi_mem() AS before \gset
SELECT pi_loop(100000);
SELECT pi_mem() - :before < 1048576 AS flat;
SELECT pj_expect('pi_loop(integer)', 'compiled') \gset

DROP TABLE pi_t;
DROP OWNED BY regress_pj_i1;
DROP ROLE regress_pj_i1;
