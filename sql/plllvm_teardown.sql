--
-- Drop the plllvm extension
--
DROP EXTENSION plllvm;

SELECT count(*) FROM pg_language WHERE lanname = 'plllvm';
