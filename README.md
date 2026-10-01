# plllvm

PostgreSQL extension for LLVM-compiled procedural code (master's thesis, FIT ČVUT;
supervisor Pavel Stěhule).

Planned parts, built in this order:

1. **PL/LLVM** — `LANGUAGE plllvm`: a function body is LLVM IR, compiled by the
   extension's own ORC LLJIT and called with the PostgreSQL V1 calling convention.
2. **PL/pgSQL compiler** — `LANGUAGE plpgsql_jit`: PL/pgSQL syntax (parsed by the
   installed `plpgsql`), compiled where supported, otherwise run by the stock
   interpreter.
3. **Expression JIT** for ordinary `plpgsql` functions through the PL/pgSQL plugin API.

Status: planning. No PostgreSQL source changes are needed; the extension builds with
PGXS against an installed PostgreSQL.

Licence: PostgreSQL Licence (`LICENSE`).
