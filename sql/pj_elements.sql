--
-- pj_elements: reading and storing elements of one-dimensional int4, int8 and
-- float8 arrays in plpgsql_jit; compiled, each gives the answer of PL/pgSQL
--
-- Every group ends with the number of calls and of evaluations by the
-- executor it made.  An evaluation is the executor's when it gives an array
-- to a call or a conversion (a::text, pg_column_size(a)), or uses a construct
-- that is not an element read or store (ARRAY[...], a slice, a second
-- subscript).
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set SHOW_CONTEXT always
\pset null NULL
SET extra_float_digits = 0;

CREATE FUNCTION pv_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;
SELECT current_setting('debug_discard_caches')::int > 0 AS dd \gset

CREATE TABLE pv_arrs (id int, a text);
INSERT INTO pv_arrs VALUES (1, '{1,2,3}'), (2, '[0:2]={4,5,6}'),
    (3, '[-3:-1]={7,8,9}'), (4, '[5:7]={10,11,12}'), (5, '{1,NULL,3}'),
    (6, '{}'), (7, '[2:3]={NULL,1}');

-- fetch: below, in and above the range, lower bounds 1, 0, -3 and 5, a NULL
-- element, an empty array.  The second read of a call is the one that reads
-- the array as it is when the first has made the elements of the array.
CREATE FUNCTION pv_get4(a int4[], i int) RETURNS int4 LANGUAGE :pj_lang AS $$
DECLARE x int4;
BEGIN x := a[i]; RETURN a[i]; END $$;
CREATE FUNCTION pv_get8(a int8[], i int) RETURNS int8 LANGUAGE :pj_lang AS $$
DECLARE x int8;
BEGIN x := a[i]; RETURN a[i]; END $$;
CREATE FUNCTION pv_getf(a float8[], i int) RETURNS float8 LANGUAGE :pj_lang AS $$
DECLARE x float8;
BEGIN x := a[i]; RETURN a[i]; END $$;
SELECT pv_get4('{1,2,3}', 2), pv_get8('{1,2,3}', 2), pv_getf('{1,2,3}', 2);
SELECT pv_get4('{1,2,3}', 5), pv_get8('{1,2,3}', 0), pv_getf('{1,2,3}', 3);
SELECT pj_expect('pv_get4(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_get8(int8[],int)', 'compiled') \gset
SELECT pj_expect('pv_getf(float8[],int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT id, string_agg(coalesce(pv_get4(a::int4[], i)::text, 'N'), ',' ORDER BY i) AS i4,
       string_agg(coalesce(pv_get8(a::int8[], i)::text, 'N'), ',' ORDER BY i) AS i8,
       string_agg(coalesce(pv_getf(a::float8[], i)::text, 'N'), ',' ORDER BY i) AS f8
  FROM pv_arrs, generate_series(-4, 8) i GROUP BY id ORDER BY id;
SELECT pj_delta(273, 0, 0, 0, 0, 495) \gset

-- the reads that follow one in range find the elements made: neighbours of
-- the subscript below, in and above the range, and of a NULL element
CREATE FUNCTION pv_walk(a int4[], i int) RETURNS int8 LANGUAGE :pj_lang AS $$
BEGIN
  RETURN coalesce(a[i - 1], -1)::int8 * 1000000 + coalesce(a[i], -1)::int8 * 1000
         + coalesce(a[i + 1], -1);
END $$;
SELECT pv_walk('{1,2,3}', 2), pv_walk('{1,NULL,3}', 2);
SELECT pj_expect('pv_walk(int4[],int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT id, string_agg(pv_walk(a::int4[], i)::text, ' ' ORDER BY i) AS walk
  FROM pv_arrs, generate_series(-4, 8) i GROUP BY id ORDER BY id;
SELECT pj_delta(91, 0, 0, 0, 0, 233) \gset

-- a two-dimensional argument read with one subscript, extreme subscripts
SELECT pj_mark() \gset
SELECT pv_get4('{{1,2},{3,4}}', 1), pv_get4('{{1,2},{3,4}}', 2),
       pv_get8('{{1,2},{3,4}}', 3), pv_getf('{{1,2},{3,4}}', 4);
SELECT i, pv_get4('[-5:-3]={7,8,9}', i), pv_get8('[-5:-3]={7,8,9}', i),
       pv_getf('[-5:-3]={7,8,9}', i)
  FROM (VALUES (2147483647), (-2147483647 - 1), (-5), (-3), (-6), (-2)) v(i);
SELECT pj_delta(22, 0, 0, 0, 0, 38) \gset

-- a NULL array reads NULL without evaluating its subscript, a NULL subscript
-- reads NULL
CREATE FUNCTION pv_nullarr(k int) RETURNS int4 LANGUAGE :pj_lang AS $$
DECLARE a int4[];
BEGIN RETURN a[1 / (k - k)]; END $$;
CREATE FUNCTION pv_nullsub(a int4[], k int) RETURNS int4 LANGUAGE :pj_lang AS $$
BEGIN RETURN a[nullif(k, k)]; END $$;
SELECT pv_nullarr(1), pv_nullarr(2);
SELECT pv_nullsub('{1,2,3}', 1), pv_nullsub('{1,2,3}', 2);
SELECT pj_expect('pv_nullarr(int)', 'compiled') \gset
SELECT pj_expect('pv_nullsub(int4[],int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pv_nullarr(3), pv_nullsub('{1,2,3}', 3), pv_nullsub('{}', 3);
SELECT pj_delta(3, 0, 0, 0, 0, 0) \gset

-- the first read of an array whose elements are not made yet, an argument of a
-- column or a text constant, is the slow function's, and the reads after it
-- are not; an array passed from a compiled caller has them
CREATE FUNCTION pv_first(k int) RETURNS int4 LANGUAGE :pj_lang AS $$
DECLARE a int4[];
BEGIN a := '{5,6,7}'; RETURN a[k] + a[k + 1] + a[k]; END $$;
CREATE TABLE pv_c (id int, a4 int4[]);
INSERT INTO pv_c VALUES (1, '{1,2,3}'), (2, '[0:1]={4,5}'), (3, '{}');
CREATE FUNCTION pv_callee(a int4[], i int) RETURNS int4 LANGUAGE :pj_lang STABLE AS $$
BEGIN RETURN a[i] + a[i + 1]; END $$;
CREATE FUNCTION pv_caller(k int) RETURNS int4 LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3,4}'; x int4;
BEGIN x := a[1]; RETURN x + pv_callee(a, k); END $$;
SELECT pv_first(1), pv_first(2), pv_first(3);
SELECT pv_first(1), pv_first(0);
SELECT pv_caller(1), pv_caller(2);
SELECT pv_caller(3), pv_caller(1), pv_caller(0);
SELECT pj_expect('pv_first(int)', 'compiled') \gset
SELECT pj_expect('pv_callee(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_caller(int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pv_first(1), pv_first(2), pv_first(3), pv_first(1);
SELECT pj_delta(4, 0, 0, 0, 0, 4) \gset
SELECT pj_mark() \gset
SELECT id, pv_get4(a4, 2), pv_get4(a4, 0) FROM pv_c ORDER BY id;
SELECT pj_delta(6, 0, 0, 0, 0, 10) \gset
SELECT pj_mark() \gset
SELECT pv_caller(1), pv_caller(2), pv_caller(3);
SELECT pj_delta(6, 0, 3, 0, 0, 3) \gset

-- the arms that the interpreter skips are not evaluated
CREATE FUNCTION pv_and(a int4[], k int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN k <> 0 AND a[10 / k] > 1; END $$;
CREATE FUNCTION pv_or(a int4[], k int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN k = 0 OR a[10 / k] > 1; END $$;
CREATE FUNCTION pv_case(a int4[], k int) RETURNS int4 LANGUAGE :pj_lang AS $$
BEGIN RETURN CASE WHEN k = 0 THEN -1 ELSE a[10 / k] END; END $$;
CREATE FUNCTION pv_coalesce(a int4[], k int) RETURNS int4 LANGUAGE :pj_lang AS $$
BEGIN RETURN coalesce(a[1], a[10 / k]); END $$;
SELECT pv_and('{1,2,3}', 0), pv_and('{1,2,3}', 5), pv_and('{1,2,3}', 10);
SELECT pv_or('{1,2,3}', 0), pv_or('{1,2,3}', 5), pv_or('{1,2,3}', 10);
SELECT pv_case('{1,2,3}', 0), pv_case('{1,2,3}', 5), pv_case('{1,2,3}', 10);
SELECT pv_coalesce('{1,2,3}', 0), pv_coalesce('{NULL,2,3}', 5),
       pv_coalesce('{NULL,2,3}', 10);
SELECT pv_and('{1,2,3}', 0), pv_or('{1,2,3}', 0), pv_case('{1,2,3}', 0),
       pv_coalesce('{1,2,3}', 0);
SELECT pj_expect('pv_and(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_or(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_case(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_coalesce(int4[],int)', 'compiled') \gset
SELECT pv_coalesce('{NULL,2,3}', 0);  -- fail
SELECT pv_and('{1,2,3}', 0);

-- store: in range, past both ends, into a NULL array and an empty one, a NULL
-- value over a value and a value over a NULL
CREATE FUNCTION pv_set4(a int4[], i int, v int4) RETURNS int4[] LANGUAGE :pj_lang AS $$
BEGIN a[i] := v; RETURN a; END $$;
CREATE FUNCTION pv_set8(a int8[], i int, v int8) RETURNS int8[] LANGUAGE :pj_lang AS $$
BEGIN a[i] := v; RETURN a; END $$;
CREATE FUNCTION pv_setf(a float8[], i int, v float8) RETURNS float8[] LANGUAGE :pj_lang AS $$
BEGIN a[i] := v; RETURN a; END $$;
CREATE FUNCTION pv_setnull(i int, v int4) RETURNS int4[] LANGUAGE :pj_lang AS $$
DECLARE a int4[];
BEGIN a[i] := v; RETURN a; END $$;
CREATE FUNCTION pv_setempty(i int, v int4) RETURNS int4[] LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{}';
BEGIN a[i] := v; RETURN a; END $$;
CREATE FUNCTION pv_setnullv(a int4[], i int) RETURNS int4[] LANGUAGE :pj_lang AS $$
BEGIN a[i] := nullif(i, i); RETURN a; END $$;
SELECT pv_set4('{1,2,3}', 2, 9), pv_set8('{1,2,3}', 2, 9), pv_setf('{1,2,3}', 2, 9);
SELECT pv_set4('{1,2,3}', 2, 9), pv_set8('{1,2,3}', 2, 9), pv_setf('{1,2,3}', 2, 9);
SELECT pv_setnull(2, 5), pv_setempty(2, 5), pv_setnullv('{1,2,3}', 2);
SELECT pv_setnull(2, 5), pv_setempty(2, 5), pv_setnullv('{1,2,3}', 2);
SELECT pj_expect('pv_set4(int4[],int,int4)', 'compiled') \gset
SELECT pj_expect('pv_set8(int8[],int,int8)', 'compiled') \gset
SELECT pj_expect('pv_setf(float8[],int,float8)', 'compiled') \gset
SELECT pj_expect('pv_setnull(int,int4)', 'compiled') \gset
SELECT pj_expect('pv_setempty(int,int4)', 'compiled') \gset
SELECT pj_expect('pv_setnullv(int4[],int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT id, string_agg(coalesce(pv_set4(a::int4[], i, 9)::text, 'N'), ' ' ORDER BY i) AS i4,
       string_agg(coalesce(pv_set8(a::int8[], i, 9)::text, 'N'), ' ' ORDER BY i) AS i8,
       string_agg(coalesce(pv_setf(a::float8[], i, 9)::text, 'N'), ' ' ORDER BY i) AS f8
  FROM pv_arrs, generate_series(-4, 8, 3) i GROUP BY id ORDER BY id;
SELECT pj_delta(105, 0, 105, 0, 0, 0) \gset
SELECT pj_mark() \gset
SELECT i, pv_setnull(i, 5), pv_setempty(i, 5)
  FROM generate_series(-2, 2) i ORDER BY i;
SELECT id, i, pv_setnullv(a::int4[], i) FROM pv_arrs,
    generate_series(0, 4) i WHERE id IN (1, 5, 6) ORDER BY id, i;
SELECT pj_delta(25, 0, 25, 0, 0, 0) \gset

-- the subscript is checked before the value is computed, and a two-dimensional
-- target, a size over the limit
CREATE FUNCTION pv_nullsubset(a int4[], k int) RETURNS int4[] LANGUAGE :pj_lang AS $$
BEGIN a[nullif(k, k)] := 1 / (k - k); RETURN a; END $$;
CREATE FUNCTION pv_valueset(a int4[], k int) RETURNS int4[] LANGUAGE :pj_lang AS $$
BEGIN a[1 / (k - k)] := nullif(k, k); RETURN a; END $$;
SELECT pv_nullsubset('{1,2,3}', 1);  -- fail
SELECT pv_nullsubset('{1,2,3}', 1);  -- fail
SELECT pv_valueset('{1,2,3}', 1);  -- fail
SELECT pv_valueset('{1,2,3}', 1);  -- fail
SELECT pj_expect('pv_nullsubset(int4[],int)', 'compiled') \gset
SELECT pj_expect('pv_valueset(int4[],int)', 'compiled') \gset
SELECT pv_set4('{{1,2},{3,4}}', 1, 5);  -- fail
SELECT pv_set4('{{1,2},{3,4}}', 1, 5);  -- fail
SELECT pv_set4('{1,2}', 2147483647, 1);  -- fail
SELECT pv_set4('{1,2}', 2147483647, 1);  -- fail
SELECT pv_set4('{1,2}', -2147483647 - 1, 1);  -- fail
SELECT pj_expect('pv_set4(int4[],int,int4)', 'compiled') \gset

-- the value reads the array it is stored into
CREATE FUNCTION pv_self(a int4[], i int, j int) RETURNS int4[] LANGUAGE :pj_lang AS $$
BEGIN
  a[i] := a[j] + a[i];
  a[a[1]] := a[2];
  RETURN a;
END $$;
SELECT pv_self('{1,2,3}', 3, 2), pv_self('{2,5,7}', 1, 3);
SELECT pv_self('{1,2,3}', 3, 2), pv_self('{2,5,7}', 1, 3);
SELECT pv_self('{1,2,3}', 1, 1), pv_self('{3,5,7}', 2, 2);
SELECT pj_expect('pv_self(int4[],int,int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pv_self('{1,2,3}', 3, 2), pv_self('{2,5,7}', 1, 3),
       pv_self('{3,5,7}', 2, 2);
SELECT pj_delta(3, 0, 6, 0, 0, 0) \gset

-- the answer that the array gives out after a store.  A value read before the
-- store left the flat copy of the array standing, and a stored element must
-- not leave it, nor the size of the flat copy, in use
CREATE FUNCTION pv_ret() RETURNS int4[] LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3}'; x int4;
BEGIN
  x := a[1];
  a[2] := 9;
  RETURN a;
END $$;
SELECT pv_ret(), pv_ret();
SELECT pv_ret();
SELECT pj_expect('pv_ret()', 'compiled') \gset
-- a slow store clears the flat copy, the size is computed and kept, and a
-- store over a NULL element must change it
CREATE FUNCTION pv_size() RETURNS int LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,NULL,3}'; s1 int; s2 int;
BEGIN
  a[4] := 4;
  s1 := pg_column_size(a);
  a[2] := 2;
  s2 := pg_column_size(a);
  RETURN s2 - s1;
END $$;
SELECT pv_size(), pv_size();
SELECT pv_size();
SELECT pj_expect('pv_size()', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pv_ret(), pv_size();
SELECT pj_delta(2, 0, 5, 0, 0, 1) \gset

-- an element read after a store of the same call; the arrays of a call in
-- another call's frames
CREATE FUNCTION pv_rec(n int, a int4[]) RETURNS int8 LANGUAGE :pj_lang STABLE AS $$
DECLARE b int4[] := a; r int8;
BEGIN
  b[n + 1] := coalesce(b[n], 1) + n;
  IF n = 0 THEN RETURN b[1]; END IF;
  r := pv_rec(n - 1, b);
  RETURN r * 10 + b[n + 1];
END $$;
SELECT pv_rec(3, '{1,1,1,1}'), pv_rec(3, '{1,1,1,1}');
SELECT pv_rec(4, '{1,2,3,4,5}'), pv_rec(2, '{1,2,3}');
SELECT pj_expect('pv_rec(int,int4[])', 'compiled') \gset

-- an array argument is the caller's: the column and the caller's variable stay
-- as they were, with PL/pgSQL and plpgsql_jit as the caller
CREATE FUNCTION pv_arg(a int4[]) RETURNS text LANGUAGE :pj_lang STABLE AS $$
DECLARE b int4[];
BEGIN
  b := a;
  a[1] := 100;
  b[2] := 200;
  RETURN a[1] || '/' || a[2] || '/' || b[1] || '/' || b[2];
END $$;
CREATE TABLE pv_t (id int, v int4[]);
INSERT INTO pv_t VALUES (1, '{1,2,3}'), (2, '{4,5,6}');
SELECT id, pv_arg(v), v FROM pv_t ORDER BY id;
SELECT id, pv_arg(v), v FROM pv_t ORDER BY id;
SELECT id, pv_arg(v), v FROM pv_t ORDER BY id;
SELECT pj_expect('pv_arg(int4[])', 'compiled') \gset
CREATE FUNCTION pv_passed(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3}'; r text;
BEGIN
  a[1] := a[3] + k;
  r := pv_arg(a);
  a[2] := a[2] + k;
  RETURN r || '|' || a[1] || '/' || a[2] || '/' || a[3];
END $$;
SELECT pv_passed(1), pv_passed(2), pv_passed(3);
SELECT pv_passed(1), pv_passed(2);
SELECT pj_expect('pv_passed(int)', 'compiled') \gset
CREATE FUNCTION pv_stock(k int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE a int4[] := '{1,2,3}'; r text;
BEGIN
  a[1] := a[3] + k;
  r := pv_arg(a);
  RETURN r || '|' || a[1] || '/' || a[2] || '/' || a[3];
END $$;
SELECT pv_stock(1), pv_stock(2), pv_stock(3);

-- memory: an array built by a store into NULL is the variable's, and the
-- value of a store with a call in it is freed with the call's memory.  The
-- bound is wide for the size of the report itself, a leak is megabytes.
CREATE FUNCTION pv_leak1(n int, probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE a int4[]; m1 bigint; m2 bigint; i int;
BEGIN
  FOR i IN 1..n LOOP
    a := NULL;
    a[1] := i;
    IF i = probe THEN m1 := pv_mem(); END IF;
  END LOOP;
  m2 := pv_mem();
  RETURN m2 - m1;
END $$;
CREATE FUNCTION pv_leak2(n int, probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60,61,62,63,64}';
  m1 bigint; m2 bigint; i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 64] := length(md5(i::text));
    IF i = probe THEN m1 := pv_mem(); END IF;
  END LOOP;
  m2 := pv_mem();
  RETURN m2 - m1;
END $$;
SELECT CASE WHEN :'dd'::bool THEN 20 ELSE 100000 END AS n1,
       CASE WHEN :'dd'::bool THEN 5 ELSE 1000 END AS p1 \gset
SELECT pv_leak1(10, 5) IS NOT NULL, pv_leak2(10, 5) IS NOT NULL;
SELECT pv_leak1(:n1, :p1) < 2097152 AS flat_null_store,
       pv_leak2(:n1, :p1) < 2097152 AS flat_site_store;
SELECT pv_leak1(:n1, :p1) < 2097152 AS flat_null_store,
       pv_leak2(:n1, :p1) < 2097152 AS flat_site_store;
SELECT pj_expect('pv_leak1(int,int)', 'compiled') \gset
SELECT pj_expect('pv_leak2(int,int)', 'compiled') \gset

-- an array is given up when the call ends
CREATE FUNCTION pv_big(n int) RETURNS int4 LANGUAGE :pj_lang AS $$
DECLARE a int4[] := array_fill(1, ARRAY[n]);
BEGIN
  a[5] := 3;
  RETURN a[5];
END $$;
SELECT pv_big(10), pv_big(10);
BEGIN;
SELECT pv_mem() AS m0 \gset
SELECT pv_big(CASE WHEN :'dd'::bool THEN 100 ELSE 2000000 END);
SELECT pv_mem() - :m0 < 4194304 AS released;
COMMIT;
SELECT pj_expect('pv_big(int)', 'compiled') \gset

-- a variable that is not an array of the three types is the executor's
CREATE FUNCTION pv_other(a int2[], b numeric[], c text[]) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  a[1] := a[2];
  b[1] := b[2];
  c[1] := c[2];
  RETURN a::text || b::text || c::text;
END $$;
SELECT pv_other('{1,2}', '{1.5,2.5}', '{x,y}'), pv_other('{1,2}', '{1.5,2.5}', '{x,y}');
SELECT pv_other('{3,4}', '{3.5,4.5}', '{z,w}');
SELECT pj_expect('pv_other(int2[],numeric[],text[])', 'compiled') \gset

-- an element store with an error in the middle of a call, and the same call
-- again: the expression is in use for the rest of the transaction
CREATE FUNCTION pv_err(n int, bad int) RETURNS int4[] LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3}'; i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 3] := a[1 + i % 3] + i;
  END LOOP;
  IF bad = 1 THEN a[nullif(bad, 1)] := 1; END IF;
  IF bad = 2 THEN a[2147483647] := 1; END IF;
  RETURN a;
END $$;
SELECT pv_err(3, 0), pv_err(4, 0);
SELECT pv_err(5, 1);  -- fail
SELECT pv_err(5, 2);  -- fail
SELECT pv_err(3, 0), pv_err(4, 0), pv_err(5, 0);
SELECT pj_expect('pv_err(int,int)', 'compiled') \gset
BEGIN;
SAVEPOINT s;
SELECT pv_err(5, 1);  -- fail
ROLLBACK TO s;
SELECT pv_err(5, 0);
SELECT pj_expect('pv_err(int,int)', 'interpreted:in use') \gset
SAVEPOINT s;
SELECT pv_err(5, 2);  -- fail
ROLLBACK TO s;
COMMIT;
SELECT pv_err(5, 0), pv_err(6, 0);
SELECT pj_expect('pv_err(int,int)', 'compiled') \gset

-- a branch that no call took when the function was translated: the call that
-- takes it is run again by PL/pgSQL, with the arrays it had at the start
CREATE FUNCTION pv_d1(a int4[], n int, k int) RETURNS int8 LANGUAGE :pj_lang AS $$
DECLARE s int8 := 0; i int;
BEGIN
  FOR i IN 1..n LOOP s := s + a[i]; END LOOP;
  IF k = 99 THEN s := s * 1000 + a[1]; END IF;
  RETURN s;
END $$;
CREATE FUNCTION pv_d2(n int, k int) RETURNS int4[] LANGUAGE :pj_lang AS $$
DECLARE a int4[] := '{1,2,3}'; i int;
BEGIN
  FOR i IN 1..n LOOP
    a[1 + i % 3] := a[1 + i % 3] + i;
  END LOOP;
  IF k = 99 THEN a[2] := 0; END IF;
  RETURN a;
END $$;
SELECT pv_d1('{1,2,3}', 3, 0), pv_d1('{1,2,3}', 3, 0), pv_d1('{4,5,6}', 2, 0);
SELECT pv_d2(3, 0), pv_d2(4, 0), pv_d2(5, 0);
SELECT pj_expect('pv_d1(int4[],int,int)', 'compiled') \gset
SELECT pj_variant('pv_d1(int4[],int,int)', false, true) \gset
SELECT pj_expect('pv_d2(int,int)', 'waiting') \gset
SELECT pj_mark() \gset
SELECT pv_d1('{1,2,3}', 3, 99);
SELECT pj_delta(0, 0, 0, 1, 0) \gset
SELECT pv_d2(3, 99);
SELECT pv_d1('{1,2,3}', 3, 0), pv_d2(3, 0), pv_d1('{1,2,3}', 3, 99), pv_d2(5, 99);
