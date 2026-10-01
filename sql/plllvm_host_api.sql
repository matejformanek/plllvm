--
-- docs/host-api.ll is a valid body
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

\getenv abs_srcdir PG_ABS_SRCDIR
\set ir `cat :'abs_srcdir'/docs/host-api.ll`

SELECT ok, sqlstate, message FROM plllvm_jit_test(:'ir', 0, false);
SELECT ok, sqlstate, message, cfi_left FROM plllvm_jit_test(:'ir', 0, true);
SELECT ok, sqlstate, message, cfi_left FROM plllvm_jit_test(:'ir', 2, true);

SELECT owner, callee, ready FROM plllvm_call_sites() ORDER BY callee;
