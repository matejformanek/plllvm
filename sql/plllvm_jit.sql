--
-- The LLJIT runtime, through plllvm_jit_test()
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;
\pset null '(null)'

-- an empty body
SELECT * FROM plllvm_jit_test('define i64 @f(ptr %fcinfo) { ret i64 0 }', 2);

SELECT owner_oid, symbol, gen, opt_level, ir_instructions, helpers_linked,
       cfi_left, retired,
       parse_bc_ms >= 0 AND parse_ms >= 0 AND link_ms >= 0 AND verify_ms >= 0
         AND optimize_ms >= 0 AND emit_ms > 0 AS timed,
       total_ms >= emit_ms AS total,
       code_addr IS NOT NULL AS addr
  FROM plllvm_code_cache();

-- every host API symbol, declared and called; all resolve at lookup
CREATE TEMP TABLE ir (name text PRIMARY KEY, body text);
INSERT INTO ir VALUES ('host_api', $ir$
declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i32 @plllvm_arg_i32(ptr, i32)
declare i64 @plllvm_arg_i64(ptr, i32)
declare double @plllvm_arg_f64(ptr, i32)
declare zeroext i1 @plllvm_arg_bool(ptr, i32)
declare i32 @plllvm_nargs(ptr)
declare i64 @plllvm_return_null(ptr)
declare void @plllvm_cfi()
declare void @plllvm_check_stack()
declare void @plllvm_error(i32, ptr)
declare void @plllvm_notice(ptr)
declare void @plllvm_rt_int_overflow()
declare void @plllvm_rt_bigint_overflow()
declare void @plllvm_rt_div_zero()
declare void @float_overflow_error()
declare void @float_underflow_error()
declare void @float_zero_divide_error()

@msg = private constant [3 x i8] c"hi\00"

define i64 @f(ptr %p) {
entry:
  call void @plllvm_cfi()
  call void @plllvm_check_stack()
  call void @plllvm_notice(ptr @msg)
  %n = call i32 @plllvm_nargs(ptr %p)
  %a = call i32 @plllvm_arg_i32(ptr %p, i32 0)
  %b = call i64 @plllvm_arg_i64(ptr %p, i32 1)
  %c = call double @plllvm_arg_f64(ptr %p, i32 2)
  %d = call i1 @plllvm_arg_bool(ptr %p, i32 3)
  %e = call i1 @plllvm_arg_isnull(ptr %p, i32 4)
  switch i32 %n, label %done [i32 1, label %e1
                              i32 2, label %e2
                              i32 3, label %e3
                              i32 4, label %e4
                              i32 5, label %e5
                              i32 6, label %e6
                              i32 7, label %e7]
e1:
  call void @plllvm_error(i32 %a, ptr @msg)
  unreachable
e2:
  call void @plllvm_rt_int_overflow()
  unreachable
e3:
  call void @plllvm_rt_bigint_overflow()
  unreachable
e4:
  call void @plllvm_rt_div_zero()
  unreachable
e5:
  call void @float_overflow_error()
  unreachable
e6:
  call void @float_underflow_error()
  unreachable
e7:
  call void @float_zero_divide_error()
  unreachable
done:
  %ai = sext i32 %a to i64
  %ci = fptosi double %c to i64
  %s = add i64 %ai, %b
  %t = add i64 %s, %ci
  %isnull = or i1 %d, %e
  br i1 %isnull, label %null, label %ret
null:
  %r = call i64 @plllvm_return_null(ptr %p)
  ret i64 %r
ret:
  ret i64 %t
}
$ir$);

SELECT t.ok, t.sqlstate, t.message, t.gen, t.helpers_linked, t.cfi_left
  FROM ir, plllvm_jit_test(body, 0) t WHERE name = 'host_api';
SELECT t.ok, t.sqlstate, t.message, t.gen, t.helpers_linked, t.cfi_left
  FROM ir, plllvm_jit_test(body, 2) t WHERE name = 'host_api';
SELECT t.ok, t.sqlstate, t.message, t.gen, t.helpers_linked, t.cfi_left
  FROM ir, plllvm_jit_test(body, codegen => false) t WHERE name = 'host_api';

-- a parse error carries its position
SELECT ok, sqlstate, line, col, gen FROM plllvm_jit_test($ir$define i64 @f(ptr %p) {
  ret i32 0
}$ir$);

-- the entry point
SELECT ok, sqlstate, message, detail
  FROM plllvm_jit_test('define i64 @g(ptr %p) { ret i64 0 }');
SELECT ok, sqlstate, message, detail
  FROM plllvm_jit_test('declare i64 @f(ptr)');
SELECT ok, sqlstate, message, detail
  FROM plllvm_jit_test('define i32 @f(ptr %p) { ret i32 0 }');
SELECT ok, sqlstate, message, detail
  FROM plllvm_jit_test('define internal i64 @f(ptr %p) { ret i64 0 }');

-- declarations are checked against the host API, definitions may not
-- take its names
SELECT ok, sqlstate, message, detail FROM plllvm_jit_test($ir$
declare i64 @plllvm_arg_i32(ptr, i32)
define i64 @f(ptr %p) {
  %v = call i64 @plllvm_arg_i32(ptr %p, i32 0)
  ret i64 %v
}
$ir$);
SELECT ok, sqlstate, message, detail FROM plllvm_jit_test($ir$
declare void @plllvm_nope()
define i64 @f(ptr %p) {
  call void @plllvm_nope()
  ret i64 0
}
$ir$);
SELECT ok, sqlstate, message, detail FROM plllvm_jit_test($ir$
define void @plllvm_x() { ret void }
define i64 @f(ptr %p) { ret i64 0 }
$ir$);
SELECT ok, sqlstate, message, detail FROM plllvm_jit_test($ir$
define void @check_stack_depth() { ret void }
define i64 @f(ptr %p) { ret i64 0 }
$ir$);

-- a symbol that neither the host API nor the server has
INSERT INTO ir VALUES ('nosym', $ir$
declare void @no_such_function()
define i64 @f(ptr %p) {
  call void @no_such_function()
  ret i64 0
}
$ir$);
SELECT t.ok, t.sqlstate, t.message
  FROM ir, plllvm_jit_test(body, codegen => false) t WHERE name = 'nosym';
SELECT t.ok, t.sqlstate, t.message
  FROM ir, plllvm_jit_test(body) t WHERE name = 'nosym';

-- invalid IR that parses
SELECT ok, sqlstate, message FROM plllvm_jit_test($ir$
define i64 @f(ptr %p) {
  %x = add i64 %y, 1
  %y = add i64 %x, 1
  ret i64 0
}
$ir$);

-- an error in code generation fails the compile and drops its module
SELECT ok, sqlstate, message
  FROM plllvm_jit_test('define i64 @f(ptr %p) { call void asm sideeffect "no_such_insn", ""() ret i64 0 }');

-- the size limit
SET plllvm.max_ir_instructions = 1;
SELECT ok, sqlstate, message, detail
  FROM plllvm_jit_test('define i64 @f(ptr %p) { %x = add i64 0, 1 ret i64 %x }');
RESET plllvm.max_ir_instructions;

-- the optimization level
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }', 7);  -- fail
SELECT ok FROM plllvm_jit_test(NULL);  -- fail
SET plllvm.opt_level = 0;
SELECT ok, gen FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }');
SELECT gen, opt_level FROM plllvm_code_cache() LIMIT 1;
RESET plllvm.opt_level;

-- the resident cap; failed compiles do not count, nothing is freed
SELECT compiles + 2 AS cap FROM plllvm_session_info() \gset
SET plllvm.max_resident_compiles = :cap;
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 1 }');
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i32 1 }');
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 2 }');
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 3 }');  -- fail
RESET plllvm.max_resident_compiles;
SELECT ok, gen FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 3 }');

SELECT compiles, compile_failures, retired FROM plllvm_session_info();
SELECT count(*), count(DISTINCT symbol) AS symbols, count(DISTINCT code_addr) AS addrs,
       bool_or(retired) AS retired
  FROM plllvm_code_cache();

-- superuser only
CREATE ROLE regress_plllvm_jit;
SET ROLE regress_plllvm_jit;
SELECT ok FROM plllvm_jit_test('define i64 @f(ptr %p) { ret i64 0 }');  -- fail
SELECT count(*) FROM plllvm_code_cache();  -- fail
SET plllvm.debug_inject = 'llvm_fatal';  -- fail
RESET ROLE;
DROP ROLE regress_plllvm_jit;
DROP TABLE ir;
