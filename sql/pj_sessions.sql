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

-- another session's REVOKE, delivered by a lock in the open transaction,
-- the cast of the function not reached before
CREATE ROLE regress_pj_rm;
CREATE ROLE regress_pj_rg;
CREATE TABLE pjs_lk(a int);
GRANT SELECT ON pjs_lk TO regress_pj_rm;
CREATE FUNCTION pjs_xe(n int) RETURNS bigint LANGUAGE :pj_lang AS $$
BEGIN RETURN CASE WHEN n > 0 THEN n END; END $$;
SELECT pjs_xe(1), pjs_xe(2), pjs_xe(3);
BEGIN;
SET ROLE regress_pj_rm;
SELECT pjs_xe(-1) IS NULL;
RESET ROLE;
SELECT dblink_exec('other', 'REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC');
LOCK TABLE pjs_lk IN ACCESS SHARE MODE;
SET ROLE regress_pj_rm;
SELECT pjs_xe(1);  -- fail
ROLLBACK;
SELECT dblink_exec('other', 'GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC');

-- the same through a group, in a new session whose caches are empty: the
-- REVOKE is delivered while the check reads the membership, after the check
-- has begun, and the key must not take that epoch
REVOKE EXECUTE ON FUNCTION int8(int4) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION int8(int4) TO regress_pj_rg;
GRANT regress_pj_rg TO regress_pj_rm;
\c
SELECT dblink_connect('other', :'conn');
SELECT pjs_xe(1), pjs_xe(2), pjs_xe(3);
BEGIN;
SET ROLE regress_pj_rm;
SELECT dblink_exec('other', 'REVOKE EXECUTE ON FUNCTION int8(int4) FROM regress_pj_rg');
SELECT pjs_xe(-1) IS NULL;
LOCK TABLE pjs_lk IN ACCESS SHARE MODE;
SELECT pjs_xe(1);  -- fail
ROLLBACK;
RESET ROLE;
SELECT dblink_exec('other', 'GRANT EXECUTE ON FUNCTION int8(int4) TO PUBLIC');
DROP OWNED BY regress_pj_rm, regress_pj_rg;
DROP ROLE regress_pj_rm, regress_pj_rg;

-- an IF whose other branch needs a right the other session takes away
CREATE ROLE regress_pj_ifr;
CREATE FUNCTION pjs_if(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN RETURN n + 1; ELSE RETURN n * 2; END IF;
END $$;
SELECT pjs_if(1), pjs_if(2), pjs_if(-1), pjs_if(-2), pjs_if(3), pjs_if(-3);
SELECT dblink_exec('other', 'REVOKE EXECUTE ON FUNCTION int4mul(int4, int4) FROM PUBLIC');
BEGIN;
SET ROLE regress_pj_ifr;
SELECT pjs_if(1);
SAVEPOINT s;
SELECT pjs_if(-1);  -- fail
ROLLBACK TO s;
ROLLBACK;
BEGIN;
SET ROLE regress_pj_ifr;
SELECT pjs_if(-1);  -- fail
ROLLBACK;
SELECT dblink_exec('other', 'GRANT EXECUTE ON FUNCTION int4mul(int4, int4) TO PUBLIC');
SELECT pjs_if(1), pjs_if(-1);
DROP ROLE regress_pj_ifr;

-- a constraint added to a domain there, to a tree that casts to it
CREATE DOMAIN pjs_dx AS int;
CREATE FUNCTION pjs_dom(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN (n + length(n::text))::pjs_dx + 0; END $$;
SELECT pjs_dom(1), pjs_dom(2), pjs_dom(3);
SELECT pj_expect('pjs_dom(int)', 'compiled') \gset
SELECT dblink_exec('other', 'ALTER DOMAIN pjs_dx ADD CONSTRAINT pjs_dx_big CHECK (VALUE > 100)');
SELECT pjs_dom(4);  -- fail
SELECT pjs_dom(200);
SELECT dblink_exec('other', 'ALTER DOMAIN pjs_dx DROP CONSTRAINT pjs_dx_big');
SELECT pjs_dom(4), pjs_dom(5), pjs_dom(6);
SELECT pj_expect('pjs_dom(int)', 'compiled') \gset

SELECT dblink_disconnect('other');
DROP ROLE regress_pj_sess;
