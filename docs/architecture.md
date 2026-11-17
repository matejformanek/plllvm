# plllvm architecture

One extension, `plllvm`, with no changes to PostgreSQL: the PL/LLVM
language (v0.1), expression JIT for PL/pgSQL (v0.2) and `LANGUAGE
plpgsql_jit` (v0.3).

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
| `src/plllvm_plpgsql.c` | the PL/pgSQL plugin: slot and chaining, `paramCompile` wrapper, trampolines on simple expressions, the Params of compiled code (`param_check`, `param_emit`); with `plllvm_pj.c`, the only file that includes `plpgsql.h` |
| `src/plllvm_pj.c`, `src/plllvm_pj.h` | `LANGUAGE plpgsql_jit`: the call handler, the side entry of each PL/pgSQL function, translation in a subtransaction, guards, the error context, the counters of `plllvm_pj_stats()`; includes `plpgsql.h` |
| `src/plllvm_pj_boxed.c` | `plpgsql_jit`: the expressions the compiler does not do, run by the executor on the translator's copy of the planned tree, and the per-transaction state they use; includes no `plpgsql.h` |
| `src/plllvm_pj_sites.c` | `plpgsql_jit`: the sites, the calls compiled code makes through fmgr and the I/O functions, built per level and transaction; includes no `plpgsql.h` |
| `src/plllvm_pj_sql.c` | `plpgsql_jit`: the SQL statements of a function, run by SPI on PL/pgSQL's plans: the shadow estate, the parameter lists, the execution and its result codes, the checks of a statement's plan; includes `plpgsql.h` |
| `src/plllvm_pj_translate.c` | `plpgsql_jit`: scope of a function, the planned trees of its expressions, the casts to their targets, the IR of a function (statements, loops, labels, positions); includes `plpgsql.h` |
| `src/plllvm_ir.c` | IR text builder: temporaries, blocks, declarations |
| `src/plllvm_expr.c` | planned expression tree to IR: the check (whole tree or nothing) and the emitter; knows neither LLVM nor PL/pgSQL |
| `src/plllvm_exprjit.c` | compiled expressions: key, stored tree and facts, cache, cap, the `ExprStateEvalFunc` wrapper, install |
| `src/plllvm_stats.c` | `plllvm_session_info()`, `plllvm_code_cache()`, `plllvm_call_sites()`, `plllvm_jit_test()`, `plllvm_function_status()`, `plllvm_expr_stats()`, `plllvm_pj_stats()`, `plllvm_pj_status()` |

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

## LANGUAGE plpgsql_jit (v0.3)

* `plllvm--0.3.sql` creates the language with `plpgsql_jit_call_handler`
  (`plllvm_pj_call_handler`) and, as inline handler and validator, two
  `pg_proc` rows that point into `$libdir/plpgsql`
  (`plpgsql_inline_handler`, `plpgsql_validator`). Not `TRUSTED`.
* The handler looks up `plpgsql_compile` and `plpgsql_call_handler` in the
  plpgsql library at its first call. It compiles with `plpgsql_compile()`
  (no SPI connection needed, `pl_comp.c` has no `SPI_` call), keeps a side
  entry per `PLpgSQL_function` in its own hash table, and calls
  `plpgsql_call_handler()` with the same `fcinfo`; `fn_extra` stays
  PL/pgSQL's.
* An entry is stale when its function's `fn_cxt` has gone: a reset callback
  sets the flag, and the next lookup of the same pointer (funccache reuses a
  struct in place) starts a new entry. A declined function is found by its
  `fn_extra` without compiling again.
* `plllvm.plpgsql_jit` off sends the call to PL/pgSQL before any entry is
  looked at.
* The first call of a function is PL/pgSQL's, which plans what it runs. The
  second reads the planned trees (`expr_simple_expr`) of the expressions the
  run can reach and translates the function if it is in scope; a function
  out of scope is declined with the reason and stays in PL/pgSQL until its
  entry is stale. The translation runs in a subtransaction with no frame of
  the function on the stack: an ERROR declines the function, a cancel is
  raised again.
* The code is `i64 (fcinfo, ctx)` with a slot (Datum and null flag) per
  variable. Before each step that can raise it stores an index of a position
  table in `ctx`, from which the handler writes the error context of
  `plpgsql_exec_error_callback`. A value is converted to the result type by
  the cast tree PL/pgSQL would build, cached per pair of types and typmods,
  but only by a cast that cannot raise: widening int4 to int8 or float8, int8
  to float8, int4 or int8 to numeric, name to text, or a relabeling through a
  pinned `pg_cast` row; or, for a constant, a
  conversion of built-in immutable functions that runs when the function is
  translated (an error there declines the function). The one that can raise
  is `numeric(numeric,int4)` of a `numeric(p,s)` target, from a numeric, int4
  or int8. The code stores the position of the statement or variable before
  it, naming no expression: PL/pgSQL fails in its cast after the expression is
  done, and leaves that expression idle. Any other cast declines (`cast`), so
  the cast of a default or a RETURN that fails is PL/pgSQL's own.
  The coercion of `:=` to `varchar(n)` or `numeric(p,s)` is a function in the
  assignment's own expression: it runs as a callee and raises from compiled
  code with PL/pgSQL's SQLSTATE and CONTEXT, and a caught error marks the
  expression as any. A domain
  is never a target: a variable of a domain type declines the function.
* A variable of a built-in base type passed by reference, or an array of one
  (not composite, domain or `refcursor`), has a slot of three parts: the
  Datum, a null flag and a flag that the copy is ours. An argument is the caller's:
  the flag is false and it is never freed. An assignment copies the value
  into the datum context of the activation level (`datum_cxt`, under the
  level's context, reset when a call first uses the level), then frees the
  old copy if it is ours (`plllvm_pj_assign()`). What the evaluation allocated
  is reset only after that, as the value lives in it. A block frees its
  variables at entry and starts them NULL. A bare constant or variable is
  moved without the executor, and a constant cast to such a type is folded
  at translation and copied at the store. An ERROR deletes the level.
* An array is such a variable that is always kept in expanded form: the
  assignment (`plllvm_pj_assign_array()`) reparents an expanded object the
  executor returned and expands anything else, and an argument is expanded
  once at entry, as PL/pgSQL does, so that a compressed or external one is not
  detoasted at every subscript. The datum context is released when the call
  ends, after the result is copied out, and goes with the level on an ERROR.
* The read `a[i]` and the store `a[i] := e` of a variable of type `int4[]`,
  `int8[]` or `float8[]`, with one subscript, are compiled when the store is
  the whole expression of an assignment to that variable (the parameter is
  the assignment target, as the in-place rule has it).
  * The order is the interpreter's: a NULL array reads NULL without the
    subscript being evaluated, and a store checks its subscript, which must
    not be NULL (22004), before it computes the value.
  * The inline helpers of `plllvm_types.c` read and write an expanded
    one-dimensional array that has its Datums: bounds from the lower bound,
    the null bitmap, and for a store in range the four changes of
    `array_set_element_expanded()` (`fvalue` and `flat_size` cleared, the
    Datum set, the null flag cleared).
  * Any other array goes to `plllvm_pj_elem_get_slow()` or
    `plllvm_pj_elem_set_slow()`, which call `array_get_element()` and
    `array_set_element()`, and are counted in `elem_slow` of
    `plllvm_pj_stats()`: an array just expanded has no Datums until the first
    access makes them; a NULL array, an empty one, a two-dimensional one, a
    NULL value and a subscript past either end are always slow.
  * A NULL array that is stored into is replaced by an empty one and expanded
    into the datum context, and the flat arrays of that are reset at once.
  * The null flag of a read goes to one slot of the function (`%en`), which
    the inlined helper is the only user of; the slow function returns its
    answer by value, so that no pointer escapes.
  * The result of a store is the slot's own array, and the code keeps it
    without `plllvm_pj_assign_array()`, then runs the reset that a call in
    the value left.
* Any other expression that reads or writes an array stays with the executor,
  which is given the variable read-only: a slice, a second subscript, a
  constructor, an array function, a call or a conversion that is given the
  array, an element of another array type. The one Param that is passed
  read/write is that of the assignment target that the in-place rule of
  PL/pgSQL allows to be modified: the top-level function has a support
  function for `SupportRequestModifyInPlace` (a subscripted assignment,
  `array_append`). It is passed read/write through a twin of the parameter,
  with an id after the datums, which exists in the harvest's copy of the tree
  only; the slot keeps the array. The twin is made for every expression that
  is compiled or goes to the executor, as `pj_codegen = boxed` runs the same
  tree through the executor and would copy the array at every store otherwise;
  the code of a compiled store reads the datum of the twin's id. The rule that
  hands the object to any function that holds the only reference is not
  applied: a callee that takes it frees it, and the slot would hold a freed
  array.
* A variant whose only array work is compiled is restartable, as one with no
  array: its arguments are copies, a store lands in the arrays of the
  activation, which the handler gives up before it starts the interpreter
  again, and the code of an element runs no function of the user and never
  sets `evaluated`. One with an expression of the executor, or a call, has no
  deopt point. A deopt point is a whole expression, so none falls inside a
  store.
* A constant text assigned to an array of `bool`, `int2`, `int4`, `int8`,
  `float4`, `float8`, `numeric` or `text` (these eight only) is converted by
  `array_in` when the function is translated, if the cast is the I/O
  conversion (the input of other types reads a setting, a date's DateStyle);
  an error there declines the function. An array of a type of the user and a
  domain over an array decline the function, and so does an implicit
  conversion of an array in a DECLARE default or a RETURN; at an assignment
  the conversion is part of its expression and compiles. `int2vector` and
  `oidvector` from a constant text decline as `cast`.
* RAISE without `USING` is a few calls of the host: one starts the message in
  a context of the activation level, then for each `%` the code evaluates the
  parameter, prints it with the output function of its type
  (`plllvm_pj_raise_param()`) and releases what the evaluation allocated,
  as `exec_stmt_raise()` does, and the last call sends the message. The
  message is built whether or not the level would be sent, so a parameter is
  evaluated, and can fail, at any level. While the parameters run, the
  position is the expression's, so an error marks it as PL/pgSQL does; the
  conversion and the message are positioned at the statement, as nothing is
  marked by then. The condition name is turned into a SQLSTATE at
  translation, by PL/pgSQL's own function. A RAISE at ERROR, and one with
  nothing to raise (outside a handler, which these functions have none), end
  the function; one below ERROR has sent a message, so like a site it leaves
  no deopt point to a variant that has an expression unplanned, and the
  function waits.
* A simple CASE keeps its selector in a variable of the function, which
  PL/pgSQL declares `int4` and retypes to the type of the value when it
  runs. The harvest keeps a copy of that variable with the type of the
  selector's plan, built by PL/pgSQL's own function, and every reader of a
  datum (slots, parameters of the executor, entry stores, the assignment of
  a value passed by reference) goes through it, so the WHENs, which carry a
  Param of that type, are read right. A selector of a domain, an array or a
  type we keep in no slot declines the function, and so does a statement
  that names the variable outside its WHENs. A WHEN counts as not planned
  while its selector is not. The variable is NULL again before an arm runs
  and before the ELSE. A CASE without an ELSE that matches nothing raises
  from the statement, which names no expression, so the call after it is
  not sent to PL/pgSQL.
* `SELECT` *expression* `INTO` a variable is the one SQL statement that
  PL/pgSQL runs without SPI, when its query is a simple expression and the
  target is one variable (`exec_stmt_execsql`). It is an assignment whose
  value converts to the type of the target as a DECLARE default does, and
  sets FOUND. Whether the query is simple is for its plan to say: one that
  is not (a `FROM`, an aggregate, a set-returning function, or an error at
  plan time) declines the function as `not simple`, once it has been
  planned. The context lines are PL/pgSQL's: while the expression runs, and
  while its executor state is built, the query is part of the context
  (`SQL statement "..."`, from the position of the expression and of the
  build); the conversion, the NOT NULL check and the copy come after
  PL/pgSQL has left the query, so they are positioned at the statement.
* `PERFORM`, a statement with no `INTO` and a `SELECT INTO` that PL/pgSQL does
  not evaluate as an expression are run by SPI from compiled
  code, on `expr->plan`, the plan the interpreter prepared. PL/pgSQL's
  statement runners are `static` and its plugin hooks only observe, so the
  code does what `exec_stmt_perform()` and `exec_stmt_execsql()` do around
  `SPI_execute_plan_with_paramlist()` (`plllvm_pj_sql.c`). It never prepares a
  plan and never writes a `PLpgSQL_expr`, so a call of either path counts
  towards the same five custom plans of the plan source.
  * A statement is harvested when its plan exists and is valid. A function
    whose only unplanned statement is in a branch no call took waits, as one
    with a call does, since a statement that has run cannot run twice.
  * The parameter list is NULL exactly when `expr->paramnos` is empty
    (`setup_param_list()`: a list makes the planner build custom plans), and
    otherwise holds the variables of `paramnos` and "no such parameter" in
    every other slot, without hooks, which a parallel worker needs. Compiled
    code stores the variables into it as it does for the executor.
  * An analysis of the statement inside the call runs the parser hooks of
    PL/pgSQL, which read `func->cur_estate`, and compiled code has none. A
    shadow estate, built once per harvest from copies of the variables and
    records (`copy_plpgsql_datums()`; the function's own datums are never
    handed out), stands in for it while SPI runs, and is taken away in
    `PG_FINALLY`.
  * SPI is connected, atomically, by the first statement of a call and
    finished by `run()` after the result is copied out. FOUND takes the answer
    of the command code as PL/pgSQL gives it; a SELECT with no `INTO` raises
    its 42601 with PL/pgSQL's HINT; PERFORM has its two messages. The tuples
    are freed after each statement.
  * `SELECT INTO` of scalar variables, one or several, `STRICT` or not, is
    `exec_stmt_execsql()` after the call: two rows are asked for when the
    statement is `STRICT` or `plpgsql.extra_errors` or `extra_warnings` has
    `too_many_rows`, else one; no row or two rows under `STRICT` raise P0002
    and P0003 with PL/pgSQL's HINT; and the first row goes to the variables as
    `exec_move_row()` moves it into a row: dropped columns are skipped, a
    target with no column gets NULL, `strict_multi_assignment` finds the
    columns that are too few or too many, and a NOT NULL variable raises 22004.
    FOUND is stored before the targets, as there. The extra checks are read
    from the two settings once per call, at the first `INTO`, where PL/pgSQL
    reads them at each statement; they change in a call only through
    `set_config()`, which is not admitted, or through a function that is not
    what it says it is. A query into one variable that PL/pgSQL runs as an
    expression is still the expression of the previous bullets; one whose plan
    says it is not an expression is the statement of this one, decided from
    its plan at each translation.
  * The value of a column goes to its variable without a cast, so the code is
    admitted only if each column has the type of its variable (and its typmod,
    unless the variable has none); a cast that PL/pgSQL would run declines the
    function (`cast`), as does `#print_strict_params on`, whose DETAIL is not
    ported. A target takes a NULL for no row or a missing column without a
    cast; PL/pgSQL calls the input function of its type for it (a function
    that is not strict must return NULL for a NULL, but may have an effect),
    so the function is declined unless that input function is strict. A column whose type changed after the
    statement was admitted is still converted, by the cast PL/pgSQL would
    use (`plllvm_pj_convert()`); the plan is then no longer what it was
    admitted as (`sql_stale`), and the next call translates again, and is
    declined if the cast is no longer none. Where PL/pgSQL marks the cast
    state of the variable after a failure of that conversion, we do not. The
    conversion raises "no cast from type" for a column of type `unknown` or
    `record`, where PL/pgSQL falls back to an I/O coercion; no such column can
    appear after admission (a table has none, and a result column of those
    types has no variable of its type to be admitted for), so this is stated
    and not pinned.
  * A function whose tables are truncated and analysed before every call (a
    benchmark's reset) finds the plans of its statements stale at each call
    start, so no translation could see them valid. A call that finds only SQL
    statements stale, or unplanned, is translated after the interpreter has
    run it, which plans them again as it goes (`fall_back_retry()`; the flag
    is read before the call, since a nested call of the function overwrites
    it); the next call runs compiled, and SPI analyses the stale plans inside
    the call, unless a statement reads a view or writes: the entry check
    misses on a stale plan of either. A view with a reset before every call
    alternates these translations with guard misses until the function is
    declined as thrashing (about eight translations). A statement that writes
    is not translated again for a stale plan: that call goes to the
    interpreter (`interpreted:stale plan`, no translation, not counted towards
    thrashing), which plans it, and the next call that finds a valid plan
    checks the facts on it (a plan that a failed planning left valid with the
    old `generation` is walked too, `PjSql.rewalk`). A write in a branch that
    no call takes keeps a stale plan, so every call goes to the interpreter
    for the price of the guard. A table that is truncated or analysed between
    rounds of calls (autovacuum included) therefore costs the interpreter one
    call per round and no LLVM work; a reset before every call, with none
    between, never runs compiled and is not declined (`psd_reset1`). A
    statement in a branch that no call takes between two resets stays
    unplanned and keeps the function waiting; each of its calls then pays two
    walks of the function for the classification plus `plpgsql_compile()`.
  * Admission: every query of the plan, rewritten, is a SELECT, INSERT, UPDATE
    or DELETE (a data-modifying CTE is a query of its own, so the rule below
    applies to its result relation too; MERGE and every other command are
    PL/pgSQL's), calls no VOLATILE function but the built-in ones that change
    no input of a plan (`nextval`, `random`, the clocks, `pg_sleep`; not
    `set_config`), and the function is not `#variable_conflict use_column`,
    under which a new analysis could bind a name to a variable the list does
    not have. The trigger, rule and constraint code of a table that is written
    is code no walk of the query shows, so a table that is written must be a
    plain table with no trigger of a user, no rule, no foreign-key action that
    changes rows (cascade, SET NULL, SET DEFAULT), no children, no CHECK
    constraint of the table, or domain constraint that the query shows (a
    coercion to a domain, also inside a table's CHECK), that calls a VOLATILE
    function, and not a partition root or a foreign table (reasons
    `relation:trigger`, `rule`, `cascade`, `inheritance`, `partitioned`,
    `foreign table`, `check`, `kind`). A domain constraint that runs inside an
    input function (`record_in`, `array_in`, `domain_in`,
    `jsonb_populate_record`) is a stated gap: those functions are STABLE, so
    the walk admits them. `pg_class` keeps `relhasrules` until a VACUUM and
    `relhassubclass` until an ANALYZE, so a table whose last rule or child was
    dropped is still declined until then. The checks of a foreign key (the
    insert side, NO ACTION and RESTRICT) and of a deferrable unique constraint
    are internal code that changes no row, so they pass. A view is written
    through its rewrite, so its base table is the one tested (an INSTEAD OF
    trigger is a trigger of the view, which has none in the plan: that case is
    declined as `relation:kind`). The catalogs are read without a lock on the
    table: a trigger, rule, default, check or child of the table invalidates
    the plan. A function that only a CHECK or domain constraint calls is no
    dependency of the plan, so a change of its volatility (`ALTER FUNCTION ...
    VOLATILE`) is not seen until something else makes the plan stale; this is
    a stated gap. The walk is made again whenever a plan was built since the
    last look, so a table with foreign-key triggers pays a scan of
    `pg_trigger` for each custom plan the statement builds; the cost is small
    beside the planning it follows. A command with INTO has a row limit of
    two, as in PL/pgSQL, whose error for a second row is P0003.
  * A statement that writes with an invalid plan is a guard miss, not a plan
    SPI analyses again: a default, a generated column, a trigger or a rule is
    new then and no walk of the old query shows it. The function goes to
    PL/pgSQL for that call, which analyses the plan; the next call re-walks
    the new plan, and runs compiled if the facts hold and is translated (and
    declined) if they do not. Nothing the code embeds depends on the plan but
    these facts: the plan source, the targets, the result columns and the row
    limit are the function's own or are checked by the walk. A statement that
    a rule turned into nothing has no query, and the command tag says that it
    writes.
  * A plan that is invalid is run, since SPI analyses it again by itself: it
    is how a function whose table is truncated and analysed between calls
    stays compiled. The entry check refuses (a guard miss) a changed
    `search_path`, a role or `row_security` that the rewrite depends on,
    other `paramnos`, and, when the plan is invalid, a callee whose
    `provolatile` changed or a view among the relations. When it is valid it
    compares `generation` of the plan source with the one last seen, which
    moves with every plan built (an interpreted call may have rebuilt it):
    then the admission walk is made again over the current query list. After
    each execution the same comparison finds an analysis done inside the
    call; the address of the new query list is no sign, since the old one is
    deleted first and the new one can take its place. A new query list is
    followed by a plan, and so by a new `generation`, unless that plan fails
    to build (a custom plan that raises): the next call then runs the list once
    unchecked, and the check after that execution finds it. A statement found no
    longer admitted ends the call as it was and makes the next call
    translate (`sql_stale`).
  * `sql_stale` is exact for a statement found changed after an execution;
    for a function replaced by code a statement ran it is counted only when
    a function or privilege changed during the statement (`exec_epoch`), not
    after every statement.
  * Compiled SQL never runs under `debug_discard_caches`: every plan is stale
    there, so the code translates nothing. The shadow estate under that setting
    was tried by the spike only; `pj_sql_replan` is what the tests use.
  * Differences: a function replaced by code a statement runs stales the plan
    of a later expression of the call, which goes on with its tree where
    PL/pgSQL plans it again; a privilege lost in a statement is raised at
    once (`key_recheck`), as after an expression of the executor.
* Statements are walked twice in the same order, skipping what a RETURN, EXIT,
  CONTINUE or RAISE that raises makes unreachable: the first walk collects the expressions and
  positions, the second emits code and takes the expressions back in that
  order. An expression PL/pgSQL has not planned becomes a deopt point: the code
  stores its index in `ctx` and returns, the handler runs the call in PL/pgSQL,
  and the function is translated again once that expression is planned. FOR
  over integers keeps its counter, end and step apart from the loop variable,
  and FOUND is set as `exec_stmt_fori` does at every way out. The code polls for interrupts
  at entry and once per loop iteration, after the position of the first
  statement of the body. A WHILE stores its position again at the head, only
  if its condition can raise.
* A compiled call checks, in this order: no NULL argument (PL/pgSQL runs
  it), every plan still simply valid with the generation it had, a variant
  for the session's `plllvm.pj_opt_level`, and the EXECUTE right on every
  function of the trees and the cast. The last is kept as a key of
  (transaction, user, epoch of the catalogs it depends on), read before the
  check; when the key differs all functions are checked again, and a denial
  sends the call to PL/pgSQL, which raises it. After a compiled error the
  expression it stopped is marked as an interpreted failure leaves it (see
  Marks below). A guard that misses sends the call to
  PL/pgSQL and the next call translates again; eight misses with fewer than
  1,000 compiled calls between decline the function (`thrash`).
* A call of a function the compiler has no operator for, an operator on another
  type, and a conversion through the I/O functions (`CoerceViaIO`, with a
  strict input function and no domain) are sites. A site is what the executor
  builds for the node, an `FmgrInfo` and a `FunctionCallInfo` with the node as
  `fn_expr`, owned by an activation level and the transaction, so that
  `track_functions` and the properties of the function are read when the
  transaction first reaches it. The code evaluates the arguments, stores them
  into the site's `fcinfo`, and `plllvm_pj_invoke()` (inline, `plllvm_types.c`)
  does the strict test and the call. A `Param` or `Const` of a type with no
  native representation is an argument as its Datum, and so is a result of one,
  so a `RETURN` of a type passed by reference needs no executor.
* A call through a site may do anything: send a message, run SQL, run code of a
  user. So after the first one the call cannot start again in PL/pgSQL, and a
  variant with a site has no deopt point; with an expression still unplanned
  the function waits in PL/pgSQL rather than compiling and deopting, as it
  does after the executor ran. The
  compiled code does not reason about which built-ins are silent. After the
  expression the code checks EXECUTE again, as the executor path does, and polls
  before the next statement. A pinned IMMUTABLE function can still run user code
  through a text search configuration with user dictionaries; such a call also
  gets no deopt and the recheck. The bare calls of `pj_codegen = v1`, which are
  built-in operators, keep their deopts. The first site of a call switches to the level's per-tuple
  memory, where the callee allocates; every expression with a call frees it once
  its value is out, the `RETURN`'s is the handler's to copy.
* An expression that needs a snapshot of its own (a stable or volatile function
  in a `VOLATILE` function) is the executor's; so is everything else the
  compiler refuses, evaluated as
  `exec_eval_simple_expr()` does: the code stores the variables the tree
  reads into a `ParamListInfo`, `plllvm_pj_boxed_eval()` runs the
  `ExprState` made from the tree copy, and the per-tuple memory is reset once
  the value is out. The `ExprState`s, parameters and expression context of one
  activation level of a variant (`use_count - 1`, so recursion has a level
  per frame) hang under an `EState` of the transaction and go with it; an
  ERROR deletes the level it crosses. A tree that calls a volatile function
  is declined. A result of a type passed by reference is copied out of the
  level by the handler.
* Once the executor has run, user code has run, and a call cannot start
  again in PL/pgSQL. A variant with such expressions has no deopt point, so
  with an expression still unplanned the function waits in PL/pgSQL until
  all are planned (`waiting`). After the executor ran, the code compares the
  user and the epoch of the catalogs with those of the call, checks the
  functions again if they differ and raises if one is denied; an
  `ExprState` made for another user is built again.
* Marks. PL/pgSQL evaluates an expression that is busy in this transaction
  through SPI, with its own plans. An error in a compiled frame marks the
  expression its position names, unless a frame below it runs the same
  expression: that frame owns the flag, as PL/pgSQL's outer frame does, and a
  nested one writes nothing. A call that goes to PL/pgSQL while compiled
  frames are on the stack marks the expression each of them runs for its
  duration, and gives them back afterwards if no one has changed them. A call
  finding any expression of the function busy goes to PL/pgSQL
  (`interpreted:in use`), so a compiled call starts only where PL/pgSQL
  takes its simple path. SPI runs on an expression only with its
  plan pointer null or refcounted: PL/pgSQL holds a refcount from its first
  use of the plan in a transaction, a compiled frame never does, so a mark
  forgets the plan pointer unless PL/pgSQL has one, and PL/pgSQL replans
  instead of trusting a pointer whose plan SPI may have freed.
* Differences from PL/pgSQL, kept: the check of `EXECUTE` at the entry of a
  call covers every function of the planned expressions, and runs the
  function execute hook for each, so a hook that raises for a function the
  call does not reach (an unreached branch) fails the call where PL/pgSQL
  returns. Pinned by `tools/pj_cmodule_pins.sh` (`make check-pj-cmodule`).
* Differences from PL/pgSQL, kept: a failed `numeric(p,s)` conversion of a
  compiled frame leaves no mark in the cast state of PL/pgSQL, which a failed
  cast there leaves to be built and checked again at its next use. That state
  is shared by all PL/pgSQL functions. After a caught compiled overflow, a
  role without `EXECUTE` on `numeric(numeric,int4)` (lost, or never held, as
  a SECURITY DEFINER owner) passes any PL/pgSQL function's next reach of the
  cast in the same transaction, plain `plpgsql` included, where PL/pgSQL
  raises 42501. The result is a stale privilege, never a wrong value.
* Differences from PL/pgSQL, kept: a compiled inner frame of a recursion
  through an expression evaluates it on the simple path, where PL/pgSQL's
  takes SPI, so values can follow the generic plan rather than the custom ones
  of its first runs. A later SPI run of such an expression lags on the plan
  count, so it can take a custom plan where PL/pgSQL takes the generic one;
  the call then returns, or raises 22012, where PL/pgSQL raises 42501, and the
  denied function does not run. A mark set in the middle of a call on an
  expression no outer frame runs is seen by the compiled frame as well.
  Compiled frames use less stack than PL/pgSQL's: a
  recursion deep enough for `stack depth limit exceeded` in PL/pgSQL may
  return a value, and a deeper one still raises.
