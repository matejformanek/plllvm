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

-- the cast of the value: its own position, as in PL/pgSQL
CREATE FUNCTION pe_narrow(n bigint) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 100000; END $$;
SELECT pe_narrow(1);
SELECT pe_narrow(2);
SELECT pe_narrow(100000);  -- fail
SELECT pe_narrow(100000);  -- fail
SELECT pj_expect('pe_narrow(bigint)', 'compiled') \gset

-- errors that PL/pgSQL raises: the function is not compiled
CREATE FUNCTION pe_i2(n int2) RETURNS int2 LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 10; END $$;
SELECT pe_i2(5::int2);
SELECT pe_i2(5::int2);
SELECT pe_i2(5000::int2);  -- fail
SELECT pe_i2(5000::int2);  -- fail
SELECT pj_expect('pe_i2(int2)', 'declined:node') \gset

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
