--
-- pj_typmod: a value converted to numeric(p,s), which can fail; compiled, it
-- gives the answer of PL/pgSQL
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set SHOW_CONTEXT always

-- the default of a variable, from a numeric, an int4 and an int8: rounding,
-- a negative scale and NaN
CREATE FUNCTION pt_n(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_i4(x int) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_i8(x bigint) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_neg(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(3,-2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_p(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(4) := x;
BEGIN RETURN n; END $$;
SELECT pt_n(1.234), pt_n(1.235), pt_n(-0.005), pt_n(999.994), pt_n('NaN'),
       pt_i4(7), pt_i8(-999), pt_neg(12345), pt_neg(-150), pt_p(1234.4);
SELECT pt_n(1.234), pt_n(1.235), pt_n(-0.005), pt_n(999.994), pt_n('NaN'),
       pt_i4(7), pt_i8(-999), pt_neg(12345), pt_neg(-150), pt_p(1234.4);
SELECT pt_n(1.234), pt_n(1.235), pt_n(-0.005), pt_n(999.994), pt_n('NaN'),
       pt_i4(7), pt_i8(-999), pt_neg(12345), pt_neg(-150), pt_p(1234.4);
SELECT pj_expect('pt_n(numeric)', 'compiled') \gset
SELECT pj_expect('pt_i4(int)', 'compiled') \gset
SELECT pj_expect('pt_i8(bigint)', 'compiled') \gset
SELECT pj_expect('pt_neg(numeric)', 'compiled') \gset
SELECT pj_expect('pt_p(numeric)', 'compiled') \gset

-- an argument that is NULL goes to PL/pgSQL; a NULL that is computed does not
CREATE FUNCTION pt_null(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := nullif(x, 1);
BEGIN RETURN n; END $$;
SELECT pt_null(1), pt_null(2.345);
SELECT pt_null(1), pt_null(2.345);
SELECT pt_null(1), pt_null(2.345);
SELECT pj_expect('pt_null(numeric)', 'compiled') \gset

-- the failures, with the position of PL/pgSQL's
SELECT pt_n(1000);  -- fail
SELECT pt_n(999.995);  -- fail
SELECT pt_n(-1000);  -- fail
SELECT pt_n('Infinity');  -- fail
SELECT pt_n('-Infinity');  -- fail
SELECT pt_i4(1000);  -- fail
SELECT pt_i8(100000);  -- fail
SELECT pt_neg(100000);  -- fail
SELECT pt_p(10000);  -- fail
SELECT pt_n(1000);  -- fail
SELECT pt_n(2.5);
SELECT pj_expect('pt_n(numeric)', 'compiled') \gset
SELECT pj_expect('pt_i4(int)', 'compiled') \gset

-- a failure leaves no mark on the expression: in the same transaction the
-- next call still runs compiled.  PL/pgSQL fails in its cast, and the
-- expression it evaluated before is not busy.
BEGIN;
SAVEPOINT s;
SELECT pt_n(1000);  -- fail
ROLLBACK TO s;
SELECT pt_n(3.456);
SELECT pj_expect('pt_n(numeric)', 'compiled') \gset
SAVEPOINT s;
SELECT pt_i8(1000);  -- fail
ROLLBACK TO s;
SELECT pt_i8(3), pt_n(4.567);
SELECT pj_expect('pt_i8(bigint)', 'compiled') \gset
SELECT pj_expect('pt_n(numeric)', 'compiled') \gset
ROLLBACK;

-- the same in a loop, with other variables around it
CREATE FUNCTION pt_loop(n int, lim numeric) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE
  tot numeric(8,2) := 0;
  step numeric(5,2) := lim;
  last numeric(6,1);
BEGIN
  FOR i IN 1..n LOOP
    DECLARE v numeric(5,1) := i * step;
    BEGIN
      tot := tot + v;
      last := v;
    END;
  END LOOP;
  RETURN tot || '/' || last;
END $$;
SELECT pt_loop(5, 1.25), pt_loop(3, 7);
SELECT pt_loop(5, 1.25), pt_loop(3, 7);
SELECT pt_loop(5, 1.25), pt_loop(3, 7);
SELECT pt_loop(60, 1.25);
SELECT pt_loop(200, 99);  -- fail
SELECT pt_loop(5, 1.25), pt_loop(0, 2);
SELECT pj_expect('pt_loop(int,numeric)', 'compiled') \gset

-- a constant is cast when the function is translated; one that cannot be
-- stays for PL/pgSQL to fail on, every call
CREATE FUNCTION pt_k() RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := 3; m numeric(9,4) := 1.00005;
BEGIN RETURN n + m; END $$;
CREATE FUNCTION pt_kbad(x int) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(2,1) := 99;
BEGIN RETURN n + x; END $$;
SELECT pt_k(), pt_k(), pt_k();
SELECT pj_expect('pt_k()', 'compiled') \gset
SELECT pt_kbad(1);  -- fail
SELECT pt_kbad(1);  -- fail
SELECT pt_kbad(1);  -- fail
SELECT pj_expect('pt_kbad(int)', 'declined:22003: numeric field overflow') \gset

-- the assignment of a computed value; the coercion is a part of its tree
CREATE FUNCTION pt_asg(x numeric, y int) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2); m numeric(6,1);
BEGIN
  n := x * y;
  m := n + 0.049;
  RETURN n + m;
END $$;
SELECT pt_asg(1.111, 3), pt_asg(0.5, 7);
SELECT pt_asg(1.111, 3), pt_asg(0.5, 7);
SELECT pt_asg(1.111, 3), pt_asg(0.5, 7);
SELECT pj_expect('pt_asg(numeric,int)', 'compiled') \gset
SELECT pt_asg(100, 100);  -- fail
SELECT pt_asg(1.111, 3);

-- what is still not ours: another source type, another target
CREATE FUNCTION pt_f8(x float8) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_txt(x text) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pt_vc(x numeric) RETURNS varchar LANGUAGE :pj_lang AS $$
DECLARE v varchar(4) := x;
BEGIN RETURN v; END $$;
SELECT pt_f8(1.5), pt_txt('2.25'), pt_vc(1.5);
SELECT pt_f8(1.5), pt_txt('2.25'), pt_vc(1.5);
SELECT pt_f8(1.5), pt_txt('2.25'), pt_vc(1.5);
SELECT pj_expect('pt_f8(float8)', 'declined:cast') \gset
SELECT pj_expect('pt_txt(text)', 'declined:cast') \gset
SELECT pj_expect('pt_vc(numeric)', 'declined:cast') \gset
SELECT pt_f8(1000);  -- fail
SELECT pt_txt('1000');  -- fail
SELECT pt_vc(12345.6);  -- fail
