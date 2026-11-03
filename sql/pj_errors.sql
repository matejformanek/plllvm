--
-- pj_errors: errors raised by compiled code, and their CONTEXT; an error
-- call counts as compiled
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pe_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n + 1;
END
$$;
SELECT pe_inc(1);
SELECT pe_inc(2);
SELECT pe_inc(2147483647);  -- fail
SELECT pe_inc(2147483647);  -- fail
SELECT pj_expect('pe_inc(int)', 'compiled') \gset
SELECT pe_inc(3);

-- the position moves with the statement
CREATE FUNCTION pe_nested(n int, d int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  BEGIN

    RETURN n / d;
  END;
END
$$;
SELECT pe_nested(6, 3);
SELECT pe_nested(6, 3);
SELECT pe_nested(6, 0);  -- fail
SELECT pj_expect('pe_nested(int,int)', 'compiled') \gset

-- the other types
CREATE FUNCTION pe_big(a bigint, b bigint) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN RETURN a * b; END $$;
CREATE FUNCTION pe_flt(a float8, b float8) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN a / b; END $$;
CREATE FUNCTION pe_sqrt(a float8) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN sqrt(a); END $$;
SELECT pe_big(2, 3), pe_flt(1, 4), pe_sqrt(16);
SELECT pe_big(2, 3), pe_flt(1, 4), pe_sqrt(16);
SELECT pe_big(9223372036854775807, 2);  -- fail
SELECT pe_flt(1, 0);  -- fail
SELECT pe_flt(1e308, 1e-308);  -- fail
SELECT pe_sqrt(-1);  -- fail
SELECT pj_expect('pe_big(bigint,bigint)', 'compiled') \gset
SELECT pj_expect('pe_flt(double precision,double precision)', 'compiled') \gset
SELECT pj_expect('pe_sqrt(double precision)', 'compiled') \gset

-- a cast that can fail is PL/pgSQL's, with its CONTEXT
CREATE FUNCTION pe_narrow(n bigint) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 100000; END $$;
SELECT pe_narrow(1);
SELECT pe_narrow(2);
SELECT pe_narrow(100000);  -- fail
SELECT pe_narrow(100000);  -- fail
SELECT pj_expect('pe_narrow(bigint)', 'declined:cast') \gset

-- errors that PL/pgSQL raises: the function is not compiled
CREATE FUNCTION pe_i2(n int2) RETURNS int2 LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 10; END $$;
SELECT pe_i2(5::int2);
SELECT pe_i2(5::int2);
SELECT pe_i2(5000::int2);  -- fail
SELECT pe_i2(5000::int2);  -- fail
SELECT pj_expect('pe_i2(int2)', 'declined:cast') \gset

CREATE FUNCTION pe_none() RETURNS int LANGUAGE :pj_lang AS $$ BEGIN END $$;
SELECT pe_none();  -- fail
SELECT pe_none();  -- fail
SELECT pe_none();  -- fail

-- the SQLSTATEs
\set VERBOSITY sqlstate
SELECT pe_inc(2147483647);  -- fail
SELECT pe_nested(1, 0);  -- fail
SELECT pe_big(9223372036854775807, 2);  -- fail
SELECT pe_flt(1, 0);  -- fail
SELECT pe_narrow(100000);  -- fail
SELECT pe_none();  -- fail
\set VERBOSITY default

-- the same, caught by the caller
CREATE FUNCTION pe_catch(n int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  r int;
  c text;
BEGIN
  r := pe_inc(n);
  RETURN 'ok ' || r;
EXCEPTION WHEN numeric_value_out_of_range THEN
  GET STACKED DIAGNOSTICS c = PG_EXCEPTION_CONTEXT;
  RETURN 'caught: ' || c;
END
$$;
SELECT pe_catch(1);
SELECT pe_catch(2147483647);
SELECT pe_catch(2147483647);
SELECT pe_catch(5);
SELECT pj_expect('pe_inc(int)', 'compiled') \gset

-- a cancel in a long run of calls: where it lands is not told, its code is
\set VERBOSITY sqlstate
SET statement_timeout = '100ms';
CREATE FUNCTION pe_wait(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1; END $$;
SELECT pe_wait(1);
SELECT pe_wait(2);
SELECT sum(pe_wait(i)) FROM generate_series(1, 1000000000) i;  -- fail
RESET statement_timeout;
\set VERBOSITY default
SELECT pj_expect('pe_wait(int)', 'compiled') \gset

-- a WHILE condition that fails after the body reads "at WHILE", and its
-- CONTINUE form
CREATE FUNCTION pe_while(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0;
BEGIN
  WHILE 10 / (n - i) > 0 LOOP
    i := i + 1;
  END LOOP;
  RETURN i;
END $$;
CREATE FUNCTION pe_whilec(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0;
BEGIN
  WHILE 10 / (n - i) > 0 LOOP
    i := i + 1;
    CONTINUE WHEN i < n;
    EXIT;
  END LOOP;
  RETURN i;
END $$;
SELECT pe_while(0), pe_whilec(3);
SELECT pe_while(-1), pe_whilec(4);
SELECT pe_while(3);  -- fail
SELECT pe_while(3);  -- fail
SELECT pe_whilec(0);  -- fail
SELECT pe_whilec(0);  -- fail
SELECT pj_expect('pe_while(int)', 'compiled') \gset
SELECT pj_expect('pe_whilec(int)', 'compiled') \gset

-- the statements of the position: IF, assignment, FOR bounds, declaration
CREATE FUNCTION pe_pos(k int, d int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE
  x int := 1;
  y int := CASE WHEN k = 9 THEN 1 / d ELSE 2 END;
BEGIN
  IF k = 1 AND 1 / d > 0 THEN RETURN 1; END IF;
  IF k = 2 THEN x := 1 / d; END IF;
  IF k = 3 THEN
    FOR i IN 1..10 / d LOOP x := x + 1; END LOOP;
  END IF;
  IF k = 4 THEN
    FOR i IN 1..3 LOOP x := x + 10 / d; END LOOP;
  END IF;
  RETURN x + y;
END $$;
SELECT pe_pos(0, 1);
SELECT pe_pos(1, 1), pe_pos(2, 1), pe_pos(3, 1), pe_pos(4, 1), pe_pos(9, 1);
SELECT pe_pos(1, 1), pe_pos(2, 1), pe_pos(3, 1), pe_pos(4, 1), pe_pos(9, 1);
SELECT pe_pos(1, 0);  -- fail
SELECT pe_pos(2, 0);  -- fail
SELECT pe_pos(3, 0);  -- fail
SELECT pe_pos(4, 0);  -- fail
SELECT pe_pos(9, 0);  -- fail
SELECT pj_expect('pe_pos(int,int)', 'compiled') \gset

-- NOT NULL and FOR bounds
CREATE FUNCTION pe_nn(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int NOT NULL := 1; y int;
BEGIN
  IF n = 1 THEN x := y; END IF;
  IF n = 2 THEN FOR i IN y..3 LOOP x := x + 1; END LOOP; END IF;
  RETURN x;
END $$;
SELECT pe_nn(0), pe_nn(0);
SELECT pe_nn(1);  -- fail
SELECT pe_nn(2);  -- fail
SELECT pe_nn(1);  -- fail
SELECT pe_nn(2);  -- fail
SELECT pj_expect('pe_nn(int)', 'compiled') \gset

-- a cancel in a loop reports the statement it interrupted
CREATE FUNCTION pe_spin(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0;
BEGIN
  WHILE i < n LOOP i := i + 1; END LOOP;
  RETURN i;
END $$;
CREATE FUNCTION pe_spin0(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  WHILE n > 0 LOOP END LOOP;
  RETURN n;
END $$;
SELECT pe_spin(3), pe_spin(4), pe_spin0(0), pe_spin0(-1);
SET statement_timeout = '100ms';
SELECT pe_spin(2147483647);  -- fail
SELECT pe_spin0(1);  -- fail
RESET statement_timeout;
SELECT pj_expect('pe_spin(int)', 'compiled') \gset
SELECT pj_expect('pe_spin0(int)', 'compiled') \gset
