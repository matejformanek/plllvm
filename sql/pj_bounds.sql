--
-- pj_bounds: names, sizes and nesting at the limits; a function compiles or
-- is declined, and the results are PL/pgSQL's either way
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

-- the DDL is run by a function, so that the language is not echoed
CREATE FUNCTION pbd_ddl(sql text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN EXECUTE sql; END $$;

-- names of 63 bytes, quoted labels and variables
SELECT pbd_ddl(format($f$CREATE FUNCTION %s(%s int) RETURNS int LANGUAGE %s AS $b$
DECLARE %s int := 1;
BEGIN
  <<%s>> LOOP
    %s := %s + %s;
    EXIT %s;
  END LOOP;
  <<"A ""quoted"" label">> FOR "i j" IN 1..3 LOOP
    CONTINUE "A ""quoted"" label" WHEN "i j" = 2;
    %s := %s + "i j";
  END LOOP;
  RETURN %s;
END $b$$f$, repeat('f', 63), repeat('a', 63), :'pj_lang', repeat('b', 63),
       repeat('l', 63), repeat('b', 63), repeat('b', 63), repeat('a', 63),
       repeat('l', 63), repeat('b', 63), repeat('b', 63), repeat('b', 63)));
SELECT length(proname) FROM pg_proc WHERE proname = repeat('f', 63);
SELECT format('SELECT %s(%s)', repeat('f', 63), g) FROM generate_series(1, 3) g \gexec
SELECT pj_expect(format('%s(int)', repeat('f', 63))::regprocedure, 'compiled') \gset

-- 100 arguments
SELECT pbd_ddl(format('CREATE FUNCTION pbd_args(%s) RETURNS int LANGUAGE %s AS $b$ BEGIN RETURN a1 + a100; END $b$',
              (SELECT string_agg('a' || g || ' int', ', ') FROM generate_series(1, 100) g), :'pj_lang'));
SELECT format('SELECT pbd_args(%s)', (SELECT string_agg(g::text, ', ') FROM generate_series(1, 100) g)) \gexec
SELECT format('SELECT pbd_args(%s)', (SELECT string_agg(g::text, ', ') FROM generate_series(1, 100) g)) \gexec
SELECT pj_expect('pbd_args(int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int,int)', 'compiled') \gset

-- 1,000 locals
SELECT pbd_ddl(format('CREATE FUNCTION pbd_locals(n int) RETURNS int LANGUAGE %s AS $b$ DECLARE %s BEGIN v1000 := n; RETURN v1 + v1000; END $b$',
              :'pj_lang', (SELECT string_agg('v' || g || ' int := ' || g || ';', ' ') FROM generate_series(1, 1000) g)));
SELECT pbd_locals(5), pbd_locals(6), pbd_locals(7);
SELECT pj_expect('pbd_locals(int)', 'compiled') \gset

-- a tree of more than 64 nodes: compiled or declined, never an error
SELECT pbd_ddl(format('CREATE FUNCTION pbd_tree(n int) RETURNS int LANGUAGE %s AS $b$ BEGIN RETURN %s; END $b$',
              :'pj_lang', (SELECT string_agg('n', ' + ') FROM generate_series(1, 100))));
SELECT pbd_tree(1), pbd_tree(2), pbd_tree(3);
SELECT pj_expect('pbd_tree(int)', 'compiled') \gset

-- 5,000 statements
SELECT pbd_ddl(format('CREATE FUNCTION pbd_stmts(n int) RETURNS int LANGUAGE %s AS $b$ DECLARE x int := 0; BEGIN %s RETURN x; END $b$',
              :'pj_lang', (SELECT string_agg('x := x + n;', ' ') FROM generate_series(1, 5000))));
SELECT pbd_stmts(1), pbd_stmts(2), pbd_stmts(3);
SELECT pj_expect('pbd_stmts(int)', 'compiled') \gset

-- 200 nested blocks and loops
SELECT pbd_ddl(format('CREATE FUNCTION pbd_nest(n int) RETURNS int LANGUAGE %s AS $b$ DECLARE x int := 0; BEGIN %s x := x + n; %s RETURN x; END $b$',
              :'pj_lang', (SELECT string_agg('LOOP BEGIN', ' ') FROM generate_series(1, 100)),
              (SELECT string_agg('EXIT; END; END LOOP;', ' ') FROM generate_series(1, 100))));
SELECT pbd_nest(1), pbd_nest(2), pbd_nest(3);
SELECT pj_expect('pbd_nest(int)', 'compiled') \gset
