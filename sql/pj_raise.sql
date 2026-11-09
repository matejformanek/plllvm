--
-- pj_raise: RAISE in compiled code: levels, %, conditions, and what a
-- message does to a deopt
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set SHOW_CONTEXT always

CREATE FUNCTION pz_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;

-- the SQLSTATE, message and context of an error, caught
CREATE FUNCTION pz_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; c text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          c = PG_EXCEPTION_CONTEXT;
  RETURN st || ' ' || m || E'\n' || c;
END $$;

-- format, NULL, %%, a condition by SQLSTATE
CREATE FUNCTION pz_fmt(n int, t text) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE '% and %% and % and %', n, null::int, t;
  IF n < 0 THEN
    RAISE SQLSTATE '22012';
  END IF;
  RETURN n;
END $$;
SELECT pz_fmt(1, 'x');
SELECT pz_fmt(2, NULL::text) IS NOT NULL;
SELECT pz_fmt(3, 'y');
SELECT pz_fmt(-1, 'z');  -- fail
SELECT pz_fmt(-1, 'z');  -- fail
SELECT pz_try('SELECT pz_fmt(-2, ''w'')');
SELECT pj_expect('pz_fmt(integer,text)', 'compiled') \gset

-- the type of the value picks the output function, which runs at each call
CREATE FUNCTION pz_types(a int8, b float8, c numeric, d date, e interval,
                         f uuid, g jsonb, h bytea, ok bool)
RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE '% % % % % % % % %', a, b, c, d, e, f, g, h, ok;
  RAISE NOTICE '% % % % %', a + 1, b * 2, c + 1, upper('x') || a::text, d + 1;
  RAISE NOTICE '% %', ARRAY[a, 2], ROW(a, 'r');
  RAISE NOTICE '%', repeat('ab', 3000) = repeat('ab', 3000);
  RETURN 1;
END $$;
SELECT pz_types(1, 1.5, 2.25, '2000-01-02', '1 day', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                '{"k": [1, 2]}', '\x0102', true);
SELECT pz_types(2, 1e100, -2.25, '2000-01-02', '1 mon 2 hours', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                '{"k": [1, 2]}', '\x0102', false);
SET datestyle = 'German';
SELECT pz_types(3, 1.5, 2.25, '2000-01-02', '1 day', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                '{"k": [1, 2]}', '\x0102', true);
SET extra_float_digits = -3;
SELECT pz_types(3, 0.1, 2.25, '2000-01-02', '1 day', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                '{"k": [1, 2]}', '\x0102', true);
RESET datestyle;
RESET extra_float_digits;
SELECT pj_expect('pz_types(bigint,double precision,numeric,date,interval,uuid,jsonb,bytea,boolean)', 'compiled') \gset

-- each level against each client_min_messages
CREATE FUNCTION pz_lvl(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE DEBUG 'debug %', n;
  RAISE LOG 'log %', n;
  RAISE INFO 'info %', n;
  RAISE NOTICE 'notice %', n;
  RAISE WARNING 'warning %', n;
  RETURN n;
END $$;
SELECT pz_lvl(1);
SELECT pz_lvl(2);
SET client_min_messages = debug1;
SELECT pz_lvl(3);
SET client_min_messages = log;
SELECT pz_lvl(4);
SET client_min_messages = warning;
SELECT pz_lvl(5);
SET client_min_messages = error;
SELECT pz_lvl(6);
RESET client_min_messages;
SELECT pj_expect('pz_lvl(integer)', 'compiled') \gset

-- a message that nobody receives is formatted all the same: its arguments
-- are evaluated and can fail
CREATE FUNCTION pz_dbg(x int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE DEBUG '%', 1 / x;
  RETURN x;
END $$;
SET client_min_messages = error;
SELECT pz_dbg(1);
SELECT pz_dbg(2);
SELECT pz_dbg(0);  -- fail
SELECT pz_dbg(0);  -- fail
RESET client_min_messages;
SELECT pj_expect('pz_dbg(integer)', 'compiled') \gset

-- conditions
CREATE FUNCTION pz_cond(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n = 1 THEN RAISE division_by_zero; END IF;
  IF n = 2 THEN RAISE unique_violation; END IF;
  IF n = 3 THEN RAISE SQLSTATE '22012'; END IF;
  IF n = 4 THEN RAISE EXCEPTION 'plain'; END IF;
  IF n = 5 THEN RAISE EXCEPTION 'with % and %% and %', n, n + 1; END IF;
  IF n = 6 THEN RAISE WARNING division_by_zero; END IF;
  IF n = 7 THEN RAISE NOTICE SQLSTATE '01000'; END IF;
  IF n = 8 THEN RAISE EXCEPTION 'no_data_found: %', n; END IF;
  IF n = 9 THEN RAISE; END IF;
  RETURN n;
END $$;
-- a message waits for everything the function reaches to be planned
SELECT pz_try('SELECT pz_cond(8)') IS NOT NULL;
SELECT pz_try('SELECT pz_cond(5)') IS NOT NULL;
SELECT pz_cond(0);
SELECT pz_cond(0);
SELECT pz_try('SELECT pz_cond(1)');
SELECT pz_try('SELECT pz_cond(2)');
SELECT pz_try('SELECT pz_cond(3)');
SELECT pz_try('SELECT pz_cond(4)');
SELECT pz_try('SELECT pz_cond(5)');
SELECT pz_try('SELECT pz_cond(6)');
SELECT pz_try('SELECT pz_cond(7)');
SELECT pz_try('SELECT pz_cond(8)');
SELECT pz_try('SELECT pz_cond(9)');
SELECT pz_cond(6);
SELECT pz_cond(7);
SELECT pz_cond(1);  -- fail
SELECT pz_cond(9);  -- fail
SELECT pj_expect('pz_cond(integer)', 'compiled') \gset

-- RAISE EXCEPTION ends the function: what follows is never planned
CREATE FUNCTION pz_term() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE EXCEPTION 'x';
  RETURN 1;
END $$;
SELECT pz_term();  -- fail
SELECT pz_term();  -- fail
SELECT pj_expect('pz_term()', 'compiled') \gset
CREATE FUNCTION pz_term2(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN
    RAISE EXCEPTION 'positive %', n;
    n := n + 1;
  END IF;
  RETURN n;
END $$;
SELECT pz_term2(0);
SELECT pz_term2(0);
SELECT pz_term2(5);  -- fail
SELECT pz_term2(5);  -- fail
SELECT pj_expect('pz_term2(integer)', 'compiled') \gset

-- a message below ERROR has been sent: a deopt after it would send it twice,
-- so the function waits until everything it reaches is planned
CREATE FUNCTION pz_rare(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE 'n = %', n;
  IF n > 100 THEN
    RETURN -1;
  END IF;
  RETURN n;
END $$;
SELECT pz_rare(1);
SELECT pz_rare(2);
SELECT pj_expect('pz_rare(integer)', 'waiting') \gset
SELECT pz_rare(500);
SELECT pz_rare(3);
SELECT pz_rare(4);
SELECT pj_expect('pz_rare(integer)', 'compiled') \gset

-- the same with the arguments of the RAISE unplanned
CREATE FUNCTION pz_rare2(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 100 THEN
    RAISE NOTICE 'big %', n;
  END IF;
  RETURN n;
END $$;
SELECT pz_rare2(1);
SELECT pz_rare2(2);
SELECT pj_expect('pz_rare2(integer)', 'waiting') \gset
SELECT pz_rare2(500);
SELECT pz_rare2(3);
SELECT pz_rare2(4);
SELECT pj_expect('pz_rare2(integer)', 'compiled') \gset

-- an exception in the branch is not a message: the call restarts there
CREATE FUNCTION pz_rare3(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 100 THEN
    RAISE EXCEPTION 'big %', n + 1;
  END IF;
  RETURN n;
END $$;
SELECT pz_rare3(1);
SELECT pz_rare3(2);
SELECT pj_expect('pz_rare3(integer)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pz_rare3(500);  -- fail
SELECT pj_delta(0, 0, 0, 1, 0) \gset
SELECT pz_rare3(500);  -- fail
SELECT pj_expect('pz_rare3(integer)', 'interpreted:replan') \gset

-- an error in an argument belongs to its expression: in the same transaction
-- the expression is in use, and a later error shows the SQL expression
CREATE FUNCTION pz_arg(x int, y int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE '% %', x, 10 / y;
  RETURN x;
END $$;
SELECT pz_arg(1, 1);
SELECT pz_arg(2, 2);
BEGIN;
SAVEPOINT s;
SELECT pz_arg(1, 0);  -- fail
ROLLBACK TO s;
SELECT pz_arg(1, 0);  -- fail
COMMIT;
SELECT pj_expect('pz_arg(integer,integer)', 'compiled') \gset

-- but not when the arguments are done: the final message is the statement's
CREATE FUNCTION pz_done(x int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE EXCEPTION 'x is %', x + 1;
END $$;
SELECT pz_done(1);  -- fail
BEGIN;
SAVEPOINT s;
SELECT pz_done(1);  -- fail
ROLLBACK TO s;
SELECT pz_done(2);  -- fail
COMMIT;
SELECT pj_expect('pz_done(integer)', 'compiled') \gset

-- in a loop, and a callee that sends messages of its own
CREATE FUNCTION pz_noisy(n int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN
  RAISE NOTICE 'noisy %', n;
  RETURN n * 2;
END $$;
CREATE FUNCTION pz_loop(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    s := s + i;
    RAISE NOTICE 'i = %, s = %, noisy = %', i, s, pz_noisy(i);
    EXIT WHEN s > 5;
  END LOOP;
  RETURN s;
END $$;
SELECT pz_loop(2);
SELECT pz_loop(5);
SELECT pj_expect('pz_loop(integer)', 'compiled') \gset

-- recursion: each level has its message (a nested call in an expression is
-- not the interpreter's, so the context lines are left out)
\set SHOW_CONTEXT never
CREATE FUNCTION pz_rec(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n = 0 THEN RETURN 0; END IF;
  RAISE NOTICE 'down % then %', n, pz_rec(n - 1);
  RETURN n;
END $$;
SELECT pz_rec(1);
SELECT pz_rec(3);
SELECT pj_expect('pz_rec(integer)', 'compiled') \gset
\set SHOW_CONTEXT always

-- RAISE USING stays PL/pgSQL's
CREATE FUNCTION pz_using(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE 'n = %', n USING HINT = 'a hint';
  RETURN n;
END $$;
SELECT pz_using(1);
SELECT pz_using(2);
SELECT pj_expect('pz_using(integer)', 'declined:statement:RAISE USING') \gset

-- the message of a call that sends many is flat in memory
CREATE FUNCTION pz_many(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE m0 bigint;
BEGIN
  FOR i IN 1..10 LOOP RAISE NOTICE 'i = %', i; END LOOP;
  m0 := pz_mem();
  FOR i IN 1..n LOOP
    RAISE NOTICE 'i = %, text = %', i, repeat('x', 100);
  END LOOP;
  RETURN pz_mem() - m0;
END $$;
SET client_min_messages = warning;
SELECT pz_many(10) IS NOT NULL;
SELECT pz_many(10) IS NOT NULL;
SELECT pz_many(1000000) < 1048576 AS flat;
RESET client_min_messages;
SELECT pj_expect('pz_many(integer)', 'compiled') \gset
