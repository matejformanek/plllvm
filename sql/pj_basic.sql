--
-- pj_basic: functions whose body is a RETURN; pj_expect says which way each
-- runs on plpgsql_jit, and the output is PL/pgSQL's either way
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- an expression of the expression compiler
CREATE FUNCTION pb_inc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n + 1;
END
$$;
SELECT pb_inc(1);
SELECT pb_inc(2);
SELECT pb_inc(3);
SELECT pb_inc(i) FROM generate_series(1, 4) i;
SELECT pj_expect('pb_inc(int)', 'compiled') \gset

-- NULL arguments run in PL/pgSQL, with the same result
SELECT pb_inc(NULL) IS NULL AS null_in;
SELECT pj_expect('pb_inc(int)', 'interpreted:null arg') \gset
SELECT pb_inc(41);
SELECT pj_expect('pb_inc(int)', 'compiled') \gset

-- the other types of the expression compiler, and the casts to the result
CREATE FUNCTION pb_big(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n * 1000000;
END
$$;
CREATE FUNCTION pb_flt(x float8, y float8) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN
  RETURN x * y - 0.5;
END
$$;
CREATE FUNCTION pb_cmp(a bigint, b int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  RETURN a > b;
END
$$;
CREATE FUNCTION pb_i2f(n int) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n;
END
$$;
CREATE FUNCTION pb_narrow(n bigint) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n / 1000;
END
$$;
SELECT pb_big(7), pb_flt(1.5, 4), pb_cmp(5000000000, 3), pb_i2f(3), pb_narrow(5000);
SELECT pb_big(7), pb_flt(1.5, 4), pb_cmp(5000000000, 3), pb_i2f(3), pb_narrow(5000);
SELECT pb_big(-7), pb_flt('NaN', 4), pb_cmp(2, 3), pb_i2f(-3), pb_narrow(-5000);
SELECT pj_expect('pb_big(int)', 'compiled') \gset
SELECT pj_expect('pb_flt(double precision,double precision)', 'compiled') \gset
SELECT pj_expect('pb_cmp(bigint,int)', 'compiled') \gset
SELECT pj_expect('pb_i2f(int)', 'compiled') \gset
SELECT pj_expect('pb_narrow(bigint)', 'compiled') \gset

-- a bare variable or constant, of any type passed by value: the Datum moves
CREATE FUNCTION pb_i2(x int2) RETURNS int2 LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_i4(x int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_i8(x bigint) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_f4(x float4) RETURNS float4 LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_f8(x float8) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_b(x bool) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_d(x date) RETURNS date LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_o(x oid) RETURNS oid LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_c(x "char") RETURNS "char" LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_ts(x timestamptz) RETURNS timestamptz LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_k4() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN 42; END $$;
CREATE FUNCTION pb_k2() RETURNS int2 LANGUAGE :pj_lang AS $$
BEGIN RETURN '-7'::int2; END $$;
CREATE FUNCTION pb_kf() RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN '-0'::float8; END $$;
CREATE FUNCTION pb_kn() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN NULL; END $$;
SELECT pb_i2((-32768)::int2), pb_i4(-2147483648), pb_i8(-9223372036854775808),
       pb_f4('1.1'), pb_f8('-Infinity'), pb_b(true), pb_d('2026-03-01'::date - 1),
       pb_o(4294967295), pb_c('x'), pb_ts('2026-11-02 12:00:00+00'),
       pb_k4(), pb_k2(), pb_kf(), pb_kn() IS NULL AS kn;
SELECT pb_i2((-32768)::int2), pb_i4(-2147483648), pb_i8(-9223372036854775808),
       pb_f4('1.1'), pb_f8('-Infinity'), pb_b(true), pb_d('2026-03-01'::date - 1),
       pb_o(4294967295), pb_c('x'), pb_ts('2026-11-02 12:00:00+00'),
       pb_k4(), pb_k2(), pb_kf(), pb_kn() IS NULL AS kn;
SELECT pb_i2(32767::int2), pb_i4(2147483647), pb_i8(9223372036854775807),
       pb_f4('NaN'), pb_f8('NaN'), pb_b(false), pb_d('infinity'),
       pb_o(0), pb_c('~'), pb_ts('-infinity'),
       pb_k4(), pb_k2(), pb_kf(), pb_kn() IS NULL AS kn;
SELECT pb_f8(-0.0)::text, pb_kf()::text;
SELECT pj_expect('pb_i2(int2)', 'compiled') \gset
SELECT pj_expect('pb_i4(int)', 'compiled') \gset
SELECT pj_expect('pb_i8(bigint)', 'compiled') \gset
SELECT pj_expect('pb_f4(float4)', 'compiled') \gset
SELECT pj_expect('pb_f8(double precision)', 'compiled') \gset
SELECT pj_expect('pb_b(bool)', 'compiled') \gset
SELECT pj_expect('pb_d(date)', 'compiled') \gset
SELECT pj_expect('pb_o(oid)', 'compiled') \gset
SELECT pj_expect('pb_c("char")', 'compiled') \gset
SELECT pj_expect('pb_ts(timestamp with time zone)', 'compiled') \gset
SELECT pj_expect('pb_k4()', 'compiled') \gset
SELECT pj_expect('pb_k2()', 'compiled') \gset
SELECT pj_expect('pb_kf()', 'compiled') \gset
SELECT pj_expect('pb_kn()', 'compiled') \gset

-- a variable that is not an argument: FOUND, and an expression over it
CREATE FUNCTION pb_found() RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN found; END $$;
CREATE FUNCTION pb_nfound(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN RETURN NOT found AND n > 0; END $$;
SELECT pb_found(), pb_nfound(1);
SELECT pb_found(), pb_nfound(1);
SELECT pb_found(), pb_nfound(0);
SELECT pj_expect('pb_found()', 'compiled') \gset
SELECT pj_expect('pb_nfound(int)', 'compiled') \gset

-- RETURN with no value
CREATE FUNCTION pb_void() RETURNS void LANGUAGE :pj_lang AS $$
BEGIN RETURN; END $$;
SELECT pb_void() IS NULL;
SELECT pb_void() IS NULL;
SELECT pb_void() IS NULL;
SELECT pj_expect('pb_void()', 'compiled') \gset

-- no RETURN at all
CREATE FUNCTION pb_none() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN END $$;
SELECT pb_none();  -- fail
SELECT pb_none();  -- fail
SELECT pb_none();  -- fail
SELECT pj_expect('pb_none()', 'compiled') \gset

-- blocks, and statements after the RETURN that never run
CREATE FUNCTION pb_nested(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  BEGIN
    BEGIN
      RETURN n + 10;
    END;
    RETURN n + 20;
  END;
  RETURN n + 30;
END
$$;
CREATE FUNCTION pb_dead(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RETURN n;
  IF n > 0 THEN RETURN 0; END IF;
  RETURN nosuch(n);
END
$$;
SELECT pb_nested(1), pb_dead(5);
SELECT pb_nested(1), pb_dead(5);
SELECT pb_nested(2), pb_dead(6);
SELECT pj_expect('pb_nested(int)', 'compiled') \gset
SELECT pj_expect('pb_dead(int)', 'compiled') \gset

-- STRICT, SECURITY DEFINER, a function with SET: they run as for PL/pgSQL
CREATE FUNCTION pb_strict(n int) RETURNS int LANGUAGE :pj_lang STRICT AS $$
BEGIN RETURN n * 2; END $$;
CREATE FUNCTION pb_definer(n int) RETURNS int LANGUAGE :pj_lang SECURITY DEFINER AS $$
BEGIN RETURN n * 3; END $$;
CREATE FUNCTION pb_setj(n int) RETURNS int LANGUAGE :pj_lang SET extra_float_digits = 0 AS $$
BEGIN RETURN n * 4; END $$;
SELECT pb_strict(1), pb_definer(1), pb_setj(1), pb_strict(NULL) IS NULL;
SELECT pb_strict(2), pb_definer(2), pb_setj(2), pb_strict(NULL) IS NULL;
SELECT pb_strict(3), pb_definer(3), pb_setj(3), pb_strict(NULL) IS NULL;
SELECT pj_expect('pb_strict(int)', 'compiled') \gset
SELECT pj_expect('pb_definer(int)', 'compiled') \gset
SELECT pj_expect('pb_setj(int)', 'compiled') \gset

-- in a query, over rows, and called from another function
SELECT sum(pb_inc(i)), sum(pb_big(i)), count(*) FILTER (WHERE pb_cmp(i, 50))
  FROM generate_series(1, 100) i;
CREATE FUNCTION pb_caller(n int) RETURNS int LANGUAGE sql AS $$ SELECT pb_inc(pb_inc(n)) $$;
SELECT pb_caller(1), pb_caller(2), pb_caller(3);
SELECT pj_expect('pb_inc(int)', 'compiled') \gset

-- what is not compiled, and why: the result is the same
CREATE FUNCTION pb_e7() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN '12abc'; END $$;
CREATE DOMAIN pb_nn AS int NOT NULL;
CREATE FUNCTION pb_e8() RETURNS pb_nn LANGUAGE :pj_lang AS $$
BEGIN RETURN NULL; END $$;
SELECT pb_e7();  -- fail
SELECT pb_e7();  -- fail
SELECT pb_e8();  -- fail
SELECT pb_e8();  -- fail
SELECT pj_expect('pb_e7()', 'declined:cast') \gset
SELECT pj_expect('pb_e8()', 'declined:cast') \gset

CREATE FUNCTION pb_i2mul(n int2) RETURNS int2 LANGUAGE :pj_lang AS $$
BEGIN RETURN n * 10; END $$;
CREATE FUNCTION pb_num(n int) RETURNS numeric LANGUAGE :pj_lang AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pb_f8k() RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN 2.5; END $$;
SELECT pb_i2mul(3::int2), pb_num(4), pb_f8k();
SELECT pb_i2mul(3::int2), pb_num(4), pb_f8k();
SELECT pb_i2mul(3::int2), pb_num(4), pb_f8k();
SELECT pj_expect('pb_i2mul(int2)', 'declined:node') \gset
SELECT pj_expect('pb_num(int)', 'declined:datum:numeric') \gset
SELECT pj_expect('pb_f8k()', 'declined:cast') \gset

CREATE FUNCTION pb_if(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN RETURN 1; END IF;
  RETURN 2;
END $$;
CREATE FUNCTION pb_decl(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int := n;
BEGIN RETURN x; END $$;
CREATE FUNCTION pb_exc(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n; EXCEPTION WHEN others THEN RETURN 0; END $$;
CREATE FUNCTION pb_text(t text) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN 1; END $$;
CREATE FUNCTION pb_poly(a anyelement) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN 1; END $$;
CREATE FUNCTION pb_out(n int, OUT m int) LANGUAGE :pj_lang AS $$
BEGIN m := n; END $$;
CREATE FUNCTION pb_set1(n int) RETURNS SETOF int LANGUAGE :pj_lang AS $$
BEGIN RETURN NEXT n; RETURN; END $$;
CREATE FUNCTION pb_rec(n int) RETURNS pb_nn LANGUAGE :pj_lang AS $$
BEGIN RETURN n; END $$;
CREATE FUNCTION pb_rnd() RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN random() * 0; END $$;
CREATE FUNCTION pb_callee(n int) RETURNS int LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN RETURN n + 1; END $$;
CREATE FUNCTION pb_user(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pb_callee(n); END $$;
CREATE FUNCTION pb_sub(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN (SELECT n + 1); END $$;
CREATE PROCEDURE pb_proc(n int) LANGUAGE :pj_lang AS $$
BEGIN RETURN; END $$;
SELECT pb_if(1), pb_decl(2), pb_exc(3), pb_text('a'), pb_poly(1), pb_out(5),
       pb_rec(6), pb_rnd(), pb_user(7), pb_sub(8);
SELECT pb_if(1), pb_decl(2), pb_exc(3), pb_text('a'), pb_poly(1), pb_out(5),
       pb_rec(6), pb_rnd(), pb_user(7), pb_sub(8);
SELECT pb_if(0), pb_decl(2), pb_exc(3), pb_text('b'), pb_poly(2), pb_out(5),
       pb_rec(6), pb_rnd(), pb_user(7), pb_sub(8);
SELECT * FROM pb_set1(9);
SELECT * FROM pb_set1(9);
SELECT * FROM pb_set1(9);
CALL pb_proc(1);
CALL pb_proc(1);
CALL pb_proc(1);
SELECT pj_expect('pb_if(int)', 'declined:statement:IF') \gset
SELECT pj_expect('pb_decl(int)', 'declined:declare') \gset
SELECT pj_expect('pb_exc(int)', 'declined:exception block') \gset
SELECT pj_expect('pb_text(text)', 'declined:datum:text') \gset
SELECT pj_expect('pb_poly(anyelement)', 'declined:signature') \gset
SELECT pj_expect('pb_out(int)', 'declined:signature') \gset
SELECT pj_expect('pb_set1(int)', 'declined:signature') \gset
SELECT pj_expect('pb_rec(int)', 'declined:cast') \gset
SELECT pj_expect('pb_rnd()', 'declined:volatile callee') \gset
SELECT pj_expect('pb_user(int)', 'declined:node') \gset
SELECT pj_expect('pb_sub(int)', 'declined:not simple') \gset
SELECT pj_expect('pb_proc(int)', 'declined:signature') \gset

-- an expression that cannot be planned is not translated, and says so each time
CREATE FUNCTION pb_nofn(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN nosuchfn(n); END $$;
SELECT pb_nofn(1);  -- fail
SELECT pb_nofn(1);  -- fail
SELECT pb_nofn(1);  -- fail
SELECT pj_expect('pb_nofn(int)', 'interpreted:unplanned') \gset
CREATE FUNCTION nosuchfn(n int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN RETURN n * 2; END $$;
SELECT pb_nofn(1);
SELECT pb_nofn(1);
SELECT pb_nofn(1);
SELECT pj_expect('pb_nofn(int)', 'declined:volatile callee') \gset

-- a domain checks its constraints at every cast, and they change under ALTER
-- DOMAIN: not compiled, whatever the plan of the cast looks like
CREATE DOMAIN pb_dx AS int;
CREATE FUNCTION pb_dm1(a int) RETURNS pb_dx LANGUAGE :pj_lang AS $$
BEGIN RETURN a + 1; END $$;
CREATE FUNCTION pb_dm2(a int) RETURNS pb_dx LANGUAGE :pj_lang AS $$
BEGIN RETURN a; END $$;
CREATE FUNCTION pb_dm3(a int) RETURNS pb_dx LANGUAGE :pj_lang AS $$
BEGIN RETURN CASE WHEN a > 0 THEN a END; END $$;
SELECT pb_dm1(1), pb_dm1(2), pb_dm1(3), pb_dm2(1), pb_dm2(2), pb_dm2(3),
       pb_dm3(1), pb_dm3(2), pb_dm3(3);
SELECT pj_expect('pb_dm1(int)', 'declined:cast') \gset
SELECT pj_expect('pb_dm2(int)', 'declined:cast') \gset
SELECT pj_expect('pb_dm3(int)', 'declined:cast') \gset
ALTER DOMAIN pb_dx ADD CONSTRAINT pb_dx_pos CHECK (VALUE > 0);
SELECT pb_dm1(-5);  -- fail
SELECT pb_dm2(-5);  -- fail
SELECT pb_dm3(5);
ALTER DOMAIN pb_dx SET NOT NULL;
SELECT pb_dm3(-5);  -- fail
