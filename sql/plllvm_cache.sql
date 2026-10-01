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

-- a call site is rebuilt only after an invalidation of its callee, and
-- checked again by another user and after any change of roles; under
-- debug_discard_caches every call rebuilds (plllvm_cache_1.out)
CREATE ROLE regress_plllvm_cuser;
CREATE ROLE regress_plllvm_cgrp;
GRANT regress_plllvm_cgrp TO regress_plllvm_cuser;
CREATE FUNCTION c_callee(x int) RETURNS int LANGUAGE sql AS 'SELECT x';
CREATE FUNCTION c_other() RETURNS int LANGUAGE sql AS 'SELECT 1';
CREATE FUNCTION c_site(x int) RETURNS int LANGUAGE plllvm STRICT AS $$
@"c_callee(integer)" = external global i8
declare i64 @plllvm_call1(ptr, i64, i1, ptr)
declare i64 @plllvm_arg_i64(ptr, i32)
define i64 @f(ptr %fcinfo) {
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %r = call i64 @plllvm_call1(ptr @"c_callee(integer)", i64 %x, i1 false, ptr null)
  ret i64 %r
}
$$;

SELECT sum(c_site(i)) FROM generate_series(1, 100) i;
SELECT prepares = 1 AS one_prepare FROM plllvm_call_sites()
WHERE owner = 'c_site(int)'::regprocedure;
ALTER FUNCTION c_other() COST 5;
SELECT c_site(1);
SELECT prepares = 1 AS one_prepare FROM plllvm_call_sites()
WHERE owner = 'c_site(int)'::regprocedure;
ALTER FUNCTION c_callee(int) COST 5;
SELECT c_site(1);
SELECT prepares = 2 AS two_prepares FROM plllvm_call_sites()
WHERE owner = 'c_site(int)'::regprocedure;
SELECT checks AS checks0 FROM plllvm_call_sites()
WHERE owner = 'c_site(int)'::regprocedure \gset

SET ROLE regress_plllvm_cuser;
SELECT c_site(1);
RESET ROLE;
SELECT checks = :checks0 + 1 AS checked, prepares = 2 AS no_rebuild
FROM plllvm_call_sites() WHERE owner = 'c_site(int)'::regprocedure;
SELECT c_site(1);
REVOKE regress_plllvm_cgrp FROM regress_plllvm_cuser;
SELECT c_site(1);
SELECT checks = :checks0 + 3 AS checked, prepares = 2 AS no_rebuild
FROM plllvm_call_sites() WHERE owner = 'c_site(int)'::regprocedure;

DROP FUNCTION c_site(int), c_callee(int), c_other();
DROP ROLE regress_plllvm_cuser, regress_plllvm_cgrp;

DROP FUNCTION c_sql(), c_one(), c_text(text);
