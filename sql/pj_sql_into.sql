--
-- pj_sql_into: SELECT INTO of a plpgsql_jit function, through SPI
--
-- A query that is not an expression, into one variable or several, STRICT or
-- not, runs in compiled code on the plan PL/pgSQL prepared.  Every value,
-- FOUND, message, HINT and CONTEXT is stock PL/pgSQL's.  Rows that name a path
-- (pj_expect) are silent on stock.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE TABLE psi_t (a int PRIMARY KEY, b text, c numeric(7,2), d varchar(12),
                    e int[], f float8, g bool);
INSERT INTO psi_t
  SELECT i, 'row' || i, i * 1.25, 'v' || i, ARRAY[i, i + 1], i / 4.0, i % 2 = 0
    FROM generate_series(1, 20) i;
INSERT INTO psi_t VALUES (21, NULL, NULL, NULL, NULL, NULL, NULL);
ANALYZE psi_t;
CREATE TABLE psi_one (a int);
INSERT INTO psi_one VALUES (1);
ANALYZE psi_one;

-- the SQLSTATE, message, hint and context of an error, caught
CREATE FUNCTION psi_try(q text) RETURNS text LANGUAGE plpgsql AS $$
DECLARE st text; m text; c text; h text; d text;
BEGIN
  EXECUTE q;
  RETURN 'ok';
EXCEPTION WHEN others THEN
  GET STACKED DIAGNOSTICS st = RETURNED_SQLSTATE, m = MESSAGE_TEXT,
                          c = PG_EXCEPTION_CONTEXT, h = PG_EXCEPTION_HINT,
                          d = PG_EXCEPTION_DETAIL;
  RETURN st || ' ' || m || E'\n' || coalesce(d, '') || E'\n'
         || coalesce(h, '') || E'\n' || c;
END $$;

-- one target and three (the shape of a row lookup), and what each type of
-- target gets; a row of NULLs, no row and an unknown key
CREATE FUNCTION psi_one_t(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE t text := 'old'; r text;
BEGIN
  SELECT b INTO t FROM psi_t WHERE a = n;
  r := coalesce(t, '<null>') || found::text;
  SELECT b INTO t FROM psi_t WHERE a = n AND false;
  RETURN r || coalesce(t, '<null>') || found::text;
END $$;
SELECT psi_one_t(3), psi_one_t(21), psi_one_t(99);
SELECT psi_one_t(3), psi_one_t(21), psi_one_t(99);
SELECT psi_one_t(3), psi_one_t(21), psi_one_t(99);
SELECT pj_expect('psi_one_t(integer)', 'compiled') \gset

CREATE FUNCTION psi_three(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE v_c numeric(7,2); v_d varchar(12); v_a int; v_e int[]; v_f float8;
        v_g bool; v_b text;
BEGIN
  SELECT c, d, a INTO v_c, v_d, v_a FROM psi_t WHERE a = n;
  SELECT e, f, g INTO v_e, v_f, v_g FROM psi_t WHERE a = n;
  SELECT b INTO v_b FROM psi_t WHERE a = n;
  RETURN concat_ws('/', v_c, v_d, v_a, v_e, v_f, v_g, v_b, found);
END $$;
SELECT psi_three(4), psi_three(21), psi_three(99);
SELECT psi_three(4), psi_three(21), psi_three(99);
SELECT psi_three(4), psi_three(21), psi_three(99);
SELECT pj_expect('psi_three(integer)', 'compiled') \gset

-- an argument is a target, by value and by reference
CREATE FUNCTION psi_arg(n int, t text, arr int[]) RETURNS text
LANGUAGE :pj_lang AS $$
BEGIN
  SELECT a INTO n FROM psi_t WHERE a > n ORDER BY a LIMIT 1;
  SELECT b INTO t FROM psi_t WHERE a = n;
  SELECT e INTO arr FROM psi_t WHERE a = n;
  RETURN n || '/' || coalesce(t, '<null>') || '/' || coalesce(arr::text, '<null>');
END $$;
SELECT psi_arg(2, 'x', ARRAY[0]), psi_arg(20, 'x', ARRAY[0]), psi_arg(30, 'x', ARRAY[0]);
SELECT psi_arg(2, 'x', ARRAY[0]), psi_arg(20, 'x', ARRAY[0]), psi_arg(30, 'x', ARRAY[0]);
SELECT psi_arg(2, 'x', ARRAY[0]), psi_arg(20, 'x', ARRAY[0]), psi_arg(30, 'x', ARRAY[0]);
SELECT pj_expect('psi_arg(integer,text,integer[])', 'compiled') \gset

-- a target that the statement reads, and two targets that are one variable
CREATE FUNCTION psi_self(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int := n; y int;
BEGIN
  SELECT a + 1 INTO x FROM psi_t WHERE a = x;
  SELECT a, a * 10 INTO y, y FROM psi_t WHERE a = x;
  RETURN x || '/' || coalesce(y::text, '<null>');
END $$;
SELECT psi_self(3), psi_self(20), psi_self(21);
SELECT psi_self(3), psi_self(20), psi_self(21);
SELECT psi_self(3), psi_self(20), psi_self(21);
SELECT pj_expect('psi_self(integer)', 'compiled') \gset

-- more or fewer rows than one, without STRICT: the first row, by the order
CREATE FUNCTION psi_many(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE lo int; hi int; c bigint;
BEGIN
  SELECT a INTO lo FROM psi_t WHERE a > n ORDER BY a;
  SELECT a INTO hi FROM psi_t WHERE a > n ORDER BY a DESC;
  SELECT count(*) INTO c FROM psi_t WHERE a > n;
  RETURN lo || '/' || hi || '/' || c;
END $$;
SELECT psi_many(5), psi_many(19), psi_many(100);
SELECT psi_many(5), psi_many(19), psi_many(100);
SELECT psi_many(5), psi_many(19), psi_many(100);
SELECT pj_expect('psi_many(integer)', 'compiled') \gset

-- NOT NULL targets: no row and a NULL value are the same error
CREATE FUNCTION psi_nn(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int NOT NULL := 7; s text NOT NULL := 'k';
BEGIN
  SELECT a INTO x FROM psi_t WHERE a = n;
  SELECT b INTO s FROM psi_t WHERE a = n;
  RETURN x;
END $$;
SELECT psi_nn(1), psi_nn(2);
SELECT psi_nn(1), psi_nn(2);
SELECT psi_nn(1), psi_nn(2);
SELECT psi_try('SELECT psi_nn(99)');
SELECT psi_try('SELECT psi_nn(99)');
SELECT psi_try('SELECT psi_nn(21)');
SELECT psi_try('SELECT psi_nn(21)');
SELECT psi_nn(3);
SELECT pj_expect('psi_nn(integer)', 'compiled') \gset

-- STRICT: exactly one row, and the hint
CREATE FUNCTION psi_strict(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE t text; u int; v int;
BEGIN
  SELECT b INTO STRICT t FROM psi_t WHERE a = n;
  SELECT a, a + 1 INTO STRICT u, v FROM psi_t WHERE a = n;
  RETURN t || '/' || u || '/' || v || '/' || found;
END $$;
CREATE FUNCTION psi_strict2(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE u int;
BEGIN
  SELECT a INTO STRICT u FROM psi_t WHERE a > n;
  RETURN u;
END $$;
SELECT psi_strict(1), psi_strict(20);
SELECT psi_strict(1), psi_strict(20);
SELECT psi_strict(1), psi_strict(20);
SELECT psi_try('SELECT psi_strict(99)');
SELECT psi_try('SELECT psi_strict(99)');
SELECT psi_strict2(20), psi_strict2(20);
SELECT psi_strict2(20), psi_strict2(20);
SELECT psi_try('SELECT psi_strict2(5)');
SELECT psi_try('SELECT psi_strict2(5)');
SELECT psi_try('SELECT psi_strict2(50)');
SELECT psi_strict2(20);
SELECT pj_expect('psi_strict(integer)', 'compiled') \gset
SELECT pj_expect('psi_strict2(integer)', 'compiled') \gset

-- FOUND is set before the targets: a target that is FOUND wins
CREATE FUNCTION psi_found(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int; r text := '';
BEGIN
  SELECT false, 1 INTO found, x FROM psi_one;
  r := r || found::text || x;
  SELECT true, 2 INTO found, x FROM psi_one WHERE a = n;
  r := r || coalesce(found::text, 'n') || coalesce(x::text, '<null>');
  SELECT 3 INTO x FROM psi_one;
  r := r || found::text || x;
  SELECT 4 INTO x FROM psi_one WHERE a = n;
  RETURN r || coalesce(found::text, 'n') || coalesce(x::text, '<null>');
END $$;
SELECT psi_found(1), psi_found(2);
SELECT psi_found(1), psi_found(2);
SELECT psi_found(1), psi_found(2);
SELECT pj_expect('psi_found(integer)', 'compiled') \gset

-- the extra checks are read at each call: set between calls they are honoured
CREATE FUNCTION psi_xc(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int; y int; z int;
BEGIN
  SELECT a INTO x FROM psi_t WHERE a > n;
  SELECT a INTO x, y FROM psi_t WHERE a = n;
  SELECT a, a + 1 INTO z FROM psi_t WHERE a = n;
  RETURN coalesce(x::text, '-') || coalesce(y::text, '-') || coalesce(z::text, '-');
END $$;
SELECT psi_xc(10), psi_xc(11);
SELECT psi_xc(10), psi_xc(11);
SELECT psi_xc(10), psi_xc(11);
SELECT pj_expect('psi_xc(integer)', 'compiled') \gset
SET plpgsql.extra_warnings = 'too_many_rows';
SELECT psi_xc(10), psi_xc(11);
SET plpgsql.extra_warnings = 'strict_multi_assignment';
SELECT psi_xc(10), psi_xc(11);
SET plpgsql.extra_warnings = 'all';
SELECT psi_xc(10);
RESET plpgsql.extra_warnings;
SET plpgsql.extra_errors = 'too_many_rows';
SELECT psi_try('SELECT psi_xc(10)');
SELECT psi_try('SELECT psi_xc(10)');
SET plpgsql.extra_errors = 'strict_multi_assignment';
SELECT psi_try('SELECT psi_xc(10)');
SELECT psi_try('SELECT psi_xc(10)');
SET plpgsql.extra_errors = 'too_many_rows, strict_multi_assignment';
SELECT psi_try('SELECT psi_xc(10)');
SET plpgsql.extra_errors = 'none';
SET plpgsql.extra_warnings = 'shadowed_variables';
SELECT psi_xc(10), psi_xc(11);
RESET plpgsql.extra_warnings;
RESET plpgsql.extra_errors;
SELECT psi_xc(10), psi_xc(11);
SELECT pj_expect('psi_xc(integer)', 'compiled') \gset
-- STRICT is strict with or without the check, and a warning keeps the row
CREATE FUNCTION psi_xc2(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  SELECT a INTO x FROM psi_t WHERE a > n ORDER BY a DESC;
  RETURN x;
END $$;
SELECT psi_xc2(3), psi_xc2(3), psi_xc2(3);
SET plpgsql.extra_warnings = 'too_many_rows';
SELECT psi_xc2(3), psi_xc2(20);
SET plpgsql.extra_errors = 'too_many_rows';
SELECT psi_try('SELECT psi_xc2(3)');
SELECT psi_xc2(20);
RESET plpgsql.extra_errors;
RESET plpgsql.extra_warnings;
SELECT pj_expect('psi_xc2(integer)', 'compiled') \gset

-- the conversion of the value: no cast is what compiles, and a cast of the
-- statement is PL/pgSQL's
CREATE FUNCTION psi_cast_ok(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE big bigint; v varchar(12); num numeric(7,2); t text;
BEGIN
  SELECT count(*) INTO big FROM psi_t WHERE a < n;
  SELECT d INTO v FROM psi_t WHERE a = n;
  SELECT c INTO num FROM psi_t WHERE a = n;
  SELECT b INTO t FROM psi_t WHERE a = n;
  RETURN big || '/' || coalesce(v, '-') || '/' || coalesce(num::text, '-') || '/' || coalesce(t, '-');
END $$;
SELECT psi_cast_ok(5), psi_cast_ok(21), psi_cast_ok(0);
SELECT psi_cast_ok(5), psi_cast_ok(21), psi_cast_ok(0);
SELECT psi_cast_ok(5), psi_cast_ok(21), psi_cast_ok(0);
SELECT pj_expect('psi_cast_ok(integer)', 'compiled') \gset
CREATE FUNCTION psi_cast_int(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  SELECT count(*) INTO c FROM psi_t WHERE a < n;
  RETURN c;
END $$;
CREATE FUNCTION psi_cast_text(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE t text;
BEGIN
  SELECT d INTO t FROM psi_t WHERE a = n;
  RETURN t;
END $$;
CREATE FUNCTION psi_cast_short(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE v varchar(2);
BEGIN
  SELECT d INTO v FROM psi_t WHERE a = n;
  RETURN v;
END $$;
CREATE FUNCTION psi_cast_num(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x numeric(3,1);
BEGIN
  SELECT sum(c) INTO x FROM psi_t WHERE a < n;
  RETURN x::text;
END $$;
SELECT psi_cast_int(5), psi_cast_int(5);
SELECT psi_cast_int(5), psi_cast_int(5);
SELECT psi_cast_text(5), psi_cast_text(21);
SELECT psi_cast_text(5), psi_cast_text(21);
SELECT psi_cast_short(5), psi_cast_short(21);
SELECT psi_try('SELECT psi_cast_short(11)');
SELECT psi_try('SELECT psi_cast_short(11)');
SELECT psi_cast_num(3), psi_cast_num(1);
SELECT psi_cast_num(3), psi_cast_num(1);
SELECT psi_try('SELECT psi_cast_num(20)');
SELECT psi_try('SELECT psi_cast_num(20)');
SELECT pj_expect('psi_cast_int(integer)', 'declined:cast') \gset
SELECT pj_expect('psi_cast_text(integer)', 'declined:cast') \gset
SELECT pj_expect('psi_cast_short(integer)', 'declined:cast') \gset
SELECT pj_expect('psi_cast_num(integer)', 'declined:cast') \gset

-- INTO of a command that has no result, and a record or a domain, are not
-- compiled; their errors and values are PL/pgSQL's
CREATE DOMAIN psi_dom AS int CHECK (VALUE < 100);
CREATE FUNCTION psi_domain(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x psi_dom;
BEGIN
  SELECT a * 10 INTO x FROM psi_t WHERE a = n;
  RETURN x;
END $$;
CREATE FUNCTION psi_rec(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r record;
BEGIN
  SELECT a, b INTO r FROM psi_t WHERE a = n;
  RETURN r.a || r.b;
END $$;
SELECT psi_domain(2), psi_domain(3);
SELECT psi_domain(2), psi_domain(3);
SELECT psi_try('SELECT psi_domain(20)');
SELECT psi_try('SELECT psi_domain(20)');
SELECT psi_rec(2), psi_rec(3);
SELECT psi_rec(2), psi_rec(3);
SELECT pj_expect('psi_domain(integer)', 'declined:datum:psi_dom') \gset
SELECT pj_expect('psi_rec(integer)', 'declined:datum:record') \gset

-- #print_strict_params adds a DETAIL we do not make: the function is declined
CREATE FUNCTION psi_psp(n int, t text) RETURNS int LANGUAGE :pj_lang AS $$
#print_strict_params on
DECLARE x int;
BEGIN
  SELECT a INTO STRICT x FROM psi_t WHERE a > n AND b <> t;
  RETURN x;
END $$;
SELECT psi_psp(19, 'x'), psi_psp(19, 'x');
SELECT psi_try('SELECT psi_psp(5, ''x'')');
SELECT psi_try('SELECT psi_psp(5, ''x'')');
SELECT psi_try('SELECT psi_psp(50, ''x'')');
SELECT pj_expect('psi_psp(integer,text)', 'declined:print_strict_params') \gset

-- under use_column a new analysis may bind a name to a variable: declined,
-- for a query that is no expression as for PERFORM
CREATE FUNCTION psi_col(n int) RETURNS int LANGUAGE :pj_lang AS $$
#variable_conflict use_column
DECLARE x int;
BEGIN
  SELECT a INTO x FROM psi_t WHERE a = n;
  RETURN x;
END $$;
SELECT psi_col(3), psi_col(4);
SELECT psi_col(3), psi_col(4);
SELECT pj_expect('psi_col(integer)', 'declined:variable_conflict') \gset

-- GET DIAGNOSTICS stays PL/pgSQL's; the row count it reads is the statement's
CREATE FUNCTION psi_diag(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int; rc int;
BEGIN
  SELECT a INTO x FROM psi_t WHERE a > n;
  GET DIAGNOSTICS rc = ROW_COUNT;
  RETURN x || '/' || rc;
END $$;
SELECT psi_diag(5), psi_diag(20), psi_diag(30);
SELECT psi_diag(5), psi_diag(20), psi_diag(30);
SELECT pj_expect('psi_diag(integer)', 'declined:statement:GET DIAGNOSTICS') \gset

-- statements that write, and a data-modifying CTE, are not compiled: the
-- trigger on the table is PL/pgSQL's to run, and the table is as stock's
CREATE TABLE psi_w (a int, b text);
INSERT INTO psi_w SELECT i, 'x' FROM generate_series(1, 6) i;
CREATE FUNCTION psi_w_fn() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE NOTICE 'trigger on %', old.a; RETURN old; END $$;
CREATE FUNCTION psi_cte_trg(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  WITH d AS (DELETE FROM psi_w WHERE a = n RETURNING *) SELECT count(*) INTO c FROM d;
  RETURN c;
END $$;
CREATE FUNCTION psi_cte_plain(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE c int;
BEGIN
  WITH d AS (DELETE FROM psi_w WHERE a = n RETURNING *) SELECT count(*) INTO c FROM d;
  RETURN c;
END $$;
CREATE FUNCTION psi_ins(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  INSERT INTO psi_w VALUES (n, 'i') RETURNING a INTO x;
  RETURN x;
END $$;
SELECT psi_cte_plain(1), psi_cte_plain(2), psi_cte_plain(3);
SELECT psi_cte_plain(1), psi_cte_plain(4);
CREATE TRIGGER psi_w_d BEFORE DELETE ON psi_w
  FOR EACH ROW EXECUTE FUNCTION psi_w_fn();
SELECT psi_cte_trg(5), psi_cte_trg(6);
SELECT psi_cte_trg(5), psi_cte_trg(7);
SELECT psi_cte_trg(5), psi_cte_trg(7);
SELECT psi_ins(10), psi_ins(11);
SELECT psi_ins(10), psi_ins(11);
SELECT psi_ins(12);
SELECT * FROM psi_w ORDER BY a, b;
SELECT pj_expect('psi_cte_trg(integer)', 'declined:statement:SQL statement') \gset
SELECT pj_expect('psi_cte_plain(integer)', 'declined:statement:SQL statement') \gset
SELECT pj_expect('psi_ins(integer)', 'declined:statement:SQL statement') \gset

-- what happens to the plan between calls changes no value and leaves no call
CREATE TABLE psi_b (a int, b text);
INSERT INTO psi_b SELECT i, 'v' || i FROM generate_series(1, 50) i;
ANALYZE psi_b;
-- (it returns a variable: an expression of its own would be stale after
-- DISCARD PLANS, and the call would be PL/pgSQL's)
CREATE FUNCTION psi_b(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE t text; x int;
BEGIN
  SELECT b, a INTO t, x FROM psi_b WHERE a = n;
  RETURN t;
END $$;
SELECT psi_b(1), psi_b(2), psi_b(99);
SELECT psi_b(1), psi_b(2), psi_b(99);
SELECT psi_b(1), psi_b(2), psi_b(99);
SELECT pj_expect('psi_b(integer)', 'compiled') \gset
SELECT pj_mark() \gset
TRUNCATE psi_b;
SELECT psi_b(1), psi_b(2);
INSERT INTO psi_b SELECT i, 'v' || i FROM generate_series(1, 50) i;
ANALYZE psi_b;
SELECT psi_b(1), psi_b(2);
CREATE INDEX psi_b_a ON psi_b (a);
SELECT psi_b(1), psi_b(2);
DISCARD PLANS;
SELECT psi_b(3), psi_b(99);
DROP INDEX psi_b_a;
SELECT psi_b(3), psi_b(99);
SELECT pj_expect('psi_b(integer)', 'compiled') \gset
SELECT pj_delta(10, 0, NULL, 0, 0);
-- a column added, one dropped that the statement does not name
ALTER TABLE psi_b ADD COLUMN c int DEFAULT 7;
SELECT psi_b(3), psi_b(99);
ALTER TABLE psi_b DROP COLUMN c;
SELECT psi_b(3), psi_b(99);
SELECT pj_expect('psi_b(integer)', 'compiled') \gset
-- a column of the statement is renamed: PL/pgSQL's error, then as before
ALTER TABLE psi_b RENAME COLUMN b TO bb;
SELECT psi_try('SELECT psi_b(3)');
SELECT psi_try('SELECT psi_b(3)');
ALTER TABLE psi_b RENAME COLUMN bb TO b;
SELECT psi_b(3), psi_b(99);
SELECT psi_b(3), psi_b(99);

-- the type of a column changes between calls: the value is converted to the
-- target as PL/pgSQL does; the statement is compiled again afterwards or not
CREATE TABLE psi_alt (a int, b int, c varchar(5));
INSERT INTO psi_alt VALUES (1, 10, 'abc'), (2, 20, 'defgh');
CREATE FUNCTION psi_alt(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int; v varchar(5);
BEGIN
  SELECT b, c INTO x, v FROM psi_alt WHERE a = n;
  RETURN x || '/' || coalesce(v, '-');
END $$;
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT pj_expect('psi_alt(integer)', 'compiled') \gset
ALTER TABLE psi_alt ALTER COLUMN b TYPE bigint;
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
ALTER TABLE psi_alt ALTER COLUMN b TYPE text USING b::text;
SELECT psi_try('SELECT psi_alt(1)');
SELECT psi_try('SELECT psi_alt(1)');
SELECT psi_alt(2), psi_alt(3);
ALTER TABLE psi_alt ALTER COLUMN b TYPE int USING b::int;
ALTER TABLE psi_alt ALTER COLUMN c TYPE varchar(3) USING left(c, 3);
SELECT psi_try('SELECT psi_alt(1)');
SELECT psi_alt(3);
ALTER TABLE psi_alt ALTER COLUMN c TYPE varchar(5);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
SELECT psi_alt(1), psi_alt(2), psi_alt(3);
-- a column added to the list of the statement, or one fewer than its targets
CREATE TABLE psi_cols (a int, b int, c int);
INSERT INTO psi_cols VALUES (1, 2, 3);
CREATE FUNCTION psi_cols(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE x int := -1; y int := -1;
BEGIN
  SELECT * INTO x, y FROM psi_cols WHERE a = n;
  RETURN coalesce(x::text, '-') || '/' || coalesce(y::text, '-');
END $$;
SELECT psi_cols(1), psi_cols(1), psi_cols(2);
SELECT psi_cols(1), psi_cols(1), psi_cols(2);
ALTER TABLE psi_cols DROP COLUMN c;
SELECT psi_cols(1), psi_cols(2);
SELECT psi_cols(1), psi_cols(2);
ALTER TABLE psi_cols DROP COLUMN b;
SELECT psi_cols(1), psi_cols(2);
SELECT psi_cols(1), psi_cols(2);
SET plpgsql.extra_errors = 'strict_multi_assignment';
SELECT psi_try('SELECT psi_cols(1)');
SELECT psi_try('SELECT psi_cols(1)');
RESET plpgsql.extra_errors;
ALTER TABLE psi_cols ADD COLUMN b int DEFAULT 5, ADD COLUMN c int DEFAULT 6, ADD COLUMN d int DEFAULT 8;
SELECT psi_cols(1), psi_cols(2);
SET plpgsql.extra_warnings = 'strict_multi_assignment';
SELECT psi_cols(1), psi_cols(1);
RESET plpgsql.extra_warnings;

-- recursion through a statement: the frames are each their own
CREATE FUNCTION psi_recur(n int) RETURNS int LANGUAGE :pj_lang STABLE AS $$
DECLARE r int := 0;
BEGIN
  IF n > 0 THEN
    SELECT psi_recur(n - 1) INTO r FROM psi_one;
  END IF;
  RETURN n + r;
END $$;
SELECT psi_recur(3), psi_recur(4);
SELECT psi_recur(20), psi_recur(3);
SELECT psi_recur(20), psi_recur(3);
SELECT pj_expect('psi_recur(integer)', 'compiled') \gset

-- a callee that says when it runs: the statement is its caller's, once
CREATE FUNCTION psi_noisy(n int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RAISE NOTICE 'noisy %', n; RETURN n; END $$;
CREATE FUNCTION psi_callee(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  SELECT psi_noisy(a + n) INTO x FROM psi_one;
  SELECT a INTO x FROM psi_one WHERE a = psi_noisy(n);
  RETURN x;
END $$;
SELECT psi_callee(1);
SELECT psi_callee(2);
SELECT psi_callee(3);
SELECT pj_expect('psi_callee(integer)', 'compiled') \gset

-- privileges are the executor's: a table, and a column, taken away
CREATE ROLE regress_psi_u;
CREATE TABLE psi_priv (a int, b text);
INSERT INTO psi_priv VALUES (1, 'one'), (2, 'two');
CREATE FUNCTION psi_priv(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE t text;
BEGIN
  SELECT b INTO t FROM psi_priv WHERE a = n;
  RETURN t;
END $$;
GRANT SELECT ON psi_priv TO regress_psi_u;
GRANT EXECUTE ON FUNCTION psi_priv(int) TO regress_psi_u;
SET ROLE regress_psi_u;
SELECT psi_priv(1), psi_priv(3);
SELECT psi_priv(1), psi_priv(3);
SELECT psi_priv(1), psi_priv(3);
RESET ROLE;
SELECT pj_expect('psi_priv(integer)', 'compiled') \gset
REVOKE SELECT ON psi_priv FROM regress_psi_u;
GRANT SELECT (a) ON psi_priv TO regress_psi_u;
SET ROLE regress_psi_u;
SELECT psi_try('SELECT psi_priv(1)');
SELECT psi_try('SELECT psi_priv(1)');
RESET ROLE;
GRANT SELECT ON psi_priv TO regress_psi_u;
SET ROLE regress_psi_u;
SELECT psi_priv(1), psi_priv(3);
SELECT psi_priv(1), psi_priv(3);
RESET ROLE;

-- a statement not planned yet leaves the call to PL/pgSQL, with nothing run
-- twice; then the function is compiled with it
CREATE FUNCTION psi_wait(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE s int := 0; x int;
BEGIN
  FOR i IN 1..n LOOP s := s + i; END LOOP;
  PERFORM psi_noisy(s);
  IF n > 100 THEN
    SELECT a + psi_noisy(n) INTO x FROM psi_one;
    s := s + x;
  END IF;
  RETURN s;
END $$;
SELECT psi_wait(3);
SELECT psi_wait(3);
SELECT psi_wait(3);
SELECT pj_expect('psi_wait(integer)', 'waiting') \gset
SELECT pj_mark() \gset
SELECT psi_wait(200);
SELECT psi_wait(200);
SELECT psi_wait(3);
SELECT psi_wait(200);
SELECT pj_expect('psi_wait(integer)', 'compiled') \gset
SELECT pj_delta(NULL, NULL, NULL, 0, NULL);

-- a loop of statements: the values, and the memory read inside the loop, which
-- the tuple tables must not grow
CREATE FUNCTION psi_mem() RETURNS bigint LANGUAGE sql STABLE AS
  $$ SELECT sum(total_bytes)::bigint FROM pg_backend_memory_contexts $$;
CREATE FUNCTION psi_loop(n int, probe int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE m bigint := 0; t text; s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    SELECT b INTO t FROM psi_t WHERE a = 1 + i % 20;
    s := s + length(t);
    IF i = probe THEN m := psi_mem(); END IF;
  END LOOP;
  RETURN m + s * 0;
END $$;
CREATE FUNCTION psi_loop_sum(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE t text; s int := 0;
BEGIN
  FOR i IN 1..n LOOP
    SELECT b INTO t FROM psi_t WHERE a = 1 + i % 25;
    s := s + coalesce(length(t), 100);
  END LOOP;
  RETURN s;
END $$;
SELECT psi_loop(3, 1) > 0, psi_loop(3, 2) > 0;
SELECT psi_loop(3, 1) > 0, psi_loop(3, 2) > 0;
SELECT psi_loop(3, 1) > 0, psi_loop(3, 2) > 0;
SELECT psi_loop(1000, 1000) AS m1 \gset
SELECT psi_loop(20000, 20000) - :m1 < 262144 AS flat;
SELECT pj_expect('psi_loop(integer,integer)', 'compiled') \gset
SELECT psi_loop_sum(10), psi_loop_sum(10), psi_loop_sum(5000);
SELECT pj_expect('psi_loop_sum(integer)', 'compiled') \gset
-- the statements ran in compiled code, in one call
SELECT pj_mark() \gset
SELECT psi_loop_sum(3000);
SELECT pj_delta(1, 0, NULL, 0, 0, NULL, 3000);
-- custom plans, which move the generation of the plan at every execution
SET plan_cache_mode = force_custom_plan;
SELECT psi_loop(1000, 1000) AS m1 \gset
SELECT psi_loop(20000, 20000) - :m1 < 262144 AS flat_custom;
SELECT psi_loop_sum(3000);
RESET plan_cache_mode;

-- plan identity: the custom and generic plans of the statement are PL/pgSQL's
-- (the same sequence as the PERFORM of pj_sql, through INTO).  Planning 1 / n
-- for n = 0 raises, a generic plan does not.
CREATE FUNCTION psi_g3(n int, h int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  SELECT 1 / n INTO x FROM psi_t WHERE false;
  RETURN x;
END $$;
SELECT psi_g3(1, NULL), psi_g3(1, 1), psi_g3(1, NULL), psi_g3(1, 1), psi_g3(1, NULL);
SELECT psi_g3(0, 1);
CREATE FUNCTION psi_g3b(n int, h int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  SELECT 1 / n INTO x FROM psi_t WHERE false;
  RETURN x;
END $$;
SELECT psi_g3b(1, 1);
SELECT psi_g3b(1, 1);
SELECT psi_g3b(1, 1);
SELECT psi_g3b(1, 1);
SELECT psi_g3b(1, 1);
SELECT psi_g3b(0, 1);
SELECT pj_expect('psi_g3(integer,integer)', 'compiled') \gset
SELECT pj_expect('psi_g3b(integer,integer)', 'compiled') \gset

-- a query under a parallel setting: INTO asks for one or two rows, so no
-- worker is started; the values are the same
CREATE TABLE psi_big AS
  SELECT i AS a, 'text' || (i % 7) AS b FROM generate_series(1, 20000) i;
ANALYZE psi_big;
CREATE FUNCTION psi_par(n int, t text) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE c bigint; m int;
BEGIN
  SELECT count(*) INTO c FROM psi_big WHERE a < n AND b <> t;
  SELECT max(a) INTO m FROM psi_big WHERE a < n AND b <> t;
  RETURN c || '/' || coalesce(m::text, '-');
END $$;
SET debug_parallel_query = regress;
SET parallel_setup_cost = 0;
SET parallel_tuple_cost = 0;
SET min_parallel_table_scan_size = 0;
SELECT psi_par(100, 'text3'), psi_par(1, 'text3');
SELECT psi_par(100, 'text3'), psi_par(1, 'text3');
SELECT psi_par(100, 'text3'), psi_par(1, 'text3');
RESET min_parallel_table_scan_size;
RESET parallel_tuple_cost;
RESET parallel_setup_cost;
RESET debug_parallel_query;
SELECT pj_expect('psi_par(integer,text)', 'compiled') \gset

DROP OWNED BY regress_psi_u;
DROP ROLE regress_psi_u;
