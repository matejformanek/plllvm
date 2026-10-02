# plllvm C code style

52 rules, each with its source. Each rule says whether it follows Pavel Stěhule's own code or PostgreSQL core; core wins where Pavel is inconsistent.

## Sources

**PC** is plpgsql_check@56fb32002e8b (`https://raw.githubusercontent.com/okbob/plpgsql_check/56fb32002e8bceba0cf39c4dfe623b9a740d7fd9/src/<file>`). **PSM** is plpsm0@11981fb21f13 (HEAD, `https://raw.githubusercontent.com/okbob/plpsm0/11981fb21f13be3cfde71990435350b21ec85909/<file>`). Core paths are relative to the PostgreSQL tree at 9510a826e4a. There is no `pldbgapi2.c` at that SHA; `pldbgapi3.c` was read instead.

## A. Files and banners
1. **Banner (follow Pavel).** Use dashes, the file name, a tab-indented one-line purpose, an author/year line, then dashes. Put an optional numbered `Notes:` block after the closing dash line. PC plpgsql_check.c:1-24, profiler.c:1-10.
   ` * plllvm_jit.c` / ` *\t\t\t  own ORC LLJIT runtime` / ` * by Matěj Formánek 2026`
   Core uses `Portions Copyright… IDENTIFICATION <path>` instead (llvmjit.c:1-12). Use Pavel's form. Only add `IDENTIFICATION` if the code is meant to go upstream.
2. **`plllvm_types.c` banner (copy core).** Explain that the file is never linked and is only turned into bitcode ("NB: This file will not be linked into the server…"), and that its types must stay non-static. llvmjit_types.c:1-25, 43-45.
3. **Include order (core rule).** Every `.c` file starts with `#include "postgres.h"`, then a blank line, then other PG headers in alphabetical order. LLVM-C headers go after those, with `#if LLVM_VERSION_MAJOR` gates where needed. llvmjit.c:14-30; PC fextra_cache.c:11-13.
   PC's main `.c` files instead rely on `plpgsql_check.h` pulling in postgres.h (PC plpgsql_check.h:1). Don't copy that; follow core.
4. **Header guard (core required).** PC plpgsql_check.h has no guard and PSM psm.h:20 has one, so Pavel is inconsistent. Always write `#ifndef PLLLVM_JIT_H` / `#define PLLLVM_JIT_H` … `#endif /* PLLLVM_JIT_H */`. llvmjit.h:11-12, 153.
5. **Module magic (Pavel's shim).** PC plpgsql_check.c:45-56.
   `#ifdef PG_MODULE_MAGIC_EXT` / `PG_MODULE_MAGIC_EXT(.name = "plllvm", .version = "0.1");` / `#else PG_MODULE_MAGIC; #endif`
   If plllvm supports only PG ≥ 18, the plain `PG_MODULE_MAGIC_EXT` that core uses (pl_handler.c:34-37) is enough.
6. **`PG_FUNCTION_INFO_V1` placement.** Pavel groups them all at the top of the file (PC tablefunc.c:22-33; PSM handler.c:15-17). Core puts each one right above its function (pl_handler.c:221, plperl.c:1839). Follow Pavel and group them in `plllvm.c` and `plllvm_stats.c`.

## B. Naming
7. **Exported symbols** take the module prefix in snake_case, like PC `plpgsql_check_*` and the newer short `plch_*` (PC plpgsql_check.h:221-436). Core LLVM uses `llvm_*` (llvmjit.h:103-118).
   Use `plllvm_` for everything exported: `plllvm_call_handler`, `plllvm_validator`, `plllvm_jit_compile()`, `plllvm_enter_fatal_on_oom()`. There is no inline handler: `DO` gets PostgreSQL's own "does not support inline code execution" ERROR.
8. **Static helpers** are unprefixed snake_case: `pin_func`, `func_stats_ht_init` (PC fextra_cache.c:75; profiler.c:684). Pavel sometimes uses CamelCase for callbacks and hash code (`fextra_CacheObjectCallback`, `plpgsql_check_HashTableInit`). Don't mix the two styles in new code.
9. **Struct typedefs.** Pavel names module structs in lowercase with the prefix and gives every struct a tag (PC plpgsql_check.h:87-133: `typedef struct plpgsql_check_info {…} plpgsql_check_info;`). Plain data records use CamelCase (`FuncStats`, profiler.c:47). Core PLs use `plperl_proc_desc` or `PLpgSQL_function`.
   Types declared in a header are lowercase, prefixed and tagged: `typedef struct plllvm_function { CachedFunction cfunc; … } plllvm_function;`, `plllvm_jit_module`, `plllvm_site`. Types local to one file are CamelCase: `JitCode`, `IrRef`.
10. **Global variables.** GUC variables are named `prefix_<gucname>` and declared `extern` in the module header (PC plpgsql_check.h:298-304, 399-403). Function-pointer typedefs end in `_t` and the pointers in `_p` (PC plpgsql_check.c:115-121).
11. **Magic field for `fn_extra` structs (Pavel).** `#define CI_MAGIC 2023042922` plus `int ci_magic;` as the first field, checked with `Assert`/`if` before use. PC plpgsql_check.h:147-151; pldbgapi3.c:40, 507.
   plllvm's is `PLLLVM_FN_MAGIC`. funccache requires `CachedFunction cfunc` to be the first field, so the magic goes right after it.

## C. Comments
12. **Block comment before every non-trivial function.** Pavel often uses a short title line and leaves a trailing blank ` *`: `/*\n * Validate function result description\n *\n */` (PC tablefunc.c:41-44). Core is a plain prose paragraph (llvmjit_error.cpp:36-53). Older core style uses `/* ---------- name … ---------- */` (pl_handler.c:214-220, pl_comp.c:95-104); don't use that in new code.
13. **Explain why, not what, and mention past attempts.** "Originally I used lxcache_mcxt… Unfortunately it doesn't work, because…" (PC profiler.c:770-776). "We cannot pin inline block due two reasons: 1. … 2. …" (PC fextra_cache.c:77-87).
14. **Markers.** Use `Note:` inline (PC pldbgapi3.c:53; pl_comp.c:101) and `XXX:` for open questions (PC check_function.c:342-344). Inline comments are lowercase fragments: `/* pin entry first as protection against … */` (fextra_cache.c:193).
15. **Struct fields** get right-aligned `/* … */` comments after pgindent, and each `bool` explains its true state: `/* true, when … */` (PC plpgsql_check.h:87-96, 156-193).
16. **Formatting.** Run pgindent: tabs, and aligned declarations like `char\t   *extver;` (PC plpgsql_check.c:148-149). Pavel's English typos ("retursn", "relased") are not the style to copy.

## D. Errors
17. **`elog` is only for "can't happen" errors**, and the wording is the canonical one: `elog(ERROR, "cache lookup failed for function %u", funcoid);` (PC tablefunc.c:241; plperl.c:1998; PSM handler.c:80).
18. **`ereport` for user-facing errors**, always with an `errcode`, with arguments in a parenthesised list (the style both Pavel and core use). PC tablefunc.c:200-202.
    `ereport(ERROR, (errcode(ERRCODE_INVALID_PARAMETER_VALUE), errmsg("…"), errhint("…")));`
19. **Message text (core style is required).** `errmsg` is lowercase with no trailing period. `errdetail` and `errhint` are full sentences with a capital and a period (llvmjit_error.cpp:116-140; PC tablefunc.c:231).
    Pavel is inconsistent here: lowercase hints (plpgsql_check.c:172-173), and a duplicated `errdetail` at profiler.c:1181-1183 where the second one should have been `errhint`. Don't copy either.
20. **Errcode choices:**
    - Pseudotype argument or result in the validator: `ERRCODE_FEATURE_NOT_SUPPORTED`, with `"PL/LLVM functions cannot return type %s"` (plperl.c:2013-2016; PSM handler.c:94-97).
    - IR that fails to parse: `ERRCODE_SYNTAX_ERROR` (PSM compiler.c:391-402).
    - Signature or verifier mismatch: `ERRCODE_INVALID_FUNCTION_DEFINITION` (core pg_proc.c:218).
    - Runtime trap inside foreign code: `ERRCODE_EXTERNAL_ROUTINE_EXCEPTION` (plperl.c:616).
    - Memory cap reached: `ERRCODE_CONFIGURATION_LIMIT_EXCEEDED` as a WARNING (PC profiler.c:1178-1179).
    - Out of memory: `ERRCODE_OUT_OF_MEMORY`.
21. **LLVM-C errors follow core.** `if (error) elog(ERROR, "failed to look up symbol \"%s\": %s", name, plllvm_error_message(error));`. The message helper `pstrdup`s the text, then calls `LLVMDisposeErrorMessage`. llvmjit.c:394-397, 1269-1277.
    Errors from the session reporter become `elog(WARNING, "error during JITing: %s", …)` (llvmjit.c:1171-1175).
22. **Debug and timing output:** `ereport(DEBUG1, (errmsg_internal("time to … %.3fs", …), errhidestmt(true), errhidecontext(true)));` (llvmjit.c:813-819).
23. **Error-context callbacks for compile and exec (core and PSM).** Push and pop `ErrorContextCallback` like this (pl_comp.c:212-217, 889-911; plperl.c:4139-4165; PSM compiler.c:4705-4715):
    `plerrcontext.callback = plllvm_compile_error_callback; plerrcontext.arg = &cbarg; plerrcontext.previous = error_context_stack;`
    Wording: `errcontext("compilation of PL/LLVM function \"%s\"", name)` and `errcontext("PL/LLVM function \"%s\"", name)`. In validator mode, call `function_parse_error_transpose()` first.
24. **Translation.** Pavel and the core PLs call `pg_bindtextdomain(TEXTDOMAIN)` in `_PG_init` (PC plpgsql_check.c:211; pl_handler.c:156), with a `-DTEXTDOMAIN` define in the build. plllvm ships no translations, as contrib does not, so it does neither.

## E. Memory
25. **One context per compiled function.** Create it as a child of `CurrentMemoryContext`. Move it under `CacheMemoryContext` with `MemoryContextSetParent` only after compilation succeeds, so a failed compile doesn't leak. Name it with `MemoryContextSetIdentifier(cxt, fn_signature)`. pl_comp.c:230-245, 718; plperl.c:2784-2795.
26. **Long-lived module contexts (Pavel).** Create them lazily under `TopMemoryContext`, named `"plllvm - <purpose> context"` (PC profiler.c:744-748; fextra_cache.c:146-150). Use `ALLOCSET_DEFAULT_SIZES` (Pavel's newer code, fextra_cache.c:213), not the three-argument form.
27. **Switching contexts.** Always `oldcxt = MemoryContextSwitchTo(x); … MemoryContextSwitchTo(oldcxt);`, with comments stating which context owns what (PC fextra_cache.c:233-245; llvmjit.c:809-811). After calling a plugin or callback, force the original context back (PC pldbgapi3.c:532-533).
28. **Cleanup on reset** uses `MemoryContextRegisterResetCallback`, with the callback struct allocated inside the context it watches (PC profiler.c:790-798). Use this for per-transaction JIT handles.
29. **Hash tables** are built from a `memset` `HASHCTL` with `hcxt = <own context>` and `HASH_ELEM | HASH_BLOBS | HASH_CONTEXT`. Write `Assert(ht == NULL)` before creating one (PC profiler.c:684-698).
30. **OOM-tolerant allocation:** `MemoryContextAllocExtended(..., MCXT_ALLOC_NO_OOM)`, then `if (unlikely(p == NULL))` clean up and `ereport(ERROR, … "out of memory")` (PC profiler.c:1188-1198).

## F. Control flow
31. **Pinning in the handler (core).** Increment `use_count` before `PG_TRY`, decrement it in `PG_FINALLY`, and restore the saved state there too. A `Datum` assigned inside the TRY block must be `volatile`. pl_handler.c:230, 243-296; plperl.c:1853-1873.
    `func->cfunc.use_count++; PG_TRY(); { … } PG_FINALLY(); { func->cfunc.use_count--; } PG_END_TRY();`
32. **Undo-then-rethrow (Pavel).** When cleanup only applies on error, write `PG_CATCH(); { /* don't leave … pinned */ x->use_count--; PG_RE_THROW(); } PG_END_TRY();`. PC fextra_cache.c:196-267; PSM handler.c:177-189.
    Converting an error into data uses `CopyErrorData()` + `FlushErrorState()` inside the owning context (PC check_function.c:358-368).
33. **Funccache glue (`plllvm_compile.c`, core pattern).**
    `function = (plllvm_function *) cached_function_compile(fcinfo, fcinfo->flinfo->fn_extra, plllvm_compile_callback, plllvm_delete_callback, sizeof(plllvm_function), false, forValidator); fcinfo->flinfo->fn_extra = function;`
    pl_comp.c:105-135. Funccache leaves `use_count` at 0, so the caller pins (funccache.c:489-494). Pavel wraps the field in a version macro, `plch_use_count(func)` (PC plpgsql_check.h:662-670).
34. **Validator (core).** Return early when `!CheckFunctionValidatorAccess(...)`. Then do the `SearchSysCache1`/`ReleaseSysCache` pseudotype checks, and compile the body only `if (check_function_bodies)`. plperl.c:1978-2042. PSM's validator (handler.c:63-158) predates `CheckFunctionValidatorAccess`; follow core.
35. **`_PG_init`** starts with `static bool inited = false; if (inited) return;` and sets `inited = true;` at the end (both PC plpgsql_check.c:206-209, 519 and pl_handler.c:150-154). Register a syscache callback with `CacheRegisterSyscacheCallback(PROCOID, cb, (Datum) 0)` only if you keep your own cache beyond funccache (PC fextra_cache.c:164).

## G. GUCs
36. **Names and contexts.** Name them `plllvm.<name>`, defined in `_PG_init` with one argument per line and `NULL, NULL, NULL` hooks (PC plpgsql_check.c:268-465). Pavel uses `PGC_USERSET` normally and `PGC_SUSET` for anything that affects security or diagnostics (PC :345; PSM handler.c:33-55). In an untrusted language every plllvm GUC affects one or the other, so all are `PGC_SUSET` except `plllvm.regress_test_mode` (`PGC_USERSET`).
37. **Integer GUCs** state bounds and units: `1024, 10, 2048, PGC_USERSET, GUC_UNIT_KB` (PC plpgsql_check.c:442-449). **Enum GUCs** use a `static const struct config_enum_entry xxx_options[] = {…, {NULL, 0, false}};` table (PC :58-91).
38. **Description wording.** Pavel's are lowercase ("when is true, then … are showed", PC :285-299) with no `gettext_noop`. Core uses `gettext_noop("Capitalized sentence.")` (pl_handler.c:159-184), and the `plpgsql.*` GUCs in core are written that way. Use the core form.
39. **Reserve the prefix** with `MarkGUCPrefixReserved("plllvm")` (pl_handler.c:203). Pavel's `EmitWarningsOnPlaceholders` (PC :467) is only an alias kept for old versions.
40. **Document GUCs in README prose** with default, min/max, and the restart caveat (PC README.md:571-589).

## H. SRFs (`plllvm_stats.c`)
41. **Pavel's hand-rolled version** (PC tablefunc.c:45-58, format.c:243-262): check `rsinfo` and `SFRM_Materialize`, switch to `ecxt_per_query_memory`, then `tuplestore_begin_heap(false, false, work_mem)` and set `returnMode`/`setResult`/`setDesc`. He keeps it because he supports PG 14.
    For PG ≥ 15, use core's `InitMaterializedSRF(fcinfo, 0);` then `tuplestore_putvalues(rsinfo->setResult, rsinfo->setDesc, values, nulls);` (pg_stat_statements.c:1693; pgstatfuncs.c:369).
42. **Null arguments** in options-style SRFs: a macro like `ERR_NULL_OPTION("name")` using `ERRCODE_NULL_VALUE_NOT_ALLOWED` (PC tablefunc.c:35-38), or declare the function `STRICT`.
43. **Check the output shape:** `if (tupdesc->natts != Natts_x) elog(ERROR, "unexpected returning columns (%d instead %d)", …)` (PC format.c:254-257).

## I. Version shims
44. **Guard style.** Write `#if PG_VERSION_NUM >= 180000`, with a blank line inside both edges of the guarded block. Use it for includes too (PC plpgsql_check.c:38-43, 154-162). Hide differing struct fields behind accessor macros in the header (PC plpgsql_check.h:662-676).
45. **Version check (my suggestion, not seen in either source).** Funccache exists only from PG 18. Use `#if PG_VERSION_NUM < 180000` / `#error "plllvm requires PostgreSQL 18 or later"` instead of scattered shims.
46. **LLVM-version gates** follow core: `#if LLVM_VERSION_MAJOR > 16` around includes and API calls (llvmjit.c:21-30, 1258-1262). Pavel's function-pointer loading (`LOAD_EXTERNAL_FUNCTION` + `StaticAssertVariableIsOfType`, PC plpgsql_check.c:139, 185-264) only matters if you call symbols from another module.

## J. C/C++ boundary (`plllvm_error.cpp`, `plllvm_jit.h`)
47. **Includes in the `.cpp`:** `extern "C"` / `{` / `#include "postgres.h"` / `}`, then LLVM C++ headers, then your own header, then `<new>`. llvmjit_error.cpp:17-26.
48. **Header wrapping.** Wrap the C part of the header in `#ifdef __cplusplus extern "C" { #endif … #ifdef __cplusplus } /* extern "C" */ #endif` (llvmjit.h:28-36, 148-150). Keep only `LLVM*Ref` C types in the header.
49. **Fatal-on-OOM section.** Copy the core design as `plllvm_enter_fatal_on_oom` / `_leave_` / `_in_fatal_on_oom` / `_reset_after_error`, with a depth counter, handlers installed only at depth 0, and FATAL-only handlers. llvmjit_error.cpp:28-141.
    Wrap every LLVM API call in this section, but **not** the execution of JIT'd code (comment at :39-44). Don't rely on core's `llvmjit.so` copies of these functions.
50. **Shutdown.** Register `on_proc_exit(plllvm_shutdown, 0)` and skip LLVM cleanup `if (proc_exit_inprogress)` (llvmjit.c:265-270, 908).

## K. Tests
51. **`plllvm.regress_test_mode`** is a bool GUC, `PGC_USERSET`, default false, described as "reduces volatile output" (PC plpgsql_check.c:268-274; declared at :110). In code, use it to hide OIDs, timings, and addresses: `if (plllvm_regress_test_mode) … else … "oid=\"%d\""` (PC format.c:839-850; tracer.c:955).
52. **Test files** start with `load 'plllvm'; set client_min_messages to notice; set plllvm.regress_test_mode = true;` (PC sql/plpgsql_check_active.sql:1-5).
    Per-major-version expected output files go in `REGRESS` as `name-$(MAJORVERSION)` (PC Makefile:19-22). Add a `*_nocrash` test that deliberately triggers errors and checks pin counts and cleanup (PC Makefile:41-42).

## Where Pavel and core differ

The guide picks:
- **Pavel:** banner, grouped `PG_FUNCTION_INFO_V1`, context naming, `PG_CATCH`-undo idiom, magic fields, `regress_test_mode`.
- **Core (required, or clearly better):** header guards, `postgres.h` first, message style, `CheckFunctionValidatorAccess`, `MarkGUCPrefixReserved`, `gettext_noop` GUC wording, `InitMaterializedSRF`, the C++ error boundary.
