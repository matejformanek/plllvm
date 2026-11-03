/* plllvm--0.3.sql */

-- complain if script is sourced in psql, rather than via CREATE EXTENSION
\echo Use "CREATE EXTENSION plllvm" to load this file. \quit

CREATE FUNCTION plllvm_call_handler() RETURNS language_handler
  LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION plllvm_validator(oid) RETURNS void
  STRICT LANGUAGE c AS 'MODULE_PATHNAME';

-- No INLINE handler: PostgreSQL itself rejects DO blocks in this language.
CREATE LANGUAGE plllvm
  HANDLER plllvm_call_handler
  VALIDATOR plllvm_validator;

COMMENT ON LANGUAGE plllvm IS 'PL/LLVM untrusted procedural language';

-- PL/pgSQL's syntax, compiler and error messages; the handler is ours.  The
-- inline handler and the validator are PL/pgSQL's own.  Not TRUSTED: only a
-- superuser can create functions in it, or grant it.
CREATE FUNCTION plpgsql_jit_call_handler() RETURNS language_handler
  LANGUAGE c AS 'MODULE_PATHNAME', 'plllvm_pj_call_handler';

CREATE FUNCTION plpgsql_jit_inline_handler(internal) RETURNS void
  STRICT LANGUAGE c AS '$libdir/plpgsql', 'plpgsql_inline_handler';

CREATE FUNCTION plpgsql_jit_validator(oid) RETURNS void
  STRICT LANGUAGE c AS '$libdir/plpgsql', 'plpgsql_validator';

CREATE LANGUAGE plpgsql_jit
  HANDLER plpgsql_jit_call_handler
  INLINE plpgsql_jit_inline_handler
  VALIDATOR plpgsql_jit_validator;

COMMENT ON LANGUAGE plpgsql_jit IS
  'PL/pgSQL functions compiled with LLVM, with PL/pgSQL as the fallback';

CREATE FUNCTION plllvm_session_info()
  RETURNS TABLE(llvm_version text, triple text, data_layout text,
                libllvm text, types_bc text, init_ms float8,
                compiles int8, compile_failures int8, retired int8,
                rss_bytes int8, spi_statements int8)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_session_info() FROM PUBLIC;

CREATE FUNCTION plllvm_code_cache()
  RETURNS TABLE(owner_oid regprocedure, symbol text, gen int8, opt_level int4,
                ir_instructions int4, helpers_linked int4, cfi_left int4,
                parse_bc_ms float8, parse_ms float8, link_ms float8,
                verify_ms float8, resolve_ms float8, optimize_ms float8,
                emit_ms float8, total_ms float8, retired bool,
                code_addr text, frame bool, kind text,
                translate_ms float8)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_code_cache() FROM PUBLIC;

CREATE FUNCTION plllvm_call_sites()
  RETURNS TABLE(owner regprocedure, callee text, ready bool, busy bool,
                prepares int8, checks int8, reentries int8, retired bool)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_call_sites() FROM PUBLIC;

-- expression JIT in the PL/pgSQL functions of this backend; state is off,
-- active, declined:paramfunc or not_in_slot.  installed counts the
-- expressions given code (compiled + taken from the cache), programs the
-- compiled ones and the failed builds, which plllvm.expr_max_programs caps;
-- compiled_evals counts evaluations of code compiled under
-- plllvm.expr_eager only
CREATE FUNCTION plllvm_expr_stats(OUT state text, OUT fired int8,
                                  OUT installed int8, OUT compiled int8,
                                  OUT declined int8, OUT failures int8,
                                  OUT capped int8, OUT programs int8,
                                  OUT compiled_evals int8)
  RETURNS record
  VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_expr_stats() FROM PUBLIC;

-- of this backend: not_compiled, live, stale or dropped; compiles counts the
-- resident ones, retired those released and freed at the next compile
CREATE FUNCTION plllvm_function_status(fn regprocedure, OUT state text,
                                       OUT compiles int8, OUT retired int8)
  RETURNS record
  STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_function_status(regprocedure) FROM PUBLIC;

-- compiles IR as a function body would be; nothing calls the code, it is
-- freed at the next compile
CREATE FUNCTION plllvm_jit_test(ir text, opt_level int4 DEFAULT NULL,
                                codegen bool DEFAULT true)
  RETURNS TABLE(ok bool, sqlstate text, message text, detail text,
                line int4, col int4, gen int8, ir_instructions int4,
                helpers_linked int4, cfi_left int4, checks_inserted int4)
  CALLED ON NULL INPUT LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_jit_test(text, int4, bool) FROM PUBLIC;

-- of this backend: every handler entry of LANGUAGE plpgsql_jit is one call,
-- and calls = compiled_calls + deopts + interpreted_calls.  declines (calls
-- that fell back because the function is declined), guard_misses, null_args,
-- plugin_fallbacks and capped are among the interpreted_calls
CREATE FUNCTION plllvm_pj_stats(OUT calls int8, OUT compiled_calls int8,
                                OUT deopts int8, OUT interpreted_calls int8,
                                OUT declines int8, OUT guard_misses int8,
                                OUT null_args int8, OUT plugin_fallbacks int8,
                                OUT capped int8, OUT translations int8,
                                OUT attempts int8, OUT failures int8,
                                OUT boxed_evals int8, OUT resident int8,
                                OUT peak_tuple_bytes int8)
  RETURNS record
  VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_pj_stats() FROM PUBLIC;

-- one row per signature and input collation of fn in this backend; state is
-- new, seen, compiled or declined.  exprs, unplanned and variants describe
-- the translation, native, boxed, restartable and translate_ms the variant
-- the session's plllvm.pj_opt_level and plllvm.pj_codegen select; they are
-- NULL when there is none.  translate_ms is the whole translation, in
-- plllvm_code_cache() too (rows of kind pj); symbol is the name of that
-- variant's code there and in a profile
CREATE FUNCTION plllvm_pj_status(fn regprocedure)
  RETURNS TABLE(signature text, collation regcollation, state text,
                reason text, calls int8, compiled_calls int8, deopts int8,
                guard_misses int8, translations int8, last_path text,
                exprs int4, unplanned int4, variants int4, native bool,
                boxed bool, restartable bool, translate_ms float8,
                symbol text)
  STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_pj_status(regprocedure) FROM PUBLIC;

-- the IR of that variant, for inspection; NULL when there is none
CREATE FUNCTION plllvm_pj_ir(fn regprocedure) RETURNS text
  STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_pj_ir(regprocedure) FROM PUBLIC;
