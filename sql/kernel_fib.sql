--
-- kernel_fib: examples/kernels/fib.ll against the PL/pgSQL original
-- (bench/kernels/50_diag.sql, fib_imm)
--
SET plllvm.regress_test_mode = on;
SET max_stack_depth = '2MB';

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/fib.ll`

CREATE FUNCTION fib_ll(n integer) RETURNS integer
LANGUAGE plllvm IMMUTABLE AS :'ir';

CREATE FUNCTION fib_pl(n integer) RETURNS integer
LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  IF n < 2 THEN
    RETURN n;
  END IF;
  RETURN fib_pl(n - 1) + fib_pl(n - 2);
END
$$;

SELECT s.n, fib_ll(s.n) AS ll, fib_ll(s.n) = fib_pl(s.n) AS ok
FROM (SELECT n FROM (VALUES (-3), (0), (1), (2), (10), (20)) v(n)
      OFFSET 0) s
ORDER BY s.n;

-- NULL n: PL/pgSQL recurses until the stack limit; fib_ll raises the same error
SELECT sqlstate_of('SELECT fib_ll(n) FROM (SELECT NULL::int AS n OFFSET 0) s') AS ll,
       sqlstate_of('SELECT fib_pl(n) FROM (SELECT NULL::int AS n OFFSET 0) s') AS pl;

-- the size of EXP-001
SELECT fib_ll(28);

SELECT state FROM plllvm_function_status('fib_ll(integer)');

DROP FUNCTION fib_ll(integer);
DROP FUNCTION fib_pl(integer);
RESET max_stack_depth;
