# plllvm

PL/LLVM, a procedural language for PostgreSQL whose function bodies are LLVM IR.
The extension compiles them with its own ORC LLJIT and calls them with the
version 1 calling convention. It is written for a master's thesis on JIT
compilation of PL/pgSQL (FIT ČVUT, supervisor Pavel Stěhule) and needs no
changes to PostgreSQL.

**Status: v0.1 in progress.** The extension installs and creates the language,
but the handler and the validator only raise "PL/LLVM functions are not
implemented yet".

## Features

Planned for v0.1:

* `LANGUAGE plllvm`: the body is an LLVM IR module with an entry
  `define i64 @<name>(ptr %fcinfo)`.
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

## Limits

Built and tested only with PostgreSQL 20devel at commit `9510a826e4a`,
LLVM 22, macOS arm64 (see `PG_PIN`). The server must be built with LLVM; the
extension links the same shared `libLLVM` as the server's `llvmjit`.

## Configuration

* `plllvm.regress_test_mode` (bool, default off, any user): reduces volatile
  output in regression tests.
* `plllvm.types_bc_path` (string, default empty, superuser): the
  `plllvm_types.bc` to use. Empty means `plllvm/plllvm_types.bc` next to the
  loaded library. A session reads it once, when it first needs LLVM.

The prefix `plllvm.` is reserved.

`plllvm_session_info()` (superuser) shows the LLVM version, target triple and
data layout of the session, the libLLVM and `plllvm_types.bc` it loaded, and
how long the setup took. It sets the session up if needed, so it also checks
the installation.

## Compilation

```
make PG_CONFIG=/path/to/pg_config [LLVM=/opt/homebrew/opt/llvm@22]
make PG_CONFIG=/path/to/pg_config install
make PG_CONFIG=/path/to/pg_config installcheck PLLLVM_PORT=
```

`LLVM` must be the LLVM the server was built with. Empty `PLLLVM_PORT` lets
`installcheck` use `PGHOST`/`PGPORT`.

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
