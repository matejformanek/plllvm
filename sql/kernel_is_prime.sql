--
-- kernel_is_prime: examples/kernels/is_prime.ll against the PL/pgSQL original
-- (bench/kernels/60_ispras2020.sql, is_prime_imm)
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/is_prime.ll`

CREATE FUNCTION is_prime_ll(n integer) RETURNS boolean
LANGUAGE plllvm IMMUTABLE AS :'ir';

CREATE FUNCTION is_prime_pl(n integer) RETURNS boolean
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  idx integer := 2;
BEGIN
  LOOP
    IF idx > n/2 THEN
      RETURN TRUE;
    END IF;
    IF mod(n, idx) = 0 THEN
      RETURN FALSE;
    END IF;
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

SELECT s.n, is_prime_ll(s.n) AS ll, is_prime_ll(s.n) = is_prime_pl(s.n) AS ok
FROM (SELECT n FROM (VALUES (-7), (0), (1), (2), (3), (4), (9), (97),
                            (7917), (7919), (1000003)) v(n)
      OFFSET 0) s
ORDER BY s.n;

SELECT count(*) FILTER (WHERE is_prime_ll(g) = is_prime_pl(g)) AS ok
FROM generate_series(-10, 2000) g;

-- NULL n: PL/pgSQL fails with 22003 only after 2^31 iterations, so only
-- the plllvm side is run here (the C twin bench/ctwins/cb/is_prime.c does
-- the same shortcut)
SELECT sqlstate_of('SELECT is_prime_ll(n) FROM (SELECT NULL::int AS n OFFSET 0) s') AS ll;

-- the size of EXP-001
SELECT is_prime_ll(20000003);

SELECT state FROM plllvm_function_status('is_prime_ll(integer)');

DROP FUNCTION sqlstate_of(text);
DROP FUNCTION is_prime_ll(integer);
DROP FUNCTION is_prime_pl(integer);
