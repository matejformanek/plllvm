--
-- expr_bool: AND, OR, NOT, NULL and boolean tests, CASE, COALESCE, NULLIF,
-- abs(), sqrt() and the casts from float8 under plllvm.expr_jit
--
-- The expected output is stock PL/pgSQL's, and make installcheck-expr
-- compares every variant against it; the plllvm check runs only where
-- plllvm is loaded, and prints nothing.  Each case runs three times in one
-- ExprState, the edge values third (after the group's harmless values,
-- where it has them).  A result is the value, "N" for NULL, "E" and the
-- SQLSTATE for an error, or "B" for an error at a harmless evaluation,
-- which must never appear.  An argument the interpreter skips must not
-- raise an error here either.
--

-- the groups: parameter types, harmless values (NULL: the edge values all
-- three times)
CREATE TABLE xb_groups (grp text PRIMARY KEY, ta text, tb text,
                        ha text, hb text);
INSERT INTO xb_groups VALUES
  ('bool', 'bool', 'bool', NULL, NULL),
  ('int', 'int4', 'int4', '1', '1'),
  ('mixed', 'int8', 'int4', '1', '1'),
  ('float', 'float8', 'float8', '1', '1');

-- the edge values of each group
CREATE TABLE xb_values (id serial, grp text, a text, b text);
INSERT INTO xb_values (grp, a, b) VALUES
  ('bool', 'true', 'true'), ('bool', 'true', 'false'),
  ('bool', 'true', NULL), ('bool', 'false', 'true'),
  ('bool', 'false', 'false'), ('bool', 'false', NULL),
  ('bool', NULL, 'true'), ('bool', NULL, 'false'), ('bool', NULL, NULL),
  ('int', '0', '0'), ('int', '1', '0'), ('int', '-1', '0'),
  ('int', '3', '2'), ('int', '-4', '2'), ('int', '10', '3'),
  ('int', NULL, '0'), ('int', '0', NULL), ('int', NULL, NULL),
  ('int', '-2147483648', '1'), ('int', '2147483647', '-1'),
  ('mixed', '1', '1'), ('mixed', '3000000000', '1'), ('mixed', '2', '2'),
  ('mixed', '-3', '0'), ('mixed', NULL, '5'), ('mixed', '5', NULL),
  ('mixed', NULL, NULL), ('mixed', '-9223372036854775808', '0'),
  ('float', '4', '2'), ('float', '2', '0'), ('float', '0', '0'),
  ('float', '-0', '-0'), ('float', '-1', '1'), ('float', '1e-320', '0'),
  ('float', 'Infinity', '1'), ('float', '-Infinity', '1'),
  ('float', 'NaN', 'NaN'), ('float', '0.5', NULL), ('float', NULL, '0.5'),
  ('float', NULL, NULL), ('float', '2.5', '0.5'), ('float', '3.5', '0'),
  ('float', '-2.5', '0'), ('float', '2147483647.4', '0'),
  ('float', '2147483647.5', '0'), ('float', '-2147483648.5', '0'),
  ('float', '-2147483649', '0'), ('float', '-9223372036854775808', '0'),
  ('float', '9223372036854775807', '0'), ('float', '1e19', '0');

-- the cases: an expression of a and b, of type tr
CREATE TABLE xb_cases (id serial, grp text, expr text, tr text);
INSERT INTO xb_cases (grp, expr, tr) VALUES
  ('bool', 'a AND b', 'bool'),
  ('bool', 'a OR b', 'bool'),
  ('bool', 'NOT a', 'bool'),
  ('bool', 'NOT (a AND b)', 'bool'),
  ('bool', 'a AND NOT b AND a IS NOT NULL', 'bool'),
  ('bool', 'a OR NOT b OR b IS NULL', 'bool'),
  ('bool', '(a OR b) AND (a = b)', 'bool'),
  ('bool', 'a IS TRUE', 'bool'),
  ('bool', 'a IS NOT TRUE', 'bool'),
  ('bool', 'a IS FALSE', 'bool'),
  ('bool', 'a IS NOT FALSE', 'bool'),
  ('bool', 'a IS UNKNOWN', 'bool'),
  ('bool', 'a IS NOT UNKNOWN', 'bool'),
  ('bool', 'a IS NULL', 'bool'),
  ('bool', '(a AND b) IS NOT NULL', 'bool'),
  ('bool', 'coalesce(a, b)', 'bool'),
  ('bool', 'nullif(a, b)', 'bool'),
  ('bool', 'CASE a WHEN b THEN 1 ELSE 0 END', 'int4'),
  ('bool', 'CASE WHEN a THEN 1 WHEN b THEN 2 END', 'int4'),
  ('int', 'a <> 0 AND 10 / a > 1', 'bool'),
  ('int', 'a = 0 OR 10 / a > 1', 'bool'),
  ('int', 'b = 0 OR a / b > 1', 'bool'),
  ('int', 'a > 0 AND b > 0 AND a / b > 1', 'bool'),
  ('int', 'a IS NULL OR a / b = 1', 'bool'),
  ('int', 'CASE WHEN a = 0 THEN 0 ELSE 10 / a END', 'int4'),
  ('int', 'CASE WHEN a > 0 THEN a WHEN a < 0 THEN 10 / b ELSE a / b END',
   'int4'),
  ('int', 'CASE WHEN a > 0 THEN a * 2 END', 'int4'),
  ('int', 'CASE a WHEN 1 THEN 10 WHEN 2 THEN 20 ELSE 0 END', 'int4'),
  ('int', 'CASE a WHEN 0 THEN 0 WHEN 10 / a THEN 1 ELSE 2 END', 'int4'),
  ('int', 'CASE a WHEN 1 THEN CASE b WHEN 1 THEN 11 ELSE 10 END '
          'ELSE CASE WHEN b = 1 THEN 1 ELSE 0 END END', 'int4'),
  ('int', 'CASE a + 1 WHEN b THEN a / b WHEN 0 THEN -1 END', 'int4'),
  ('int', 'coalesce(a, b)', 'int4'),
  ('int', 'coalesce(a, b, 7)', 'int4'),
  ('int', 'coalesce(a, 10 / b)', 'int4'),
  ('int', 'coalesce(nullif(a, 0), 1)', 'int4'),
  ('int', 'nullif(a, b)', 'int4'),
  ('int', 'nullif(a, 10 / b)', 'int4'),
  ('int', 'a IS NULL', 'bool'),
  ('int', '(a + b) IS NOT NULL', 'bool'),
  ('int', '(a / b) IS NULL', 'bool'),
  ('int', 'abs(a)', 'int4'),
  ('int', '@ b', 'int4'),
  ('int', 'abs(a - b)', 'int4'),
  ('mixed', 'CASE a WHEN 1 THEN 10 WHEN 3000000000 THEN 30 END', 'int4'),
  ('mixed', 'CASE a WHEN b THEN 1 ELSE 0 END', 'int4'),
  ('mixed', 'nullif(a, b)', 'int8'),
  ('mixed', 'coalesce(a, b)', 'int8'),
  ('mixed', 'abs(a)', 'int8'),
  ('mixed', 'a IS NULL AND b IS NULL', 'bool'),
  ('mixed', 'a > b OR a / b > 0', 'bool'),
  ('float', 'sqrt(a)', 'float8'),
  ('float', '|/ a', 'float8'),
  ('float', 'dsqrt(a)', 'float8'),
  ('float', 'sqrt(a) * b', 'float8'),
  ('float', 'abs(a)', 'float8'),
  ('float', '@ a', 'float8'),
  ('float', 'a::int4', 'int4'),
  ('float', 'int4(a)', 'int4'),
  ('float', 'a::int8', 'int8'),
  ('float', '(a::int8 + 1)::float8', 'float8'),
  ('float', 'nullif(a, b)', 'float8'),
  ('float', 'coalesce(a, b)', 'float8'),
  ('float', 'CASE a WHEN 0.5 THEN 1 ELSE 0 END', 'int4'),
  ('float', 'a > 0 AND sqrt(a) > b', 'bool'),
  ('float', 'a < 0 OR sqrt(a) > b', 'bool'),
  ('float', 'CASE WHEN a >= 0 THEN sqrt(a) ELSE -sqrt(-a) END', 'float8'),
  ('float', 'a IS NOT NULL AND b IS NULL', 'bool');

-- one function per case: xb_<id>(a0, b0)
DO $do$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT x.id, x.expr, x.tr, g.ta, g.tb, g.ha, g.hb
      FROM xb_cases x JOIN xb_groups g USING (grp)
  LOOP
    EXECUTE format($f$
CREATE FUNCTION xb_%1$s(a0 %2$s, b0 %3$s) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
  a %2$s;
  b %3$s;
  n int;
  r %4$s;
BEGIN
  FOR k IN 1..3 LOOP
    n := k;
    %5$s
    r := %6$s;
  END LOOP;
  RETURN coalesce(r::text, 'N');
EXCEPTION WHEN OTHERS THEN
  RETURN CASE WHEN n < 3 THEN 'B' ELSE 'E' || SQLSTATE END;
END
$$$f$, c.id, c.ta, c.tb, c.tr,
      CASE WHEN c.ha IS NULL THEN 'a := a0; b := b0;'
           ELSE format('a := CASE k WHEN 3 THEN a0 ELSE %s END; '
                       'b := CASE k WHEN 3 THEN b0 ELSE %s END;',
                       c.ha, c.hb)
      END,
      c.expr);
  END LOOP;
END
$do$;

-- every case on every value of its group, one transaction each
CREATE TABLE xb_res (case_id int, value_id int, r text);
CREATE PROCEDURE xb_run()
LANGUAGE plpgsql AS $$
DECLARE
  c record;
  r text;
BEGIN
  FOR c IN
    SELECT x.id AS case_id, v.id AS value_id, v.a, v.b, g.ta, g.tb
      FROM xb_cases x JOIN xb_values v USING (grp) JOIN xb_groups g USING (grp)
     ORDER BY x.id, v.id
  LOOP
    EXECUTE format('SELECT xb_%s(%L::%s, %L::%s)',
                   c.case_id, c.a, c.ta, c.b, c.tb) INTO r;
    INSERT INTO xb_res VALUES (c.case_id, c.value_id, r);
    COMMIT;
  END LOOP;
END
$$;

-- with plllvm loaded, what it installed before the run
DO $$
BEGIN
  IF current_setting('plllvm.expr_jit', true) IS NOT NULL THEN
    EXECUTE 'CREATE TEMP TABLE xb_before AS
               SELECT installed FROM plllvm_expr_stats()';
  END IF;
END
$$;

CALL xb_run();

-- with plllvm.expr_jit on, every case got code for every value, and so did
-- the CASEs that pick the harmless values
DO $$
DECLARE
  n int8;
  want int8;
BEGIN
  IF current_setting('plllvm.expr_jit', true)::bool THEN
    SELECT sum(CASE WHEN g.ha IS NULL THEN 1 ELSE 3 END) INTO want
      FROM xb_cases x JOIN xb_values v USING (grp) JOIN xb_groups g USING (grp);
    EXECUTE 'SELECT s.installed - b.installed
               FROM plllvm_expr_stats() s, xb_before b' INTO n;
    IF n <> want THEN
      RAISE EXCEPTION '% expressions installed, not %', n, want;
    END IF;
  END IF;
  IF current_setting('plllvm.expr_jit', true) IS NOT NULL THEN
    EXECUTE 'DROP TABLE xb_before';
  END IF;
END
$$;

-- the values of each group, then each case's results in that order
\a
SELECT grp, string_agg(coalesce(a, 'N') || ',' || coalesce(b, 'N'), ' '
                       ORDER BY id) AS "values"
  FROM xb_values GROUP BY grp ORDER BY grp;
SELECT x.grp, x.expr, string_agg(r.r, ' ' ORDER BY r.value_id) AS results
  FROM xb_cases x JOIN xb_res r ON r.case_id = x.id
 GROUP BY x.id, x.grp, x.expr ORDER BY x.id;
\a

-- errors at the third evaluation: message and CONTEXT
CREATE FUNCTION xb_err(e float8, x int, c int8, p bool) RETURNS bool
LANGUAGE plpgsql AS $$
DECLARE
  f float8;
  y int;
  d int8;
  q bool;
  rf float8;
  ri int;
  rl int8;
  rb bool;
BEGIN
  FOR k IN 1..3 LOOP
    f := CASE k WHEN 3 THEN e ELSE 1 END;
    y := CASE k WHEN 3 THEN x ELSE 1 END;
    d := CASE k WHEN 3 THEN c ELSE 1 END;
    q := CASE k WHEN 3 THEN p ELSE true END;
    rf := sqrt(f);
    ri := abs(y);
    rl := abs(d);
    rl := f::int8;
    ri := f::int4;
    rb := q AND 10 / y > 1;
  END LOOP;
  RETURN rb;
END
$$;
SELECT xb_err(1, 1, 1, NULL);
SELECT xb_err(-1, 1, 1, true);
SELECT xb_err(1, -2147483648, 1, true);
SELECT xb_err(1, 1, -9223372036854775808, true);
SELECT xb_err(1e19, 1, 1, true);
SELECT xb_err(2147483647.5, 1, 1, true);
SELECT xb_err(1, 0, 1, false);
SELECT xb_err(1, 0, 1, NULL);

DO $$
DECLARE
  c record;
BEGIN
  FOR c IN SELECT id, g.ta, g.tb
             FROM xb_cases x JOIN xb_groups g USING (grp)
  LOOP
    EXECUTE format('DROP FUNCTION xb_%s(%s, %s)', c.id, c.ta, c.tb);
  END LOOP;
END
$$;
DROP FUNCTION xb_err(float8, int, int8, bool);
DROP PROCEDURE xb_run();
DROP TABLE xb_res, xb_cases, xb_values, xb_groups;
