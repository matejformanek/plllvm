--
-- pj_results: OUT parameters and composite results; pj_expect says which way
-- each runs on plpgsql_jit, and the output is PL/pgSQL's either way
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- one OUT parameter: the function returns its type, not a row
CREATE FUNCTION po_out1(n int, OUT m int) LANGUAGE :pj_lang AS $$
BEGIN m := n * 2; END $$;
SELECT po_out1(5);
SELECT po_out1(6);
SELECT po_out1(i) FROM generate_series(1, 3) i;
SELECT * FROM po_out1(7);
SELECT pj_expect('po_out1(int)', 'compiled') \gset
SELECT pj_variant('po_out1(int)', false, true) \gset

-- an OUT parameter nobody assigns is NULL
CREATE FUNCTION po_unset(n int, OUT m int) LANGUAGE :pj_lang AS $$
BEGIN NULL; END $$;
SELECT po_unset(1) IS NULL AS unset;
SELECT po_unset(2) IS NULL AS unset;
SELECT pj_expect('po_unset(int)', 'compiled') \gset

-- INOUT: an argument that is also the result
CREATE FUNCTION po_inout(INOUT x int, y int) LANGUAGE :pj_lang AS $$
BEGIN x := x + y; END $$;
SELECT po_inout(1, 2);
SELECT po_inout(10, 20);
SELECT * FROM po_inout(100, 200);
SELECT pj_expect('po_inout(int,int)', 'compiled') \gset

-- several: a row, with a NULL among its fields
CREATE FUNCTION po_out3(a int, OUT x int, OUT y text, OUT z float8)
LANGUAGE :pj_lang AS $$
BEGIN
  x := a * 2;
  IF a >= 0 THEN y := 'n' || a; END IF;
  z := a * 0.5::float8;
END $$;
SELECT po_out3(1);
SELECT po_out3(2);
SELECT po_out3(-3);
SELECT * FROM po_out3(4);
SELECT (po_out3(i)).y FROM generate_series(1, 3) i;
SELECT po_out3(5)::text, row_to_json(po_out3(5)), po_out3(5) IS NULL AS isnull;
SELECT pj_expect('po_out3(int)', 'compiled') \gset

-- the fields of other types
CREATE FUNCTION po_types(n int, OUT b bool, OUT l int8, OUT d date, OUT t text,
                         OUT num numeric)
LANGUAGE :pj_lang AS $$
BEGIN
  b := n > 0;
  l := n::int8 * 3;
  d := DATE '2020-01-01' + n;
  t := repeat('ab', n);
  num := n * 1.5;
END $$;
SELECT * FROM po_types(1);
SELECT * FROM po_types(2);
SELECT * FROM po_types(0);
SELECT row_to_json(po_types(3));
SELECT pj_expect('po_types(int)', 'compiled') \gset

-- an OUT function that leaves the code once: the interpreter finishes the call
CREATE FUNCTION po_deopt(a int, OUT x int, OUT y text) LANGUAGE :pj_lang AS $$
BEGIN
  IF a > 0 THEN x := a; y := 'pos'; ELSE x := -a * 2; y := 'neg'; END IF;
END $$;
SELECT po_deopt(1);
SELECT po_deopt(2);
SELECT pj_expect('po_deopt(int)', 'compiled') \gset
SELECT pj_variant('po_deopt(int)', false, true) \gset
SELECT pj_mark() \gset
SELECT po_deopt(-1);
SELECT pj_delta(NULL, NULL, NULL, 1, 0) \gset
SELECT pj_expect('po_deopt(int)', 'deopt') \gset
SELECT po_deopt(-2), po_deopt(3);
SELECT pj_expect('po_deopt(int)', 'compiled') \gset

-- a recursion that returns three OUT parameters at each level
CREATE FUNCTION po_depth(n int, OUT a int, OUT b int, OUT c text)
LANGUAGE :pj_lang IMMUTABLE AS $$
BEGIN
  IF n = 0 THEN
    a := 0; b := 0; c := 'z';
  ELSE
    a := (po_depth(n - 1)).a + 1; b := a * 2; c := 'x';
  END IF;
END $$;
SELECT * FROM po_depth(2);
SELECT * FROM po_depth(50);
SELECT * FROM po_depth(50);
SELECT pj_expect('po_depth(int)', 'compiled') \gset

-- what the signature still declines: a procedure
CREATE PROCEDURE po_proc(INOUT x int) LANGUAGE :pj_lang AS $$
BEGIN x := x + 1; END $$;
CALL po_proc(1);
CALL po_proc(2);
CALL po_proc(3);
SELECT pj_expect('po_proc(int)', 'declined:signature') \gset

-- an OUT parameter that is a record, or a domain, is out of scope, whether
-- the body assigns it or not
CREATE TYPE po_t AS (a int, b text);
CREATE DOMAIN po_dom AS int CHECK (VALUE >= 0);
CREATE FUNCTION po_orec(n int, OUT p po_t) LANGUAGE :pj_lang AS $$
BEGIN p := ROW(n, 'a'::text); END $$;
CREATE FUNCTION po_orec2(n int, OUT k int, OUT p po_t) LANGUAGE :pj_lang AS $$
BEGIN k := n; p := ROW(n, 'a'::text); END $$;
CREATE FUNCTION po_odom(n int, OUT k int, OUT d po_dom) LANGUAGE :pj_lang AS $$
BEGIN k := n; d := n; END $$;
CREATE FUNCTION po_orec3(n int, OUT k int, OUT p po_t) LANGUAGE :pj_lang AS $$
BEGIN k := n; END $$;
CREATE FUNCTION po_odom2(n int, OUT k int, OUT d po_dom) LANGUAGE :pj_lang AS $$
BEGIN k := n; END $$;
SELECT po_orec(1);
SELECT po_orec(2);
SELECT po_orec2(1);
SELECT po_orec2(2);
SELECT po_odom(1);
SELECT po_odom(2);
SELECT po_orec3(1);
SELECT po_orec3(2);
SELECT po_odom2(1);
SELECT po_odom2(2);
SELECT pj_expect('po_orec(int)', 'declined:datum:record') \gset
SELECT pj_expect('po_orec2(int)', 'declined:datum:record') \gset
SELECT pj_expect('po_odom(int)', 'declined:datum:po_dom') \gset
SELECT pj_expect('po_orec3(int)', 'declined:datum:record') \gset
SELECT pj_expect('po_odom2(int)', 'declined:datum:po_dom') \gset

-- a composite result from a row expression
CREATE FUNCTION po_row(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN ROW(x, 'a' || x); END $$;
SELECT po_row(1);
SELECT po_row(2);
SELECT * FROM po_row(3);
SELECT row_to_json(po_row(4));
SELECT (po_row(5)).b;
SELECT po_row(6) IS NULL AS isnull;
SELECT pj_expect('po_row(int)', 'compiled') \gset
SELECT pj_variant('po_row(int)', true, false) \gset

-- a cast to the type, and a call of a function that returns it
CREATE FUNCTION po_cast(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN (x, 'b')::po_t; END $$;
CREATE FUNCTION po_g(x int) RETURNS po_t LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN (x * 2, 'g')::po_t; END $$;
CREATE FUNCTION po_call(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN po_g(x); END $$;
SELECT po_cast(1), po_call(1);
SELECT po_cast(2), po_call(2);
SELECT row_to_json(po_cast(3)), row_to_json(po_call(3));
SELECT pj_expect('po_cast(int)', 'compiled') \gset
SELECT pj_expect('po_call(int)', 'compiled') \gset

-- a row of another shape: the error is raised at the exit of the function,
-- which names no expression, so the next call in the transaction is compiled
CREATE FUNCTION po_bad(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN
  IF x > 0 THEN RETURN ROW(x, 'a'::text); END IF;
  RETURN ROW(x);
END $$;
SELECT po_bad(1);
SELECT po_bad(0);  -- fail
SELECT po_bad(0);  -- fail
SELECT po_bad(1);
SELECT po_bad(1);
BEGIN;
SAVEPOINT s;
SELECT po_bad(0);  -- fail
ROLLBACK TO s;
SELECT po_bad(1);
SELECT pj_expect('po_bad(int)', 'compiled') \gset
COMMIT;

-- NULL is returned as it is
CREATE FUNCTION po_null(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN NULL; END $$;
SELECT po_null(1) IS NULL AS isnull, po_null(1)::text AS txt;
SELECT po_null(2) IS NULL AS isnull, po_null(2)::text AS txt;
SELECT pj_expect('po_null(int)', 'compiled') \gset

-- RECORD: passed as it is, or given the type of the caller's column list
CREATE FUNCTION po_rec(x int) RETURNS record LANGUAGE :pj_lang AS $$
BEGIN RETURN ROW(x, 'a'::text); END $$;
SELECT po_rec(1);
SELECT po_rec(2);
SELECT * FROM po_rec(3) AS (a int, b text);
SELECT * FROM po_rec(4) AS (a int, b text);
SELECT * FROM po_rec(5) AS (c bigint, d text);
SELECT * FROM po_rec(6) AS (a int);  -- fail
SELECT pj_expect('po_rec(int)', 'compiled') \gset

-- a type with a dropped column: the fields are mapped, and the result is
-- labelled with the type of the function
CREATE TYPE po_d AS (a int, gone int, b text);
ALTER TYPE po_d DROP ATTRIBUTE gone;
CREATE FUNCTION po_drop(x int) RETURNS po_d LANGUAGE :pj_lang AS $$
BEGIN RETURN ROW(x, 'd'::text); END $$;
SELECT po_drop(1);
SELECT po_drop(2);
SELECT row_to_json(po_drop(3));
SELECT (po_drop(4)).b;
SELECT pj_expect('po_drop(int)', 'compiled') \gset

-- a column added between calls: the row no longer fits
CREATE TYPE po_add AS (a int, b text);
CREATE FUNCTION po_addf(x int) RETURNS po_add LANGUAGE :pj_lang AS $$
BEGIN RETURN ROW(x, 'e'::text); END $$;
SELECT po_addf(1);
SELECT po_addf(2);
ALTER TYPE po_add ADD ATTRIBUTE c int;
SELECT po_addf(3);  -- fail
SELECT po_addf(3);  -- fail
ALTER TYPE po_add DROP ATTRIBUTE c;
SELECT po_addf(4);
SELECT pj_expect('po_addf(int)', 'compiled') \gset

-- a value that is no row is PL/pgSQL's to refuse
CREATE FUNCTION po_noncomp(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN x + 1; END $$;
SELECT po_noncomp(1);  -- fail
SELECT po_noncomp(2);  -- fail
SELECT po_noncomp(3);  -- fail
SELECT pj_expect('po_noncomp(int)', 'declined:cast') \gset

-- a composite domain checks its value with user code: out of scope
CREATE TYPE po_two AS (q1 int8, q2 int8);
CREATE DOMAIN po_ordered AS po_two CHECK ((VALUE).q1 <= (VALUE).q2);
CREATE FUNCTION po_build(i int8, j int8) RETURNS po_ordered LANGUAGE :pj_lang AS $$
BEGIN RETURN ROW(i, j); END $$;
SELECT po_build(1, 2);
SELECT po_build(1, 3);
SELECT po_build(2, 1);  -- fail
SELECT po_build(2, 1);  -- fail
SELECT pj_expect('po_build(int8,int8)', 'declined:signature') \gset

-- the value of a callee that returns a record variable reaches the exit as an
-- expanded record: of the type of the function, and of another type that has
-- the same columns
CREATE TYPE po_t2 AS (a int, b text);
CREATE FUNCTION po_exp1(x int) RETURNS po_t LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r po_t;
BEGIN r := ROW(x, 'e1'::text); RETURN r; END $$;
CREATE FUNCTION po_exp2(x int) RETURNS po_t2 LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE r po_t2;
BEGIN r := ROW(x, 'e2'::text); RETURN r; END $$;
CREATE FUNCTION po_exph1(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN po_exp1(x); END $$;
CREATE FUNCTION po_exph2(x int) RETURNS po_t LANGUAGE :pj_lang AS $$
BEGIN RETURN po_exp2(x); END $$;
CREATE FUNCTION po_exph3(x int) RETURNS po_d LANGUAGE :pj_lang AS $$
BEGIN RETURN po_exp1(x); END $$;
SELECT po_exph1(1), po_exph2(1), po_exph3(1);
SELECT po_exph1(2), po_exph2(2), po_exph3(2);
SELECT row_to_json(po_exph1(3)), row_to_json(po_exph2(3)), row_to_json(po_exph3(3));
SELECT pj_expect('po_exph1(int)', 'compiled') \gset
SELECT pj_expect('po_exph2(int)', 'compiled') \gset
SELECT pj_expect('po_exph3(int)', 'compiled') \gset
