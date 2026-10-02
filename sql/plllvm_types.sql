--
-- plllvm_types.bc and the LLVM session check
--
LOAD 'plllvm';
SET plllvm.regress_test_mode = on;

\getenv abs_builddir PG_ABS_BUILDDIR
\set stale :abs_builddir '/src/plllvm_types_stale.bc'
\set notbc :abs_builddir '/plllvm.control'
\set dir :abs_builddir '/src'

-- a .bc built from other sources is refused
SET plllvm.types_bc_path = :'stale';
SELECT llvm_version FROM plllvm_session_info();  -- fail

-- so are a file that is not bitcode and a missing file
SET plllvm.types_bc_path = :'notbc';
SELECT llvm_version FROM plllvm_session_info();  -- fail
SET plllvm.types_bc_path = '/nonexistent/plllvm_types.bc';
SELECT llvm_version FROM plllvm_session_info();  -- fail
-- and a directory; LLVM would read a FIFO or a device without end
SET plllvm.types_bc_path = :'dir';
SELECT llvm_version FROM plllvm_session_info();  -- fail

-- the default, next to the library, works after the failed attempts
RESET plllvm.types_bc_path;
SELECT llvm_version, triple <> '' AS triple, data_layout <> '' AS data_layout,
       libllvm LIKE 'libLLVM%' AS libllvm, types_bc, init_ms > 0 AS timed
  FROM plllvm_session_info();

-- once set up, the session does not read the file again
SET plllvm.types_bc_path = :'stale';
SELECT types_bc FROM plllvm_session_info();
RESET plllvm.types_bc_path;

-- only superusers may set the path or call the function
CREATE ROLE regress_plllvm_types;
SET ROLE regress_plllvm_types;
SET plllvm.types_bc_path = '/tmp/x.bc';  -- fail
SELECT count(*) FROM plllvm_session_info();  -- fail
RESET ROLE;
DROP ROLE regress_plllvm_types;
