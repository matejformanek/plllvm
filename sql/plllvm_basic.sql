--
-- Calling PL/LLVM functions: types, shapes and NULLs
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

-- the result is the Datum: integers sign-extended, float8 as its bits
CREATE FUNCTION add_i4(a int4, b int4) RETURNS int4
LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %a = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %b = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 1)
  %s = add i32 %a, %b
  %d = sext i32 %s to i64
  ret i64 %d
}
$$;

CREATE FUNCTION mul_i8(a int8, b int8) RETURNS int8
LANGUAGE plllvm STRICT AS $$
declare i64 @plllvm_arg_i64(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %a = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %b = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 1)
  %p = mul i64 %a, %b
  ret i64 %p
}
$$;

CREATE FUNCTION half(x float8) RETURNS float8
LANGUAGE plllvm STRICT AS $$
declare double @plllvm_arg_f64(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call double @plllvm_arg_f64(ptr %fcinfo, i32 0)
  %h = fmul double %x, 0.5
  %d = bitcast double %h to i64
  ret i64 %d
}
$$;

CREATE FUNCTION negate(b bool) RETURNS bool
LANGUAGE plllvm STRICT AS $$
declare zeroext i1 @plllvm_arg_bool(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %b = call i1 @plllvm_arg_bool(ptr %fcinfo, i32 0)
  %n = xor i1 %b, true
  %d = zext i1 %n to i64
  ret i64 %d
}
$$;

SELECT add_i4(40, 2), add_i4(-5, 3), mul_i8(3000000000, 3),
       half(3.0), half(-1e300), negate(true), negate(false);

-- no arguments, and ten summed through plllvm_nargs
CREATE FUNCTION seven() RETURNS int4
LANGUAGE plllvm IMMUTABLE AS $$
define i64 @f(ptr %fcinfo) {
  ret i64 7
}
$$;

CREATE FUNCTION sum10(int4, int4, int4, int4, int4,
                      int4, int4, int4, int4, int4) RETURNS int8
LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_nargs(ptr)
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
entry:
  %n = call i32 @plllvm_nargs(ptr %fcinfo)
  br label %loop

loop:
  %i = phi i32 [ 0, %entry ], [ %i.next, %body ]
  %sum = phi i64 [ 0, %entry ], [ %sum.next, %body ]
  %more = icmp slt i32 %i, %n
  br i1 %more, label %body, label %done

body:
  %a = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 %i)
  %a.l = sext i32 %a to i64
  %sum.next = add i64 %sum, %a.l
  %i.next = add i32 %i, 1
  br label %loop

done:
  ret i64 %sum
}
$$;

SELECT seven(), sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10);

-- an IMMUTABLE function is folded at plan time
EXPLAIN (VERBOSE, COSTS OFF) SELECT seven();

-- internal helpers stay inside the module
CREATE FUNCTION sumsq(a int8, b int8) RETURNS int8
LANGUAGE plllvm STRICT AS $$
declare i64 @plllvm_arg_i64(ptr, i32)

define internal i64 @sq(i64 %x) {
  %r = mul i64 %x, %x
  ret i64 %r
}

define i64 @f(ptr %fcinfo) {
  %a = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %b = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 1)
  %a2 = call i64 @sq(i64 %a)
  %b2 = call i64 @sq(i64 %b)
  %s = add i64 %a2, %b2
  ret i64 %s
}
$$;

SELECT sumsq(3, 4);

-- RETURNS void, SECURITY DEFINER with a SET clause, and a NOTICE
CREATE FUNCTION hello() RETURNS void
LANGUAGE plllvm SECURITY DEFINER SET search_path = pg_catalog AS $$
declare void @plllvm_notice(ptr)

@msg = private constant [19 x i8] c"hello from PL/LLVM\00"

define i64 @f(ptr %fcinfo) {
  call void @plllvm_notice(ptr @msg)
  ret i64 0
}
$$;

SELECT hello();

-- not STRICT: the IR sees the NULL and returns one
CREATE FUNCTION inc_or_null(x int8) RETURNS int8
LANGUAGE plllvm AS $$
declare zeroext i1 @plllvm_arg_isnull(ptr, i32)
declare i64 @plllvm_arg_i64(ptr, i32)
declare i64 @plllvm_return_null(ptr)

define i64 @f(ptr %fcinfo) {
entry:
  %isnull = call i1 @plllvm_arg_isnull(ptr %fcinfo, i32 0)
  br i1 %isnull, label %null, label %value

null:
  %n = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %n

value:
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %r = add i64 %x, 1
  ret i64 %r
}
$$;

SELECT inc_or_null(41), inc_or_null(NULL) IS NULL AS is_null;

-- STRICT with a NULL argument: the handler is not even called
CREATE FUNCTION never_called(x int4) RETURNS int4
LANGUAGE plllvm STRICT AS $$
define i64 @f(ptr %fcinfo) {
  ret i64 0
}
$$;

SELECT never_called(NULL) IS NULL AS is_null;

-- one call per row
SELECT sum(add_i4(g, 1)) FROM generate_series(1, 1000) g;

SELECT p.proname, s.*
  FROM pg_proc p, plllvm_function_status(p.oid) s
 WHERE p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plllvm')
 ORDER BY p.proname;

-- a parallel worker loads plllvm, compiles the function and exits
CREATE FUNCTION par_twice(x int4) RETURNS int4
LANGUAGE plllvm STRICT PARALLEL SAFE AS $$
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %r = mul i32 %x, 2
  %d = sext i32 %r to i64
  ret i64 %d
}
$$;

CREATE FUNCTION par_raise() RETURNS int4
LANGUAGE plllvm PARALLEL SAFE AS $$
declare void @plllvm_error(i32, ptr)

@msg = private constant [5 x i8] c"boom\00"

define i64 @f(ptr %fcinfo) {
  call void @plllvm_error(i32 0, ptr @msg)
  unreachable
}
$$;

SET debug_parallel_query = on;
EXPLAIN (COSTS OFF) SELECT par_twice(21);
SELECT par_twice(21);
-- the error comes from the worker
SELECT par_raise();
RESET debug_parallel_query;

DROP FUNCTION par_twice(int4), par_raise();
DROP FUNCTION add_i4(int4, int4);
DROP FUNCTION mul_i8(int8, int8);
DROP FUNCTION half(float8);
DROP FUNCTION negate(bool);
DROP FUNCTION seven();
DROP FUNCTION sum10(int4, int4, int4, int4, int4, int4, int4, int4, int4, int4);
DROP FUNCTION sumsq(int8, int8);
DROP FUNCTION hello();
DROP FUNCTION inc_or_null(int8);
DROP FUNCTION never_called(int4);
