--
-- pj_ctxraw: the CONTEXT of an error in a recursion, as it is
--
-- Expected from plllvm, once.  PL/pgSQL evaluates a recursive call through
-- SPI, which adds a "PL/pgSQL expression" line per level; compiled code does
-- not.  Everything else is the same (pj_abort compares the frames).
--
CREATE FUNCTION pcr_f(n int, d int) RETURNS int LANGUAGE plpgsql_jit STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN 1 / d; END IF;
  RETURN pcr_f(n - 1, d) + 1;
END $$;
CREATE FUNCTION pcr_g(n int, d int) RETURNS int LANGUAGE plpgsql STABLE AS $$
BEGIN
  IF n = 0 THEN RETURN 1 / d; END IF;
  RETURN pcr_g(n - 1, d) + 1;
END $$;
SELECT pcr_f(3, 1), pcr_g(3, 1);
SELECT pcr_f(3, 1), pcr_g(3, 1);
SELECT pj_expect('pcr_f(int,int)', 'compiled') \gset
-- PL/pgSQL
SELECT pcr_g(3, 0);  -- fail
-- plpgsql_jit
SELECT pcr_f(3, 0);  -- fail
SELECT pj_expect('pcr_f(int,int)', 'compiled') \gset
