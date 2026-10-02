--
-- kernel_ispras: examples/kernels/{gt,inc,sumn}.ll against the PL/pgSQL
-- originals (bench/kernels/60_ispras2020.sql, gt_imm, inc_imm, sumn_imm) and
-- the queries q2-q4 of EXP-001 on its table tbl (40_glue_schema.sql);
-- is_prime (q1) is kernel_is_prime
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set gt_ir `cat :'abs_srcdir'/examples/kernels/gt.ll`
\set inc_ir `cat :'abs_srcdir'/examples/kernels/inc.ll`
\set sumn_ir `cat :'abs_srcdir'/examples/kernels/sumn.ll`

CREATE TABLE tbl (a integer, b integer);
INSERT INTO tbl
SELECT ((g::bigint * 7919) % 64)::integer, ((g::bigint * 104729 + 13) % 61)::integer
FROM generate_series(1, 3000000) g;
ANALYZE tbl;

CREATE FUNCTION gt_ll(x integer, y integer) RETURNS boolean
LANGUAGE plllvm IMMUTABLE AS :'gt_ir';

CREATE FUNCTION inc_ll(x integer) RETURNS integer
LANGUAGE plllvm IMMUTABLE AS :'inc_ir';

CREATE FUNCTION sumn_ll(n integer) RETURNS integer
LANGUAGE plllvm IMMUTABLE AS :'sumn_ir';

CREATE FUNCTION gt_pl(x integer, y integer) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF x > y THEN
    RETURN TRUE;
  ELSE
    RETURN FALSE;
  END IF;
END
$$;

CREATE FUNCTION inc_pl(x integer) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN x + 1;
END
$$;

CREATE FUNCTION sumn_pl(n integer) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  sum integer := 0;
  idx integer := 0;
BEGIN
  LOOP
    IF idx > n THEN
      RETURN sum;
    END IF;
    sum := sum + idx;
    idx := idx + 1;
  END LOOP;
END
$$;

CREATE FUNCTION sqlstate_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END
$$;

SELECT s.x, s.y, gt_ll(s.x, s.y) AS ll,
       gt_ll(s.x, s.y) IS NOT DISTINCT FROM gt_pl(s.x, s.y) AS ok
FROM (SELECT * FROM (VALUES (1, 2), (2, 1), (2, 2), (-2147483648, 2147483647),
                            (NULL, 1), (1, NULL), (NULL, NULL)) v(x, y)
      OFFSET 0) s
ORDER BY 1, 2;

SELECT s.x, inc_ll(s.x) AS ll, inc_ll(s.x) IS NOT DISTINCT FROM inc_pl(s.x) AS ok
FROM (SELECT x FROM (VALUES (-2147483648), (-1), (0), (63), (NULL)) v(x) OFFSET 0) s
ORDER BY 1;

SELECT s.n, sumn_ll(s.n) AS ll, sumn_ll(s.n) = sumn_pl(s.n) AS ok
FROM (SELECT n FROM (VALUES (-5), (0), (1), (63), (65535)) v(n) OFFSET 0) s
ORDER BY 1;

-- inc overflows (22003), sumn at "sum + idx" (22003), also with a NULL n
SELECT sqlstate_of('SELECT inc_ll(x) FROM (SELECT 2147483647 AS x OFFSET 0) s') AS inc_ll,
       sqlstate_of('SELECT inc_pl(x) FROM (SELECT 2147483647 AS x OFFSET 0) s') AS inc_pl;
SELECT s.n,
       sqlstate_of(format('SELECT sumn_ll(n) FROM (SELECT %L::int AS n OFFSET 0) s', s.n)) AS ll,
       sqlstate_of(format('SELECT sumn_pl(n) FROM (SELECT %L::int AS n OFFSET 0) s', s.n)) AS pl
FROM (VALUES (NULL::int), (65536)) s(n);

-- q2-q4 on every (a, b) of tbl, against PL/pgSQL
CREATE TABLE ab AS
SELECT a, b FROM generate_series(0, 63) a, generate_series(0, 60) b;
SELECT (SELECT count(*) FROM ab WHERE gt_ll(a, b) = true)
     = (SELECT count(*) FROM ab WHERE gt_pl(a, b) = true) AS q2,
       (SELECT sum(inc_ll(a)) FROM ab WHERE gt_ll(a, b) = true)
     = (SELECT sum(inc_pl(a)) FROM ab WHERE gt_pl(a, b) = true) AS q3,
       (SELECT sum(sumn_ll(a)) FROM ab WHERE gt_ll(a, b) = false)
     = (SELECT sum(sumn_pl(a)) FROM ab WHERE gt_pl(a, b) = false) AS q4;

-- the queries of EXP-001
SELECT count(*) FROM tbl WHERE gt_ll(a, b) = true;
SELECT sum(inc_ll(a)) FROM tbl WHERE gt_ll(a, b) = true;
SELECT sum(sumn_ll(a)) FROM tbl WHERE gt_ll(a, b) = false;

SELECT p, s.state
FROM unnest(ARRAY['gt_ll(integer,integer)', 'inc_ll(integer)',
                  'sumn_ll(integer)']::regprocedure[]) p,
     plllvm_function_status(p) s
ORDER BY p::text;

DROP FUNCTION sqlstate_of(text);
DROP FUNCTION gt_ll(integer, integer), inc_ll(integer), sumn_ll(integer);
DROP FUNCTION gt_pl(integer, integer), inc_pl(integer), sumn_pl(integer);
DROP TABLE ab, tbl;
