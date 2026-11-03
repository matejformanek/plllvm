--
-- pj_memory: calls leave nothing behind
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pm_inc(n int) RETURNS int LANGUAGE :pj_lang IMMUTABLE AS $$
DECLARE x int := n;
BEGIN
  FOR i IN 1..3 LOOP x := x + i; END LOOP;
  RETURN x;
END $$;
SELECT pm_inc(1), pm_inc(2);
SELECT pj_expect('pm_inc(int)', 'compiled') \gset

-- the memory of all contexts, before and after 100,000 calls in one query
CREATE FUNCTION pm_total() RETURNS bigint LANGUAGE sql AS
  $$ SELECT sum(total_bytes) FROM pg_backend_memory_contexts $$;
SELECT sum(pm_inc(i)) FROM generate_series(1, 100000) i \g /dev/null
SELECT pm_total() AS before \gset
SELECT sum(pm_inc(i)) FROM generate_series(1, 100000) i \g /dev/null
SELECT pm_total() - :before < 1048576 AS flat;
SELECT pj_expect('pm_inc(int)', 'compiled') \gset

-- and under caught errors
CREATE FUNCTION pm_err(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN RETURN 10 / n; END $$;
CREATE FUNCTION pm_catch(k int) RETURNS int LANGUAGE plpgsql AS $$
DECLARE c int := 0;
BEGIN
  FOR i IN 1..k LOOP
    BEGIN PERFORM pm_err(0); EXCEPTION WHEN division_by_zero THEN c := c + 1; END;
  END LOOP;
  RETURN c;
END $$;
SELECT pm_err(1), pm_err(2);
SELECT pm_catch(10);
SELECT pm_total() AS before \gset
SELECT pm_catch(5000);
SELECT pm_total() - :before < 1048576 AS flat;
