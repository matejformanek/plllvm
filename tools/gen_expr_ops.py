#!/usr/bin/env python3
#
# Writes sql/expr_ops.sql: every T0 operator of plllvm.expr_jit over edge
# values (NULL, 0, +-1, the integer limits, values whose product or sum
# overflows, NaN, +-Infinity, -0, denormals).
#
# Each case is one assignment in a loop of three: two evaluations with
# harmless values, then the edge value, so that the edge value reaches the
# compiled code (an ExprState is compiled at its second evaluation).  An
# error poisons a simple expression for the rest of the transaction
# (expr_simple_in_use, pl_exec.c:6143), so the driver commits after every
# row.  An error at a harmless evaluation shows as "B", which the expected
# output must never contain.
#
# With plllvm.expr_jit on, every case but those in REFUSED must have been
# given code once per row; the test checks the count, so that a class of
# cases the compiler starts to refuse does not pass unnoticed.
#
# Run from the top directory: tools/gen_expr_ops.py > sql/expr_ops.sql
# Adapted from the plllvm-v1 spike (swapv2/gen_ops.py).

import sys
import textwrap

# group: (parameters, harmless values, edge values per parameter, cases)
# A case is (expression, result type) or (expression, result type,
# harmless values) where the defaults would raise.

I4 = ['NULL', '0', '1', '-1', '2', '-2', '7', '2147483647', '-2147483648',
      '46341', '65536']
I8 = ['NULL', '0', '1', '-1', '3', '-9223372036854775808',
      '9223372036854775807', '3037000500', '4294967296', '2147483648',
      '-2147483649']
F8 = ['NULL', '0', "'-0'", '1', '-1', '0.5', '1e308', '-1e308', '1e-308',
      '2.5e-308', "'NaN'", "'Infinity'", "'-Infinity'", '3']
BOOL = ['NULL', 'true', 'false']


def chain(terms):
    # a + b + a + ... with the given number of Params
    return ' + '.join(('a', 'b')[i % 2] for i in range(terms))


CASES_I4 = [
    ('a + b', 'int4'), ('a - b', 'int4'), ('a * b', 'int4'),
    ('a / b', 'int4'), ('a % b', 'int4'), ('mod(a, b)', 'int4'),
    ('int4pl(a, b)', 'int4'), ('int4mul(a, b)', 'int4'),
    ('a = b', 'bool'), ('a <> b', 'bool'), ('a < b', 'bool'),
    ('a <= b', 'bool'), ('a > b', 'bool'), ('a >= b', 'bool'),
    ('-a', 'int4'), ('a + 1', 'int4'), ('1 - a', 'int4'), ('a * 3', 'int4'),
    ('7 / a', 'int4'), ('a % 3', 'int4'), ('a < 5', 'bool'),
    ('5 > a', 'bool'),
    ('(a + b) * (a - b)', 'int4'),
    ('((a * 2) + (b % 3)) - (a / 7)', 'int4'),
    ('((a + 1) * (b - 1)) / ((a % 5) + 1)', 'int4'),
    ('-(a * b)', 'int4'),
    ('a::int8 + b', 'int8'), ('b + a::int8', 'int8'),
    ('a::int8 * b::int8', 'int8'),
    ('(a::int8 * 3000000000)::int4', 'int4', ('0', '1')),
    ('a::float8 / b', 'float8'),
    ('(a < b) = (b < a)', 'bool'), ('(a = b) <> (a >= b)', 'bool'),
    ('(a / 0) + b', 'int4', ('NULL', '1')),
    ('b + (a / 0)', 'int4', ('NULL', '1')),
    ('a + (b / 0)', 'int4', ('NULL', 'NULL')),
    ('((((a + 1) + 2) + 3) + 4) + (((b + 1) + 2) + 3)', 'int4'),
    # around PLLLVM_EXPR_MAX_NODES (64): 63, 64 and 65 nodes
    (chain(32), 'int4'), (f'-({chain(32)})', 'int4'), (chain(33), 'int4'),
]

# cases the compiler refuses
REFUSED = {chain(33)}

CASES_I8 = [
    ('c + d', 'int8'), ('c - d', 'int8'), ('c * d', 'int8'),
    ('c / d', 'int8'), ('c % d', 'int8'), ('mod(c, d)', 'int8'),
    ('int8mi(c, d)', 'int8'),
    ('c = d', 'bool'), ('c <> d', 'bool'), ('c < d', 'bool'),
    ('c <= d', 'bool'), ('c > d', 'bool'), ('c >= d', 'bool'),
    ('-c', 'int8'), ('c + 1', 'int8'), ('c * 3000000000', 'int8'),
    ('c / -1', 'int8'), ('c % -1', 'int8'),
    ('(c * 2) + (d / 3)', 'int8'),
    ('c::int4', 'int4'), ('(c + d)::int4', 'int4'),
    ('c::float8 * d', 'float8'),
    ('(c < d) <> (d < c)', 'bool'),
]

CASES_I48 = [
    ('c + a', 'int8'), ('c - a', 'int8'), ('c * a', 'int8'),
    ('c / a', 'int8'), ('c % a', 'int8'),
    ('c = a', 'bool'), ('c <> a', 'bool'), ('c < a', 'bool'),
    ('c <= a', 'bool'), ('c > a', 'bool'), ('c >= a', 'bool'),
    ('a + c', 'int8'), ('a - c', 'int8'), ('a * c', 'int8'),
    ('a / c', 'int8'), ('a % c', 'int8'),
    ('a = c', 'bool'), ('a <> c', 'bool'), ('a < c', 'bool'),
    ('a <= c', 'bool'), ('a > c', 'bool'), ('a >= c', 'bool'),
    ('int84pl(c, a)', 'int8'), ('int48div(a, c)', 'int8'),
    ('(c + a)::int4', 'int4'), ('c::int4 + a', 'int4'),
    ('a::float8 + c::float8', 'float8'), ('c::float8 / a', 'float8'),
]

CASES_F8 = [
    ('e + f', 'float8'), ('e - f', 'float8'), ('e * f', 'float8'),
    ('e / f', 'float8'), ('float8pl(e, f)', 'float8'),
    ('e = f', 'bool'), ('e <> f', 'bool'), ('e < f', 'bool'),
    ('e <= f', 'bool'), ('e > f', 'bool'), ('e >= f', 'bool'),
    ('-e', 'float8'), ('-(e * f)', 'float8'),
    ('e * 0.5 + 1.0', 'float8'), ('(e - f) * (e + f)', 'float8'),
    ('e / 3.0', 'float8'), ('2.0 / e', 'float8'),
    ('e / 0', 'float8', ('NULL', '1')),
    ('e >= 1.99', 'bool'), ('e < 0.0', 'bool'),
    ('(e < f) <> (f < e)', 'bool'), ('(e = f) = (e <> f)', 'bool'),
]

CASES_BOOL = [
    ('p = q', 'bool'), ('p <> q', 'bool'), ('(p = q) = (q <> p)', 'bool'),
    ('(p <> q) <> false', 'bool'),
]

GROUPS = [
    ('i4', [('a', 'int4', I4), ('b', 'int4', I4)], ('1', '1'), CASES_I4),
    ('i8', [('c', 'int8', I8), ('d', 'int8', I8)], ('1', '1'), CASES_I8),
    ('i48', [('a', 'int4', I4), ('c', 'int8', I8)], ('1', '1'), CASES_I48),
    ('f8', [('e', 'float8', F8), ('f', 'float8', F8)], ('1', '1'), CASES_F8),
    ('bool', [('p', 'bool', BOOL), ('q', 'bool', BOOL)], ('true', 'true'),
     CASES_BOOL),
]

RESULT_VAR = {'int4': 'ri', 'int8': 'rl', 'float8': 'rf', 'bool': 'rb'}


def wrap(line, indent):
    # a statement at indent, continued two spaces deeper, within 79 columns
    return '\n'.join(textwrap.wrap(line, 79, initial_indent=' ' * indent,
                                   subsequent_indent=' ' * (indent + 2),
                                   break_on_hyphens=False)) + '\n'


def function(name, params, harmless, cases):
    (x, xt, _), (y, yt, _) = params
    out = []
    out.append(f'CREATE FUNCTION expr_ops_{name}(x0 {xt}, y0 {yt}) '
               f'RETURNS text\nLANGUAGE plpgsql AS $$\nDECLARE\n'
               f'  {x} {xt};\n  {y} {yt};\n  n int;\n  r text := \'\';\n'
               f'  ri int4; rl int8; rf float8; rb bool;\nBEGIN\n')
    for case in cases:
        expr, rt = case[0], case[1]
        hx, hy = case[2] if len(case) > 2 else harmless
        v = RESULT_VAR[rt]
        out.append(
            f'  BEGIN\n'
            f'    FOR k IN 1..3 LOOP\n'
            f'      n := k;\n'
            f'      {x} := CASE k WHEN 3 THEN x0 ELSE {hx} END;\n'
            f'      {y} := CASE k WHEN 3 THEN y0 ELSE {hy} END;\n'
            + wrap(f'{v} := {expr};', 6) +
            f'    END LOOP;\n'
            f'    r := r || coalesce({v}::text, \'N\') || \' \';\n'
            f'  EXCEPTION WHEN OTHERS THEN\n'
            f'    r := r || CASE WHEN n < 3 THEN \'B\' '
            f'ELSE \'E\' || SQLSTATE END || \' \';\n'
            f'  END;\n')
    out.append('  RETURN rtrim(r);\nEND\n$$;\n')
    return ''.join(out)


def main():
    w = sys.stdout.write
    w('--\n'
      '-- expr_ops: the T0 operators of plllvm.expr_jit over edge values\n'
      '--\n'
      '-- GENERATED by tools/gen_expr_ops.py -- do not edit.  The\n'
      '-- expected output is stock PL/pgSQL\'s, and make installcheck-expr\n'
      '-- compares every variant against it; the one plllvm query is true\n'
      '-- in every variant.  Each case runs three times in one ExprState,\n'
      '-- the edge value third; "B" would be an error at a harmless\n'
      '-- evaluation, "N" is NULL.\n'
      '--\n\n')
    w('CREATE TABLE expr_ops_res (id serial, grp text, x text, y text,\n'
      '                           r text);\n\n')
    for name, params, harmless, cases in GROUPS:
        w(function(name, params, harmless, cases))
        w('\n')

    # the driver: one transaction per row
    w('CREATE PROCEDURE expr_ops_run()\nLANGUAGE plpgsql AS $$\nDECLARE\n')
    values = {}
    for name, params, _, _ in GROUPS:
        for _, t, vals in params:
            values[t] = vals
    for t, vals in values.items():
        # the cast types every element, so that '-0' is not read as numeric
        w(wrap(f'v_{t} {t}[] := ARRAY[{", ".join(vals)}]::{t}[];', 2))
    w('BEGIN\n')
    for name, params, _, _ in GROUPS:
        (_, xt, _), (_, yt, _) = params
        x, y = f'v_{xt}[i]', f'v_{yt}[j]'
        w(f'  FOR i IN 1..array_length(v_{xt}, 1) LOOP\n'
          f'    FOR j IN 1..array_length(v_{yt}, 1) LOOP\n'
          f'      INSERT INTO expr_ops_res (grp, x, y, r)\n'
          f'        VALUES (\'{name}\', {x}, {y},\n'
          f'                expr_ops_{name}({x}, {y}));\n'
          f'      COMMIT;\n'
          f'    END LOOP;\n'
          f'  END LOOP;\n')
    w('END\n$$;\n\n')
    # each row is one transaction, so a case is installed once per row
    installs = 0
    for name, params, _, cases in GROUPS:
        (_, _, xv), (_, _, yv) = params
        installs += len(xv) * len(yv) * \
            sum(1 for case in cases if case[0] not in REFUSED)
    w('-- installed (compiled or from the cache) before the run\n'
      'CREATE TEMP TABLE expr_ops_before AS\n'
      '  SELECT installed FROM plllvm_expr_stats();\n\n')
    w('CALL expr_ops_run();\n\n')
    w(f'-- with plllvm.expr_jit on, every case but {len(REFUSED)} got code '
      f'in every row\n'
      f'SELECT NOT coalesce(current_setting(\'plllvm.expr_jit\', true), '
      f'\'off\')::bool\n'
      f'       OR s.installed - b.installed = {installs} AS all_installed\n'
      f'  FROM plllvm_expr_stats() s, expr_ops_before b;\n\n')

    w('-- every case, one row per pair of values\n'
      '\\a\n'
      'SELECT grp, coalesce(x, \'N\') AS x, coalesce(y, \'N\') AS y, r\n'
      '  FROM expr_ops_res ORDER BY id;\n'
      '\\a\n\n')
    w('-- what the cases raised\n'
      'SELECT grp, count(*) AS cases,\n'
      '       count(*) FILTER (WHERE t = \'E22003\') AS out_of_range,\n'
      '       count(*) FILTER (WHERE t = \'E22012\') AS division_by_zero,\n'
      '       count(*) FILTER (WHERE t LIKE \'E%\') AS errors,\n'
      '       count(*) FILTER (WHERE t = \'N\') AS nulls,\n'
      '       count(*) FILTER (WHERE t = \'B\') AS harmless_failed\n'
      '  FROM expr_ops_res, regexp_split_to_table(r, \' \') t\n'
      ' GROUP BY ROLLUP (grp) ORDER BY grp;\n\n')
    w('DROP PROCEDURE expr_ops_run();\n')
    for name, params, _, _ in GROUPS:
        (_, xt, _), (_, yt, _) = params
        w(f'DROP FUNCTION expr_ops_{name}({xt}, {yt});\n')
    w('DROP TABLE expr_ops_res, expr_ops_before;\n')


if __name__ == '__main__':
    main()
