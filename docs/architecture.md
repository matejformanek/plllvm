# plllvm architecture

One extension, `plllvm`, with no changes to PostgreSQL. v0.1 is the PL/LLVM
language only; everything else depends on the thesis plan.

## Files

| file | content |
|---|---|
| `src/plllvm.c` | module magic, `_PG_init` (GUCs), call handler, validator |
| `src/plllvm.h` | internal declarations, version floor |
| `src/plllvm_jit.h` | the LLVM-facing API, the only header shared with C++ |
| `src/plllvm_error.cpp` | fatal-on-OOM sections (copy of core's `llvmjit_error.cpp`) |
| `src/plllvm_types.c` | host types and helpers, compiled to `plllvm_types.bc` only (PR 1) |
| `src/plllvm_jit.c` | LLJIT session, compile pipeline, symbols, timings (PR 2) |
| `src/plllvm_compile.c` | funccache callbacks, signature and scope checks (PR 3) |
| `src/plllvm_sites.c`, `src/plllvm_runtime.c` | calls to other functions, host helpers (PR 4) |
| `src/plllvm_stats.c` | `plllvm_session_info()`, `plllvm_code_cache()`, `plllvm_function_status()` |

Only `plllvm_jit.c` and `plllvm_error.cpp` include LLVM headers.

## Runtime (v0.1)

* One LLJIT per backend, created lazily, RTDyld object layer, no compile
  threads.
* Each compile gets a fresh `LLVMContext`: parse `plllvm_types.bc`, parse the
  user IR, check the user's declarations against the helpers, link, rename
  the entry to `plllvm_<oid>_<gen>_<n>`, internalise, verify, optimise, add
  with its own resource tracker, look up.
* Compiled code is never freed in v0.1; a GUC caps the number of resident
  compiles.
* Every LLVM call runs inside a fatal-on-OOM section; JIT-compiled code never
  does.

## Language

* V1 entry `define i64 @f(ptr %fcinfo)`; the IR declares the host helpers it
  uses.
* The handler goes through core's funccache (`cached_function_compile`) and
  pins the entry during the call.
* The validator checks access, signature and scope, and (with
  `check_function_bodies`) parses, links and verifies the body without code
  generation.
* Out of scope for v0.1: sets, OUT parameters, records, polymorphic types,
  triggers, procedures, `DO`, trusted mode.
