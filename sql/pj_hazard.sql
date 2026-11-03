--
-- pj_hazard: tests that crash the server when their fix regresses
-- (installcheck-hazard, on a throwaway cluster only)
--
-- Things that change under a recursion of compiled calls: the plans, the
-- function itself, the options of the next translation.  Values are those of
-- PL/pgSQL; expected from plllvm because the file needs the language.
--
SET plllvm.regress_test_mode = on;
CREATE EXTENSION dblink;
SELECT format('host=%s port=%s dbname=%s user=%s',
              current_setting('unix_socket_directories'),
              current_setting('port'), current_database(), current_user) AS conn \gset
SELECT dblink_connect('other', :'conn');

CREATE TABLE ph_t (i int);

-- plans flushed, then used by the frames that are still running
CREATE FUNCTION ph_flush_v(f int) RETURNS int LANGUAGE plpgsql AS $$
BEGIN
  IF f > 0 THEN EXECUTE 'DISCARD PLANS'; END IF;
  RETURN 0;
END $$;
-- labelled STABLE, as a callee that changes what the plans depend on
CREATE FUNCTION ph_flush(f int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN RETURN ph_flush_v(f); END $$;
CREATE FUNCTION ph_rec(n int, f int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
DECLARE x int := n * 2;
BEGIN
  IF n = 0 THEN RETURN ph_flush(f); END IF;
  x := x + ph_rec(n - 1, f);
  RETURN x + length(n::text);
END $$;
SELECT ph_rec(5, 0), ph_rec(5, 0), ph_rec(5, 0);
SELECT ph_rec(25, 1);
SELECT ph_rec(25, 0), ph_rec(25, 0), ph_rec(25, 0);
SELECT ph_rec(25, 1), ph_rec(3, 1);
BEGIN;
SELECT ph_rec(20, 1), ph_rec(20, 1), ph_rec(20, 0);
DISCARD PLANS;
SELECT ph_rec(20, 0), ph_rec(20, 0), ph_rec(20, 0);
COMMIT;

-- the function replaced by another session under a recursion, at a lock point
CREATE FUNCTION ph_swap(f int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF f > 0 THEN
    PERFORM dblink_exec('other', 'CREATE OR REPLACE FUNCTION ph_rep(n int, f int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $f$
      BEGIN IF n = 0 THEN RETURN ph_swap(f); END IF; RETURN ph_rep(n - 1, f) + length(n::text) + 1000; END $f$');
    PERFORM count(*) FROM ph_t;
  END IF;
  RETURN 0;
END $$;
CREATE FUNCTION ph_rep(n int, f int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN ph_swap(f); END IF;
  RETURN ph_rep(n - 1, f) + length(n::text);
END $$;
SELECT ph_rep(8, 0), ph_rep(8, 0), ph_rep(8, 0);
SELECT ph_rep(8, 1);
SELECT ph_rep(8, 0), ph_rep(8, 0), ph_rep(8, 0);
SELECT ph_rep(8, 1);

-- the options of translation changed under a recursion: the inner calls run
-- in PL/pgSQL, the next top-level call builds the variant
CREATE FUNCTION ph_opt(f int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF f > 0 THEN PERFORM set_config('plllvm.pj_opt_level', f::text, true); END IF;
  RETURN 0;
END $$;
CREATE FUNCTION ph_lvl(n int, f int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN ph_opt(f); END IF;
  RETURN ph_lvl(n - 1, f) + length(n::text);
END $$;
SELECT ph_lvl(10, 0), ph_lvl(10, 0), ph_lvl(10, 0);
BEGIN;
SELECT ph_lvl(10, 1);
SELECT ph_lvl(10, 0), ph_lvl(10, 0);
COMMIT;
SELECT ph_lvl(10, 0), ph_lvl(10, 0);
SELECT variants, failures FROM plllvm_pj_status('ph_lvl(int,int)'), plllvm_pj_stats();

-- expression JIT compiling in the calls that run in PL/pgSQL during a
-- recursion
SET plllvm.expr_jit = on;
SET plllvm.expr_eager = on;
SELECT ph_lvl(10, 0), ph_lvl(10, 0);
SELECT ph_rec(25, 1);
SELECT ph_lvl(10, 1);
RESET plllvm.expr_eager;
RESET plllvm.expr_jit;
RESET plllvm.pj_opt_level;
SELECT ph_lvl(10, 0), ph_lvl(10, 0), ph_lvl(10, 0);

SELECT dblink_disconnect('other');
