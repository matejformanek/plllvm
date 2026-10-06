--
-- expr_collide: expressions whose serialisations share a prefix, so that
-- they may share a hash bucket of the expression cache; each must still
-- get its own program
--
-- The expected output is stock PL/pgSQL's, and make installcheck-expr
-- compares every variant against it; the one plllvm query is true in
-- every variant.  Every
-- function evaluates its expression three times per call.  Each list runs
-- twice (the second time from the cache), then again in a new session with
-- the other function of each pair first.
--

-- Consts that differ only in value
CREATE FUNCTION ec_p1a(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + 1;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p1b(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + 2;
  END LOOP;
  RETURN r;
END
$$;

-- the same operator, the Params swapped
CREATE FUNCTION ec_p2a(x int, y int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x - y;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p2b(x int, y int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := y - x;
  END LOOP;
  RETURN r;
END
$$;

-- the same nodes in another tree
CREATE FUNCTION ec_p3a(x int, y int, z int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := (x + y) * z;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p3b(x int, y int, z int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + y * z;
  END LOOP;
  RETURN r;
END
$$;

-- an int4 and an int8 Param at the same paramid
CREATE FUNCTION ec_p4a(x int, y int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + y;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p4b(x bigint, y int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + y;
  END LOOP;
  RETURN r;
END
$$;

-- the same text, the variables declared in the other order
CREATE FUNCTION ec_p5a(x int, y int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x - y;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p5b(y int, x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x - y;
  END LOOP;
  RETURN r;
END
$$;

-- float8, the Params swapped
CREATE FUNCTION ec_p6a(e float8, f float8) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
  r float8;
BEGIN
  FOR k IN 1..3 LOOP
    r := e / f;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p6b(e float8, f float8) RETURNS float8
LANGUAGE plpgsql AS $$
DECLARE
  r float8;
BEGIN
  FOR k IN 1..3 LOOP
    r := f / e;
  END LOOP;
  RETURN r;
END
$$;

-- neighbouring comparisons
CREATE FUNCTION ec_p7a(x int, y int) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE
  r bool;
BEGIN
  FOR k IN 1..3 LOOP
    r := x < y;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p7b(x int, y int) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE
  r bool;
BEGIN
  FOR k IN 1..3 LOOP
    r := x <= y;
  END LOOP;
  RETURN r;
END
$$;

-- an int4 and an int8 Const
CREATE FUNCTION ec_p8a(x bigint) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + 1;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p8b(x bigint) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  r bigint;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + 1::bigint;
  END LOOP;
  RETURN r;
END
$$;

-- division and modulo
CREATE FUNCTION ec_p9a(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x / 3;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_p9b(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x % 3;
  END LOOP;
  RETURN r;
END
$$;

-- a first
SELECT 'p1' AS pair, '5' AS args,
       ec_p1a(5)::text AS a,
       ec_p1b(5)::text AS b
UNION ALL
SELECT 'p1' AS pair, '-1' AS args,
       ec_p1a(-1)::text AS a,
       ec_p1b(-1)::text AS b
UNION ALL
SELECT 'p2' AS pair, '7, 2' AS args,
       ec_p2a(7, 2)::text AS a,
       ec_p2b(7, 2)::text AS b
UNION ALL
SELECT 'p2' AS pair, '2, 7' AS args,
       ec_p2a(2, 7)::text AS a,
       ec_p2b(2, 7)::text AS b
UNION ALL
SELECT 'p3' AS pair, '2, 3, 4' AS args,
       ec_p3a(2, 3, 4)::text AS a,
       ec_p3b(2, 3, 4)::text AS b
UNION ALL
SELECT 'p3' AS pair, '-1, 5, 0' AS args,
       ec_p3a(-1, 5, 0)::text AS a,
       ec_p3b(-1, 5, 0)::text AS b
UNION ALL
SELECT 'p4' AS pair, '1, 2' AS args,
       ec_p4a(1, 2)::text AS a,
       ec_p4b(1, 2)::text AS b
UNION ALL
SELECT 'p4' AS pair, '2000000000, 147483647' AS args,
       ec_p4a(2000000000, 147483647)::text AS a,
       ec_p4b(2000000000, 147483647)::text AS b
UNION ALL
SELECT 'p5' AS pair, '10, 3' AS args,
       ec_p5a(10, 3)::text AS a,
       ec_p5b(10, 3)::text AS b
UNION ALL
SELECT 'p5' AS pair, '3, 10' AS args,
       ec_p5a(3, 10)::text AS a,
       ec_p5b(3, 10)::text AS b
UNION ALL
SELECT 'p6' AS pair, '1, 4' AS args,
       ec_p6a(1, 4)::text AS a,
       ec_p6b(1, 4)::text AS b
UNION ALL
SELECT 'p6' AS pair, '0.5, ''-Infinity''' AS args,
       ec_p6a(0.5, '-Infinity')::text AS a,
       ec_p6b(0.5, '-Infinity')::text AS b
UNION ALL
SELECT 'p7' AS pair, '3, 3' AS args,
       ec_p7a(3, 3)::text AS a,
       ec_p7b(3, 3)::text AS b
UNION ALL
SELECT 'p7' AS pair, '2, 3' AS args,
       ec_p7a(2, 3)::text AS a,
       ec_p7b(2, 3)::text AS b
UNION ALL
SELECT 'p8' AS pair, '9223372036854775806' AS args,
       ec_p8a(9223372036854775806)::text AS a,
       ec_p8b(9223372036854775806)::text AS b
UNION ALL
SELECT 'p8' AS pair, '-3' AS args,
       ec_p8a(-3)::text AS a,
       ec_p8b(-3)::text AS b
UNION ALL
SELECT 'p9' AS pair, '10' AS args,
       ec_p9a(10)::text AS a,
       ec_p9b(10)::text AS b
UNION ALL
SELECT 'p9' AS pair, '-7' AS args,
       ec_p9a(-7)::text AS a,
       ec_p9b(-7)::text AS b;
SELECT 'p1' AS pair, '5' AS args,
       ec_p1a(5)::text AS a,
       ec_p1b(5)::text AS b
UNION ALL
SELECT 'p1' AS pair, '-1' AS args,
       ec_p1a(-1)::text AS a,
       ec_p1b(-1)::text AS b
UNION ALL
SELECT 'p2' AS pair, '7, 2' AS args,
       ec_p2a(7, 2)::text AS a,
       ec_p2b(7, 2)::text AS b
UNION ALL
SELECT 'p2' AS pair, '2, 7' AS args,
       ec_p2a(2, 7)::text AS a,
       ec_p2b(2, 7)::text AS b
UNION ALL
SELECT 'p3' AS pair, '2, 3, 4' AS args,
       ec_p3a(2, 3, 4)::text AS a,
       ec_p3b(2, 3, 4)::text AS b
UNION ALL
SELECT 'p3' AS pair, '-1, 5, 0' AS args,
       ec_p3a(-1, 5, 0)::text AS a,
       ec_p3b(-1, 5, 0)::text AS b
UNION ALL
SELECT 'p4' AS pair, '1, 2' AS args,
       ec_p4a(1, 2)::text AS a,
       ec_p4b(1, 2)::text AS b
UNION ALL
SELECT 'p4' AS pair, '2000000000, 147483647' AS args,
       ec_p4a(2000000000, 147483647)::text AS a,
       ec_p4b(2000000000, 147483647)::text AS b
UNION ALL
SELECT 'p5' AS pair, '10, 3' AS args,
       ec_p5a(10, 3)::text AS a,
       ec_p5b(10, 3)::text AS b
UNION ALL
SELECT 'p5' AS pair, '3, 10' AS args,
       ec_p5a(3, 10)::text AS a,
       ec_p5b(3, 10)::text AS b
UNION ALL
SELECT 'p6' AS pair, '1, 4' AS args,
       ec_p6a(1, 4)::text AS a,
       ec_p6b(1, 4)::text AS b
UNION ALL
SELECT 'p6' AS pair, '0.5, ''-Infinity''' AS args,
       ec_p6a(0.5, '-Infinity')::text AS a,
       ec_p6b(0.5, '-Infinity')::text AS b
UNION ALL
SELECT 'p7' AS pair, '3, 3' AS args,
       ec_p7a(3, 3)::text AS a,
       ec_p7b(3, 3)::text AS b
UNION ALL
SELECT 'p7' AS pair, '2, 3' AS args,
       ec_p7a(2, 3)::text AS a,
       ec_p7b(2, 3)::text AS b
UNION ALL
SELECT 'p8' AS pair, '9223372036854775806' AS args,
       ec_p8a(9223372036854775806)::text AS a,
       ec_p8b(9223372036854775806)::text AS b
UNION ALL
SELECT 'p8' AS pair, '-3' AS args,
       ec_p8a(-3)::text AS a,
       ec_p8b(-3)::text AS b
UNION ALL
SELECT 'p9' AS pair, '10' AS args,
       ec_p9a(10)::text AS a,
       ec_p9b(10)::text AS b
UNION ALL
SELECT 'p9' AS pair, '-7' AS args,
       ec_p9a(-7)::text AS a,
       ec_p9b(-7)::text AS b;

-- a fresh cache, b first
\c
SELECT 'p1' AS pair, '5' AS args,
       ec_p1b(5)::text AS b,
       ec_p1a(5)::text AS a
UNION ALL
SELECT 'p1' AS pair, '-1' AS args,
       ec_p1b(-1)::text AS b,
       ec_p1a(-1)::text AS a
UNION ALL
SELECT 'p2' AS pair, '7, 2' AS args,
       ec_p2b(7, 2)::text AS b,
       ec_p2a(7, 2)::text AS a
UNION ALL
SELECT 'p2' AS pair, '2, 7' AS args,
       ec_p2b(2, 7)::text AS b,
       ec_p2a(2, 7)::text AS a
UNION ALL
SELECT 'p3' AS pair, '2, 3, 4' AS args,
       ec_p3b(2, 3, 4)::text AS b,
       ec_p3a(2, 3, 4)::text AS a
UNION ALL
SELECT 'p3' AS pair, '-1, 5, 0' AS args,
       ec_p3b(-1, 5, 0)::text AS b,
       ec_p3a(-1, 5, 0)::text AS a
UNION ALL
SELECT 'p4' AS pair, '1, 2' AS args,
       ec_p4b(1, 2)::text AS b,
       ec_p4a(1, 2)::text AS a
UNION ALL
SELECT 'p4' AS pair, '2000000000, 147483647' AS args,
       ec_p4b(2000000000, 147483647)::text AS b,
       ec_p4a(2000000000, 147483647)::text AS a
UNION ALL
SELECT 'p5' AS pair, '10, 3' AS args,
       ec_p5b(10, 3)::text AS b,
       ec_p5a(10, 3)::text AS a
UNION ALL
SELECT 'p5' AS pair, '3, 10' AS args,
       ec_p5b(3, 10)::text AS b,
       ec_p5a(3, 10)::text AS a
UNION ALL
SELECT 'p6' AS pair, '1, 4' AS args,
       ec_p6b(1, 4)::text AS b,
       ec_p6a(1, 4)::text AS a
UNION ALL
SELECT 'p6' AS pair, '0.5, ''-Infinity''' AS args,
       ec_p6b(0.5, '-Infinity')::text AS b,
       ec_p6a(0.5, '-Infinity')::text AS a
UNION ALL
SELECT 'p7' AS pair, '3, 3' AS args,
       ec_p7b(3, 3)::text AS b,
       ec_p7a(3, 3)::text AS a
UNION ALL
SELECT 'p7' AS pair, '2, 3' AS args,
       ec_p7b(2, 3)::text AS b,
       ec_p7a(2, 3)::text AS a
UNION ALL
SELECT 'p8' AS pair, '9223372036854775806' AS args,
       ec_p8b(9223372036854775806)::text AS b,
       ec_p8a(9223372036854775806)::text AS a
UNION ALL
SELECT 'p8' AS pair, '-3' AS args,
       ec_p8b(-3)::text AS b,
       ec_p8a(-3)::text AS a
UNION ALL
SELECT 'p9' AS pair, '10' AS args,
       ec_p9b(10)::text AS b,
       ec_p9a(10)::text AS a
UNION ALL
SELECT 'p9' AS pair, '-7' AS args,
       ec_p9b(-7)::text AS b,
       ec_p9a(-7)::text AS a;
SELECT 'p1' AS pair, '5' AS args,
       ec_p1b(5)::text AS b,
       ec_p1a(5)::text AS a
UNION ALL
SELECT 'p1' AS pair, '-1' AS args,
       ec_p1b(-1)::text AS b,
       ec_p1a(-1)::text AS a
UNION ALL
SELECT 'p2' AS pair, '7, 2' AS args,
       ec_p2b(7, 2)::text AS b,
       ec_p2a(7, 2)::text AS a
UNION ALL
SELECT 'p2' AS pair, '2, 7' AS args,
       ec_p2b(2, 7)::text AS b,
       ec_p2a(2, 7)::text AS a
UNION ALL
SELECT 'p3' AS pair, '2, 3, 4' AS args,
       ec_p3b(2, 3, 4)::text AS b,
       ec_p3a(2, 3, 4)::text AS a
UNION ALL
SELECT 'p3' AS pair, '-1, 5, 0' AS args,
       ec_p3b(-1, 5, 0)::text AS b,
       ec_p3a(-1, 5, 0)::text AS a
UNION ALL
SELECT 'p4' AS pair, '1, 2' AS args,
       ec_p4b(1, 2)::text AS b,
       ec_p4a(1, 2)::text AS a
UNION ALL
SELECT 'p4' AS pair, '2000000000, 147483647' AS args,
       ec_p4b(2000000000, 147483647)::text AS b,
       ec_p4a(2000000000, 147483647)::text AS a
UNION ALL
SELECT 'p5' AS pair, '10, 3' AS args,
       ec_p5b(10, 3)::text AS b,
       ec_p5a(10, 3)::text AS a
UNION ALL
SELECT 'p5' AS pair, '3, 10' AS args,
       ec_p5b(3, 10)::text AS b,
       ec_p5a(3, 10)::text AS a
UNION ALL
SELECT 'p6' AS pair, '1, 4' AS args,
       ec_p6b(1, 4)::text AS b,
       ec_p6a(1, 4)::text AS a
UNION ALL
SELECT 'p6' AS pair, '0.5, ''-Infinity''' AS args,
       ec_p6b(0.5, '-Infinity')::text AS b,
       ec_p6a(0.5, '-Infinity')::text AS a
UNION ALL
SELECT 'p7' AS pair, '3, 3' AS args,
       ec_p7b(3, 3)::text AS b,
       ec_p7a(3, 3)::text AS a
UNION ALL
SELECT 'p7' AS pair, '2, 3' AS args,
       ec_p7b(2, 3)::text AS b,
       ec_p7a(2, 3)::text AS a
UNION ALL
SELECT 'p8' AS pair, '9223372036854775806' AS args,
       ec_p8b(9223372036854775806)::text AS b,
       ec_p8a(9223372036854775806)::text AS a
UNION ALL
SELECT 'p8' AS pair, '-3' AS args,
       ec_p8b(-3)::text AS b,
       ec_p8a(-3)::text AS a
UNION ALL
SELECT 'p9' AS pair, '10' AS args,
       ec_p9b(10)::text AS b,
       ec_p9a(10)::text AS a
UNION ALL
SELECT 'p9' AS pair, '-7' AS args,
       ec_p9b(-7)::text AS b,
       ec_p9a(-7)::text AS a;

-- an error in one of a pair leaves the other alone
SELECT ec_p4a(2147483647, 1);
SELECT ec_p4b(2147483647, 1), ec_p8b(9223372036854775806);
SELECT ec_p8b(9223372036854775807);
SELECT ec_p8a(9223372036854775806), ec_p9a(0), ec_p9b(0);

DROP FUNCTION ec_p1a(int),
  ec_p1b(int),
  ec_p2a(int, int),
  ec_p2b(int, int),
  ec_p3a(int, int, int),
  ec_p3b(int, int, int),
  ec_p4a(int, int),
  ec_p4b(bigint, int),
  ec_p5a(int, int),
  ec_p5b(int, int),
  ec_p6a(float8, float8),
  ec_p6b(float8, float8),
  ec_p7a(int, int),
  ec_p7b(int, int),
  ec_p8a(bigint),
  ec_p8b(bigint),
  ec_p9a(int),
  ec_p9b(int);

-- The same key, trees not equal(): an operator over int4pl other than +
-- differs from x + 12345 only in its OID, which the key leaves out.  The
-- second function must get its own program, not the first one's.
CREATE OPERATOR ### (LEFTARG = int, RIGHTARG = int, FUNCTION = int4pl);
CREATE FUNCTION ec_k1a(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x ### 12345;
  END LOOP;
  RETURN r;
END
$$;
CREATE FUNCTION ec_k1b(x int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  r int;
BEGIN
  FOR k IN 1..3 LOOP
    r := x + 12345;
  END LOOP;
  RETURN r;
END
$$;

CREATE TEMP TABLE ec_before AS
  SELECT compiled, installed FROM plllvm_expr_stats();
SELECT ec_k1a(1);
SELECT ec_k1b(2);
SELECT ec_k1a(3);
SELECT ec_k1b(4);

-- with plllvm.expr_jit on: two programs, each taken again from the cache
SELECT NOT coalesce(current_setting('plllvm.expr_jit', true), 'off')::bool
       OR (s.compiled - b.compiled = 2 AND s.installed - b.installed = 4)
         AS two_programs
  FROM plllvm_expr_stats() s, ec_before b;

DROP TABLE ec_before;
DROP FUNCTION ec_k1a(int), ec_k1b(int);
DROP OPERATOR ### (int, int);
