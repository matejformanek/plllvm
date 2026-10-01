--
-- PL/LLVM next to the server's query JIT (llvmjit), in either order
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

CREATE FUNCTION qj_add1(x int4) RETURNS int8 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %x.l = sext i32 %x to i64
  %r = add i64 %x.l, 1
  ret i64 %r
}
$$;

-- whether the query was JIT-compiled
CREATE FUNCTION qj_jitted(q text) RETURNS bool LANGUAGE plpgsql AS $$
DECLARE
  plan json;
BEGIN
  EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) ' || q INTO plan;
  RETURN (plan -> 0 -> 'JIT' ->> 'Functions')::int > 0;
END
$$;

-- the validator set up the LLVM of plllvm, start over
\c
SET plllvm.regress_test_mode = on;
SET jit = on;
SET jit_above_cost = 0;
SET jit_inline_above_cost = 0;
SET jit_optimize_above_cost = 0;

-- llvmjit first
SELECT qj_jitted('SELECT sum(g) FROM generate_series(1, 1000) g');
SELECT sum(qj_add1(g)) FROM generate_series(1, 1000) g;
SELECT qj_jitted('SELECT sum(qj_add1(g)) FROM generate_series(1, 1000) g');

\c
SET plllvm.regress_test_mode = on;
SET jit = on;
SET jit_above_cost = 0;
SET jit_inline_above_cost = 0;
SET jit_optimize_above_cost = 0;

-- plllvm first
SELECT qj_add1(41);
SELECT qj_jitted('SELECT sum(qj_add1(g)) FROM generate_series(1, 1000) g');
SELECT sum(qj_add1(g)) FROM generate_series(1, 1000) g;

SELECT init_ms > 0 AS init, llvm_version FROM plllvm_session_info();
SELECT * FROM plllvm_function_status('qj_add1(int4)');

DROP FUNCTION qj_add1(int4), qj_jitted(text);
