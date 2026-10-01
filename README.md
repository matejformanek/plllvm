# plllvm

PL/LLVM, a procedural language for PostgreSQL whose function bodies are LLVM IR.
The extension compiles them with its own ORC LLJIT and calls them with the
version 1 calling convention. It is written for a master's thesis on JIT
compilation of PL/pgSQL (FIT ČVUT, supervisor Pavel Stěhule) and needs no
changes to PostgreSQL.

**Status: v0.1 in progress.** Functions in `LANGUAGE plllvm` are checked at
`CREATE FUNCTION`, compiled with plllvm's own LLJIT at their first call in a
session, and run. `examples/kernels/` has four benchmark kernels written by
hand in IR.

## Features

v0.1:

* `LANGUAGE plllvm`: the body is an LLVM IR module with an entry
  `define i64 @f(ptr %fcinfo)`, called as a version 1 function.
* A small host API (argument and NULL access, errors, interrupts) that the IR
  declares and the validator checks against the extension's helper bitcode.
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
process. Names starting with `plllvm_` cannot be defined. The validator
parses and verifies the body; with `check_function_bodies = off` the first
call does. Errors inside the body point into it.

`plllvm_function_status(fn regprocedure)` (superuser) gives the `state` of
a function's code in this backend, `not_compiled`, `live`, `stale` (the
definition changed since the compile), `retired` (replaced) or `dropped`,
with the numbers of its compiles and retired compiles.

`plllvm_jit_test(ir text, opt_level int DEFAULT
NULL, codegen bool DEFAULT true)` (superuser) compiles a function body and
returns the outcome as a row: `ok`, the SQLSTATE, message and detail of a
refusal, the line and column of a parse error, and the instruction and helper
counts. With `codegen => false` it only checks the IR. Its code stays resident
like any other compile.

```sql
SELECT ok, gen, helpers_linked
  FROM plllvm_jit_test('define i64 @f(ptr %fcinfo) { ret i64 0 }');
```

`plllvm_code_cache()` (superuser) lists the compiled code of the session,
newest first, with the time of each compile stage (`parse_bc`, `parse`,
`link`, `verify`, `optimize`, `emit`; code is generated at the lookup in
`emit`).
## Limits

* Functions only: no procedures, window functions, triggers or set-returning
  functions; no OUT parameters; no composite, domain or pseudo-type results
  other than `void`, and no composite or pseudo-type arguments.
* Compiled code is never freed during a session, not even when the function
  is replaced or dropped (see `plllvm.max_resident_compiles`).
* Every backend compiles its own copy; status and counters are per backend.

Built and tested only with PostgreSQL 20devel at commit `9510a826e4a`,
LLVM 22, macOS arm64 (see `PG_PIN`). The server must be built with LLVM; the
extension links the same shared `libLLVM` as the server's `llvmjit`.

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
* `plllvm.max_resident_compiles` (int, default 2000, superuser): compiled code
  is never freed during a session, not even when a function is replaced. When
  this many compiles are resident, the next one fails with SQLSTATE 53400
  until the session reconnects.
* `plllvm.max_ir_instructions` (int, default 100000, 0 = no limit,
  superuser): the largest function body accepted (SQLSTATE 54000).
* `plllvm.debug_inject` (`none`, `llvm_fatal`, `bad_alloc`, superuser): for
  tests only. Raises that LLVM error in the next compile, which ends the
  session with FATAL.

The prefix `plllvm.` is reserved.

`plllvm_session_info()` (superuser) shows the LLVM version, target triple and
data layout of the session, the libLLVM and `plllvm_types.bc` it loaded, how
long the setup took, the numbers of compiles, failed compiles and retired
code, and the resident size of the backend (`rss_bytes`, macOS only). It sets
the session up if needed, so it also checks the installation.

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
`make pgindent` formats the C sources (`docs/style.md`).

## Checked on

* PostgreSQL 20devel (9510a826e4a), LLVM 22.1.8, macOS 26 arm64

## Licence

PostgreSQL Licence, see `LICENSE`.
