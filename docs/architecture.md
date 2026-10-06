# plllvm architecture

One extension, `plllvm`, with no changes to PostgreSQL: the PL/LLVM
language (v0.1) and expression JIT for PL/pgSQL (v0.2).

## Files

| file | content |
|---|---|
| `src/plllvm.c` | module magic, `_PG_init` (GUCs, abort callbacks), call handler, validator |
| `src/plllvm.h` | internal declarations |
| `src/plllvm_host.h` | what JIT code shares with the server: version floor, layout probes, `plllvm_site`, the inline call protocol, out-of-line host functions; the only header of `plllvm_types.c`, hashed into the `.bc` version |
| `src/plllvm_jit.h` | the LLVM-facing API, the only header shared with C++ |
| `src/plllvm_error.cpp` | fatal-on-OOM sections (copy of core's `llvmjit_error.cpp`) |
| `src/plllvm_types.c` | inline host helpers and the version and layout constants, compiled to `plllvm_types.bc` only |
| `src/plllvm_runtime.c` | out-of-line host functions for errors, memory and arrays; frames; the JIT symbol table |
| `src/plllvm_jit.c` | LLVM session (checks `plllvm_types.bc`, target machine); LLJIT, compile pipeline, symbols, timings |
| `src/plllvm_compile.c` | funccache callbacks, signature and scope checks |
| `src/plllvm_spi.c` | read-only prepared statements: prepare into a slot, SELECT INTO, result checks (`plllvm_spi_*` host functions) |
| `src/plllvm_sites.c` | call sites and constants: resolution, rebuild, EXECUTE checks, invalidation callbacks (`plllvm_rt_site_*` host functions) |
| `src/plllvm_plpgsql.c` | the PL/pgSQL plugin: slot and chaining, `paramCompile` wrapper, trampolines on simple expressions, the Params of compiled code (`param_check`, `param_emit`); the only file that includes `plpgsql.h` |
| `src/plllvm_ir.c` | IR text builder: temporaries, blocks, declarations |
| `src/plllvm_expr.c` | planned expression tree to IR: the check (whole tree or nothing) and the emitter; knows neither LLVM nor PL/pgSQL |
| `src/plllvm_exprjit.c` | compiled expressions: key, stored tree and facts, cache, cap, the `ExprStateEvalFunc` wrapper, install |
| `src/plllvm_stats.c` | `plllvm_session_info()`, `plllvm_code_cache()`, `plllvm_call_sites()`, `plllvm_jit_test()`, `plllvm_function_status()`, `plllvm_expr_stats()` |

Only `plllvm_jit.c` and `plllvm_error.cpp` include LLVM headers.

## Terms

* **module**, **compile**: the code of one successful compile
  (`plllvm_jit_module`, in `plllvm_jit.c` wrapped as `JitCode` with its
  resource tracker); one row of `plllvm_code_cache()`. Its `kind` is
  `function` (PL/LLVM) or `expr` (PL/pgSQL expression).
* **program**: a compiled expression in `plllvm_exprjit.c`'s cache: key,
  copy of the tree, facts and module, or no module for a failed build.
* **released** (counted as **retired**): no funccache entry points at the
  module any more; the next compile frees it.
* **refs**: the call sites and constants of one module (`plllvm_refs`).
* **site**: one call site, its FmgrInfo and fcinfo (`plllvm_site`).
* **frame**: the scratch context of a running call (`plllvm_frame`).

## Runtime (v0.1)

* One LLJIT per backend, created with the session, RTDyld object layer with
  reserved allocation, no compile threads. Server symbols resolve through a
  process generator; plllvm's own host functions are hidden from `dlsym` and
  defined as absolute symbols.
* Each compile gets a fresh `LLVMContext`: parse `plllvm_types.bc` (helpers
  become `linkonce_odr`), parse the user IR, check the entry `@f`, the size
  and the user's declarations against the helpers, add the interrupt and
  stack checks its loops and recursions lack (`plllvm.auto_checks`), link,
  rename the entry to
  `plllvm_<oid>_<gen>`, internalise, verify, resolve every declaration,
  optimise, add with its own resource tracker, look up.
* When its funccache entry lets go of a module (the entry is stale and no
  call runs it, or the last call of a forgotten entry ends),
  `plllvm_jit_release()` marks it and releases its call sites. The next
  compile frees it: its statements, its module data and its tracker (as
  llvmjit, `LLVMOrcResourceTrackerRemove`). `plllvm.max_resident_compiles`
  caps the compiles not released. A failed add or lookup removes its tracker
  at once. Why nothing can reach freed code: `src/plllvm_jit.c`, note 4.
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
* A site follows its name, as a cached plan does: PROCOID and NAMESPACEOID
  invalidations make it rebuild, which resolves the signature again; role
  and database invalidations repeat the EXECUTE check. The executor's protocol is inline; recursion
  through a busy site gets a fresh FmgrInfo. Sites are released with their
  code.
* Memory: a body that declares a call, text or memory helper runs in a
  scratch context under the caller's context. Values kept with
  `plllvm_keep` live in the caller's context, as PL/pgSQL's datums.
* Handler order: take the caller's context; compile; SPI connect (a body
  that declares a `plllvm_spi_` function); push the frame; pin; run; copy
  a by-reference result out; pop; unpin; SPI finish. After an ERROR the
  abort pops the SPI level, as for PL/pgSQL.
* SQL: a statement is prepared on first use into a slot of the module and
  kept (`SPI_keepplan`) on the module's list, freed with the code. It runs
  read-only unless the function is VOLATILE; the result types are checked
  at every execution, as a saved plan may be replanned. Columns go to the
  caller's context.
* Arrays: `arg`, `new` and `copy` check the shape (flat, one dimension, no
  NULLs) once; the inline accessors check the element type and the
  subscript.
* The handler goes through core's funccache (`cached_function_compile`) and
  pins the entry during the call.
* The validator checks access, signature and scope, and (with
  `check_function_bodies`) parses, links and verifies the body without code
  generation.
* Out of scope for v0.1: other SQL than SELECT INTO, multi-dimensional
  arrays, sets, OUT parameters, records, polymorphic types,
  triggers, procedures, `DO`, trusted mode.

## PL/pgSQL plugin (v0.2)

* `_PG_init` takes the `PLpgSQL_plugin` rendezvous slot and keeps the
  previous occupant. Its `func_beg`, `func_end`, `stmt_beg` and `stmt_end`
  are forwarded only if it has them; before its `func_setup` it gets
  PL/pgSQL's helper pointers, which PL/pgSQL writes into the slot owner's
  struct only.
* `func_setup` (with `plllvm.expr_jit` on, not in a parallel worker)
  replaces `paramLI->paramCompile` with a wrapper. The wrapper runs inside
  `ExecInitExprWithParams()`; on the ExprState of a simple expression
  (`parent == NULL`, `expr == expr_simple_expr`) it puts a trampoline on
  the first `PARAM_CALLBACK` step.
* The trampoline re-arms itself at the first evaluation and fires at the
  second, after restoring the original paramfunc. `plllvm.expr_eager`
  fires at the first. A fired trampoline checks `plllvm.expr_jit` again
  and that `evalfunc` is still the interpreter's, then hands the ExprState
  to `plllvm_exprjit_install()`.
* `plpgsql_param_eval_var` is learnt as the paramfunc of a non-varlena
  variable; a second value turns the plugin off (`declined:paramfunc`).

## Expression JIT (v0.2)

* The tree compiled is `state->expr`, the planned tree, not the steps.
  `plllvm_expr_check()` walks it once (at most 64 nodes, every node
  supported, a native operator only where no fmgr hook wants the
  function) and produces the key and, through `param_check`, the facts:
  per Param its type, datum kind and length. A Param is taken only if it
  is a PL/pgSQL variable passed by value (`int4`, `int8`, `float8`,
  `bool`).
* Cache: a hash of the key (opt level, eager flag, tags with their kind
  and arity, functions, types) leads to the programs with that key; one
  is taken when its tree is `equal()` to the ExprState's and its facts
  match. Otherwise the tree is compiled, and a failed build is kept too,
  so it is not tried again.
  Programs are never freed; `plllvm.expr_max_programs` caps them and
  beyond it expressions stay interpreted. Stack too deep, an unsupported
  tree or a failed build leave the expression interpreted; only the
  session setup may raise an ERROR.
* Code: `define i64 @f(ptr %state, ptr %econtext, ptr %isnull)`, an
  `ExprStateEvalFunc` set as `state->evalfunc`. It reads a variable as
  `plpgsql_param_eval_var()` does, through `econtext`, the paramLI's
  `paramFetchArg` (the estate) and `datums[paramid - 1]`, with offsets of
  this library's compile of `plpgsql.h`. Operators are the
  `plllvm_ops.h` helpers of `plllvm_types.bc`; the result is boxed as a
  Datum (an `int4` sign extended), 0 when NULL. `AND`, `OR`, `CASE` and
  `COALESCE` branch to a block that joins the results with phis, so an
  argument the interpreter skips is not evaluated; a `select` would
  evaluate it, and it may raise an error.
* `plllvm_jit_compile_expr()` is the PL/LLVM compile with the other entry
  type, no call sites and no interrupt checks (an expression has no
  loops). Expression modules do not count in `plllvm_session_info()` or
  `plllvm.max_resident_compiles`.
