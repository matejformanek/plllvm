--
-- kernel_text: examples/kernels/wordscan.ll against phase 2 of
-- bench/kernels/31_tokenize.sql over its phase 1 lines joined by ' '
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/wordscan.ll`

CREATE FUNCTION wordscan_ll(doc text) RETURNS text
LANGUAGE plllvm IMMUTABLE STRICT AS :'ir';

-- tokenize phase 1
CREATE FUNCTION wordscan_doc(nlines integer) RETURNS text
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  syl CONSTANT text[] := ARRAY['ka','lo','ren','ti','sa','mu','be','xor','qui','on','al','de','the','and','of'];
  punct CONSTANT text[] := ARRAY[',', '.', ';', '(', ')', '!', '-'];
  seed bigint := 12345;
  lines text[] := '{}';
  line text; w text;
  i integer; j integer; k integer; nsyl integer; ntok integer;
BEGIN
  FOR i IN 1..nlines LOOP
    line := '';
    seed := (seed * 1103515245 + 12345) % 2147483648;
    ntok := 8 + (seed % 9)::integer;
    FOR j IN 1..ntok LOOP
      seed := (seed * 1103515245 + 12345) % 2147483648;
      IF seed % 10 < 7 THEN
        w := '';
        nsyl := 1 + ((seed / 16) % 4)::integer;
        FOR k IN 1..nsyl LOOP
          seed := (seed * 1103515245 + 12345) % 2147483648;
          w := w || syl[1 + ((seed / 64) % 15)::integer];
        END LOOP;
        IF (seed / 1024) % 5 = 0 THEN
          w := upper(substr(w, 1, 1)) || substr(w, 2);
        END IF;
      ELSIF seed % 10 < 9 THEN
        w := ((seed / 8) % 100000)::text;
      ELSE
        w := punct[1 + ((seed / 8) % 7)::integer];
      END IF;
      IF j > 1 THEN
        line := line || ' ';
      END IF;
      line := line || w;
    END LOOP;
    lines := lines || line;
  END LOOP;
  RETURN array_to_string(lines, ' ');
END
$$;

-- tokenize phase 2, over one line
CREATE FUNCTION wordscan_pl(doc text) RETURNS text
LANGUAGE plpgsql IMMUTABLE STRICT AS $$
DECLARE
  letters CONSTANT text := 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
  stop CONSTANT text := ' the and of on al de ';
  line text; tok text; c text;
  len integer; pos integer;
  num bigint; innum boolean;
  nwords integer := 0; ncap integer := 0; nstop integer := 0; nnum integer := 0; npunct integer := 0;
  numsum bigint := 0; longest integer := 0;
  h bigint := 7;
BEGIN
  line := doc || ' ';
  len := length(line);
  tok := '';
  innum := false;
  num := 0;
  pos := 1;
  WHILE pos <= len LOOP
    c := substr(line, pos, 1);
    IF position(c IN letters) > 0 THEN
      tok := tok || c;
    ELSIF c >= '0' AND c <= '9' THEN
      innum := true;
      num := num * 10 + (ascii(c) - 48);
    ELSE
      -- flush pending word
      IF tok <> '' THEN
        nwords := nwords + 1;
        IF upper(substr(tok, 1, 1)) = substr(tok, 1, 1) THEN
          ncap := ncap + 1;
        END IF;
        tok := lower(tok);
        IF position(' ' || tok || ' ' IN stop) > 0 THEN
          nstop := nstop + 1;
        END IF;
        IF length(tok) > longest THEN
          longest := length(tok);
        END IF;
        h := (h * 131 + length(tok) * 17 + ascii(tok)) % 1000000007;
        tok := '';
      END IF;
      -- flush pending number
      IF innum THEN
        nnum := nnum + 1;
        numsum := numsum + num;
        h := (h * 131 + num % 1000) % 1000000007;
        num := 0;
        innum := false;
      END IF;
      IF c <> ' ' THEN
        npunct := npunct + 1;
        h := (h * 131 + ascii(c)) % 1000000007;
      END IF;
    END IF;
    pos := pos + 1;
  END LOOP;
  RETURN nwords || '/' || ncap || '/' || nstop || '/' || nnum || '/' || numsum || '/'
         || npunct || '/' || longest || '/' || h;
END
$$;

CREATE FUNCTION sqlstate_of(q text) RETURNS text
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE q;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE;
END
$$;

SELECT s.n, wordscan_ll(s.d) AS ll, wordscan_ll(s.d) = wordscan_pl(s.d) AS ok
FROM (SELECT n, wordscan_doc(n) AS d FROM unnest('{0,1,2,7,50,400}'::int[]) n
      OFFSET 0) s
ORDER BY s.n;

SELECT s.d, wordscan_ll(s.d) AS ll, wordscan_ll(s.d) = wordscan_pl(s.d) AS ok
FROM (SELECT d FROM (VALUES (''), (' '), ('The the of'), ('123 45')) v(d)
      OFFSET 0) s;

SELECT wordscan_ll(NULL) IS NULL AS strict;

-- num * 10 overflows bigint (22003); wordscan_ll is ASCII only (0A000)
SELECT s.d,
       sqlstate_of(format('SELECT wordscan_ll(d) FROM (SELECT %L::text AS d OFFSET 0) s', s.d)) AS ll,
       sqlstate_of(format('SELECT wordscan_pl(d) FROM (SELECT %L::text AS d OFFSET 0) s', s.d)) AS pl
FROM (VALUES ('9999999999999999999'), ('naïve')) s(d);

-- the size of EXP-001: tokenize(19000)
SELECT wordscan_ll(wordscan_doc(19000));

SELECT state FROM plllvm_function_status('wordscan_ll(text)');

DROP FUNCTION sqlstate_of(text);
DROP FUNCTION wordscan_ll(text);
DROP FUNCTION wordscan_pl(text);
DROP FUNCTION wordscan_doc(integer);
