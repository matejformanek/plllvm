--
-- pj_case: CASE, searched and simple
--
-- A simple CASE keeps its selector in a variable of the selector's type, so the
-- selectors here have several types, by value and by reference.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pk_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;

-- the SQLSTATE, message, hint and context of an error, caught
CREATE FUNCTION pk_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; h text; c text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          h = PG_EXCEPTION_HINT, c = PG_EXCEPTION_CONTEXT;
  RETURN st || ' ' || m || ' [' || coalesce(h, '') || ']' || E'\n' || c;
END $$;

-- searched, with ELSE, nested; a NULL condition is not true
CREATE FUNCTION pk_search(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r text := '';
BEGIN
  CASE
    WHEN n < 0 THEN r := 'neg';
    WHEN n = 0 THEN r := 'zero';
    WHEN n < 10 THEN
      CASE WHEN n % 2 = 0 THEN r := 'even'; ELSE r := 'odd'; END CASE;
    ELSE r := 'big';
  END CASE;
  RETURN r || '.';
END $$;
SELECT pk_search(v) FROM unnest(ARRAY[-5, 0, 4, 7, 99]) v;
SELECT pk_search(v) FROM unnest(ARRAY[-5, 0, 4, 7, 99]) v;
SELECT pk_search(v) FROM unnest(ARRAY[-5, 0, 4, 7, 99]) v;
SELECT pj_expect('pk_search(integer)', 'compiled') \gset
-- the rows ran in compiled code, none by fallback
SELECT pj_mark() \gset
SELECT pk_search(v) FROM unnest(ARRAY[-5, 0, 4, 7, 99]) v;
SELECT pj_delta(5, 0, NULL, 0, 0);

-- arms that return, no ELSE: nothing matches, and the error is the CASE's
CREATE FUNCTION pk_ret(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE
    WHEN n = 1 THEN RETURN 10;
    WHEN n = 2 THEN RETURN 20;
  END CASE;
  RETURN 0;
END $$;
SELECT pk_ret(1), pk_ret(2);
SELECT pk_ret(1), pk_ret(2);
SELECT pk_ret(3);  -- fail
SELECT pk_ret(NULL);  -- fail
SELECT pk_ret(1), pk_ret(2);
SELECT pj_expect('pk_ret(integer)', 'compiled') \gset
-- the hint, the line and the statement are those of PL/pgSQL, and the failure
-- names no expression: the next call is compiled all the same
SELECT pk_try('SELECT pk_ret(3)');
SELECT pk_ret(2);
SELECT pj_expect('pk_ret(integer)', 'compiled') \gset

-- an empty ELSE is an ELSE
CREATE FUNCTION pk_empty(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0;
BEGIN
  CASE WHEN n = 1 THEN s := 1; ELSE END CASE;
  CASE n WHEN 2 THEN s := s + 2; ELSE END CASE;
  RETURN s;
END $$;
SELECT pk_empty(1), pk_empty(2), pk_empty(3);
SELECT pk_empty(1), pk_empty(2), pk_empty(3);
SELECT pj_expect('pk_empty(integer)', 'compiled') \gset

-- EXIT, CONTINUE and RETURN in the arms of a CASE in a loop
CREATE FUNCTION pk_loop(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    CASE i % 4
      WHEN 0 THEN CONTINUE;
      WHEN 1 THEN s := s + i;
      WHEN 2 THEN
        CASE WHEN i > 20 THEN EXIT; ELSE s := s + 100; END CASE;
      ELSE
        IF s > 100000 THEN RETURN -1; END IF;
        s := s + 1000;
    END CASE;
  END LOOP;
  RETURN s;
END $$;
SELECT pk_loop(5), pk_loop(30);
SELECT pk_loop(5), pk_loop(30);
SELECT pk_loop(7), pk_loop(0), pk_loop(100);
SELECT pj_expect('pk_loop(integer)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pk_loop(7), pk_loop(0), pk_loop(100);
SELECT pj_delta(3, 0, 0, 0, 0);

-- the selector is int8: the WHENs compare with it, a list of values is an
-- array operator
CREATE FUNCTION pk_int8(x bigint) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int = 10;
        b int = 1;
BEGIN
  CASE x
    WHEN 1 THEN RETURN 'one';
    WHEN 2 THEN RETURN 'two';
    WHEN 3, 4, 3 + 5 THEN RETURN 'three, four or eight';
    WHEN a THEN RETURN 'ten';
    WHEN a + b, a + b + 1 THEN RETURN 'eleven, twelve';
    ELSE RETURN 'other';
  END CASE;
END $$;
SELECT pk_int8(v) FROM unnest(ARRAY[1, 2, 3, 4, 8, 10, 11, 12, 13]) v;
SELECT pk_int8(v) FROM unnest(ARRAY[1, 2, 3, 4, 8, 10, 11, 12, 13]) v;
SELECT pk_int8(v) FROM unnest(ARRAY[1, 2, 3, 4, 8, 10, 11, 12, 13]) v;
SELECT pj_expect('pk_int8(bigint)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pk_int8(v) FROM unnest(ARRAY[1, 2, 3, 4, 8, 10, 11, 12, 13]) v;
SELECT pj_delta(9, 0, NULL, 0, 0);

-- selectors of other types: by value, numeric, text, varchar, a NULL one
CREATE FUNCTION pk_types(n int, t text) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r text := '';
BEGIN
  CASE n::float8 / 2 WHEN 1.5 THEN r := r || 'a'; WHEN 1 THEN r := r || 'b'; ELSE r := r || 'c'; END CASE;
  CASE (n * 1.5)::numeric WHEN 1.5 THEN r := r || 'd'; WHEN 3.0 THEN r := r || 'e'; ELSE r := r || 'f'; END CASE;
  CASE upper(t) WHEN 'PER' THEN r := r || 'g'; WHEN 'RAD', 'DEG' THEN r := r || 'h'; ELSE r := r || 'i'; END CASE;
  CASE lower(t)::varchar(5) WHEN 'per' THEN r := r || 'j'; WHEN 'rad' THEN r := r || 'k'; ELSE r := r || 'l'; END CASE;
  CASE n > 1 WHEN true THEN r := r || 'm'; WHEN false THEN r := r || 'n'; END CASE;
  CASE NULL::int WHEN 1 THEN NULL; ELSE r := r || 'q'; END CASE;
  CASE lower(t)::name WHEN 'per' THEN r := r || 'r'; ELSE r := r || 's'; END CASE;
  RETURN r;
END $$;
SELECT pk_types(1, 'per'), pk_types(2, 'RAD'), pk_types(3, 'deg'), pk_types(0, 'x');
SELECT pk_types(1, 'per'), pk_types(2, 'RAD'), pk_types(3, 'deg'), pk_types(0, 'x');
SELECT pk_types(1, 'per'), pk_types(2, 'RAD'), pk_types(3, 'deg'), pk_types(0, 'x');
SELECT pj_expect('pk_types(integer,text)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pk_types(1, 'per'), pk_types(2, 'RAD'), pk_types(3, 'deg'), pk_types(0, 'x');
SELECT pj_delta(4, 0, NULL, 0, 0);

-- a selector of a type that is kept nowhere declines: a domain, an array
CREATE DOMAIN pk_dom AS int CHECK (value > 0);
CREATE FUNCTION pk_domain(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE n::pk_dom WHEN 1 THEN RETURN 1; ELSE RETURN 2; END CASE;
END $$;
CREATE FUNCTION pk_array(a int[]) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE a WHEN '{1}' THEN RETURN 1; ELSE RETURN 2; END CASE;
END $$;
SELECT pk_domain(1), pk_domain(2), pk_array('{1}'), pk_array('{2}');
SELECT pk_domain(1), pk_domain(2), pk_array('{1}'), pk_array('{2}');
SELECT pj_expect('pk_domain(integer)', 'declined:datum:pk_dom') \gset
SELECT pj_expect('pk_array(integer[])', 'declined:datum:_int4') \gset

-- the CASE variable is the CASE's: it is NULL again in every arm, and there is
-- no way to name it in a statement of its own
CREATE FUNCTION pk_name(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  CASE n WHEN 1 THEN x := 1; ELSE x := 2; END CASE;
  x := "__Case__Variable_3__";
  RETURN x;
END $$;
SELECT pk_name(1), pk_name(2);
SELECT pk_name(1), pk_name(2);
SELECT pj_expect('pk_name(integer)', 'declined:datum:case variable') \gset

-- errors: the selector, a later WHEN, and the CASE itself, each with the line
CREATE FUNCTION pk_err(n int, k int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE 10 / n
    WHEN 1 THEN RETURN 1;
    WHEN 5, 10 / k THEN RETURN 2;
    WHEN 3 THEN RETURN 3;
  END CASE;
END $$;
SELECT pk_err(10, 1), pk_err(2, 1), pk_err(1, 1), pk_err(3, 1);
SELECT pk_err(10, 1), pk_err(2, 1), pk_err(1, 1), pk_err(3, 1);
SELECT pj_expect('pk_err(integer,integer)', 'compiled') \gset
-- an error of the selector or of a WHEN names that expression, so a call in
-- the same transaction is PL/pgSQL's; the CASE's own error names none
BEGIN;
SELECT pk_err(10, 1);
SELECT pk_try('SELECT pk_err(5, 1)');
SELECT pk_err(10, 1);
SELECT pj_expect('pk_err(integer,integer)', 'compiled') \gset
SELECT pk_try('SELECT pk_err(0, 1)');
SELECT pk_err(10, 1);
SELECT pj_expect('pk_err(integer,integer)', 'interpreted:in use') \gset
COMMIT;
SELECT pk_err(10, 1), pk_err(2, 1);
SELECT pk_err(10, 1), pk_err(2, 1);
SELECT pj_expect('pk_err(integer,integer)', 'compiled') \gset
BEGIN;
SELECT pk_try('SELECT pk_err(3, 0)');
SELECT pk_err(10, 1);
SELECT pj_expect('pk_err(integer,integer)', 'interpreted:in use') \gset
COMMIT;
SELECT pk_err(10, 1), pk_err(2, 1);
SELECT pk_err(10, 1), pk_err(2, 1);
SELECT pj_expect('pk_err(integer,integer)', 'compiled') \gset

-- a replaced function takes the type of its new selector
CREATE FUNCTION pk_swap(n int) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  CASE n WHEN 1 THEN RETURN 'a'; ELSE RETURN 'b'; END CASE;
END $$;
SELECT pk_swap(1), pk_swap(2);
SELECT pk_swap(1), pk_swap(2);
SELECT pj_expect('pk_swap(integer)', 'compiled') \gset
CREATE OR REPLACE FUNCTION pk_swap(n int) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  CASE n::text WHEN '1' THEN RETURN 'a'; ELSE RETURN 'b'; END CASE;
END $$;
SELECT pk_swap(1), pk_swap(2);
SELECT pk_swap(1), pk_swap(2);
SELECT pk_swap(1), pk_swap(2);
SELECT pj_expect('pk_swap(integer)', 'compiled') \gset

-- the selector is planned again while its WHENs are not: the plan of a call
-- of an SQL function goes with the function, and the WHENs read a variable
-- whose type is that of the selector's value
CREATE FUNCTION pk_sel() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'a'::text $$;
CREATE FUNCTION pk_stale(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE pk_sel() || n::text WHEN 'a1' THEN RETURN 1; ELSE RETURN 3; END CASE;
END $$;
SELECT pk_stale(1), pk_stale(2);
SELECT pk_stale(1), pk_stale(2);
SELECT pj_expect('pk_stale(integer)', 'compiled') \gset
CREATE OR REPLACE FUNCTION pk_sel() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'b'::text $$;
SELECT pk_stale(1), pk_stale(2);
SELECT pk_stale(1), pk_stale(2);
SELECT pk_stale(1), pk_stale(2);
SELECT pj_expect('pk_stale(integer)', 'compiled') \gset

-- a call that finds the selector planned again before the function was
-- translated: the WHENs are not read, and the call is PL/pgSQL's at first
CREATE FUNCTION pk_sel3() RETURNS bigint LANGUAGE sql IMMUTABLE AS $$ SELECT 1::bigint $$;
CREATE FUNCTION pk_stale3(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE pk_sel3() + n WHEN 2 THEN RETURN 1; ELSE RETURN 3; END CASE;
END $$;
SELECT pk_stale3(1);
CREATE OR REPLACE FUNCTION pk_sel3() RETURNS bigint LANGUAGE sql IMMUTABLE AS $$ SELECT 2::bigint $$;
SELECT pk_stale3(1);
SELECT pj_expect('pk_stale3(integer)', 'deopt') \gset
SELECT pk_stale3(1), pk_stale3(0);
SELECT pk_stale3(1), pk_stale3(0);
SELECT pj_expect('pk_stale3(integer)', 'compiled') \gset

-- a selector of int8 and WHENs the compiler handles: no call of the executor
CREATE FUNCTION pk_native(x bigint) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE r int;
BEGIN
  CASE x WHEN 1 THEN r := 10; WHEN 2 THEN r := 20; ELSE r := 0; END CASE;
  RETURN r;
END $$;
SELECT pk_native(1), pk_native(2), pk_native(3);
SELECT pk_native(1), pk_native(2), pk_native(3);
SELECT pj_mark() \gset
SELECT pk_native(1), pk_native(2), pk_native(3);
SELECT pj_delta(3, 0, 0, 0, 0);

-- the memory of a text selector (the value of a call of upper) is flat inside one call, measured inside it:
-- every iteration's selector is a copy in a variable, freed by the next.  A
-- selector variable that were not set to NULL after the WHENs would free its
-- copy at the next assignment all the same, so no pin can tell that apart;
-- the values of this call, under a build that clobbers freed memory, catch a
-- selector read after it is freed.
CREATE FUNCTION pk_text(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE s int := 0; t text; m0 bigint;
BEGIN
  FOR i IN 1..10 LOOP
    t := (i % 3)::text;
    CASE upper(t || 'x') WHEN '0X' THEN s := s + 1; WHEN '1X' THEN s := s + 2; ELSE s := s + 3; END CASE;
  END LOOP;
  m0 := pk_mem();
  FOR i IN 1..n LOOP
    t := (i % 3)::text;
    CASE upper(t || 'x') WHEN '0X' THEN s := s + 1; WHEN '1X' THEN s := s + 2; ELSE s := s + 3; END CASE;
  END LOOP;
  RETURN pk_mem() - m0;
END $$;
CREATE FUNCTION pk_text_sum(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0; t text;
BEGIN
  FOR i IN 1..n LOOP
    t := (i % 3)::text;
    CASE upper(t || 'x') WHEN '0X' THEN s := s + 1; WHEN '1X' THEN s := s + 2; ELSE s := s + 3; END CASE;
  END LOOP;
  RETURN s;
END $$;
SELECT pk_text(10) IS NOT NULL;
SELECT pk_text(10) IS NOT NULL;
SELECT pk_text(100000) < 1048576 AS flat;
SELECT pj_expect('pk_text(integer)', 'compiled') \gset
SELECT pk_text_sum(10), pk_text_sum(10), pk_text_sum(99999);
SELECT pj_expect('pk_text_sum(integer)', 'compiled') \gset

-- the shape of a callback over raster pixels: a text selector that picks the
-- arm, array reads that the executor evaluates, an arm for each unit.  While
-- an arm has not run, it is not planned, and the function waits for it.
CREATE FUNCTION pk_pixel(units text, a int[], pixsize float8) RETURNS float8
LANGUAGE :pj_lang AS $$
DECLARE r float8;
BEGIN
  CASE substring(upper(trim(leading from units)) for 3)
    WHEN 'PER' THEN r := (a[1] - a[2]) / pixsize * 100.0;
    WHEN 'RAD' THEN r := atan((a[1] - a[2]) / pixsize);
    WHEN 'DEG' THEN r := degrees(atan((a[1] - a[2]) / pixsize));
    ELSE RAISE EXCEPTION 'units must be percent, radians or degrees: %', units;
  END CASE;
  RETURN r;
END $$;
SELECT pk_pixel('percent', ARRAY[3, 1], 2.0);
SELECT pk_pixel('percent', ARRAY[3, 1], 2.0);
SELECT pk_pixel('percent', ARRAY[3, 1], 2.0);
SELECT pj_expect('pk_pixel(text,integer[],double precision)', 'waiting') \gset
SELECT pk_pixel('radians', ARRAY[3, 1], 2.0);
SELECT pk_pixel('degrees', ARRAY[3, 1], 2.0);
SELECT pk_pixel('nonsense', ARRAY[3, 1], 2.0);  -- fail
SELECT pk_pixel('percent', ARRAY[3, 1], 2.0);
SELECT pk_pixel('radians', ARRAY[5, 1], 2.0);
SELECT pk_pixel('degrees', ARRAY[5, 1], 2.0);
SELECT pj_expect('pk_pixel(text,integer[],double precision)', 'compiled') \gset

-- an arm with a message, and an arm that was not planned: the call waits, and
-- the message is sent once
CREATE FUNCTION pk_wait(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE n
    WHEN 1 THEN RAISE NOTICE 'one %', n;
    WHEN 2 THEN RETURN 20;
    ELSE RETURN 30;
  END CASE;
  RETURN n;
END $$;
SELECT pk_wait(1);
SELECT pk_wait(1);
SELECT pk_wait(1);
SELECT pj_expect('pk_wait(integer)', 'waiting') \gset
SELECT pk_wait(2), pk_wait(3);
SELECT pk_wait(1);
SELECT pj_expect('pk_wait(integer)', 'compiled') \gset
