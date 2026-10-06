<p align="center">
  <img src="docs/images/plllvm.jpeg" alt="PL/LLVM" width="360">
</p>

# PL/LLVM

An untrusted procedural language for PostgreSQL whose function bodies are
LLVM IR. The extension compiles them with its own ORC LLJIT and calls them
as version 1 C functions. It needs no changes to PostgreSQL.

Written for a master's thesis on JIT compilation of PL/pgSQL (FIT ČVUT,
supervisor Pavel Stěhule).

```sql
CREATE EXTENSION plllvm;

CREATE FUNCTION add1(x int4) RETURNS int4 LANGUAGE plllvm STRICT AS $$
declare i32 @plllvm_arg_i32(ptr, i32)

define i64 @f(ptr %fcinfo) {
  %x = call i32 @plllvm_arg_i32(ptr %fcinfo, i32 0)
  %r = add i32 %x, 1
  %d = sext i32 %r to i64
  ret i64 %d
}
$$;

SELECT add1(41);
```

## Install

```
make PG_CONFIG=/path/to/pg_config [LLVM=/opt/homebrew/opt/llvm@22]
make PG_CONFIG=/path/to/pg_config install
```

`LLVM` must be the LLVM the server was built with: the extension links the
same shared `libLLVM` as the server's `llvmjit`. `install` also writes
`plllvm/build-info.txt` (git head and checksums of the installed files).

`CREATE EXTENSION plllvm` needs a superuser. There is no upgrade script
yet: to move to a new version, `DROP EXTENSION plllvm CASCADE` and create it
again.

## Usage

The body is an LLVM IR module with the entry `define i64 @f(ptr %fcinfo)`.
`@f` returns the result Datum: integers sign-extended to `i64`, `float8` as
its bits (`bitcast`), `bool` as 0 or 1. A non-STRICT function handles NULL
arguments itself (`plllvm_arg_isnull`, `plllvm_return_null`).

* The validator parses and verifies the body at `CREATE FUNCTION`; with
  `check_function_bodies = off` the first call does. Parse errors give the
  line and column in the body.
* A function is compiled at its first call in a session; every backend
  compiles its own copy. Each input collation gets its own code, as in
  PL/pgSQL.
* Declarations of host API functions are checked against the extension's
  own; other external symbols resolve against the server process. Names
  starting with `plllvm_` cannot be defined.
* Only `@f` is visible outside the body. Module asm, aliases, ifuncs and
  `llvm.*` globals other than `llvm.used`, `llvm.compiler.used` and empty
  constructor lists are refused (constructors would never run).
* Loops and recursions without interrupt and stack depth checks get them
  added (`plllvm.auto_checks`).
* There is no inline handler, so `DO` is not supported.

### Calls and constants

A declared global named by a callee's `regprocedure` text is a call site,
passed to `plllvm_call0` ... `plllvm_call3` with each argument and its NULL
flag. A global named `'literal'::type` is a constant, read once per compile
by the type's immutable input function:

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

* Names resolve under the function's own `SET search_path`, else under
  `pg_catalog, <its schema>, pg_temp`, never under the caller's path. An
  unqualified name without `SET search_path` follows a rename of the
  function's schema; a qualified one follows that schema's name.
* A site calls with the executor's protocol: a strict callee is not called
  with a NULL argument, `EXECUTE` is checked, and an `ALTER`, `GRANT` or
  role change is seen at the next call.
* Like a cached plan, a site follows its name: after a change of the callee
  or of a schema the signature is resolved again. A callee of other argument
  or result types is an ERROR.
* A body that uses calls, text or memory helpers runs in a scratch context;
  a by-reference result is copied out of it and must not be a null pointer.

### SQL and arrays

A body that declares `plllvm_spi_prepare` runs SQL: one plain SELECT per
statement (no `FOR UPDATE` or data-modifying `WITH` at the top level),
prepared into a slot (`internal global ptr null`) at its first use in a
backend and run as a non-STRICT `SELECT INTO`. Argument and column types are
type names without type modifiers (cast in the statement instead); a result
of other column types is an ERROR. It runs read-only unless the function is
VOLATILE, as in PL/pgSQL. A full example is the `spi` branch of
`docs/host-api.ll`; more are in `sql/plllvm_spi.sql`.

Arrays are flat, one-dimensional (or empty) `int4`, `int8` or `float8`
arrays without NULL elements. `plllvm_array_arg` makes a private copy of an
argument at each call, so call it once per argument and call.

## Host API

`docs/host-api.ll` declares every host function with its types and is
itself a valid body (`make check-host-api` keeps it complete).

| group | functions |
|---|---|
| arguments, result | `plllvm_arg_isnull`, `plllvm_arg_i32`/`_i64`/`_f64`/`_bool`, `plllvm_nargs`, `plllvm_return_null` |
| errors, interrupts | `plllvm_error`, `plllvm_notice`, `plllvm_int_overflow`, `plllvm_bigint_overflow`, `plllvm_div_zero`, `plllvm_cfi`, `plllvm_check_stack` |
| calls, constants | `plllvm_call0` ... `plllvm_call3`, `plllvm_const` |
| text, varlena | `plllvm_cstring_to_text`, `plllvm_text_to_cstring`, `plllvm_detoast`, `plllvm_vardata_any`, `plllvm_varsize_any_exhdr` |
| memory | `plllvm_keep`, `plllvm_free`, `plllvm_scratch_reset` |
| SQL | `plllvm_spi_prepare`, `plllvm_spi_select_into` |
| arrays | `plllvm_array_arg`, `_new`, `_copy`, `_length`, `_lower`, `_get_i32`/`_i64`/`_f64`, `_set_i32`/`_i64`/`_f64` |

### Inspection functions

All are superuser only and show the current backend.

| function | shows |
|---|---|
| `plllvm_session_info()` | LLVM version, triple, data layout, loaded `libLLVM` and `plllvm_types.bc`, setup time, compiles, failed and retired compiles, `rss_bytes` (macOS only), prepared SQL statements; sets the session up, so it also checks the installation |
| `plllvm_code_cache()` | compiled code, newest first, with the time of each stage (`parse_bc`, `parse`, `link`, `verify`, `resolve`, `optimize`, `emit`), whether it runs in a scratch context (`frame`) and its `kind`, `function` or `expr` |
| `plllvm_call_sites()` | call sites, their state and how often each was prepared, checked and re-entered |
| `plllvm_function_status(regprocedure)` | `not_compiled`, `live`, `stale` or `dropped`, with resident and retired compiles |
| `plllvm_expr_stats()` | expression JIT in PL/pgSQL (below): `state`; expressions `fired`, `installed` (given code), `compiled`, `declined`, failed (`failures`) and left interpreted at the cap (`capped`); `programs` kept; `compiled_evals`, evaluations of code compiled under `plllvm.expr_eager` |
| `plllvm_jit_test(ir, opt_level, codegen)` | compiles a body without calling it: `ok`, SQLSTATE, message, detail, line and column of a parse error, instruction and helper counts, checks added; `codegen => false` only checks the IR |

Retired code (replaced, no call running it) is listed until the next compile
frees it.

## PL/pgSQL expressions

`plllvm.expr_jit` compiles the simple expressions of `LANGUAGE plpgsql`
functions, at their second evaluation in a transaction. An expression is
compiled whole or not at all. This version takes:

* constants, and variables of type `int4`, `int8`, `float8` and `bool`;
* `+ - * /` and unary minus of `int4`, `int8` and the mixed `int4`/`int8`
  operators, `%` and `mod()` of `int4` and `int8`, and their six
  comparisons;
* `+ - * /`, unary minus and the comparisons of `float8`; `=` and `<>` of
  `bool`;
* the casts `int8(int4)`, `int4(int8)`, `float8(int4)`, `float8(int8)`.

Anything else (`numeric`, `text`, other functions, `CASE`, `AND`/`OR`,
arrays) stays interpreted. Results and errors are those of PL/pgSQL;
integer errors under `VERBOSITY verbose` name another source location.

A compiled expression is kept for the session and found again by its
tree, so the next transaction pays only a lookup. The code is never freed:
`plllvm.expr_max_programs` caps it, and beyond the cap new expressions are
interpreted. Each takes some tens of KiB.

The library has to be loaded before the PL/pgSQL function starts: `LOAD
'plllvm'`, `session_preload_libraries` or `shared_preload_libraries`. Once
loaded, it takes PL/pgSQL's plugin slot (`PLpgSQL_plugin`), the one that
debuggers and profilers use.

* A plugin loaded before plllvm is chained: its callbacks still run.
* A plugin loaded after plllvm that chains keeps both working. One that
  overwrites the slot turns expression JIT off without notice;
  `plllvm_expr_stats()` then shows `not_in_slot`.
* `state` is `declined:paramfunc` when PL/pgSQL's parameter functions are
  not what plllvm expects; expression JIT is then off for the session.
* An expression evaluated once per transaction is never taken. Parallel
  workers leave their expressions alone.
* `SET plllvm.expr_jit = off` stops new expressions at once; those already
  compiled run compiled until the transaction ends.
* With `plllvm.expr_jit` on, a broken installation (no usable
  `plllvm_types.bc`) fails the first statement that would compile, as for
  PL/LLVM functions.
* Loaded, every PL/pgSQL call goes through plllvm's `func_setup`, also with
  `plllvm.expr_jit` off.

## Configuration

| GUC | type | default | set by | meaning |
|---|---|---|---|---|
| `plllvm.opt_level` | int 0–3 | 2 | superuser | LLVM optimization level of new compiles; at 0 only the always-inline host helpers are inlined |
| `plllvm.auto_checks` | bool | on | superuser | add interrupt and stack depth checks to loops and recursions that lack them; turn off only for measurements |
| `plllvm.max_resident_compiles` | int 1–1000000 | 2000 | superuser | compiles resident in a session; the next one fails with SQLSTATE 53400 |
| `plllvm.max_ir_instructions` | int, 0 = no limit | 100000 | superuser | largest body accepted (SQLSTATE 54000) |
| `plllvm.dump_ir` | bool | off | superuser | log the optimized IR of every compile |
| `plllvm.types_bc_path` | string | empty | superuser | the `plllvm_types.bc` to use; empty means `plllvm/plllvm_types.bc` next to the library; read once per session |
| `plllvm.expr_jit` | bool | off | superuser | expression JIT in PL/pgSQL functions (above) |
| `plllvm.expr_opt_level` | int 0–3 | 2 | superuser | LLVM optimization level of compiled expressions |
| `plllvm.expr_max_programs` | int 1–1000000 | 1000 | superuser | compiled expressions (and failed builds) kept in a session; beyond it, new expressions are interpreted |
| `plllvm.expr_eager` | bool | off | superuser | tests only: take an expression at its first evaluation instead of the second |
| `plllvm.regress_test_mode` | bool | off | any user | reduce volatile output (times, addresses) in regression tests |
| `plllvm.debug_inject` | `none`, `llvm_fatal`, `bad_alloc` | none | superuser | tests only: raise that LLVM error in the next compile, which ends the session with FATAL |

Code already compiled keeps its `opt_level`; an expression compiled at
another `expr_opt_level` is compiled again. Retired code does not count
against `max_resident_compiles`; code of dropped functions and of each input
collation does. The prefix `plllvm.` is reserved.

## Limits

* Functions only: no procedures, window functions, triggers or set-returning
  functions; no OUT parameters; no composite, domain or pseudo-type results
  other than `void`, and no composite or pseudo-type arguments.
* Replaced code is freed once no call runs it; code of a dropped function
  stays until the session ends.
* A role that may call a function with a `text` argument and create
  temporary objects (`PUBLIC` by default) can fill
  `plllvm.max_resident_compiles` in a long-lived session with new temporary
  collations. `REVOKE EXECUTE ... FROM PUBLIC` on such functions, or
  `REVOKE TEMP`, prevents this.
* Call sites take at most 3 arguments. They cannot call procedures,
  set-returning functions, functions with polymorphic or `"any"` arguments
  or results, or functions returning `record` or a trigger. A callee dropped
  and created again with another result type is an ERROR until the caller
  is replaced.
* Calls through sites are not counted by `track_functions`. The function
  execute hook runs once per user and invalidation, not per query, and an
  fmgr hook's decision (`FmgrHookIsNeeded`, e.g. after `SECURITY LABEL`) is
  taken only when a site is rebuilt.
* SQL: only `SELECT INTO` of one row; no cursors, other commands or dynamic
  SQL. "Plain SELECT" is checked at the top level only, so a VOLATILE
  function may run `FOR UPDATE` in a subquery (a STABLE one is refused by
  SPI's read-only check).
* Arrays: one dimension, no NULL elements, `int4`, `int8` and `float8` only.
* Status and counters are per backend.

## Security

The language is untrusted, as C is: a body can declare and call any symbol
of the server process, so it can do whatever the server's operating system
user can. Only superusers create PL/LLVM functions.

* There is no memory safety. A value used after `plllvm_scratch_reset`, a
  value freed twice, a constant freed or a store out of bounds corrupts or
  crashes the backend, as a bug in a C function does.
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
  of an untrusted language. Keep such functions owned by superusers and
  write call-site signatures schema-qualified.
* SQL statements resolve names under the caller's `search_path`, as in
  PL/pgSQL; only call sites do not. A `SECURITY DEFINER` function should
  have `SET search_path = <its schema>, pg_temp`.
* Call sites and constants record no dependency, as SQL in PL/pgSQL does
  not: dropping a callee does not see its callers, and a dump restores only
  with `check_function_bodies = off`, which pg_dump's output sets.

## Status

v0.1, the PL/LLVM language, is done. v0.2 adds expression JIT for
PL/pgSQL, for integer and float expressions so far. `examples/kernels/` has the benchmark
kernels of the thesis in IR; `nbody` and `revcomp` are compiled from C
(`examples/kernels/src/`). The neword kernel (TPC-C New-Order) is not
ported: it needs `UPDATE` and `INSERT` through SPI, and its checksum does
not depend on these writes, so a port without them would skip the work it
measures.

Planned, depending on the thesis: a `plpgsql_jit` language.

## Building and testing

```
make PG_CONFIG=/path/to/pg_config installcheck PLLLVM_PORT=
```

Empty `PLLLVM_PORT` lets `installcheck` use `PGHOST`/`PGPORT`. The tests
need contrib `dblink` installed in the server.

In the thesis workspace the extension is staged instead of installed and
tested on its own cluster (port 5447 by default):

```
make cluster-init                                   # once
make stage cluster-start installcheck doctor cluster-stop
```

`PG_CONFIG` defaults to the workspace's `code/install-jit` build.

| target | does |
|---|---|
| `doctor` | checks pg_config, catalog version, LLVM and the `libLLVM` link against `PG_PIN` |
| `check-host-api` | checks that `docs/host-api.ll` declares the whole host API (part of `installcheck`) |
| `installcheck-discard` | call-site and cache tests under `debug_discard_caches=1` |
| `installcheck-opt` | the kernel tests at `plllvm.opt_level` 0 and 3 |
| `installcheck-hazard PLLLVM_PORT=<port>` | tests that crash the server if their fix regresses; throwaway cluster only |
| `installcheck-plpgsql PLLLVM_PORT=<port>` | PostgreSQL's PL/pgSQL tests without plllvm, then with it loaded and `plllvm.expr_jit` off, on, and on with `plllvm.expr_eager`; every output must match the first. `PG_SRC` and `PG_BUILD` are the server's source and build tree (the workspace's `code/` and `code/build-jit`) |
| `kernels`, `check-kernels` | compile `examples/kernels/src/*.c` to IR with the install-perf headers; check the committed `.ll` files are current |
| `pgindent` | format the C sources (`docs/style.md`) |

The layout of the sources is in `docs/architecture.md`.

Built and tested only with PostgreSQL 20devel (`9510a826e4a`), LLVM 22.1.8,
macOS 26 arm64 (`PG_PIN`). The server must be built with LLVM.

## Licence

PostgreSQL Licence, see `LICENSE`. The kernels derived from the Computer
Language Benchmarks Game are under `LICENSES/BENCHMARKS-GAME-BSD-3.md`.

## Trademarks

PL/LLVM is an independent PostgreSQL extension. It is not affiliated with,
endorsed by or sponsored by the PostgreSQL Community Association or the LLVM
Foundation. Postgres and PostgreSQL are trademarks of the PostgreSQL
Community Association of Canada. LLVM is a trademark of the LLVM Foundation.
