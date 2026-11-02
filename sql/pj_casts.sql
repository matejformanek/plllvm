--
-- pj_casts: a cast created or dropped between calls
--
-- PL/pgSQL keeps the cast it first built in the session, so the new one is
-- seen later than a flush would show it; not run under debug_discard_caches.
-- The function is declined, as the cast it first had is an I/O conversion.
--
\getenv pj_lang PJ_LANG
\if :{?pj_lang}
\else
  \set pj_lang plpgsql
\endif

CREATE FUNCTION pjg_bf(b bool) RETURNS float8 LANGUAGE :pj_lang AS $$
BEGIN RETURN b; END $$;
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
SELECT pj_expect('pjg_bf(bool)', 'declined:cast') \gset
CREATE FUNCTION pjg_castf(bool) RETURNS float8 LANGUAGE sql AS 'SELECT 42.5::float8';
CREATE CAST (bool AS float8) WITH FUNCTION pjg_castf(bool) AS ASSIGNMENT;
SELECT pjg_bf(true), pjg_bf(false);
SELECT pjg_bf(true), pjg_bf(false);
DROP CAST (bool AS float8);
SELECT pjg_bf(true);  -- fail
SELECT pjg_bf(true);  -- fail
DROP FUNCTION pjg_castf(bool);

-- a cast made between calls, which PL/pgSQL keeps out of its cache: an
-- I/O conversion first (stock: $5.00), the cast made later is not used
CREATE FUNCTION hb2(x float8) RETURNS money LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
SELECT hb2(5) AS first_io;
CREATE CAST (float8 AS money) WITHOUT FUNCTION AS ASSIGNMENT;
SELECT hb2(5) AS second;
SELECT hb2(5) AS third;
SELECT pj_expect('hb2(float8)', 'declined:cast') \gset
DROP CAST (float8 AS money);
SELECT hb2(5) AS after_drop;

CREATE FUNCTION hb1(x bool) RETURNS "char" LANGUAGE :pj_lang AS $$
BEGIN RETURN x; END $$;
SELECT hb1(true) AS hb1_io;
CREATE CAST (bool AS "char") WITHOUT FUNCTION AS ASSIGNMENT;
SELECT hb1(true)::int AS hb1_2;
SELECT hb1(true)::int AS hb1_3;
SELECT pj_expect('hb1(bool)', 'declined:cast') \gset
DROP CAST (bool AS "char");
