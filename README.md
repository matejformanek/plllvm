# plllvm

PL/LLVM, a procedural language for PostgreSQL whose function bodies are LLVM IR.
The extension compiles them with its own ORC LLJIT and calls them with the
version 1 calling convention. It is written for a master's thesis on JIT
compilation of PL/pgSQL (FIT ČVUT, supervisor Pavel Stěhule) and needs no
changes to PostgreSQL.

**Status: v0.1 in progress.** Functions in `LANGUAGE plllvm` are checked at
`CREATE FUNCTION`, compiled with plllvm's own LLJIT at their first call in a
session, and run. `examples/kernels/` has the benchmark kernels of the thesis
except neword (see Limits): twelve written by hand in IR and two compiled
from C (`make kernels`).

## Features

v0.1:

* `LANGUAGE plllvm`: the body is an LLVM IR module with an entry
  `define i64 @f(ptr %fcinfo)`, called as a version 1 function.
* A small host API (argument and NULL access, errors, interrupts, calls of
  other functions, constants, text, memory, read-only SQL, arrays) that the
  IR declares and the
  validator checks against the extension's helper bitcode
  (`docs/host-api.ll`).
* Compile time reported per stage, next to the code it produced.

Later parts (a PL/pgSQL compiler, expression JIT) depend on the thesis plan
and are not part of v0.1.

## Usage

```sql
CREATE EXTENSION plllvm;
```

The language is untrusted: only a superuser can install it and create
functions in it. There is no inline handler, so `DO` is not supported.

```sql
CREATE FUNCTION add1(x int4) RETURNS int4 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %r = add i32 %x, 1
  %d = sext i32 %r to i64
  ret i64 %d
}
$$;
```

`@f` returns the result Datum: integers sign-extended to `i64`, `float8` as
its bits (`bitcast`), `bool` as 0 or 1. The IR handles NULL arguments of a
non-STRICT function itself (`plllvm_arg_isnull`, `plllvm_return_null`).
Declarations of the host API (`src/plllvm_types.c`, `src/plllvm_runtime.c`)
are checked against it; other external symbols resolve against the server
process. Names starting with `plllvm_` cannot be defined. Only `@f` is
seen outside the body, so module asm, aliases, ifuncs and `llvm.*` globals
other than `llvm.used`, `llvm.compiler.used` and empty constructor lists are
refused; static constructors would never run. A loop or a recursion that
does not check for interrupts and the stack depth itself gets the checks
added (`plllvm.auto_checks`). The validator parses and verifies the body;
with `check_function_bodies = off` the first call does. Errors inside the
body point into it.

Other functions are called through call sites: a declared global named by
the callee's `regprocedure` text, passed to `plllvm_call0` … `plllvm_call3`
with each argument and its NULL flag. A global named `'literal'::type` is a
constant, read once per compile by the type's immutable input function:

```sql
CREATE FUNCTION add_cent(x numeric) RETURNS numeric LANGUAGE plllvm STRICT AS $$
@"numeric_add(numeric,numeric)" = external global i8
@"'0.01'::numeric" = external global i8
declare i64 @plllvm_arg_i64(ptr, i32)
declare i64 @plllvm_const(ptr)
declare i64 @plllvm_call2(ptr, i64, i1, i64, i1, ptr)

define i64 @f(ptr %fcinfo) {
  %x = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  %c = call i64 @plllvm_const(ptr @"'0.01'::numeric")
  %r = call i64 @plllvm_call2(ptr @"numeric_add(numeric,numeric)",
                              i64 %x, i1 false, i64 %c, i1 false, ptr null)
  ret i64 %r
}
$$;
```

The names are resolved under the function's own `SET search_path`, else
under `pg_catalog, <its schema>, pg_temp`, never under the caller's path.
A site calls with the executor's protocol: a strict callee is not called
with a NULL argument, `EXECUTE` is checked, and an `ALTER`, `GRANT` or role
change is seen at the next call. Like a cached plan, a site follows its
name: after any change of the callee or of a schema, the signature is
resolved again. A qualified name follows that schema's name; an
unqualified one resolves under the function's own path, which without a
`SET search_path` follows a rename of the function's schema. A callee of
other argument or result types is an ERROR. A body that uses calls, text
or memory helpers runs in a scratch context; a by-reference result is
copied out of it, and must not be a null pointer.

A body that declares `plllvm_spi_prepare` runs SQL. A statement lives in a
slot, an `internal global ptr null` of the body, and is prepared at its
first use in a backend; its argument and column types are type names,
without type modifiers (cast in the statement instead). It must be one
plain SELECT, without `FOR UPDATE` or data-modifying `WITH` at the top
level; the functions it calls are not restricted. It runs
read-only unless the function is VOLATILE, as in PL/pgSQL.
`plllvm_spi_select_into` runs it as a non-STRICT `SELECT INTO`: the first
row, or NULLs. A result of other column types than declared is an ERROR.
By-reference columns are copies as from `plllvm_keep`; free them with
`plllvm_free`:

```sql
CREATE FUNCTION name_of(i int) RETURNS text LANGUAGE plllvm STABLE AS $$
@q.sql = private constant [33 x i8] c"SELECT s FROM spi_t WHERE i = $1\00"
@q.args = private constant [5 x i8] c"int4\00"
@q.cols = private constant [5 x i8] c"text\00"
@q = internal global ptr null
%struct.NullableDatum = type { i64, i8 }
declare ptr @plllvm_spi_prepare(ptr, ptr, ptr, ptr)
declare i32 @plllvm_spi_select_into(ptr, ptr, ptr, ptr)
declare i64 @plllvm_arg_i64(ptr, i32)
declare i64 @plllvm_return_null(ptr)

define i64 @f(ptr %fcinfo) {
  %args = alloca %struct.NullableDatum
  %out = alloca %struct.NullableDatum
  %i = call i64 @plllvm_arg_i64(ptr %fcinfo, i32 0)
  store %struct.NullableDatum zeroinitializer, ptr %args
  store i64 %i, ptr %args
  %stmt = call ptr @plllvm_spi_prepare(ptr @q, ptr @q.sql, ptr @q.args, ptr @q.cols)
  %rows = call i32 @plllvm_spi_select_into(ptr %fcinfo, ptr %stmt, ptr %args, ptr %out)
  %np = getelementptr %struct.NullableDatum, ptr %out, i32 0, i32 1
  %n = load i8, ptr %np
  %null = icmp ne i8 %n, 0
  br i1 %null, label %none, label %some
none:
  %z = call i64 @plllvm_return_null(ptr %fcinfo)
  ret i64 %z
some:
  %v = load i64, ptr %out
  ret i64 %v
}
$$;
```

Arrays are flat, one-dimensional (or empty) arrays of `int4`, `int8` or
`float8` without NULL elements. `plllvm_array_arg` gives an argument as a
private copy, made at each call, so call it once per argument and call;
`plllvm_array_new` makes one of zeros, `plllvm_array_copy` copies one, and
the inline `plllvm_array_get_*`/`_set_*` index it from its lower bound. An
out-of-range subscript or another element type is an ERROR. Arrays are
allocated in the current context, the scratch in a frame.

`plllvm_function_status(fn regprocedure)` (superuser) gives the `state` of
a function's code in this backend, `not_compiled`, `live`, `stale` (the
definition changed since the compile) or `dropped`, with the numbers of its
resident compiles and of those retired (released, freed at the next
compile).

`plllvm_jit_test(ir text, opt_level int DEFAULT
NULL, codegen bool DEFAULT true)` (superuser) compiles a function body and
returns the outcome as a row: `ok`, the SQLSTATE, message and detail of a
refusal, the line and column of a parse error, the instruction and helper
counts, and the number of checks added. With `codegen => false` it only
checks the IR. Nothing calls its code, so it is retired at once and freed
at the next compile.

```sql
SELECT ok, gen, helpers_linked
  FROM plllvm_jit_test('define i64 @f(ptr %fcinfo) { ret i64 0 }');
```

`plllvm_code_cache()` (superuser) lists the compiled code of the session,
newest first, with the time of each compile stage (`parse_bc`, `parse`,
`link`, `verify`, `resolve`, `optimize`, `emit`; code is generated at the
lookup in `emit`) and whether it runs in a scratch context (`frame`).
`plllvm_call_sites()` (superuser) lists its call sites with their state and
how often each was prepared, checked and re-entered. Retired code is listed
until the next compile frees it.

## Limits

* Functions only: no procedures, window functions, triggers or set-returning
  functions; no OUT parameters; no composite, domain or pseudo-type results
  other than `void`, and no composite or pseudo-type arguments.
* Replaced code is freed once no call runs it. Code of a dropped function
  stays until the session ends.
* Each input collation compiles its own code, as in PL/pgSQL. A role that
  may call a function with a `text` argument and create temporary objects
  (`PUBLIC` by default) can fill `plllvm.max_resident_compiles` in a
  long-lived session with new temporary collations. `REVOKE EXECUTE ...
  FROM PUBLIC` on such functions, or `REVOKE TEMP`, prevents this.
* Call sites take at most 3 arguments. They cannot call procedures,
  set-returning functions, functions with polymorphic or `"any"` arguments
  or results, or functions returning `record` or a trigger. A callee that
  is dropped and created again with another result type is an ERROR until
  the caller is replaced.
* Calls through sites are not counted by `track_functions`. The function
  execute hook runs once per user and invalidation, not per query, and an
  fmgr hook's decision (`FmgrHookIsNeeded`, e.g. after `SECURITY LABEL`) is
  taken only when a site is rebuilt.
* SQL: "plain SELECT" is checked at the top level only, so a VOLATILE
  function may run a `FOR UPDATE` inside a subquery (a STABLE one is
  refused by SPI's read-only check).
* SQL: only `SELECT INTO` of one row; no cursors, no other commands, no
  dynamic SQL.
* Arrays: one dimension, no NULL elements, `int4`, `int8` and `float8` only.
* The neword kernel (TPC-C New-Order) is not ported: it needs `UPDATE`
  (district, stock) and `INSERT` (orders, new_order, order_line) through
  SPI. Its checksum does not depend on these writes, so a port without
  them would match it but skip the work the kernel measures.
* Every backend compiles its own copy; status and counters are per backend.

Built and tested only with PostgreSQL 20devel at commit `9510a826e4a`,
LLVM 22, macOS arm64 (see `PG_PIN`). The server must be built with LLVM; the
extension links the same shared `libLLVM` as the server's `llvmjit`.

## Security

The language is untrusted, as C is: a body can declare and call any symbol
of the server process, so it can do whatever the server's operating system
user can. Only superusers create PL/LLVM functions.

* There is no memory safety. A value used after `plllvm_scratch_reset`, a
  value freed twice or a constant freed, or a store out of bounds corrupts
  or crashes the backend, as a bug in a C function does.
* A body must not hand a pointer to its own functions or constants to
  anything that outlives the call (a memory context callback,
  `RegisterXactCallback`, a hook): replaced code is freed, unlike a C
  library, which is never unloaded.
* The added checks do not cover a blocking call (`pause`, `read` of a
  FIFO), a dynamic `alloca` inside a loop (the stack grows unchecked until
  the backend dies with SIGSEGV), a loop in inline assembly, or a
  `sigsetjmp`/`siglongjmp` loop through process symbols.
* The owner of a function may change its `SET search_path`, and with it
  what its call sites resolve to, as core lets an owner alter any function
  of an untrusted language. Keep such functions owned by superusers, write
  call-site signatures schema-qualified, and give `SECURITY DEFINER`
  functions their own `SET search_path`.
* SQL statements resolve names under the caller's `search_path`, as in
  PL/pgSQL; only call sites do not. A `SECURITY DEFINER` function should
  have `SET search_path = <its schema>, pg_temp`.
* Call sites and constants record no dependency, as SQL in PL/pgSQL does
  not: dropping a callee does not see its callers, and a dump restores only
  with `check_function_bodies = off`, which pg_dump's output sets.

## Configuration

* `plllvm.regress_test_mode` (bool, default off, any user): reduces volatile
  output in regression tests.
* `plllvm.types_bc_path` (string, default empty, superuser): the
  `plllvm_types.bc` to use. Empty means `plllvm/plllvm_types.bc` next to the
  loaded library. A session reads it once, when it first needs LLVM.
* `plllvm.opt_level` (int 0–3, default 2, superuser): LLVM optimization level
  of new compiles; code already compiled keeps its level. At 0 only the
  always-inline host helpers are inlined.
* `plllvm.dump_ir` (bool, default off, superuser): logs the optimized IR of
  every compile.
* `plllvm.max_resident_compiles` (int, default 2000, superuser): the most
  compiles resident in a session. Retired code does not count; code of
  dropped functions and of every input collation does (see Limits). When
  this many compiles are resident, the next one fails with SQLSTATE 53400.
* `plllvm.max_ir_instructions` (int, default 100000, 0 = no limit,
  superuser): the largest function body accepted (SQLSTATE 54000).
* `plllvm.debug_inject` (`none`, `llvm_fatal`, `bad_alloc`, superuser): for
  tests only. Raises that LLVM error in the next compile, which ends the
  session with FATAL.
* `plllvm.auto_checks` (bool, default on, superuser): adds interrupt and
  stack depth checks to loops and recursions that lack them, at compile
  time. Turn it off only for measurements.

The prefix `plllvm.` is reserved.

`plllvm_session_info()` (superuser) shows the LLVM version, target triple and
data layout of the session, the libLLVM and `plllvm_types.bc` it loaded, how
long the setup took, the numbers of compiles, failed compiles and retired
compiles (resident ones are `compiles - retired`), the resident size of the
backend (`rss_bytes`, macOS only) and the number of SQL statements prepared
(`spi_statements`). It sets the session up if needed, so it also checks the
installation.

## Compilation

```
make PG_CONFIG=/path/to/pg_config [LLVM=/opt/homebrew/opt/llvm@22]
make PG_CONFIG=/path/to/pg_config install    # also writes plllvm/build-info.txt
make PG_CONFIG=/path/to/pg_config installcheck PLLLVM_PORT=
```

`LLVM` must be the LLVM the server was built with. Empty `PLLLVM_PORT` lets
`installcheck` use `PGHOST`/`PGPORT`. The tests need contrib `dblink`
installed in the server.

In the thesis workspace the extension is not installed into the server but
staged, and tested on a separate cluster (port 5447):

```
make PG_CONFIG=.../code/install-jit/bin/pg_config cluster-init      # once
make PG_CONFIG=.../code/install-jit/bin/pg_config stage cluster-start installcheck doctor cluster-stop
```

`make doctor` checks pg_config, LLVM and the libLLVM link against `PG_PIN`;
`make pgindent` formats the C sources (`docs/style.md`). `make check-host-api`
(part of `installcheck`) checks that `docs/host-api.ll` declares the whole
host API; `make installcheck-discard` runs the call-site tests under
`debug_discard_caches`. `make kernels` compiles `examples/kernels/src/*.c`
to IR with the install-perf headers, and `make check-kernels` checks that
the committed `.ll` files are up to date.

## Checked on

* PostgreSQL 20devel (9510a826e4a), LLVM 22.1.8, macOS 26 arm64

## Licence

PostgreSQL Licence, see `LICENSE`.
