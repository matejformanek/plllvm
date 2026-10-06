--
-- Operator helpers of the host API: one normal and one edge or error case
-- each, against the SQL operator
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

-- plllvm_<helper> is the SQL expression op of arguments of types ta, tb
CREATE TEMP TABLE op_helpers (helper text, op text, ta text, tb text, tr text);
INSERT INTO op_helpers VALUES
  ('int4_pl', '%s + %s', 'int4', 'int4', 'int4'),
  ('int4_mi', '%s - %s', 'int4', 'int4', 'int4'),
  ('int4_mul', '%s * %s', 'int4', 'int4', 'int4'),
  ('int4_div', '%s / %s', 'int4', 'int4', 'int4'),
  ('int4_mod', '%s %% %s', 'int4', 'int4', 'int4'),
  ('int4_um', '-%s', 'int4', NULL, 'int4'),
  ('int8_pl', '%s + %s', 'int8', 'int8', 'int8'),
  ('int8_mi', '%s - %s', 'int8', 'int8', 'int8'),
  ('int8_mul', '%s * %s', 'int8', 'int8', 'int8'),
  ('int8_div', '%s / %s', 'int8', 'int8', 'int8'),
  ('int8_mod', 'mod(%s, %s)', 'int8', 'int8', 'int8'),
  ('int8_um', '-%s', 'int8', NULL, 'int8'),
  ('int48_pl', '%s + %s', 'int4', 'int8', 'int8'),
  ('int48_mi', '%s - %s', 'int4', 'int8', 'int8'),
  ('int48_mul', '%s * %s', 'int4', 'int8', 'int8'),
  ('int48_div', '%s / %s', 'int4', 'int8', 'int8'),
  ('int84_pl', '%s + %s', 'int8', 'int4', 'int8'),
  ('int84_mi', '%s - %s', 'int8', 'int4', 'int8'),
  ('int84_mul', '%s * %s', 'int8', 'int4', 'int8'),
  ('int84_div', '%s / %s', 'int8', 'int4', 'int8'),
  ('int4_from_int8', 'int4(%s)', 'int8', NULL, 'int4'),
  ('float8_pl', '%s + %s', 'float8', 'float8', 'float8'),
  ('float8_mi', '%s - %s', 'float8', 'float8', 'float8'),
  ('float8_mul', '%s * %s', 'float8', 'float8', 'float8'),
  ('float8_div', '%s / %s', 'float8', 'float8', 'float8'),
  ('float8_um', '-%s', 'float8', NULL, 'float8'),
  ('float8_eq', '%s = %s', 'float8', 'float8', 'bool'),
  ('float8_ne', '%s <> %s', 'float8', 'float8', 'bool'),
  ('float8_lt', '%s < %s', 'float8', 'float8', 'bool'),
  ('float8_le', '%s <= %s', 'float8', 'float8', 'bool'),
  ('float8_gt', '%s > %s', 'float8', 'float8', 'bool'),
  ('float8_ge', '%s >= %s', 'float8', 'float8', 'bool');

CREATE TEMP TABLE op_cases (n serial, helper text, a text, b text);
INSERT INTO op_cases (helper, a, b) VALUES
  ('int4_pl', '2', '3'),
  ('int4_pl', '2147483647', '1'),
  ('int4_mi', '2', '5'),
  ('int4_mi', '-2147483648', '1'),
  ('int4_mul', '6', '-7'),
  ('int4_mul', '65536', '32768'),
  ('int4_div', '-7', '2'),
  ('int4_div', '1', '0'),
  ('int4_div', '-2147483648', '-1'),
  ('int4_mod', '-7', '3'),
  ('int4_mod', '5', '0'),
  ('int4_mod', '-2147483648', '-1'),
  ('int4_um', '5', NULL),
  ('int4_um', '-2147483648', NULL),
  ('int8_pl', '2', '3'),
  ('int8_pl', '9223372036854775807', '1'),
  ('int8_mi', '2', '5'),
  ('int8_mi', '-9223372036854775808', '1'),
  ('int8_mul', '3000000000', '-3'),
  ('int8_mul', '4294967296', '2147483648'),
  ('int8_div', '-7', '2'),
  ('int8_div', '1', '0'),
  ('int8_div', '-9223372036854775808', '-1'),
  ('int8_mod', '-7', '3'),
  ('int8_mod', '5', '0'),
  ('int8_mod', '-9223372036854775808', '-1'),
  ('int8_um', '5', NULL),
  ('int8_um', '-9223372036854775808', NULL),
  ('int48_pl', '2', '3'),
  ('int48_pl', '1', '9223372036854775807'),
  ('int48_mi', '2', '5'),
  ('int48_mi', '-2', '9223372036854775807'),
  ('int48_mul', '3', '-3000000000'),
  ('int48_mul', '2', '4611686018427387904'),
  ('int48_div', '-7', '2'),
  ('int48_div', '1', '0'),
  ('int48_div', '-2147483648', '-1'),
  ('int84_pl', '2', '3'),
  ('int84_pl', '9223372036854775807', '1'),
  ('int84_mi', '2', '5'),
  ('int84_mi', '-9223372036854775808', '1'),
  ('int84_mul', '-3000000000', '3'),
  ('int84_mul', '4611686018427387904', '2'),
  ('int84_div', '-7', '2'),
  ('int84_div', '1', '0'),
  ('int84_div', '-9223372036854775808', '-1'),
  ('int4_from_int8', '-2147483648', NULL),
  ('int4_from_int8', '2147483648', NULL),
  ('float8_pl', '1.5', '2.25'),
  ('float8_pl', '1e308', '1e308'),
  ('float8_pl', 'Infinity', '1'),
  ('float8_mi', '1', '0.25'),
  ('float8_mi', '-1e308', '1e308'),
  ('float8_mul', '1.5', '-2'),
  ('float8_mul', '1e-300', '1e-300'),
  ('float8_mul', 'Infinity', '0'),
  ('float8_mul', '0', '1e-300'),
  ('float8_div', '1', '3'),
  ('float8_div', '1', '0'),
  ('float8_div', 'NaN', '0'),
  ('float8_um', '1.5', NULL),
  ('float8_um', '0', NULL),
  ('float8_eq', '1', '1'),
  ('float8_eq', 'NaN', 'NaN'),
  ('float8_eq', '0', '-0'),
  ('float8_ne', '1', '2'),
  ('float8_ne', 'NaN', 'NaN'),
  ('float8_lt', '1', '2'),
  ('float8_lt', '1', 'NaN'),
  ('float8_le', '2', '1'),
  ('float8_le', 'NaN', 'NaN'),
  ('float8_gt', '2', '1'),
  ('float8_gt', 'NaN', 'Infinity'),
  ('float8_ge', '1', '2'),
  ('float8_ge', '1', 'NaN');

-- the result of q as text, or its error
CREATE FUNCTION op_eval(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE
  r text;
BEGIN
  EXECUTE 'SELECT (' || q || ')::text' INTO r;
  RETURN coalesce(r, 'NULL');
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ': ' || SQLERRM;
END
$$;

-- each case as the SQL expression and as a call of op.<helper> (below)
CREATE TEMP VIEW op_calls AS
SELECT c.n, c.helper, c.a, c.b,
       format(h.op, format('%L::%s', c.a, h.ta),
              format('%L::%s', c.b, h.tb)) AS sql,
       format('op.%s(%s)', c.helper,
              concat_ws(', ', format('%L::%s', c.a, h.ta),
                        CASE WHEN h.tb IS NOT NULL
                             THEN format('%L::%s', c.b, h.tb) END)) AS ll
  FROM op_cases c JOIN op_helpers h USING (helper);

SELECT helper, a, b, op_eval(sql) AS result FROM op_calls ORDER BY n;

-- op.<helper>, a PL/LLVM function that calls plllvm_<helper>; the
-- arguments are read as Datums and converted with the cast of their type
CREATE SCHEMA op;
CREATE TEMP TABLE op_types (t text, ir text, from_datum text, to_datum text);
INSERT INTO op_types VALUES
  ('int4', 'i32', 'trunc', 'sext'),
  ('int8', 'i64', 'bitcast', 'bitcast'),
  ('float8', 'double', 'bitcast', 'bitcast'),
  ('bool', 'i1', NULL, 'zext');

DO $do$
DECLARE
  h record;
BEGIN
  FOR h IN
    SELECT o.helper, o.ta, o.tb, o.tr,
           a.ir AS a, a.from_datum AS a_from, b.ir AS b, b.from_datum AS b_from,
           r.ir AS r, r.to_datum AS r_to
      FROM op_helpers o
      JOIN op_types a ON a.t = o.ta
      LEFT JOIN op_types b ON b.t = o.tb
      JOIN op_types r ON r.t = o.tr
  LOOP
    IF h.tb IS NULL THEN
      EXECUTE format($f$
CREATE FUNCTION op.%1$s(%2$s) RETURNS %3$s LANGUAGE plllvm STRICT AS $ir$
declare i64 @plllvm_arg_i64(ptr, i32)
declare %6$s @plllvm_%1$s(%4$s)

define i64 @f(ptr %%fcinfo) {
  %%da = call i64 @plllvm_arg_i64(ptr %%fcinfo, i32 0)
  %%a = %5$s i64 %%da to %4$s
  %%r = call %6$s @plllvm_%1$s(%4$s %%a)
  %%dr = %7$s %6$s %%r to i64
  ret i64 %%dr
}
$ir$$f$, h.helper, h.ta, h.tr, h.a, h.a_from, h.r, h.r_to);
    ELSE
      EXECUTE format($f$
CREATE FUNCTION op.%1$s(%2$s, %3$s) RETURNS %4$s LANGUAGE plllvm STRICT AS $ir$
declare i64 @plllvm_arg_i64(ptr, i32)
declare %9$s @plllvm_%1$s(%5$s, %7$s)

define i64 @f(ptr %%fcinfo) {
  %%da = call i64 @plllvm_arg_i64(ptr %%fcinfo, i32 0)
  %%db = call i64 @plllvm_arg_i64(ptr %%fcinfo, i32 1)
  %%a = %6$s i64 %%da to %5$s
  %%b = %8$s i64 %%db to %7$s
  %%r = call %9$s @plllvm_%1$s(%5$s %%a, %7$s %%b)
  %%dr = %10$s %9$s %%r to i64
  ret i64 %%dr
}
$ir$$f$, h.helper, h.ta, h.tb, h.tr, h.a, h.a_from, h.b, h.b_from,
         h.r, h.r_to);
    END IF;
  END LOOP;
END
$do$;

-- the same result or error as the SQL operator
SELECT helper, a, b, op_eval(sql) = op_eval(ll) AS ok FROM op_calls ORDER BY n;

SET client_min_messages = warning;
DROP SCHEMA op CASCADE;
RESET client_min_messages;
DROP FUNCTION op_eval(text);
