--
-- kernel_loop: examples/kernels/loop.ll against the PL/pgSQL original
-- (bench/kernels/50_diag.sql, loop_imm)
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/loop.ll`

CREATE FUNCTION loop_ll(n integer) RETURNS integer
LANGUAGE plllvm IMMUTABLE AS :'ir';

CREATE FUNCTION loop_pl(n integer) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  i integer := 0;
BEGIN
  WHILE i < n LOOP
    i := i + 1;
  END LOOP;
  RETURN i;
END
$$;

-- OFFSET 0 keeps the planner from folding the IMMUTABLE calls
SELECT s.n, loop_ll(s.n) AS ll, loop_ll(s.n) = loop_pl(s.n) AS ok
FROM (SELECT n FROM (VALUES (-5), (0), (1), (2), (1000), (100000)) v(n)
      OFFSET 0) s
ORDER BY s.n;

-- NULL n: the loop never runs, both return 0
SELECT loop_ll(s.n) AS ll, loop_pl(s.n) AS pl
FROM (SELECT NULL::int AS n OFFSET 0) s;

-- the size of EXP-001
SELECT loop_ll(20000000);

SELECT state FROM plllvm_function_status('loop_ll(integer)');

DROP FUNCTION loop_ll(integer);
DROP FUNCTION loop_pl(integer);
