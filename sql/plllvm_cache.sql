--
-- The core function cache: one compile per definition and call signature
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE FUNCTION c_one() RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 1 } $$;

-- many call sites, each with its own FmgrInfo
SELECT c_one();
SELECT c_one() + c_one();

PREPARE c_p AS SELECT c_one();
EXECUTE c_p;
EXECUTE c_p;
EXECUTE c_p;

DO $$
DECLARE
  s int8 := 0;
BEGIN
  FOR i IN 1..100 LOOP
    s := s + c_one();
  END LOOP;
  RAISE NOTICE 'sum %', s;
END
$$;

CREATE FUNCTION c_sql() RETURNS int8 LANGUAGE sql AS 'SELECT c_one() + 1';
SELECT c_sql();

SELECT * FROM plllvm_function_status('c_one()');

DISCARD ALL;
SET plllvm.regress_test_mode = on;
SELECT c_one();
SELECT * FROM plllvm_function_status('c_one()');

-- the input collation is part of the key
CREATE FUNCTION c_text(t text) RETURNS int8 LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;
SELECT c_text('a' COLLATE "C"), c_text('a' COLLATE "POSIX");
SELECT * FROM plllvm_function_status('c_text(text)');

-- any change of the pg_proc row makes the entry stale
ALTER FUNCTION c_one() COST 5;
SELECT * FROM plllvm_function_status('c_one()');
SELECT c_one();
SELECT * FROM plllvm_function_status('c_one()');

DROP FUNCTION c_sql(), c_one(), c_text(text);
