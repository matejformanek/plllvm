--
-- pj_control: IF, loops, labels and FOUND
--
-- Each function is called over all its branches before the call that pj_expect
-- reads, because an expression PL/pgSQL has not planned yet leaves the call
-- to it.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pc_if(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n < 0 THEN RETURN -1;
  ELSIF n = 0 THEN RETURN 0;
  ELSIF n > 100 THEN RETURN 100;
  ELSE RETURN 1;
  END IF;
END $$;
SELECT pc_if(v) FROM unnest(ARRAY[-5, 0, 500, 7]) v;
SELECT pc_if(v) FROM unnest(ARRAY[-5, 0, 500, 7]) v;
SELECT pc_if(v) FROM unnest(ARRAY[-5, 0, 500, 7]) v;
SELECT pj_expect('pc_if(int)', 'compiled') \gset

-- a NULL condition is false; the NULL is a local, an argument runs in PL/pgSQL
CREATE FUNCTION pc_null(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE x int;
BEGIN
  IF x > 0 THEN RETURN 1; END IF;
  IF NOT (x > 0) THEN RETURN 2; END IF;
  RETURN n;
END $$;
SELECT pc_null(1), pc_null(2), pc_null(3), pc_null(NULL) IS NULL;
SELECT pc_null(1), pc_null(2);
SELECT pj_expect('pc_null(int)', 'compiled') \gset

-- LOOP with EXIT WHEN and CONTINUE WHEN
CREATE FUNCTION pc_loop(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0; s int := 0;
BEGIN
  LOOP
    i := i + 1;
    EXIT WHEN i > n;
    CONTINUE WHEN i % 2 = 0;
    s := s + i;
  END LOOP;
  RETURN s;
END $$;
SELECT pc_loop(0), pc_loop(5), pc_loop(10);
SELECT pc_loop(0), pc_loop(5), pc_loop(10);
SELECT pj_expect('pc_loop(int)', 'compiled') \gset

-- FOR over integers: REVERSE, BY, bounds that do not run, FOUND after it
CREATE FUNCTION pc_for(a int, b int, st int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE s bigint := 0;
BEGIN
  FOR i IN a..b BY st LOOP s := s * 10 + i; END LOOP;
  RETURN s * 10 + CASE WHEN found THEN 1 ELSE 0 END;
END $$;
CREATE FUNCTION pc_rev(a int, b int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE s bigint := 0;
BEGIN
  FOR i IN REVERSE a..b LOOP s := s * 10 + i; END LOOP;
  RETURN s * 10 + CASE WHEN found THEN 1 ELSE 0 END;
END $$;
SELECT pc_for(1, 5, 1), pc_for(1, 9, 3), pc_for(5, 1, 1), pc_rev(5, 1), pc_rev(1, 5);
SELECT pc_for(1, 5, 1), pc_for(1, 9, 3), pc_for(5, 1, 1), pc_rev(5, 1), pc_rev(1, 5);
SELECT pc_for(1, 5, 1), pc_for(1, 9, 3), pc_for(5, 1, 1), pc_rev(5, 1), pc_rev(1, 5);
SELECT pj_expect('pc_for(int,int,int)', 'compiled') \gset
SELECT pj_expect('pc_rev(int,int)', 'compiled') \gset

-- the loop ends at the largest and smallest int4 instead of overflowing
CREATE FUNCTION pc_limit() RETURNS int LANGUAGE :pj_lang AS $$
DECLARE n int := 0;
BEGIN
  FOR i IN 2147483646..2147483647 LOOP n := n + 1; END LOOP;
  FOR i IN REVERSE -2147483647..-2147483648 LOOP n := n + 10; END LOOP;
  FOR i IN -2147483648..-2147483647 BY 2147483647 LOOP n := n + 100; END LOOP;
  RETURN n;
END $$;
SELECT pc_limit(), pc_limit(), pc_limit();
SELECT pj_expect('pc_limit()', 'compiled') \gset

-- NULL and non-positive bounds, steps
CREATE FUNCTION pc_bad(lo int, hi int, st int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE n int := 0; x int; y int := 1;
BEGIN
  IF lo = 1 THEN FOR i IN x..y LOOP n := n + 1; END LOOP; END IF;
  IF lo = 2 THEN FOR i IN y..x LOOP n := n + 1; END LOOP; END IF;
  IF lo = 3 THEN FOR i IN y..y BY x LOOP n := n + 1; END LOOP; END IF;
  IF lo = 4 THEN FOR i IN y..y BY 0 LOOP n := n + 1; END LOOP; END IF;
  IF lo = 5 THEN FOR i IN y..y BY -1 LOOP n := n + 1; END LOOP; END IF;
  RETURN n;
END $$;
SELECT pc_bad(0, 0, 0), pc_bad(0, 0, 0);
SELECT pc_bad(1, 0, 0);  -- fail
SELECT pc_bad(2, 0, 0);  -- fail
SELECT pc_bad(3, 0, 0);  -- fail
SELECT pc_bad(4, 0, 0);  -- fail
SELECT pc_bad(5, 0, 0);  -- fail
SELECT pc_bad(1, 0, 0);  -- fail
SELECT pc_bad(2, 0, 0);  -- fail
SELECT pc_bad(3, 0, 0);  -- fail
SELECT pc_bad(4, 0, 0);  -- fail
SELECT pc_bad(5, 0, 0);  -- fail
SELECT pj_expect('pc_bad(int,int,int)', 'compiled') \gset

-- empty bodies
CREATE FUNCTION pc_empty(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0;
BEGIN
  FOR k IN 1..n LOOP END LOOP;
  WHILE i < n LOOP i := i + 1; END LOOP;
  LOOP EXIT; END LOOP;
  WHILE false LOOP END LOOP;
  RETURN i;
END $$;
SELECT pc_empty(3), pc_empty(4), pc_empty(5);
SELECT pj_expect('pc_empty(int)', 'compiled') \gset

-- labels: EXIT and CONTINUE of an outer loop, EXIT of a block, FOUND
CREATE FUNCTION pc_labels(m int) RETURNS bigint LANGUAGE :pj_lang AS $$
DECLARE r bigint := 0;
BEGIN
  <<outer>> FOR i IN 1..3 LOOP
    <<blk>> BEGIN
      FOR j IN 1..3 LOOP
        CONTINUE outer WHEN j = 2 AND m = 1;
        EXIT blk WHEN i = 2;
        EXIT outer WHEN i = 3 AND m = 2;
        r := r * 100 + i * 10 + j;
      END LOOP;
    END;
    r := r * 100 + 90 + i;
  END LOOP;
  RETURN r * 10 + CASE WHEN found THEN 1 ELSE 0 END;
END $$;
SELECT pc_labels(0), pc_labels(1), pc_labels(2);
SELECT pc_labels(0), pc_labels(1), pc_labels(2);
SELECT pj_expect('pc_labels(int)', 'compiled') \gset

CREATE FUNCTION pc_whilec(n int) RETURNS int LANGUAGE :pj_lang AS $$
DECLARE i int := 0; s int := 0; j int;
BEGIN
  <<o>> WHILE i < n LOOP
    i := i + 1;
    j := 0;
    WHILE j < 5 LOOP
      j := j + 1;
      CONTINUE o WHEN j = 2 AND i % 2 = 0;
      EXIT o WHEN i = 7;
      s := s + 1;
    END LOOP;
  END LOOP;
  RETURN s * 100 + i;
END $$;
SELECT pc_whilec(3), pc_whilec(5), pc_whilec(9);
SELECT pc_whilec(3), pc_whilec(5), pc_whilec(9);
SELECT pj_expect('pc_whilec(int)', 'compiled') \gset

-- FOUND is also an ordinary variable
CREATE FUNCTION pc_found(n int) RETURNS bool LANGUAGE :pj_lang AS $$
BEGIN
  FOR i IN 1..n LOOP EXIT; END LOOP;
  IF n > 5 THEN RETURN found; END IF;
  FOR i IN REVERSE 2..1 LOOP NULL; END LOOP;
  RETURN found;
END $$;
SELECT pc_found(0), pc_found(1), pc_found(9);
SELECT pc_found(0), pc_found(1), pc_found(9);
SELECT pj_expect('pc_found(int)', 'compiled') \gset

-- control reaches the end: PL/pgSQL's error and CONTEXT
CREATE FUNCTION pc_end(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  IF n > 0 THEN RETURN 1; END IF;
END $$;
SELECT pc_end(1), pc_end(2);
SELECT pc_end(0);  -- fail
SELECT pc_end(0);  -- fail
SELECT pj_expect('pc_end(int)', 'compiled') \gset

-- what is not compiled: a label of the function, CASE, other statements
CREATE FUNCTION pc_fnlabel() RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  LOOP EXIT pc_fnlabel; END LOOP;
  RETURN 1;
END $$;
CREATE FUNCTION pc_case(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  CASE WHEN n > 0 THEN RETURN 1; ELSE RETURN 2; END CASE;
END $$;
CREATE FUNCTION pc_raise(n int) RETURNS int LANGUAGE :pj_lang AS $$
BEGIN
  RAISE NOTICE 'x';
  RETURN n;
END $$;
SELECT pc_fnlabel();  -- fail
SELECT pc_fnlabel();  -- fail
SELECT pc_case(1), pc_case(0), pc_raise(1);
SELECT pc_case(1), pc_case(0), pc_raise(1);
SELECT pj_expect('pc_fnlabel()', 'declined:label') \gset
SELECT pj_expect('pc_case(int)', 'declined:statement:CASE') \gset
SELECT pj_expect('pc_raise(int)', 'declined:statement:RAISE') \gset
