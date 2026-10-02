--
-- kernel_rowudf: examples/kernels/line_net.ll against the PL/pgSQL original
-- (bench/kernels/43_rowudf.sql, line_net_imm) on its table udf_rows
-- (40_glue_schema.sql)
--
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/examples/kernels/line_net.ll`

CREATE TABLE udf_rows (
  id integer, qty integer, price numeric(8,2), disc numeric(4,4), tax numeric(4,4), region integer);
INSERT INTO udf_rows
SELECT g, 1 + (g::bigint * 37) % 60, 1.00 + ((g::bigint * 7907) % 99901) / 100.0,
       ((g::bigint * 13) % 11) / 100.0, ((g::bigint * 17) % 9) / 100.0, g % 5
FROM generate_series(1, 1200000) g;

CREATE FUNCTION line_net_ll(qty integer, price numeric, disc numeric,
                            tax numeric, region integer) RETURNS numeric
LANGUAGE plllvm IMMUTABLE AS :'ir';

CREATE FUNCTION line_net_pl(qty integer, price numeric, disc numeric,
                            tax numeric, region integer) RETURNS numeric
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
  gross numeric;
  net numeric;
BEGIN
  gross := qty * price;
  IF qty >= 50 THEN
    gross := gross * 0.95;
  ELSIF qty >= 20 THEN
    gross := gross * 0.98;
  END IF;
  net := round(gross * (1 - disc) * (1 + tax), 2);
  IF region = 3 THEN
    net := net + 1.50;
  END IF;
  RETURN net;
END
$$;

-- each branch, and NULL in each argument
SELECT a.*, line_net_ll(qty, price, disc, tax, region) AS ll,
       line_net_ll(qty, price, disc, tax, region)
         IS NOT DISTINCT FROM line_net_pl(qty, price, disc, tax, region) AS ok
FROM (SELECT * FROM (VALUES (10, 12.34, 0.05, 0.08, 1),
                            (20, 12.34, 0.05, 0.08, 3),
                            (50, 12.34, 0.05, 0.08, 2),
                            (60, 999.99, 0.10, 0.00, 3),
                            (NULL, 12.34, 0.05, 0.08, 3),
                            (10, NULL, 0.05, 0.08, 1),
                            (10, 12.34, NULL, 0.08, 1),
                            (10, 12.34, 0.05, NULL, 1),
                            (10, 12.34, 0.05, 0.08, NULL))
                     v(qty, price, disc, tax, region)
      OFFSET 0) a
ORDER BY 1, 2, 3, 4, 5;

SELECT count(*) FILTER (WHERE line_net_ll(qty, price, disc, tax, region)
                              = line_net_pl(qty, price, disc, tax, region)) AS ok
FROM udf_rows WHERE id <= 20000;

-- the query of EXP-001
SELECT sum(line_net_ll(qty, price, disc, tax, region)) FROM udf_rows;

SELECT frame FROM plllvm_code_cache()
 WHERE owner_oid = 'line_net_ll(integer,numeric,numeric,numeric,integer)'::regprocedure;

DROP FUNCTION line_net_ll(integer, numeric, numeric, numeric, integer);
DROP FUNCTION line_net_pl(integer, numeric, numeric, numeric, integer);
DROP TABLE udf_rows;
