--
-- pj_sessions: another session changes what this session has compiled
--
-- Between two calls the other session replaces or drops the function,
-- changes its attributes or the privileges on what it calls.  The next call
-- here must show it, as PL/pgSQL does.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif
SET pj.lang = :'pj_lang';
CREATE EXTENSION dblink;

-- a connection made by the server does not see pg_regress's PGHOST/PGPORT
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset
SELECT dblink_connect('other', :'conn');

CREATE FUNCTION pjs_f(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN n + 1; END $$;
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- replaced there
SELECT dblink_exec('other', $$CREATE OR REPLACE FUNCTION pjs_f(n int) RETURNS int
  LANGUAGE $$ || current_setting('pj.lang') || $$ AS 'BEGIN RETURN n + 10; END'$$);
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- attributes changed there
SELECT dblink_exec('other', 'ALTER FUNCTION pjs_f(int) SET search_path = pg_catalog');
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
SELECT dblink_exec('other', 'ALTER FUNCTION pjs_f(int) COST 12');
SELECT pjs_f(4), pjs_f(5), pjs_f(6);
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- a privilege revoked there: the next transaction here checks it
CREATE ROLE regress_pj_sess;
SELECT dblink_exec('other', 'REVOKE EXECUTE ON FUNCTION int4pl(int4, int4) FROM PUBLIC');
SET ROLE regress_pj_sess;
SELECT pjs_f(7);  -- fail
SELECT pjs_f(8);  -- fail
RESET ROLE;
SELECT dblink_exec('other', 'GRANT EXECUTE ON FUNCTION int4pl(int4, int4) TO PUBLIC');
SET ROLE regress_pj_sess;
SELECT pjs_f(9), pjs_f(10);
RESET ROLE;
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- dropped there, and created again
SELECT dblink_exec('other', 'DROP FUNCTION pjs_f(int)');
SELECT pjs_f(1);  -- fail
SELECT dblink_exec('other', $$CREATE FUNCTION pjs_f(n int) RETURNS int
  LANGUAGE $$ || current_setting('pj.lang') || $$ AS 'BEGIN RETURN n + 100; END'$$);
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- a call open here while the function changes there: the running call is
-- not affected, the next one is
SELECT dblink_exec('other', 'BEGIN');
SELECT dblink_exec('other', $$CREATE OR REPLACE FUNCTION pjs_f(n int) RETURNS int
  LANGUAGE $$ || current_setting('pj.lang') || $$ AS 'BEGIN RETURN n + 1000; END'$$);
SELECT pjs_f(1), pjs_f(2);
SELECT dblink_exec('other', 'COMMIT');
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
SELECT pj_expect('pjs_f(int)', 'compiled') \gset

-- an inlined callee replaced or altered there
CREATE FUNCTION pjs_g(n int) RETURNS int LANGUAGE sql AS 'SELECT $1 + 1';
CREATE FUNCTION pjs_h(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN pjs_g(n); END $$;
SELECT pjs_h(1), pjs_h(2), pjs_h(3);
SELECT pj_expect('pjs_h(int)', 'compiled') \gset
SELECT dblink_exec('other', 'CREATE OR REPLACE FUNCTION pjs_g(n int) RETURNS int LANGUAGE sql AS ''SELECT $1 + 20''');
SELECT pjs_h(1), pjs_h(2), pjs_h(3);
SELECT dblink_exec('other', 'ALTER FUNCTION pjs_g(int) COST 9');
SELECT pjs_h(1), pjs_h(2), pjs_h(3);
SELECT dblink_exec('other', 'DROP FUNCTION pjs_g(int)');
SELECT pjs_h(1);  -- fail
SELECT dblink_exec('other', 'CREATE FUNCTION pjs_g(n int) RETURNS int LANGUAGE sql AS ''SELECT $1 + 30''');
SELECT pjs_h(1), pjs_h(2), pjs_h(3);
-- PL/pgSQL gave up the simple path when it failed to replan: so do we
SELECT pj_expect('pjs_h(int)', 'declined:not simple') \gset

-- a transaction open here, the function warmed before it began, and the
-- other session committing in the middle of it
SELECT pjs_f(1), pjs_f(2), pjs_f(3);
BEGIN;
SELECT pjs_f(1);
SELECT dblink_exec('other', $$CREATE OR REPLACE FUNCTION pjs_f(n int) RETURNS int
  LANGUAGE $$ || current_setting('pj.lang') || $$ AS 'BEGIN RETURN n + 2000; END'$$);
SELECT pjs_f(2);
SELECT pjs_f(3);
COMMIT;
SELECT pjs_f(4);

SELECT dblink_disconnect('other');
DROP ROLE regress_pj_sess;
