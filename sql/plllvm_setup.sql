--
-- Install the plllvm extension
--

-- PL/LLVM is untrusted: a non-superuser cannot install it, not even with
-- CREATE on the database (compare plperl_setup).
CREATE USER regress_plllvm_user1;

DO $$
begin
  execute format('grant create on database %I to regress_plllvm_user1',
                 current_database());
end;
$$;

SET ROLE regress_plllvm_user1;

CREATE EXTENSION plllvm;  -- fail

RESET ROLE;

CREATE EXTENSION plllvm;

SET plllvm.regress_test_mode = on;

SELECT extversion, extrelocatable, extnamespace::regnamespace
  FROM pg_extension WHERE extname = 'plllvm';

SELECT lanpltrusted, lanplcallfoid::regprocedure, laninline,
       lanvalidator::regprocedure
  FROM pg_language WHERE lanname = 'plllvm';

-- the extension owns the language and its support functions
SELECT pg_describe_object(classid, objid, objsubid) AS member
  FROM pg_depend
 WHERE refclassid = 'pg_extension'::regclass
   AND refobjid = (SELECT oid FROM pg_extension WHERE extname = 'plllvm')
   AND deptype = 'e'
 ORDER BY 1;

DROP LANGUAGE plllvm;  -- fail

-- the prefix is reserved once the library is loaded
SET plllvm.no_such_setting = on;  -- fail

-- a non-superuser cannot use the language
SET ROLE regress_plllvm_user1;

CREATE SCHEMA plllvm_setup_scratch;
SET search_path = plllvm_setup_scratch;

CREATE FUNCTION plllvm_user_fn() RETURNS int LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 0 } $$;  -- fail

RESET ROLE;
RESET search_path;

-- a superuser can
CREATE FUNCTION plllvm_fn() RETURNS int LANGUAGE plllvm
AS $$ define i64 @f(ptr %fcinfo) { ret i64 7 } $$;

SELECT plllvm_fn();

DROP FUNCTION plllvm_fn();

-- no inline handler
DO LANGUAGE plllvm $$ $$;  -- fail

-- Clean up
DROP OWNED BY regress_plllvm_user1;
DROP USER regress_plllvm_user1;
