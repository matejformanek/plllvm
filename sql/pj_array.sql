--
-- pj_array: arrays in functions of plpgsql_jit: values, errors, ownership and
-- memory; compiled, each gives the answer of PL/pgSQL
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set SHOW_CONTEXT always
SET extra_float_digits = 0;

-- the biggest per-tuple memory the compiled code has seen (0 on PL/pgSQL)
CREATE FUNCTION pa_peak() RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE p bigint := 0;
BEGIN
  IF current_setting('plllvm.plpgsql_jit', true) IS NOT NULL
     AND current_setting('debug_discard_caches')::int = 0 THEN
    EXECUTE 'SELECT peak_tuple_bytes FROM plllvm_pj_stats()' INTO p;
  END IF;
  RETURN p;
END $$;
CREATE FUNCTION pa_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;

-- a big array, stored compressed or out of line, is read in a loop: it is
-- expanded once, not at every subscript
CREATE TABLE pa_big (id int, v float8[]);
INSERT INTO pa_big SELECT 1,
    array_agg(0.5::float8 * g) FROM generate_series(1, 100000) g;
CREATE FUNCTION pa_sum(a float8[],
    n int) RETURNS float8 LANGUAGE :pj_lang STABLE AS $$
DECLARE s float8 := 0; i int;
BEGIN
  FOR i IN 1..n LOOP s := s + a[i * 7]; END LOOP;
  RETURN s;
END $$;
-- a flush of the caches makes every evaluation of PL/pgSQL read the argument
-- again, so there the loops are short
SELECT current_setting('debug_discard_caches')::int > 0 AS dd \gset
SELECT CASE WHEN :'dd'::bool THEN 3 ELSE 10 END AS n1,
       CASE WHEN :'dd'::bool THEN 8 ELSE 100 END AS n2,
       CASE WHEN :'dd'::bool THEN 10 ELSE 1000 END AS n3,
       CASE WHEN :'dd'::bool THEN 20 ELSE 14285 END AS n4,
       CASE WHEN :'dd'::bool THEN 5 ELSE 1000 END AS n6,
       CASE WHEN :'dd'::bool THEN 20 ELSE 100000 END AS n7 \gset
SELECT pa_sum(v, :n1) = 3.5 * :n1 * (:n1 + 1) / 2 AS sum1,
       pa_sum(v, :n2) = 3.5 * :n2 * (:n2 + 1) / 2 AS sum2 FROM pa_big;
SELECT pa_sum(v, :n1) = 3.5 * :n1 * (:n1 + 1) / 2 AS sum1,
       pa_sum(v, :n2) = 3.5 * :n2 * (:n2 + 1) / 2 AS sum2,
       pa_sum(v, :n3) = 3.5 * :n3 * (:n3 + 1) / 2 AS sum3,
       pa_sum(v, :n4) = 3.5 * :n4 * (:n4 + 1) / 2 AS sum4 FROM pa_big;
SELECT pj_expect('pa_sum(float8[],int)', 'compiled') \gset
SELECT pa_peak() < 65536 AS peak_small_arg;

-- an element store changes the array in place, it is not copied: 4000 stores
-- in an array of 32 MB cost less than 100 copies of it, where a copy of each
-- would cost 4000.  Both are timed in the same call, so a slow host moves
-- them together.  (A volatile callee would keep the function interpreted, so
-- the clock is labelled STABLE.)
CREATE FUNCTION pa_clock() RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN clock_timestamp(); END $$;
CREATE FUNCTION pa_store(n int, copies int) RETURNS bool LANGUAGE :pj_lang AS $$
DECLARE a float8[] := array_fill(1.5::float8, ARRAY[4000000]);
  b float8[]; i int; t0 timestamptz; t1 timestamptz; t2 timestamptz;
BEGIN
  a[1] := 0;
  t0 := pa_clock();
  FOR i IN 1..copies LOOP b := array_append(a, 1.5::float8); END LOOP;
  t1 := pa_clock();
  FOR i IN 1..n LOOP
    a[1 + i % 4000000] := a[1 + i % 4000000] + i;
  END LOOP;
  t2 := pa_clock();
  IF a[7] <> 1.5 + 6 OR a[4000000] <> 1.5 OR a[1] <> 0 THEN
    RAISE 'wrong element';
  END IF;
  RETURN t2 - t1 < 100 * (t1 - t0) / copies;
END $$;
SELECT pa_store(10, 3), pa_store(10, 3);
SELECT CASE WHEN :'dd'::bool THEN true ELSE pa_store(4000, 3) END AS in_place;
SELECT pj_expect('pa_store(int,int)', 'compiled') \gset

-- and its arrays are given up when the call ends
BEGIN;
SELECT pa_mem() AS m0 \gset
SELECT pa_store(10, 1);
SELECT pa_mem() - :m0 < 4194304 AS released;
COMMIT;

-- values: NULL elements, subscripts out of range, assignment past the ends,
-- other lower bounds; the argument is not changed
CREATE FUNCTION pa_rw(a float8[], i int,
    v float8) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE b float8[];
BEGIN
  b := a;
  b[i] := v;
  RETURN coalesce(b::text, 'NULL') || ' | ' || coalesce(a::text, 'NULL')
      || ' | ' ||
         coalesce(b[i]::text, 'NULL') || ' | ' || coalesce(a[i]::text,
             'NULL') || ' | ' ||
         array_ndims(b) || array_lower(b, 1);
END $$;
SELECT pa_rw('{1,2,3}', 2, 9.5) FROM generate_series(1, 3);
SELECT i, pa_rw(a::float8[], i, v)
  FROM (VALUES ('{1,2,3}'), ('{1,NULL,3}'), ('{}'), ('[5:7]={1,2,3}'),
      ('[-2:0]={4,5,6}'),
               ('{1,2,3,4,5,6,7,8,9,10,11,12}')) a(a),
       generate_series(-3, 8) i, (VALUES (9.5), ('NaN'::float8)) x(v)
  WHERE i % 2 = 0 OR a LIKE '{1,2%'
  ORDER BY a, i, v;
SELECT pj_expect('pa_rw(float8[],int,float8)', 'compiled') \gset

-- two dimensions
CREATE FUNCTION pa_md(a float8[], i int, j int,
    v float8) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE b float8[];
BEGIN
  b := a;
  b[i][j] := v;
  RETURN b::text || coalesce(b[i][j]::text, 'N') || coalesce(a[i][j]::text,
      'N') || array_dims(b);
END $$;
SELECT pa_md('{{1,2},{3,4}}', i, j, 8) FROM generate_series(1, 2) i,
    generate_series(1, 2) j ORDER BY i, j;
SELECT pa_md('[2:3][-1:0]={{1,2},{3,4}}', i, j, 8) FROM generate_series(2,
    3) i, generate_series(-1, 0) j ORDER BY i, j;
SELECT pa_md('{{1,2},{3,4}}', 1, 1, 1);
SELECT pj_expect('pa_md(float8[],int,int,float8)', 'compiled') \gset

-- slices, a NULL subscript, a NULL array, a subscript past the end, array
-- functions on the variable itself
CREATE FUNCTION pa_misc(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[10, 20, 30, 40]; b int[]; c text[];
    n int := nullif(k, k);
BEGIN
  IF k = 1 THEN a[2:3] := ARRAY[7, 8]; RETURN a::text; END IF;
  IF k = 2 THEN b[3] := 1; RETURN b::text; END IF;
  IF k = 3 THEN a[7] := 1; RETURN a::text; END IF;
  IF k = 4 THEN a[0] := 1; RETURN a::text || array_lower(a, 1); END IF;
  IF k = 5 THEN RETURN coalesce(a[n]::text, 'null-read') || a[2:3]::text
      || a[n:n]::text; END IF;
  IF k = 6 THEN c := ARRAY['x', NULL, 'z']; c[2] := 'y'; c[5] := NULL;
      RETURN c::text; END IF;
  IF k = 7 THEN b := a; a := NULL; RETURN coalesce(a::text, 'N') || b::text;
      END IF;
  IF k = 8 THEN a := a || a; a[1] := a[1] + a[8]; a := array_append(a, a[1]);
      RETURN a::text; END IF;
  IF k = 9 THEN b := array_fill(0, ARRAY[2, 3]); b[2][3] := 5;
      b[1][1] := b[2][3] * 2; RETURN b::text; END IF;
  RETURN 'none';
END $$;
SELECT k, pa_misc(k) FROM generate_series(0, 9) k, generate_series(1,
    3) rep WHERE rep = 3 ORDER BY k;
SELECT pa_misc(k) FROM generate_series(1, 9) k, generate_series(1,
    2) rep ORDER BY k, rep;
SELECT pj_expect('pa_misc(int)', 'compiled') \gset

-- element types
CREATE FUNCTION pa_types(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE
  b bool[] := ARRAY[true, false];
  i4 int4[] := ARRAY[1, 2];
  i8 int8[] := ARRAY[10000000000, 2];
  f8 float8[] := ARRAY[1.5, 2.5]::float8[];
  nu numeric[] := ARRAY[1.10, 2.25];
  tx text[] := ARRAY['a', 'b'];
BEGIN
  IF k = 1 THEN b[3] := NOT b[1]; i4[1] := i4[2] * 3; i8[2] := i8[1] + 1;
      f8[2] := f8[1] / 3; END IF;
  IF k = 2 THEN nu[3] := nu[1] * nu[2]; tx[1] := upper(tx[2]) || tx[1];
      tx[3] := tx[1] || tx[2]; END IF;
  IF k = 3 THEN tx[2] := NULL; tx[5] := 'e'; nu[1] := NULL; b[2] := NULL;
      END IF;
  RETURN concat_ws('|', b::text, i4::text, i8::text, f8::text, nu::text,
      tx::text);
END $$;
SELECT k, pa_types(k) FROM generate_series(0, 3) k, generate_series(1,
    2) r ORDER BY k, r;
SELECT pj_expect('pa_types(int)', 'compiled') \gset
CREATE FUNCTION pa_i4err(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int4[] := ARRAY[1, 2];
BEGIN
  a[1] := 2147483647 + k;
  RETURN a::text;
END $$;
SELECT pa_i4err(0);
SELECT pa_i4err(0);
SELECT pa_i4err(1);  -- fail
SELECT pj_expect('pa_i4err(int)', 'compiled') \gset

-- errors and their CONTEXT
CREATE FUNCTION pa_err(k int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3]; m int[]; n int := nullif(k, k);
    z int := k - k;
BEGIN
  m := array_fill(0, ARRAY[2, 2]);
  IF k = 1 THEN a[n] := 1; END IF;
  IF k = 2 THEN a[1] := 1 / z; END IF;
  IF k = 3 THEN m[5][1] := 1; END IF;
  IF k = 4 THEN a[1:2] := ARRAY[1]; END IF;
  IF k = 5 THEN a[1] := 2147483647 + k - 4; END IF;
  IF k = 6 THEN a[2] := a[1] / z; END IF;
  IF k = 7 THEN m[1] := 1; END IF;
  IF k = 8 THEN a[1] := a[k]::text::int; END IF;
  RETURN a[1] + coalesce(m[1][1], 0);
END $$;
SELECT pa_err(0), pa_err(0);
SELECT pa_err(1);  -- fail
SELECT pa_err(2);  -- fail
SELECT pa_err(3);  -- fail
SELECT pa_err(4);  -- fail
SELECT pa_err(5);  -- fail
SELECT pa_err(6);  -- fail
SELECT pa_err(7);  -- fail
SELECT pa_err(8);  -- fail
SELECT pa_err(1);  -- fail
SELECT pa_err(3);  -- fail
SELECT pa_err(0), pa_err(0);
SELECT pj_expect('pa_err(int)', 'compiled') \gset

-- an error after element stores leaves the marks of an interpreted failure:
-- the next call of the transaction is PL/pgSQL's, a later one compiled
CREATE FUNCTION pa_mark(n int, bad int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3]; i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 3] := a[1 + i % 3] + i;
  END LOOP;
  IF bad = 1 THEN a[nullif(bad, 1)] := 1; END IF;
  a[2] := a[2] * 2;
  RETURN a::text;
END $$;
SELECT pa_mark(3, 0);
SELECT pa_mark(4, 0), pa_mark(5, 0);
SELECT pa_mark(4, 1);  -- fail
SELECT pa_mark(3, 0), pa_mark(4, 0);
SELECT pj_expect('pa_mark(int,int)', 'compiled') \gset
BEGIN;
SAVEPOINT s;
SELECT pa_mark(5, 1);  -- fail
ROLLBACK TO s;
SELECT pa_mark(5, 0);
SELECT pj_expect('pa_mark(int,int)', 'interpreted:in use') \gset
COMMIT;
SELECT pa_mark(5, 0), pa_mark(6, 0);
SELECT pj_expect('pa_mark(int,int)', 'compiled') \gset

-- recursion: a frame has its own arrays, and an error in the deepest one
CREATE FUNCTION pa_rec(n int, a int[],
    bad int) RETURNS text LANGUAGE :pj_lang STABLE AS $$
DECLARE b int[] := a;
BEGIN
  b[n + 1] := n;
  IF n = 0 THEN
    IF bad = 1 THEN b[nullif(n, 0)] := 1; END IF;
    RETURN b::text;
  END IF;
  RETURN pa_rec(n - 1, b, bad) || b::text;
END $$;
SELECT pa_rec(4, '{}', 0), pa_rec(4, '{}', 0), pa_rec(6, '{1,2}', 0);
\set SHOW_CONTEXT never
SELECT pa_rec(3, '{}', 1);  -- fail
SELECT pa_rec(3, '{}', 1);  -- fail
BEGIN;
SAVEPOINT s;
SELECT pa_rec(3, '{}', 1);  -- fail
ROLLBACK TO s;
SELECT pa_rec(2, '{9}', 0);
COMMIT;
\set SHOW_CONTEXT always
SELECT pa_rec(2, '{}', 0), pa_rec(5, '{}', 0);

-- an array argument is the caller's: assigning to it, or to what it was
-- assigned to, changes neither it nor the column it came from
CREATE FUNCTION pa_alias(a int[]) RETURNS text LANGUAGE :pj_lang STABLE AS $$
DECLARE b int[]; c int[];
BEGIN
  b := a;
  a[1] := 100;
  b[2] := 200;
  c := b;
  c[3] := c[1] + c[2];
  a := array_append(a, a[1]);
  b := array_cat(b, b);
  RETURN a::text || b::text || c::text;
END $$;
CREATE TABLE pa_t (id int, v int[]);
INSERT INTO pa_t VALUES (1, '{1,2,3}'), (2, '{4,5,6}');
SELECT id, pa_alias(v), v FROM pa_t ORDER BY id;
SELECT id, pa_alias(v), v FROM pa_t ORDER BY id;
SELECT id, pa_alias(v), v FROM pa_t ORDER BY id;
SELECT pj_expect('pa_alias(int[])', 'compiled') \gset
CREATE FUNCTION pa_idem(a int[]) RETURNS int[] LANGUAGE :pj_lang STABLE AS $$
BEGIN
  RETURN a;
END $$;
CREATE FUNCTION pa_caller() RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3]; r text;
BEGIN
  a[1] := 5;
  r := pa_alias(a);
  a := pa_idem(a);
  a[2] := 7;
  RETURN r || '/' || a::text;
END $$;
SELECT pa_caller(), pa_caller(), pa_caller();
SELECT pj_expect('pa_caller()', 'compiled') \gset

-- PL/pgSQL hands a read/write array to a callee that is the only reference's
-- user, and the callee owns it: it modifies it, returns it, or frees it.  The
-- caller's variable must stay whole whatever the callee does
CREATE FUNCTION pa_take(a int[]) RETURNS int[] LANGUAGE plpgsql STABLE AS $$
BEGIN
  a[1] := a[1] + 1;
  RETURN a;
END $$;
CREATE FUNCTION pa_same(a int[]) RETURNS int[] LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN a;
END $$;
CREATE FUNCTION pa_give(a int[]) RETURNS int[] LANGUAGE plpgsql STABLE AS $$
BEGIN
  a := array_cat(a, ARRAY[7]);
  RETURN a;
END $$;
CREATE FUNCTION pa_drop(a int[]) RETURNS int[] LANGUAGE plpgsql STABLE AS $$
BEGIN
  RETURN ARRAY[a[1], 5];
END $$;
CREATE FUNCTION pa_first(a int[]) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  a[2] := 99;
  RETURN a[1];
END $$;
CREATE FUNCTION pa_transfer(n int, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3]; i int;
BEGIN
  FOR i IN 1..n LOOP
    a[2] := a[2] + 1;
    IF k = 1 THEN a := pa_take(a); END IF;
    IF k = 2 THEN a := pa_same(a); END IF;
    IF k = 3 THEN a := array_append(a, pa_first(a)); END IF;
    IF k = 4 THEN a := pa_give(a); END IF;
    IF k = 5 THEN a := pa_drop(a); END IF;
    a[3] := a[3] + a[1];
  END LOOP;
  RETURN a::text;
END $$;
SELECT pa_transfer(5, 0), pa_transfer(5, 1), pa_transfer(5, 2),
    pa_transfer(5, 3),
       pa_transfer(5, 4), pa_transfer(5, 5);
SELECT pa_transfer(5, 0), pa_transfer(5, 1), pa_transfer(5, 2),
    pa_transfer(5, 3),
       pa_transfer(5, 4), pa_transfer(5, 5);
SELECT pa_transfer(5, 5), pa_transfer(5, 4), pa_transfer(5, 3),
    pa_transfer(5, 2),
       pa_transfer(5, 1), pa_transfer(5, 0);
SELECT CASE WHEN :'dd'::bool THEN true
       ELSE md5(concat_ws('|', pa_transfer(200, 1), pa_transfer(200, 2),
       pa_transfer(30, 3), pa_transfer(20, 4), pa_transfer(200, 5))) =
       'e530d5dd369c31c2b17284c24718f1ad' END AS long_chains;
SELECT pj_expect('pa_transfer(int,int)', 'compiled') \gset

-- an array that no assignment targets is read-only in every expression, in
-- the first slot of the function as in any other
CREATE FUNCTION pa_ro0(a int[], k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE b int[];
BEGIN
  b := pa_take(a);
  IF k = 1 THEN b := array_append(b, pa_first(a)); END IF;
  IF k = 2 THEN b := pa_give(a); END IF;
  IF k = 3 THEN b := array_append(a, 9); END IF;
  RETURN a::text || b::text;
END $$;
SELECT pa_ro0('{1,2,3}', 0), pa_ro0('{1,2,3}', 1), pa_ro0('{1,2,3}', 2),
       pa_ro0('{1,2,3}', 3);
SELECT pa_ro0('{1,2,3}', 0), pa_ro0('{1,2,3}', 1), pa_ro0('{1,2,3}', 2),
       pa_ro0('{1,2,3}', 3);
SELECT pj_expect('pa_ro0(int[],int)', 'compiled') \gset

-- a variable assigned to itself or to another: PL/pgSQL copies the value
-- first and frees the old one only if it is not the same object
CREATE FUNCTION pa_self(a int[], k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE b int[] := a;
BEGIN
  a := a;
  b := b;
  IF k = 1 THEN a := NULL; END IF;
  IF k = 2 THEN a := b; a[1] := 0; b[2] := 0; END IF;
  IF k = 3 THEN b := a[1:2]; a := b || a; END IF;
  IF k = 4 THEN a := array_cat(a, a); a := a[2:5]; END IF;
  RETURN coalesce(a::text, 'N') || '|' || coalesce(b::text, 'N');
END $$;
SELECT pa_self('{1,2,3}', 0), pa_self('{1,2,3}', 1), pa_self('{1,2,3}', 2),
       pa_self('{1,2,3}', 3), pa_self('{1,2,3}', 4);
SELECT pa_self('{1,2,3}', 0), pa_self('{1,2,3}', 1), pa_self('{1,2,3}', 2),
       pa_self('{1,2,3}', 3), pa_self('{1,2,3}', 4);
SELECT pj_expect('pa_self(int[],int)', 'compiled') \gset

-- PL/pgSQL converts a constant text to the array type at every call; for a
-- type whose input reads no setting the conversion is made once, when the
-- function is translated, and for any other type the function stays
-- PL/pgSQL's
CREATE FUNCTION pa_const(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE
  l text[] := '{}';
  w int4[] := '{1,2,3}';
  f float8[] := '{1.5,NaN}';
  n numeric[] := '{1.50,2}';
BEGIN
  IF k = 1 THEN l := l || 'x'::text; w[2] := w[2] + 1; END IF;
  RETURN l::text || w::text || f::text || n::text;
END $$;
SELECT pa_const(0), pa_const(1), pa_const(0);
SELECT pa_const(0), pa_const(1);
SELECT pj_expect('pa_const(int)', 'compiled') \gset
CREATE FUNCTION pa_const_date(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE d date[] := '{1.2.2020}';
BEGIN
  IF k = 1 THEN d[2] := d[1] + 1; END IF;
  RETURN d::text;
END $$;
SELECT pa_const_date(0), pa_const_date(1);
SET datestyle = 'ISO, DMY';
SELECT pa_const_date(0), pa_const_date(1);
SET datestyle = 'ISO, MDY';
SELECT pa_const_date(0), pa_const_date(1);
RESET datestyle;
SELECT pj_expect('pa_const_date(int)', 'declined:cast') \gset
CREATE FUNCTION pa_const_err() RETURNS text LANGUAGE :pj_lang AS $$
DECLARE w int4[] := '{1,x}';
BEGIN
  RETURN w::text;
END $$;
SELECT pa_const_err();  -- fail
SELECT pa_const_err();  -- fail

-- an element store: no deopt after it, and nothing it did repeats.  A branch
-- no call has taken yet makes the function wait.
CREATE FUNCTION pa_wait(n int, flag int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3];
BEGIN
  a[1] := a[1] + n;
  RAISE NOTICE 'stored %', a[1];
  IF flag = 1 THEN a[2] := a[2] * 10; END IF;
  a[3] := a[3] + 1;
  RETURN a::text;
END $$;
SELECT pa_wait(5, 0), pa_wait(5, 0);
SELECT pj_expect('pa_wait(int,int)', 'waiting') \gset
SELECT pa_wait(5, 1);
SELECT pa_wait(5, 0), pa_wait(5, 1), pa_wait(6, 1);
SELECT pj_expect('pa_wait(int,int)', 'compiled') \gset
-- a branch unplanned after translation
DISCARD PLANS;
SELECT pa_wait(7, 1), pa_wait(7, 0);
SELECT pj_expect('pa_wait(int,int)', 'compiled') \gset

-- a restartable function: arrays only declared and returned; the deopt
-- gives up the arrays of the call
CREATE FUNCTION pa_restart(flag int) RETURNS int[] LANGUAGE :pj_lang AS $$
DECLARE a int[] := '{1,2,3}'; b text[] := '{x,y}'; c int[];
BEGIN
  IF flag = 1 THEN c := a; END IF;
  RETURN c;
END $$;
SELECT pa_restart(0), pa_restart(0), pa_restart(0);
SELECT pj_expect('pa_restart(int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pa_restart(1);
SELECT pj_delta(0, 0, 0, 1, 0) \gset
SELECT pa_restart(1), pa_restart(0);

-- memory: the old array of each assignment is freed, whatever the shape of
-- the loop; measured inside the call, between an iteration and the end.  The
-- bound is wide for the size of the report itself, a leak is megabytes.
CREATE FUNCTION pa_loop(n int,
    probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE
  a float8[] := array_fill(0.0::float8, ARRAY[10]);
  t text[] := array_fill('x'::text, ARRAY[5]);
  b float8[];
  s text := '';
  m1 bigint; m2 bigint;
  i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 10] := a[1 + i % 10] + i;
    t[1 + i % 5] := md5(i::text);
    b := a;
    a := array_cat(a, ARRAY[1.0::float8]);
    a := a[1:10];
    s := repeat('y', i % 50);
    IF i = probe THEN m1 := pa_mem(); END IF;
  END LOOP;
  m2 := pa_mem();
  RETURN m2 - m1;
END $$;
SELECT pa_loop(10, 5) IS NOT NULL;
SELECT pa_loop(:n7, :n6) < 2097152 AS flat_100k;
SELECT pa_loop(:n7, :n6) < 2097152 AS flat_100k_again;
SELECT pj_expect('pa_loop(int,int)', 'compiled') \gset

-- over many calls of one function
CREATE FUNCTION pa_small(i int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int[] := ARRAY[1, 2, 3]; t text := 'abc' || i::text;
BEGIN
  a[2] := i;
  a := array_append(a, length(t));
  RETURN a[2] + a[4];
END $$;
CREATE FUNCTION pa_calls(n int, probe int) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE m bigint; s bigint := 0; i int;
BEGIN
  FOR i IN 1..n LOOP
    s := s + pa_small(i);
    IF i = probe THEN m := pa_mem(); END IF;
  END LOOP;
  RETURN pa_mem() - m + 0 * s;
END $$;
SELECT pa_calls(:n6 + 1, :n6) IS NOT NULL;
SELECT pa_calls(:n7, :n6) < 2097152 AS flat;
SELECT pa_small(5), pa_small(6);
SELECT pj_expect('pa_small(int)', 'compiled') \gset

-- a cancel in a long loop of element stores, and the function again
CREATE FUNCTION pa_cancel(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE a float8[] := array_fill(0.0::float8, ARRAY[1000]); s text := '';
    i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 1000] := a[1 + i % 1000] + i;
    s := repeat('z', i % 100);
  END LOOP;
  RETURN (a[1] + length(s))::bigint;
END $$;
SELECT pa_cancel(10), pa_cancel(10);
SELECT pa_mem() AS m0 \gset
SET statement_timeout = 300;
\set SHOW_CONTEXT never
SELECT pa_cancel(2000000000);  -- fail
SELECT pa_cancel(2000000000);  -- fail
\set SHOW_CONTEXT always
RESET statement_timeout;
SELECT pa_cancel(:n6) = :n6, pa_cancel(:n6) = :n6;
SELECT pa_mem() - :m0 < 2097152 AS flat_after_cancel;
SELECT pj_expect('pa_cancel(int)', 'compiled') \gset

-- what stays declined, and so runs as in PL/pgSQL: a domain over an array,
-- an array of a type of the user
CREATE DOMAIN pa_dom AS int[] CHECK (cardinality(VALUE) < 5);
CREATE TYPE pa_comp AS (a int, b text);
CREATE FUNCTION pa_domain(x int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE d pa_dom := ARRAY[1, 2];
BEGIN d[2] := x; RETURN d[2]; END $$;
CREATE FUNCTION pa_composite(x int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c pa_comp[] := ARRAY[ROW(1, 'x')]::pa_comp[];
BEGIN RETURN x + cardinality(c); END $$;
SELECT pa_domain(1), pa_composite(1);
SELECT pa_domain(2), pa_composite(2);
SELECT pj_expect('pa_domain(int)', 'declined:datum:pa_dom') \gset
SELECT pj_expect('pa_composite(int)', 'declined:datum:_pa_comp') \gset
SELECT pa_domain(9);  -- fail
SELECT pa_domain(2), pa_composite(3);

-- NOT NULL, CONSTANT and a NULL argument
CREATE FUNCTION pa_decl(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE
  nn int[] NOT NULL := ARRAY[1, 2];
  c CONSTANT int[] := ARRAY[5, 6, 7];
  n int[];
BEGIN
  IF k = 1 THEN nn[3] := c[2] + c[3]; n[2] := nn[3]; END IF;
  IF k = 2 THEN nn := NULL; END IF;
  RETURN nn::text || c::text || coalesce(n::text, 'N');
END $$;
SELECT pa_decl(0), pa_decl(0), pa_decl(1), pa_decl(1);
SELECT pa_decl(2);  -- fail
SELECT pa_decl(2);  -- fail
SELECT pa_decl(1);
SELECT pj_expect('pa_decl(int)', 'compiled') \gset
SELECT pa_sum(NULL, 3), pa_idem(NULL) IS NULL AS n, pa_rw(NULL, 1, 1);
