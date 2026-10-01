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
                libllvm text, types_bc text, init_ms float8)
  LANGUAGE c AS 'MODULE_PATHNAME';

REVOKE ALL ON FUNCTION plllvm_session_info() FROM PUBLIC;
