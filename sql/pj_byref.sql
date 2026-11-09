--
-- pj_byref: variables of types passed by reference (arguments, locals,
-- results); compiled, each gives the answer of PL/pgSQL
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pr_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;

-- an argument, a local, a result, chained
CREATE FUNCTION pr_chain(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text;
BEGIN
  y := x;
  IF k > 0 THEN
    x := upper(x) || k::text;
  END IF;
  y := y || '/' || x;
  RETURN y;
END $$;
SELECT pr_chain('ab', 1), pr_chain('cd', 0);
SELECT pr_chain('ab', 1), pr_chain('cd', 0), pr_chain('', 2);
SELECT pj_expect('pr_chain(text,int)', 'compiled') \gset

-- an argument assigned in one branch is the caller's: a column of a table, a
-- local of an interpreted function, and the caller still reads it afterwards
CREATE TABLE pr_t (id int, s text);
INSERT INTO pr_t SELECT g, repeat(chr(96 + g), g) FROM generate_series(1, 5) g;
CREATE FUNCTION pr_arg(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN
  IF k > 2 THEN
    x := 'replaced';
  END IF;
  RETURN x || '!';
END $$;
CREATE FUNCTION pr_caller(n int) RETURNS text LANGUAGE plpgsql AS $$
DECLARE l text := repeat('q', n) || 'z'; r text; res text := '';
BEGIN
  FOR i IN 1..4 LOOP
    r := pr_arg(l, i);
    res := res || r || l || ';';
  END LOOP;
  RETURN res;
END $$;
SELECT pr_arg(s, id) FROM pr_t ORDER BY id;
SELECT pr_arg(s, id) FROM pr_t ORDER BY id;
SELECT s, pr_arg(s, id) FROM pr_t ORDER BY id;
SELECT pr_caller(3), pr_caller(5);
SELECT pr_caller(3), pr_caller(5);
SELECT pj_expect('pr_arg(text,int)', 'compiled') \gset

-- x := x, x := NULL, and a copy that outlives the assignment to its source
CREATE FUNCTION pr_self(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text;
BEGIN
  x := x;
  y := x;
  IF k = 1 THEN x := NULL; END IF;
  IF k = 2 THEN x := lower(x) || '+'; END IF;
  IF k = 3 THEN x := y; x := x; END IF;
  RETURN coalesce(x, '<null>') || '|' || coalesce(y, '<null>');
END $$;
SELECT pr_self('Ab', 0), pr_self('Ab', 1), pr_self('Ab', 2), pr_self('Ab', 3);
SELECT pr_self('Ab', 0), pr_self('Ab', 1), pr_self('Ab', 2), pr_self('Ab', 3);
SELECT pj_expect('pr_self(text,int)', 'compiled') \gset

CREATE FUNCTION pr_alias(x text) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text;
BEGIN
  y := x;
  x := upper(x) || 'x';
  x := x || x;
  RETURN y;
END $$;
SELECT pr_alias('abc'), pr_alias('abc');
SELECT pr_alias('abc'), pr_alias('de');
SELECT pj_expect('pr_alias(text)', 'compiled') \gset

-- NULL as the result of a branch, of a call, and as the declared default
CREATE FUNCTION pr_null(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text;
BEGIN
  IF k = 1 THEN y := 'one'; END IF;
  IF k = 2 THEN y := nullif(x, x); END IF;
  RETURN y;
END $$;
SELECT pr_null('a', 1), pr_null('a', 2), pr_null('a', 3);
SELECT pr_null('a', 1), pr_null('a', 2), pr_null('a', 3);
SELECT pj_expect('pr_null(text,int)', 'compiled') \gset

-- a default in a loop: the block starts afresh at every entry
CREATE FUNCTION pr_block(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE s text := '';
BEGIN
  FOR i IN 1..n LOOP
    DECLARE
      t text := repeat('a', i);
      u text;
    BEGIN
      s := s || coalesce(u, '-') || t;
      u := t;
    END;
  END LOOP;
  RETURN s;
END $$;
SELECT pr_block(4), pr_block(4);
SELECT pr_block(0), pr_block(1), pr_block(6);
SELECT pj_expect('pr_block(int)', 'compiled') \gset

-- the memory of a loop is flat inside one call, measured inside it
CREATE FUNCTION pr_grow(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE t text := 'x'; m0 bigint;
BEGIN
  FOR i IN 1..10 LOOP t := left(t || 'x', 10); END LOOP;
  m0 := pr_mem();
  FOR i IN 1..n LOOP t := left(t || repeat('x', 100), 10); END LOOP;
  RETURN pr_mem() - m0;
END $$;
SELECT pr_grow(10) IS NOT NULL;
SELECT pr_grow(10) IS NOT NULL;
SELECT pr_grow(200000) < 1048576 AS flat_assign;
SELECT pj_expect('pr_grow(int)', 'compiled') \gset

CREATE FUNCTION pr_grow_block(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE s int := 0; m0 bigint;
BEGIN
  FOR i IN 1..10 LOOP
    DECLARE t text := repeat('a', 100);
    BEGIN s := s + length(t); END;
  END LOOP;
  m0 := pr_mem();
  FOR i IN 1..n LOOP
    DECLARE t text := repeat('a', 100);
    BEGIN s := s + length(t); END;
  END LOOP;
  RETURN pr_mem() - m0;
END $$;
SELECT pr_grow_block(10) IS NOT NULL;
SELECT pr_grow_block(10) IS NOT NULL;
SELECT pr_grow_block(200000) < 1048576 AS flat_block;
SELECT pj_expect('pr_grow_block(int)', 'compiled') \gset

-- and across calls: the copies of a call are gone when the next one starts, so
-- a per-row function does not grow the transaction
CREATE FUNCTION pr_cross(k int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE t text := repeat('x', 3000 + k % 7); u text;
BEGIN
  u := t || k::text;
  RETURN length(u);
END $$;
SELECT sum(pr_cross(g)) FROM generate_series(1, 10) g;
SELECT sum(pr_cross(g)) FROM generate_series(1, 10) g;
BEGIN;
SELECT sum(pr_cross(g)) FROM generate_series(1, 2000) g;
SELECT pr_mem() AS m0 \gset
SELECT sum(pr_cross(g)) FROM generate_series(1, 20000) g;
SELECT pr_mem() - :m0 < 1048576 AS flat_across_calls;
COMMIT;
SELECT pj_expect('pr_cross(int)', 'compiled') \gset

-- a local passed down a recursion; the callee assigns its argument
CREATE FUNCTION pr_rec(n int, s text) RETURNS text LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE t text;
BEGIN
  IF n = 0 THEN
    RETURN s;
  END IF;
  t := s || n::text;
  s := 'x' || n::text;
  RETURN pr_rec(n - 1, t) || s;
END $$;
SELECT pr_rec(3, 'a');
SELECT pr_rec(4, 'a'), pr_rec(1, 'b');
SELECT pr_rec(40, 'seed') = pr_rec(40, 'seed');
SELECT pj_expect('pr_rec(int,text)', 'compiled') \gset

-- name, uuid, interval, numeric, bytea, jsonb, varchar
CREATE FUNCTION pr_name(x name, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE n name;
BEGIN
  n := x;
  IF k > 0 THEN n := 'other'; END IF;
  RETURN x || '/' || n;
END $$;
CREATE FUNCTION pr_name_ret(x name) RETURNS name LANGUAGE :pj_lang AS $$
DECLARE n name := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pr_name_text(x name) RETURNS text LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pr_uuid(x uuid, k int) RETURNS uuid LANGUAGE :pj_lang AS $$
DECLARE u uuid := x;
BEGIN
  IF k > 0 THEN u := '00000000-0000-0000-0000-00000000000a'; END IF;
  RETURN u;
END $$;
CREATE FUNCTION pr_interval(x interval, k int) RETURNS interval LANGUAGE :pj_lang AS $$
DECLARE v interval;
BEGIN
  v := x;
  IF k > 0 THEN v := x + interval '1 day'; END IF;
  RETURN v;
END $$;
CREATE FUNCTION pr_num(x numeric, k int) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE z numeric := 0; w numeric;
BEGIN
  w := x;
  IF k > 0 THEN z := w * 2 + k; END IF;
  RETURN z + w;
END $$;
CREATE FUNCTION pr_bytea(x bytea, k int) RETURNS bytea LANGUAGE :pj_lang AS $$
DECLARE b bytea := x;
BEGIN
  IF k > 0 THEN b := b || '\x01'::bytea; END IF;
  RETURN b;
END $$;
CREATE FUNCTION pr_jsonb(x jsonb, k int) RETURNS jsonb LANGUAGE :pj_lang AS $$
DECLARE j jsonb := x;
BEGIN
  IF k > 0 THEN j := j || '{"a": 1}'::jsonb; END IF;
  RETURN j;
END $$;
CREATE FUNCTION pr_varchar(x varchar, k int) RETURNS varchar LANGUAGE :pj_lang AS $$
DECLARE v varchar := x;
BEGIN
  IF k > 0 THEN v := v || 'x'; END IF;
  RETURN v;
END $$;
CREATE FUNCTION pr_i2n(x int, y bigint) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric := x; m numeric;
BEGIN
  m := y;
  RETURN n + m;
END $$;
CREATE FUNCTION pr_ret_i4(x int) RETURNS numeric LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pr_ret_i8(x bigint) RETURNS numeric LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pr_const() RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE c numeric := 7; d numeric;
BEGIN d := 5; RETURN c + d; END $$;
SELECT pr_name('abc', 0), pr_name('abc', 1), pr_name_ret('nm'), pr_name_text('nm'),
       pr_uuid('11111111-2222-3333-4444-555555555555', 0),
       pr_uuid('11111111-2222-3333-4444-555555555555', 1),
       pr_interval('1 hour 2 mon', 0), pr_interval('1 hour 2 mon', 1),
       pr_num(1.5, 0), pr_num(1.5, 3), pr_bytea('\xdead', 0), pr_bytea('\xdead', 1),
       pr_jsonb('{"b": 2}', 0), pr_jsonb('{"b": 2}', 1),
       pr_varchar('v', 0), pr_varchar('v', 1),
       pr_i2n(3, 4000000000), pr_ret_i4(5), pr_ret_i8(6), pr_const();
SELECT pr_name('abc', 0), pr_name('abc', 1), pr_name_ret('nm'), pr_name_text('nm'),
       pr_uuid('11111111-2222-3333-4444-555555555555', 0),
       pr_uuid('11111111-2222-3333-4444-555555555555', 1),
       pr_interval('1 hour 2 mon', 0), pr_interval('1 hour 2 mon', 1),
       pr_num(1.5, 0), pr_num(1.5, 3), pr_bytea('\xdead', 0), pr_bytea('\xdead', 1),
       pr_jsonb('{"b": 2}', 0), pr_jsonb('{"b": 2}', 1),
       pr_varchar('v', 0), pr_varchar('v', 1),
       pr_i2n(3, 4000000000), pr_ret_i4(5), pr_ret_i8(6), pr_const();
SELECT pr_name('abc', 1), pr_uuid('11111111-2222-3333-4444-555555555555', 1),
       pr_interval('1 hour 2 mon', 1), pr_num(1.5, 3), pr_bytea('\xdead', 1),
       pr_jsonb('{"b": 2}', 1), pr_varchar('v', 1);
SELECT pj_expect('pr_name(name,int)', 'compiled') \gset
SELECT pj_expect('pr_name_ret(name)', 'compiled') \gset
SELECT pj_expect('pr_name_text(name)', 'compiled') \gset
SELECT pj_expect('pr_uuid(uuid,int)', 'compiled') \gset
SELECT pj_expect('pr_interval(interval,int)', 'compiled') \gset
SELECT pj_expect('pr_num(numeric,int)', 'compiled') \gset
SELECT pj_expect('pr_bytea(bytea,int)', 'compiled') \gset
SELECT pj_expect('pr_jsonb(jsonb,int)', 'compiled') \gset
SELECT pj_expect('pr_varchar(varchar,int)', 'compiled') \gset
SELECT pj_expect('pr_i2n(int,bigint)', 'compiled') \gset
SELECT pj_expect('pr_ret_i4(int)', 'compiled') \gset
SELECT pj_expect('pr_ret_i8(bigint)', 'compiled') \gset
SELECT pj_expect('pr_const()', 'compiled') \gset

-- what stays declined, and why: a cast to a varchar or a char can raise, an
-- array is not ours
CREATE FUNCTION pr_typmod(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2) := x;
BEGIN RETURN n; END $$;
CREATE FUNCTION pr_trunc(x text) RETURNS varchar LANGUAGE :pj_lang AS $$
DECLARE v varchar(3) := x;
BEGIN RETURN v; END $$;
CREATE FUNCTION pr_pad(x text) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE v char(4) := x;
BEGIN RETURN v || '|'; END $$;
CREATE FUNCTION pr_pad2(x text) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE v char(4); w char(4);
BEGIN v := x; w := v; RETURN v || '|' || w || '|'; END $$;
CREATE FUNCTION pr_tm(x numeric) RETURNS numeric LANGUAGE :pj_lang AS $$
DECLARE n numeric(5,2);
BEGIN n := x; RETURN n; END $$;
CREATE FUNCTION pr_arr(x int[]) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN 1; END $$;
CREATE FUNCTION pr_dom(x int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE d regclass := 'pg_class'::regclass;
BEGIN RETURN 1; END $$;
SELECT pr_typmod(1.234), pr_trunc('abc'), pr_pad('ab'), pr_pad2('abc'), pr_tm(1.234), pr_arr('{1}'), pr_dom(1);
SELECT pr_typmod(1.234), pr_trunc('abc'), pr_pad('ab'), pr_pad2('abc'), pr_tm(1.234), pr_arr('{1}'), pr_dom(1);
SELECT pr_typmod(1.234), pr_trunc('abc'), pr_pad('ab'), pr_pad2('abc'), pr_tm(1.234), pr_arr('{1}'), pr_dom(1);
SELECT pj_expect('pr_typmod(numeric)', 'compiled') \gset
SELECT pj_expect('pr_trunc(text)', 'declined:cast') \gset
SELECT pj_expect('pr_pad(text)', 'declined:cast') \gset
SELECT pj_expect('pr_pad2(text)', 'compiled') \gset
SELECT pj_expect('pr_tm(numeric)', 'compiled') \gset
SELECT pj_expect('pr_arr(int[])', 'declined:datum:_int4') \gset
SELECT pr_trunc('abcdef');  -- fail
SELECT pr_typmod(123456);  -- fail
SELECT pr_tm(123456);  -- fail
SELECT pr_tm(1.234);

-- an error after an assignment: the next call starts afresh
CREATE FUNCTION pr_err(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text;
BEGIN
  y := x || 'a';
  x := y || 'b';
  IF k = 1 THEN
    y := substring(x, 1, -1);
  END IF;
  RETURN x || y;
END $$;
SELECT pr_err('p', 0), pr_err('q', 0);
SELECT pr_err('p', 0), pr_err('q', 0);
SELECT pr_err('p', 1);  -- fail
SELECT pr_err('p', 0), pr_err('r', 0);
SELECT pr_err('p', 0), pr_err('r', 0);
SELECT pj_expect('pr_err(text,int)', 'compiled') \gset

-- an unplanned branch after a by-reference store, in a function with no call:
-- the call goes back to PL/pgSQL, which gives the same answer
CREATE FUNCTION pr_deopt(x text, k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE y text := 'start';
BEGIN
  IF k = 1 THEN y := 'one'; END IF;
  IF k = 2 THEN y := x; x := 'two'; END IF;
  IF k = 3 THEN RETURN x; END IF;
  RETURN y;
END $$;
SELECT pr_deopt('a', 0);
SELECT pr_deopt('a', 1);
SELECT pr_deopt('a', 0);
SELECT pj_mark() \gset
SELECT pr_deopt('a', 2);
SELECT pj_delta(0, 0, 0, 1, 0) \gset
SELECT pr_deopt('b', 3);
SELECT pr_deopt('a', 0), pr_deopt('a', 1), pr_deopt('b', 2), pr_deopt('c', 3);
SELECT pr_deopt('a', 0), pr_deopt('a', 1), pr_deopt('b', 2), pr_deopt('c', 3);
SELECT pj_expect('pr_deopt(text,int)', 'compiled') \gset

-- calls that allocate, in a function with a branch not yet taken: it waits
CREATE FUNCTION pr_wait(x text, k int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE t text;
BEGIN
  t := lower(x);
  IF k = 0 THEN
    RETURN -1;
  END IF;
  IF t = '' THEN
    RETURN 0;
  END IF;
  RETURN length(t) + k;
END $$;
SELECT pr_wait('Ab', 1);
SELECT pr_wait('Ab', 1);
SELECT pj_expect('pr_wait(text,int)', 'waiting') \gset
SELECT pr_wait('Ab', 0), pr_wait('', 1);
SELECT pr_wait('Ab', 1);
SELECT pr_wait('Ab', 0), pr_wait('', 1), pr_wait('Abc', 2);
SELECT pj_expect('pr_wait(text,int)', 'compiled') \gset

-- a constant is the Datum of a copy, and a bare one needs no executor
CREATE FUNCTION pr_lit(k int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE s text := 'init';
BEGIN
  IF k = 1 THEN s := 'a literal'; END IF;
  IF k = 2 THEN s := NULL; END IF;
  RETURN s;
END $$;
SELECT pr_lit(0);
SELECT pr_lit(0);
SELECT pj_mark() \gset
SELECT pr_lit(1);
SELECT pj_delta(0, 0, 0, 1, 0) \gset
SELECT pr_lit(2);
SELECT pr_lit(0), pr_lit(1), pr_lit(2), pr_lit(3);
SELECT pj_expect('pr_lit(int)', 'compiled') \gset
SELECT pj_mark() \gset
SELECT pr_lit(0), pr_lit(1), pr_lit(2), pr_lit(3);
SELECT pj_delta(4, 0, 0, 0, 0) \gset

-- a table's rows through a compiled function, then the same rows by name
SELECT s, pr_chain(s, id), pr_self(s, id % 4) FROM pr_t ORDER BY id;
SELECT s, pr_chain(s, id), pr_self(s, id % 4) FROM pr_t ORDER BY id;
SELECT pj_expect('pr_chain(text,int)', 'compiled') \gset
SELECT pj_expect('pr_self(text,int)', 'compiled') \gset

-- a NULL argument is PL/pgSQL's
SELECT pr_chain(NULL, 1), pr_arg(NULL, 3), pr_self(NULL, 0);
SELECT pr_chain('a', NULL), pr_arg(NULL, NULL);
