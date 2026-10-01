# plllvm architecture

One extension, `plllvm`, with no changes to PostgreSQL. v0.1 is the PL/LLVM
language only; everything else depends on the thesis plan.

## Files

| file | content |
|---|---|
| `src/plllvm.c` | module magic, `_PG_init` (GUCs, abort callbacks), call handler, validator |
| `src/plllvm.h` | internal declarations, version floor |
| `src/plllvm_jit.h` | the LLVM-facing API, the only header shared with C++ |
| `src/plllvm_error.cpp` | fatal-on-OOM sections (copy of core's `llvmjit_error.cpp`) |
| `src/plllvm_types.c` | inline host helpers and the version and layout constants, compiled to `plllvm_types.bc` only |
| `src/plllvm_runtime.c` | out-of-line host functions and the JIT symbol table |
| `src/plllvm_jit.c` | LLVM session (checks `plllvm_types.bc`, target machine); LLJIT, compile pipeline, symbols, timings |
| `src/plllvm_compile.c` | funccache callbacks, signature and scope checks (PR 3) |
| `src/plllvm_sites.c` | call sites and constants: resolution, rebuild, EXECUTE checks, invalidation callbacks |
| `src/plllvm_stats.c` | `plllvm_session_info()`, `plllvm_code_cache()`, `plllvm_jit_test()`, `plllvm_function_status()` (PR 3) |

Only `plllvm_jit.c` and `plllvm_error.cpp` include LLVM headers.

## Runtime (v0.1)

* One LLJIT per backend, created with the session, RTDyld object layer with
  reserved allocation, no compile threads. Server symbols resolve through a
  process generator; plllvm's own host functions are hidden from `dlsym` and
  defined as absolute symbols.
* Each compile gets a fresh `LLVMContext`: parse `plllvm_types.bc` (helpers
  become `linkonce_odr`), parse the user IR, check the entry `@f`, the size
  and the user's declarations against the helpers, link, rename the entry to
  `plllvm_<oid>_<gen>`, internalise, verify, resolve every declaration,
  optimise, add with its own resource tracker, look up.
* Compiled code is never freed in v0.1: a successful compile keeps its
  tracker for the session, and `plllvm_jit_retire()` only marks it.
  `plllvm.max_resident_compiles` caps the number of resident compiles. A
  failed add or lookup removes its tracker at once.
* Every LLVM call runs inside a fatal-on-OOM section that never raises an
  ERROR; failures are returned and raised after leaving it. JIT-compiled code
  never runs inside a section.

## Language

* V1 entry `define i64 @f(ptr %fcinfo)`; the IR declares the host helpers it
  uses (`docs/host-api.ll`).
* Calls: a declared global named by `regprocedure` text is a call site, one
  named `'literal'::type` a constant. After verify, `build()` leaves its
  section and resolves them with PostgreSQL's own errors, under the
  function's `SET search_path` or `pg_catalog, <schema>, pg_temp`. A site
  global becomes the address of its record (FmgrInfo and fcinfo), each
  `plllvm_const` call the constant's Datum.
* A site is bound by OID for the session. PROCOID invalidations make it
  rebuild (re-resolving a dropped callee), role and database invalidations
  repeat the EXECUTE check. The executor's protocol is inline; recursion
  through a busy site gets a fresh FmgrInfo. Sites are released with their
  code.
* Memory: a body that declares a call, text or memory helper runs in a
  scratch context under the caller's context. Values kept with
  `plllvm_keep` live in the caller's context, as PL/pgSQL's datums.
* Handler order: take the caller's context; compile; (SPI connect, later);
  push the frame; pin; run; copy a by-reference result out; pop; unpin.
* The handler goes through core's funccache (`cached_function_compile`) and
  pins the entry during the call.
* The validator checks access, signature and scope, and (with
  `check_function_bodies`) parses, links and verifies the body without code
  generation.
* Out of scope for v0.1: sets, OUT parameters, records, polymorphic types,
  triggers, procedures, `DO`, trusted mode.
