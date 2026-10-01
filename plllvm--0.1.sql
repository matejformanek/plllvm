/* plllvm--0.1.sql */

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

CREATE FUNCTION plllvm_session_info()
  RETURNS TABLE(llvm_version text, triple text, data_layout text,
                libllvm text, types_bc text, init_ms float8,
                compiles int8, compile_failures int8, retired int8,
                rss_bytes int8)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_session_info() FROM PUBLIC;

CREATE FUNCTION plllvm_code_cache()
  RETURNS TABLE(owner_oid regprocedure, symbol text, gen int8, opt_level int4,
                ir_instructions int4, helpers_linked int4, cfi_left int4,
                parse_bc_ms float8, parse_ms float8, link_ms float8,
                verify_ms float8, optimize_ms float8, emit_ms float8,
                total_ms float8, retired bool, code_addr text)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_code_cache() FROM PUBLIC;

-- of this backend: not_compiled, live, stale, retired or dropped
CREATE FUNCTION plllvm_function_status(fn regprocedure, OUT state text,
                                       OUT compiles int8, OUT retired int8)
  RETURNS record
  STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_function_status(regprocedure) FROM PUBLIC;

-- compiles IR as a function body would be; the code stays resident
CREATE FUNCTION plllvm_jit_test(ir text, opt_level int4 DEFAULT NULL,
                                codegen bool DEFAULT true)
  RETURNS TABLE(ok bool, sqlstate text, message text, detail text,
                line int4, col int4, gen int8, ir_instructions int4,
                helpers_linked int4, cfi_left int4)
  CALLED ON NULL INPUT LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_jit_test(text, int4, bool) FROM PUBLIC;
