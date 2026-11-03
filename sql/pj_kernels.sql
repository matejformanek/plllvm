--
-- pj_kernels: the loop kernels of the bench, at the sizes of the other
-- tests; with plllvm loaded, each is compared with the hand-written one
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION loop_k(n integer) RETURNS integer LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE i integer := 0;
BEGIN
  WHILE i < n LOOP i := i + 1; END LOOP;
  RETURN i;
END $$;
CREATE FUNCTION is_prime_k(n integer) RETURNS boolean LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE idx integer := 2;
BEGIN
  LOOP
    IF idx > n/2 THEN RETURN TRUE; END IF;
    IF mod(n, idx) = 0 THEN RETURN FALSE; END IF;
    idx := idx + 1;
  END LOOP;
END $$;
CREATE FUNCTION sumn_k(n integer) RETURNS integer LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE sum integer := 0; idx integer := 0;
BEGIN
  LOOP
    IF idx > n THEN RETURN sum; END IF;
    sum := sum + idx;
    idx := idx + 1;
  END LOOP;
END $$;
CREATE FUNCTION gt_k(x integer, y integer) RETURNS boolean LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN
  IF x > y THEN RETURN TRUE; ELSE RETURN FALSE; END IF;
END $$;
CREATE FUNCTION inc_k(x integer) RETURNS integer LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN RETURN x + 1; END $$;

-- OFFSET 0 keeps the planner from folding the IMMUTABLE calls
SELECT loop_k(7), loop_k(7);
SELECT is_prime_k(7), is_prime_k(7);
SELECT sumn_k(7), sumn_k(7);
SELECT gt_k(2, 1), gt_k(1, 2);
SELECT inc_k(1), inc_k(2);
SELECT s.n, loop_k(s.n), is_prime_k(s.n), sumn_k(s.n), gt_k(s.n, 5), inc_k(s.n)
  FROM (SELECT n FROM (VALUES (-5), (0), (1), (2), (3), (4), (9), (97), (1000), (104729)) v(n)
        OFFSET 0) s ORDER BY s.n;
SELECT loop_k(100000), sumn_k(2000), is_prime_k(1000003);
SELECT pj_expect('loop_k(int)', 'compiled') \gset
SELECT pj_expect('is_prime_k(int)', 'compiled') \gset
SELECT pj_expect('sumn_k(int)', 'compiled') \gset
SELECT pj_expect('gt_k(int,int)', 'compiled') \gset
SELECT pj_expect('inc_k(int)', 'compiled') \gset

-- sumn overflows int4 as the interpreter does
SELECT sumn_k(100000);  -- fail
SELECT sumn_k(100000);  -- fail
SELECT pj_expect('sumn_k(int)', 'compiled') \gset

-- is_prime: the composite input deopts once, the next call is compiled
SELECT is_prime_k(9), is_prime_k(15), is_prime_k(11);
SELECT pj_expect('is_prime_k(int)', 'compiled') \gset

-- over rows, from a query
SELECT count(*) FILTER (WHERE is_prime_k(i)), sum(inc_k(i)), count(*) FILTER (WHERE gt_k(i, 50))
  FROM generate_series(2, 200) i;
SELECT pj_expect('is_prime_k(int)', 'compiled') \gset

-- mandelbrot at full size: the loops compiled, the result a text from the executor
CREATE FUNCTION mandelbrot_k(sz integer) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE
  two CONSTANT float8 := 2.0;
  four CONSTANT float8 := 4.0;
  one CONSTANT float8 := 1.0;
  onehalf CONSTANT float8 := 1.5;
  fsz float8;
  x integer; y integer; k integer;
  cr float8; ci float8; zr float8; zi float8; tr float8; ti float8;
  cnt integer := 0;
  h bigint := 0;
BEGIN
  fsz := sz;
  FOR y IN 0..sz-1 LOOP
    ci := two * y / fsz - one;
    FOR x IN 0..sz-1 LOOP
      cr := two * x / fsz - onehalf;
      zr := 0; zi := 0; tr := 0; ti := 0; k := 0;
      WHILE k < 50 AND tr + ti <= four LOOP
        zi := two * zr * zi + ci;
        zr := tr - ti + cr;
        tr := zr * zr;
        ti := zi * zi;
        k := k + 1;
      END LOOP;
      IF tr + ti <= four THEN
        cnt := cnt + 1;
        h := (h * 31 + x * 7 + y) % 1000000007;
      END IF;
    END LOOP;
  END LOOP;
  RETURN cnt::text || '/' || h::text;
END $$;
SELECT mandelbrot_k(20), mandelbrot_k(21);
SELECT pj_mark() \gset
SELECT mandelbrot_k(440);
SELECT pj_delta(1, 0, 1, 0, 0) \gset
SELECT pj_expect('mandelbrot_k(int)', 'compiled') \gset
