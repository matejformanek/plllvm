--
-- pj_planfree: a plan that SPI frees while PL/pgSQL still points at it
--
-- A compiled call fails and is caught: the expression is marked busy in
-- this transaction, so SPI runs it, replans in place and frees the old plan,
-- unless a refcount is held, and a compiled frame holds none.  PL/pgSQL then
-- compares the stale pointer with the address of a new generic plan that
-- may have reused the memory, and runs a freed tree, or gets a wrong value.
-- Whether the addresses collide depends on the size of the tree, so the
-- same function is made in 150 sizes.  Another session's schema change
-- (any one resets the plans of all) delivers the invalidation.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
\set VERBOSITY terse
CREATE EXTENSION dblink;
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset
SELECT dblink_connect('other', :'conn');

\set ECHO none
\o /dev/null
SELECT format('CREATE FUNCTION pf%s(m int) RETURNS int LANGUAGE %s STABLE AS $f$ BEGIN RETURN 10 / m%s; END $f$',
              k, :'pj_lang',
              (SELECT coalesce(string_agg((ARRAY[' + m', ' - m', ' * 1', ' + 7', ' - 3'])[1 + (i * i + k) % 5], ''), '')
                 FROM generate_series(1, k) i)) FROM generate_series(0, 149) k \gexec
\o
\set ECHO all
CREATE FUNCTION pf_try_g() RETURNS void LANGUAGE plpgsql AS $$
BEGIN PERFORM pf_g(0); EXCEPTION WHEN division_by_zero THEN NULL; END $$;
-- a caught failure of the compiled function, from PL/pgSQL
CREATE FUNCTION pf_try(k int) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE format('SELECT pf%s(0)', k);
EXCEPTION WHEN division_by_zero THEN NULL;
END $$;
CREATE TABLE pf_res (k int, round int, v int);

-- per function: warm calls; in one transaction a caught failure, six calls,
-- the other session's DDL, a table access that delivers it, one call; then
-- four transactions that call it again
CREATE TEMP TABLE pf_cmd AS
SELECT k * 100 + s AS ord, c AS cmd FROM generate_series(0, 149) k,
  LATERAL (VALUES
    (1, format('SELECT pf%s(1)', k)), (2, format('SELECT pf%s(1)', k)),
    (3, format('SELECT pf%s(1)', k)), (4, 'BEGIN'),
    (5, format('SELECT pf_try(%s)', k)),
    (6, format('SELECT pf%s(1), pf%s(1), pf%s(1), pf%s(1), pf%s(1), pf%s(1)', k, k, k, k, k, k)),
    (7, $$SELECT dblink_exec('other', 'CREATE SCHEMA pf_other; DROP SCHEMA pf_other')$$),
    (8, 'SELECT count(*) >= 0 FROM pg_class'),
    (9, format('SELECT pf%s(1)', k)), (10, 'COMMIT'),
    (11, format('INSERT INTO pf_res SELECT %s, 1, pf%s(1)', k, k)),
    (12, format('INSERT INTO pf_res SELECT %s, 2, pf%s(1)', k, k)),
    (13, format('INSERT INTO pf_res SELECT %s, 3, pf%s(1)', k, k)),
    (14, format('INSERT INTO pf_res SELECT %s, 4, pf%s(1)', k, k)),
    (15, format('SELECT pj_expect(''pf%s(int)'', ''compiled'')', k))) v(s, c);
\set ECHO none
\o /dev/null
SELECT cmd FROM pf_cmd ORDER BY ord \gexec
\o
\set ECHO all
-- every call, in every later transaction, gives what PL/pgSQL gives: a freed
-- tree is an error, a stale one a wrong value that stays while the code is
-- compiled
SELECT count(*) AS calls, md5(string_agg(v::text, ',' ORDER BY k, round)) AS values FROM pf_res;

-- the same with the plans discarded, not another session's DDL, and always
-- the generic plan
CREATE FUNCTION pf_g(m int) RETURNS int LANGUAGE :pj_lang STABLE AS $f$
BEGIN
  RETURN 10 / m + m + m + m + m + m + m + m + m + m + m + m;
END $f$;
SET plan_cache_mode = force_generic_plan;
SELECT pf_g(1);
SELECT pf_g(1);
SELECT pf_g(1);
BEGIN;
SELECT pf_try_g();
DISCARD PLANS;
SELECT pf_g(1);
COMMIT;
SELECT pf_g(1);
SELECT pf_g(1);
RESET plan_cache_mode;
SELECT pj_expect('pf_g(int)', 'compiled') \gset
