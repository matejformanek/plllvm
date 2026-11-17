--
-- pj_sql_fdw: a foreign table written by a plpgsql_jit function
--
-- The wrapper's code runs inside the statement, and compiled code cannot see
-- what it does: such a statement is PL/pgSQL's.  The foreign server is this
-- database, through postgres_fdw.  Rows that name a path (pj_expect) are
-- silent on stock.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE EXTENSION postgres_fdw;
CREATE TABLE psf_remote (a int, b text);
DO $$
BEGIN
  EXECUTE format('CREATE SERVER psf_srv FOREIGN DATA WRAPPER postgres_fdw OPTIONS (host %L, port %L, dbname %L)',
                 split_part(current_setting('unix_socket_directories'), ',', 1),
                 current_setting('port'), current_database());
END $$;
CREATE USER MAPPING FOR CURRENT_USER SERVER psf_srv;
CREATE FOREIGN TABLE psf_f (a int, b text) SERVER psf_srv OPTIONS (table_name 'psf_remote');

CREATE FUNCTION psf_ins(n int) RETURNS text LANGUAGE :pj_lang AS $$
DECLARE r text;
BEGIN
  INSERT INTO psf_f VALUES (n, 'x');
  r := found::text;
  UPDATE psf_f SET b = 'y' WHERE a = n;
  RETURN r || found::text;
END $$;
SELECT psf_ins(1);
SELECT * FROM psf_remote ORDER BY a;
SELECT psf_ins(2);
SELECT * FROM psf_remote ORDER BY a;
SELECT psf_ins(3);
SELECT * FROM psf_remote ORDER BY a;
SELECT psf_ins(4);
SELECT * FROM psf_remote ORDER BY a;

DROP FOREIGN TABLE psf_f;
DROP USER MAPPING FOR CURRENT_USER SERVER psf_srv;
DROP SERVER psf_srv;
DROP EXTENSION postgres_fdw;
