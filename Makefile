# plllvm/Makefile

MODULE_big = plllvm
# src/plllvm_types.c is compiled to bitcode only (like llvmjit_types.c)
OBJS = $(patsubst %.c,%.o,$(filter-out src/plllvm_types.c,$(wildcard src/*.c))) \
	src/plllvm_error.o
EXTENSION = plllvm
DATA = plllvm--0.3.sql
PGFILEDESC = "plllvm - PL/LLVM procedural language"

# setup, features, kernels (examples/kernels/*.ll), fatal, teardown
REGRESS_FEATURES = plllvm_types \
		plllvm_jit \
		plllvm_basic \
		plllvm_validator \
		plllvm_errors \
		plllvm_lifecycle \
		plllvm_cache \
		plllvm_queryjit \
		plllvm_memory \
		plllvm_calls \
		plllvm_host_api \
		plllvm_ops \
		plllvm_spi \
		plllvm_array \
		plllvm_sessions
REGRESS_KERNELS = kernel_loop \
		kernel_fib \
		kernel_is_prime \
		kernel_mandelbrot \
		kernel_ledger \
		kernel_wordscan \
		kernel_lookup \
		kernel_nbody \
		kernel_revcomp \
		kernel_spectralnorm \
		kernel_rowudf \
		kernel_ispras
# PL/pgSQL only, with stock PL/pgSQL's output (installcheck-expr)
REGRESS_EXPR = expr_basic \
		expr_ops \
		expr_kernels \
		expr_collide \
		expr_bool
REGRESS = plllvm_setup $(REGRESS_FEATURES) $(REGRESS_KERNELS) expr_plugin \
	$(REGRESS_EXPR) expr_stats plllvm_fatal plllvm_teardown

# LANGUAGE plpgsql_jit, with PJ_LANG=plpgsql_jit (make installcheck-pj); the
# files run against stock PL/pgSQL's output.  REGRESS_PJ_ONCE runs in one
# variant only, REGRESS_PJ_OPT at opt level 3.
REGRESS_PJ = pj_language pj_basic pj_errors pj_guards pj_execute pj_casts pj_sessions
REGRESS_PJ_ONCE = pj_states pj_discard pj_execute_diff
REGRESS_PJ_OPT =

REGRESS_OPTS = --dbname=$(PL_TESTDB)

EXTRA_CLEAN = stage results-plpgsql src/plllvm_types.bc src/plllvm_types_stale.bc

# PGXS of a meson-built server has empty LLVM_* variables
LLVM ?= /opt/homebrew/opt/llvm@22
LLVM_CONFIG ?= $(LLVM)/bin/llvm-config

PG_CPPFLAGS += $(shell $(LLVM_CONFIG) --cppflags)
PG_CXXFLAGS += $(shell $(LLVM_CONFIG) --cxxflags)

# the shared libLLVM, so that we and llvmjit use one LLVM image
SHLIB_LINK += -L$(LLVM)/lib -lLLVM -Wl,-rpath,$(LLVM)/lib

# no per-object bitcode for inlining (bitcode/plllvm/)
override with_llvm := no

ifdef NO_PGXS
# plllvm_fatal provokes FATAL errors in a second session
EXTRA_INSTALL = contrib/dblink
subdir = contrib/plllvm
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
else
# in the thesis workspace, default to its PG 20devel build, not the first pg_config on PATH
THESIS_ROOT ?= $(abspath $(dir $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))/..)
PG_CONFIG ?= $(firstword $(wildcard $(THESIS_ROOT)/code/install-jit/bin/pg_config) pg_config)
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
endif

# C++ code inside, link with the C++ compiler (as src/backend/jit/llvm)
override COMPILER = $(CXX) $(CXXFLAGS)

ifdef PG_SYSROOT
override CXXFLAGS += -isysroot $(PG_SYSROOT)
endif

#
# plllvm_types.bc, with core's flags for llvmjit_types.bc
# (src/backend/jit/llvm/meson.build).  PGXS's own %.bc rule would use the
# empty BITCODE_CFLAGS of a meson-built server.
#
PLLLVM_CLANG ?= $(LLVM)/bin/clang
PLLLVM_BCFLAGS = -O2 -flto=thin -emit-llvm -fno-strict-aliasing -fwrapv \
	-ffp-contract=off -Wno-ignored-attributes -Wno-empty-body
ifdef PG_SYSROOT
PLLLVM_BCFLAGS += -isysroot $(PG_SYSROOT)
endif

# the .bc and plllvm_jit.o must come from the same sources (see plllvm_host.h)
PLLLVM_TYPES_SRCS = src/plllvm_types.c src/plllvm_host.h src/plllvm_ops.h
PLLLVM_TYPES_VERSION := $(shell cat $(PLLLVM_TYPES_SRCS) | cksum | cut -d' ' -f1)

all: src/plllvm_types.bc

src/plllvm_types.bc: $(PLLLVM_TYPES_SRCS)
	$(PLLLVM_CLANG) $(PLLLVM_BCFLAGS) $(CPPFLAGS) \
		-DPLLLVM_TYPES_VERSION=$(PLLLVM_TYPES_VERSION)U -c -o $@ $<

# PGXS sets CPPFLAGS with override, so a plain += would be ignored
src/plllvm_jit.o: override CPPFLAGS += -DPLLLVM_TYPES_VERSION=$(PLLLVM_TYPES_VERSION)U
src/plllvm_jit.o: $(PLLLVM_TYPES_SRCS)

# the .bc of slightly different sources, for the plllvm_types test
src/plllvm_types_stale.bc: $(PLLLVM_TYPES_SRCS)
	{ cat $<; echo '/* stale */'; } > $@.tmp
	$(PLLLVM_CLANG) $(PLLLVM_BCFLAGS) $(CPPFLAGS) -Isrc \
		-DPLLLVM_TYPES_VERSION=`cat $@.tmp src/plllvm_host.h src/plllvm_ops.h | cksum | cut -d' ' -f1`U \
		-x c -c -o $@ $@.tmp
	rm -f $@.tmp

installcheck: src/plllvm_types_stale.bc

install: install-types install-build-info
uninstall: uninstall-types

.PHONY: install-types uninstall-types install-build-info

install-types: src/plllvm_types.bc
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)/plllvm'
	$(INSTALL_DATA) src/plllvm_types.bc '$(DESTDIR)$(pkglibdir)/plllvm/'

# ties an installation to its sources, for the benchmarks
install-build-info: install-lib install-types
	{ echo "git_head=`git rev-parse HEAD`"; \
	  echo "git_dirty=`git status --porcelain --untracked-files=no | wc -l | tr -d ' '`"; \
	  echo "plllvm_sha256=`shasum -a 256 '$(DESTDIR)$(pkglibdir)/$(MODULE_big)$(DLSUFFIX)' | cut -d' ' -f1`"; \
	  echo "types_bc_sha256=`shasum -a 256 '$(DESTDIR)$(pkglibdir)/plllvm/plllvm_types.bc' | cut -d' ' -f1`"; \
	} > '$(DESTDIR)$(pkglibdir)/plllvm/build-info.txt'

uninstall-types:
	rm -f '$(DESTDIR)$(pkglibdir)/plllvm/plllvm_types.bc' \
		'$(DESTDIR)$(pkglibdir)/plllvm/build-info.txt'
	rmdir '$(DESTDIR)$(pkglibdir)/plllvm' 2>/dev/null || true

plllvm.typedefs: $(OBJS)
	./typedefs_gen.py

ifndef NO_PGXS

#
# Development in the thesis workspace: a cluster on PLLLVM_PORT that loads
# the extension from ./stage, so the PostgreSQL installation stays clean.
#
PLLLVM_PORT ?= 5447
PLLLVM_DATA ?= $(THESIS_ROOT)/scratch/plllvm/data-$(PLLLVM_PORT)
STAGE = $(CURDIR)/stage

# PLLLVM_PORT= (empty) leaves installcheck to PGHOST/PGPORT
ifneq ($(PLLLVM_PORT),)
REGRESS_OPTS += --host=/tmp --port=$(PLLLVM_PORT)
installcheck: port-ok
endif

# install-perf is for measurements only (workspace rule W4)
ifneq ($(findstring /install-perf/,$(bindir)/),)
ifneq ($(MEASURE),1)
$(error install-perf needs MEASURE=1)
endif
ifeq ($(wildcard $(THESIS_ROOT)/scratch/measure.lock),)
$(error MEASURE=1 needs $(THESIS_ROOT)/scratch/measure.lock)
endif
endif

.PHONY: port-ok doctor stage cluster-init cluster-start cluster-stop pgindent \
	installcheck-discard installcheck-opt installcheck-hazard installcheck-plpgsql \
	installcheck-expr installcheck-pj installcheck-pj-once installcheck-pj-opt \
	installcheck-plpgsql-pj verify check-host-api kernels check-kernels

# 5432, 5433 belong to pg-claude, 5444 to the perf cluster
port-ok:
	@case "$(PLLLVM_PORT)" in 5432|5433|5444) \
	  echo "port $(PLLLVM_PORT) is reserved" >&2; exit 1;; esac

doctor: all
	@. ./PG_PIN; rc=0; \
	v=`$(PG_CONFIG) --version`; \
	[ "$$v" = "$$PG_VERSION" ] || { echo "pg_config is $$v, want $$PG_VERSION"; rc=1; }; \
	cv=`awk '/define CATALOG_VERSION_NO/ {print $$3}' '$(includedir_server)/catalog/catversion.h'`; \
	[ "$$cv" = "$$PG_CATVERSION" ] || { echo "catversion is $$cv, want $$PG_CATVERSION ($$PG_COMMIT)"; rc=1; }; \
	lv=`$(LLVM_CONFIG) --version`; \
	[ "$${lv%%.*}" = "$$LLVM_MAJOR" ] || { echo "llvm-config is $$lv, want $$LLVM_MAJOR"; rc=1; }; \
	brew list --pinned | grep -qx "$$LLVM_BREW" || { echo "$$LLVM_BREW is not pinned"; rc=1; }; \
	ours=`otool -L $(MODULE_big)$(DLSUFFIX) | awk '/libLLVM/ {print $$1}'`; \
	theirs=`otool -L '$(pkglibdir)/llvmjit$(DLSUFFIX)' | awk '/libLLVM/ {print $$1}'`; \
	[ -n "$$ours" -a "$$ours" = "$$theirs" ] || { echo "libLLVM is '$$ours', llvmjit has '$$theirs'"; rc=1; }; \
	[ $$rc = 0 ] && echo "doctor: $$v (catversion $$cv), LLVM $$lv (pinned), $$ours"; \
	exit $$rc

# rm first: overwriting a file that a backend has mapped can crash it
stage: all
	$(MKDIR_P) '$(STAGE)/share/extension' '$(STAGE)/lib/plllvm'
	cp $(EXTENSION).control $(DATA) '$(STAGE)/share/extension/'
	rm -f '$(STAGE)/lib/$(MODULE_big)$(DLSUFFIX)' '$(STAGE)/lib/plllvm/plllvm_types.bc'
	cp $(MODULE_big)$(DLSUFFIX) '$(STAGE)/lib/'
	cp src/plllvm_types.bc '$(STAGE)/lib/plllvm/'

cluster-init: port-ok
	$(MKDIR_P) '$(dir $(PLLLVM_DATA))'
	'$(bindir)/initdb' -D '$(PLLLVM_DATA)' -A trust -E UTF8 --locale=C --no-sync --no-instructions
	printf "port = $(PLLLVM_PORT)\nunix_socket_directories = '/tmp'\nlisten_addresses = ''\njit = on\ninclude_if_exists = 'stage.conf'\n" \
	  >> '$(PLLLVM_DATA)/postgresql.conf'

# stage.conf is written at each start, so the cluster serves the ./stage of
# the checkout (or worktree) that started it.  The first hit wins in both
# paths, and the installation ($system) may hold an older plllvm.control.
cluster-start: port-ok
	printf "extension_control_path = '$(STAGE)/share:\$$system'\ndynamic_library_path = '$(STAGE)/lib:\$$libdir'\n" \
	  > '$(PLLLVM_DATA)/stage.conf'
	'$(bindir)/pg_ctl' -D '$(PLLLVM_DATA)' -l '$(PLLLVM_DATA).log' -w start

cluster-stop:
	'$(bindir)/pg_ctl' -D '$(PLLLVM_DATA)' -w -m fast stop

# call sites under cache flushes; plllvm_cache has an alternative output
installcheck-discard:
	$(MAKE) installcheck REGRESS='plllvm_setup plllvm_calls plllvm_cache' \
		PGOPTIONS='-c debug_discard_caches=1'

# the operators and the kernels at the other opt levels, against the same
# expected output
installcheck-opt:
	$(MAKE) installcheck REGRESS='plllvm_setup plllvm_ops $(REGRESS_KERNELS)' \
		PGOPTIONS='-c plllvm.opt_level=0'
	$(MAKE) installcheck REGRESS='plllvm_setup plllvm_ops $(REGRESS_KERNELS)' \
		PGOPTIONS='-c plllvm.opt_level=3'

#
# The expression tests against the same expected output, interpreted and
# compiled: at O0 and O2, and taken at the first evaluation.  expr_stats
# checks that compiled code ran where it should.  Under cache flushes every
# evaluation plans again (tens of ms each) and gets a new ExprState, which
# never reaches its second evaluation; so that variant runs only
# expr_stats, taken at the first evaluation.
#
EXPR_JIT = -c session_preload_libraries=plllvm -c plllvm.expr_jit=on

installcheck-expr:
	$(MAKE) installcheck REGRESS='plllvm_setup $(REGRESS_EXPR) expr_stats'
	$(MAKE) installcheck REGRESS='plllvm_setup $(REGRESS_EXPR) expr_stats' \
		PGOPTIONS='$(EXPR_JIT) -c plllvm.expr_opt_level=0'
	$(MAKE) installcheck REGRESS='plllvm_setup $(REGRESS_EXPR) expr_stats' \
		PGOPTIONS='$(EXPR_JIT) -c plllvm.expr_opt_level=2'
	$(MAKE) installcheck REGRESS='plllvm_setup $(REGRESS_EXPR) expr_stats' \
		PGOPTIONS='$(EXPR_JIT) -c plllvm.expr_opt_level=2 -c plllvm.expr_eager=on'
	$(MAKE) installcheck REGRESS='plllvm_setup expr_stats' \
		PGOPTIONS='$(EXPR_JIT) -c plllvm.expr_opt_level=2 -c plllvm.expr_eager=on -c debug_discard_caches=1'

# tests that crash the server when their fix regresses, so never part of
# installcheck: only on a throwaway cluster, with PLLLVM_PORT given
installcheck-hazard: port-ok
	@case "$(origin PLLLVM_PORT):$(PLLLVM_PORT)" in file:*|*:|*:544[2-5]) \
	  echo "installcheck-hazard needs the PLLLVM_PORT of a throwaway cluster" >&2; \
	  exit 1;; esac
	$(MAKE) installcheck REGRESS='plllvm_setup plllvm_hazard'

#
# PostgreSQL's PL/pgSQL tests (src/pl/plpgsql and the core plpgsql test),
# without plllvm and then with it loaded: plllvm.expr_jit off, on, and on
# taken at the first evaluation.  Each run must give the output of the
# first, and with plllvm.expr_jit on a loop must have run compiled.  test_setup
# creates a tablespace, which outlives its database, so this is for a
# throwaway cluster only.  With plllvm in shared_preload_libraries the
# first run has it loaded too, and compares nothing against stock PL/pgSQL.
#
PG_SRC ?= $(THESIS_ROOT)/code
PG_BUILD ?= $(THESIS_ROOT)/code/build-jit
PLPGSQL_TESTS = plpgsql_array plpgsql_cache plpgsql_call plpgsql_control \
	plpgsql_copy plpgsql_domain plpgsql_misc plpgsql_record plpgsql_simple \
	plpgsql_transaction plpgsql_trap plpgsql_trigger plpgsql_varprops
PLPGSQL_LOAD = -c session_preload_libraries=plllvm

# $(call plpgsql_suite,name,PGOPTIONS)
plpgsql_suite = \
	export PGOPTIONS='$(2)' && \
	$(MKDIR_P) results-plpgsql/$(1)/pl results-plpgsql/$(1)/core && \
	$(pg_regress_installcheck) --host=/tmp --port=$(PLLLVM_PORT) \
		--inputdir=$(PG_SRC)/src/pl/plpgsql/src --outputdir=results-plpgsql/$(1)/pl \
		--dbname=pl_regression $(PLPGSQL_TESTS) && \
	'$(bindir)/psql' -X -q -h /tmp -p $(PLLLVM_PORT) -d postgres \
		-c 'DROP DATABASE IF EXISTS regression' \
		-c 'DROP DATABASE IF EXISTS regression_utf8' \
		-c 'DROP TABLESPACE IF EXISTS regress_tblspace' && \
	$(pg_regress_installcheck) --host=/tmp --port=$(PLLLVM_PORT) \
		--inputdir=$(PG_SRC)/src/test/regress --dlpath=$(PG_BUILD)/src/test/regress \
		--outputdir=results-plpgsql/$(1)/core --dbname=regression test_setup plpgsql

# $(call plpgsql_fired,PGOPTIONS), in pl_regression as the suite left it
plpgsql_fired = \
	r=`PGOPTIONS='$(1)' '$(bindir)/psql' -X -q -At -h /tmp -p $(PLLLVM_PORT) -d pl_regression \
		-c 'CREATE EXTENSION plllvm' \
		-c 'DO $$$$ DECLARE s int := 0; BEGIN FOR i IN 1..10 LOOP s := s + i; END LOOP; END $$$$' \
		-c "SELECT state = 'active' AND installed > 0 AND failures = 0 FROM plllvm_expr_stats()"` && \
	[ "$$r" = t ] || { echo 'plllvm did not compile with $(1)' >&2; exit 1; }

installcheck-plpgsql: port-ok
	@case "$(origin PLLLVM_PORT):$(PLLLVM_PORT)" in file:*|*:|*:544[2-5]) \
	  echo "installcheck-plpgsql needs the PLLLVM_PORT of a throwaway cluster" >&2; \
	  exit 1;; esac
	rm -rf results-plpgsql
	$(call plpgsql_suite,base,)
	$(call plpgsql_suite,off,$(PLPGSQL_LOAD))
	$(call plpgsql_suite,on,$(PLPGSQL_LOAD) -c plllvm.expr_jit=on)
	$(call plpgsql_fired,$(PLPGSQL_LOAD) -c plllvm.expr_jit=on)
	$(call plpgsql_suite,eager,$(PLPGSQL_LOAD) -c plllvm.expr_jit=on -c plllvm.expr_eager=on)
	$(call plpgsql_fired,$(PLPGSQL_LOAD) -c plllvm.expr_jit=on -c plllvm.expr_eager=on)
	for m in off on eager; do \
	  diff -r results-plpgsql/base/pl/results results-plpgsql/$$m/pl/results && \
	  diff -r results-plpgsql/base/core/results results-plpgsql/$$m/core/results || exit 1; \
	done

#
# LANGUAGE plpgsql_jit: the pj_ files create their functions in the language
# of :pj_lang, plpgsql unless PJ_LANG says otherwise, so one expected output
# is stock PL/pgSQL's.  Every variant has plllvm preloaded: pj_expect takes a
# session without plllvm.plpgsql_jit for stock.  Under cache flushes only
# pj_stats runs, as installcheck-expr does with expr_stats.
#
PJ_FIXTURE = plllvm_setup pj_setup

# $(call pj_run,PGOPTIONS,files)
pj_run = PJ_LANG=plpgsql_jit $(MAKE) installcheck REGRESS='$(2)' PGOPTIONS='$(1)'

installcheck-pj:
	$(call pj_run,$(PLPGSQL_LOAD) -c plllvm.plpgsql_jit=off,$(PJ_FIXTURE) $(REGRESS_PJ) pj_stats)
	$(call pj_run,$(PLPGSQL_LOAD) -c plllvm.pj_opt_level=0,$(PJ_FIXTURE) $(REGRESS_PJ) pj_stats)
	$(call pj_run,$(PLPGSQL_LOAD) -c plllvm.pj_opt_level=2,$(PJ_FIXTURE) $(REGRESS_PJ) pj_stats)
	$(call pj_run,$(EXPR_JIT) -c plllvm.expr_eager=on,$(PJ_FIXTURE) $(REGRESS_PJ) pj_stats)
	$(call pj_run,$(PLPGSQL_LOAD) -c debug_discard_caches=1,$(PJ_FIXTURE) pj_guards pj_stats)

# expected from plllvm, so not against stock
installcheck-pj-once:
	@[ -z '$(REGRESS_PJ_ONCE)' ] || \
	  $(call pj_run,$(PLPGSQL_LOAD),$(PJ_FIXTURE) $(REGRESS_PJ_ONCE))

# no file needs it yet
installcheck-pj-opt:
	@[ -z '$(REGRESS_PJ_OPT)' ] || \
	  $(call pj_run,$(PLPGSQL_LOAD) -c plllvm.pj_opt_level=3,$(PJ_FIXTURE) $(REGRESS_PJ_OPT))

#
# PG's PL/pgSQL tests with every LANGUAGE plpgsql changed to plpgsql_jit
# (a generated copy of the inputs) against the unchanged run.  Allowed
# differences, with their reason: tools/plpgsql_pj_allowed.diff.  Throwaway
# cluster only: the tests create roles and a tablespace.
#
PJPL = results-plpgsql-pj
PJPL_SWAP = perl -pe 's/\b(language\s+)(["\x27]?)plpgsql\2\b/$$1plpgsql_jit/gi'
PJPL_BACK = perl -0pe 's/plpgsql_jit/plpgsql/g; s/-- pj compiled count\n.*?\\o\n//s'

# each generated file ends by appending the compiled calls of its session
# to $PJ_COMPILED; the comparison drops these lines
define PJPL_TAIL
-- pj compiled count
RESET SESSION AUTHORIZATION;
\o | cat >> "$$PJ_COMPILED"
SELECT compiled_calls FROM plllvm_pj_stats();
\o
endef
export PJPL_TAIL

# $(call pjpl_inputs,dir,source dir,tests)
pjpl_inputs = \
	rm -rf $(1) && $(MKDIR_P) $(1)/sql $(1)/expected && \
	{ [ ! -d $(2)/data ] || cp -R $(2)/data $(1); } && \
	for t in $(3); do \
	  $(PJPL_SWAP) $(2)/sql/$$t.sql > $(1)/sql/$$t.sql && \
	  $(PJPL_SWAP) $(2)/expected/$$t.out > $(1)/expected/$$t.out && \
	  { echo; echo "$$PJPL_TAIL"; } >> $(1)/sql/$$t.sql || exit 1; done

# $(call pjpl_suite,name,PGOPTIONS,regress options,pl inputdir,core inputdir):
# the tests as installcheck-plpgsql's suites; a failed test shows in the diff
# against base, not here
pjpl_suite = \
	export PGOPTIONS='$(2)' && \
	$(MKDIR_P) $(PJPL)/$(1)/pl $(PJPL)/$(1)/core && \
	{ export PJ_COMPILED=$(CURDIR)/$(PJPL)/$(1)/compiled.txt; \
		$(pg_regress_installcheck) --host=/tmp --port=$(PLLLVM_PORT) $(3) \
		--inputdir=$(4) --outputdir=$(PJPL)/$(1)/pl --dbname=pl_regression \
		$(PLPGSQL_TESTS) || true; } && \
	'$(bindir)/psql' -X -q -h /tmp -p $(PLLLVM_PORT) -d postgres \
		-c 'DROP DATABASE IF EXISTS regression' \
		-c 'DROP DATABASE IF EXISTS regression_utf8' \
		-c 'DROP TABLESPACE IF EXISTS regress_tblspace' && \
	$(pg_regress_installcheck) --host=/tmp --port=$(PLLLVM_PORT) $(3) \
		--inputdir=$(PG_SRC)/src/test/regress --dlpath=$(PG_BUILD)/src/test/regress \
		--outputdir=$(PJPL)/$(1)/core --dbname=regression test_setup && \
	{ export PJ_COMPILED=$(CURDIR)/$(PJPL)/$(1)/compiled.txt; \
		$(pg_regress_installcheck) --host=/tmp --port=$(PLLLVM_PORT) --use-existing \
		--inputdir=$(5) --dlpath=$(PG_BUILD)/src/test/regress \
		--outputdir=$(PJPL)/$(1)/core --dbname=regression plpgsql || true; }

installcheck-plpgsql-pj: port-ok
	@case "$(origin PLLLVM_PORT):$(PLLLVM_PORT)" in file:*|*:|*:544[2-5]) \
	  echo "installcheck-plpgsql-pj needs the PLLLVM_PORT of a throwaway cluster" >&2; \
	  exit 1;; esac
	rm -rf $(PJPL)
	$(call pjpl_inputs,$(PJPL)/in/pl,$(PG_SRC)/src/pl/plpgsql/src,$(PLPGSQL_TESTS))
	$(call pjpl_inputs,$(PJPL)/in/core,$(PG_SRC)/src/test/regress,plpgsql)
	$(call pjpl_suite,base,,,$(PG_SRC)/src/pl/plpgsql/src,$(PG_SRC)/src/test/regress)
	$(call pjpl_suite,off,$(PLPGSQL_LOAD) -c plllvm.plpgsql_jit=off,--load-extension=plllvm,$(PJPL)/in/pl,$(PJPL)/in/core)
	$(call pjpl_suite,on,$(PLPGSQL_LOAD),--load-extension=plllvm,$(PJPL)/in/pl,$(PJPL)/in/core)
	rc=0; for m in off on; do \
	  n=`perl -ne '$$s += $$1 if /^\s*(\d+)\s*$$/; END {print $$s + 0}' $(PJPL)/$$m/compiled.txt`; \
	  echo "installcheck-plpgsql-pj: $$m ran $$n calls compiled (a lower bound: a reconnect starts a new session)"; \
	  [ $$m != off ] || [ $$n = 0 ] || { echo "installcheck-plpgsql-pj: compiled calls with the handler off" >&2; rc=1; }; \
	  [ $$m = off ] || [ $$n != 0 ] || { echo "installcheck-plpgsql-pj: nothing compiled with the handler on" >&2; rc=1; }; \
	  cp -r $(PJPL)/$$m $(PJPL)/$$m-back && \
	  for f in $(PJPL)/$$m-back/*/results/*.out; do $(PJPL_BACK) $$f > $$f.tmp && mv $$f.tmp $$f; done; \
	  diff -r -x regression.out -x regression.diffs -x compiled.txt -x '*.diff' $(PJPL)/base $(PJPL)/$$m-back \
	    | sed "s#$(PJPL)/##g; s#$$m-back#MODE#g" > $(PJPL)/$$m.diff; \
	  grep -v '^#' tools/plpgsql_pj_allowed.diff | diff - $(PJPL)/$$m.diff > /dev/null || \
	    { echo "installcheck-plpgsql-pj: $$m differs from base, see $(PJPL)/$$m.diff" >&2; rc=1; }; \
	done; exit $$rc

#
# Every suite of a PR in order; the commit and each exit code go to
# results-verify.log, and a failure does not stop the rest.
#
VERIFY_LOG = results-verify.log

verify: port-ok
	@echo "plllvm `git rev-parse HEAD` dirty=`git status --porcelain --untracked-files=no | wc -l | tr -d ' '`" > $(VERIFY_LOG); \
	fail=0; \
	step() { echo "== $$*"; "$$@"; rc=$$?; echo "$$rc $$*" >> $(VERIFY_LOG); [ $$rc = 0 ] || fail=1; }; \
	step $(MAKE) all stage; \
	[ -d '$(PLLLVM_DATA)' ] || step $(MAKE) cluster-init; \
	'$(bindir)/pg_ctl' -D '$(PLLLVM_DATA)' status > /dev/null || step $(MAKE) cluster-start; \
	for t in installcheck installcheck-opt installcheck-discard installcheck-hazard \
	  check-host-api pgindent doctor installcheck-expr installcheck-plpgsql \
	  installcheck-pj installcheck-pj-once installcheck-pj-opt installcheck-plpgsql-pj; do \
	  step $(MAKE) $$t; \
	  [ $$t != pgindent ] || step git diff --exit-code; \
	done; \
	step $(MAKE) cluster-stop; \
	exit $$fail

# runtime functions that only the inline helpers call
HOST_API_INTERNAL = plllvm_rt_site_call plllvm_rt_site_null plllvm_rt_array_access

# docs/host-api.ll declares every other plllvm_* name of plllvm_types.bc
check-host-api: src/plllvm_types.bc
	$(LLVM)/bin/llvm-nm -j $< | sed 's/^_//' | grep '^plllvm_' | \
		grep -v -x -e plllvm_attr_template -e 'plllvm_types_.*' -e 'plllvm_pj_.*' $(addprefix -e ,$(HOST_API_INTERNAL)) | \
		sort -u > $@.bc
	sed -n 's/^declare .*@\(plllvm_[a-z0-9_]*\)(.*/\1/p' docs/host-api.ll | sort -u > $@.ll
	diff $@.bc $@.ll; rc=$$?; rm -f $@.bc $@.ll; exit $$rc

installcheck: check-host-api

#
# examples/kernels/<k>.ll from examples/kernels/src/<k>.c: unoptimised IR,
# which plllvm.opt_level optimises.  install-perf headers, so that no
# Assert() code goes in (nothing is installed there).  A fixed target and
# SDK version, so that an OS update does not change the files; the compile
# sets the session's triple anyway.
#
KERNEL_SRCS = $(wildcard examples/kernels/src/*.c)
KERNEL_INCLUDEDIR ?= $(THESIS_ROOT)/code/install-perf/include/postgresql/server
KERNEL_FLAGS = --target=arm64-apple-macosx15.0 -Xclang -target-sdk-version=15.0 \
	-O2 -Xclang -disable-llvm-passes -S -emit-llvm \
	-fno-strict-aliasing -fwrapv -ffp-contract=off -I'$(KERNEL_INCLUDEDIR)'
ifdef PG_SYSROOT
KERNEL_FLAGS += -isysroot $(PG_SYSROOT)
endif

# $(call kernel_ll,source,output)
kernel_ll = { echo '; GENERATED by "make kernels" from '$(1)' -- do not edit'; \
	$(PLLLVM_CLANG) $(KERNEL_FLAGS) -o - $(1); } > $(2).tmp && mv $(2).tmp $(2)

kernels: $(KERNEL_SRCS:examples/kernels/src/%.c=examples/kernels/%.ll)

examples/kernels/%.ll: examples/kernels/src/%.c
	$(call kernel_ll,$<,$@)

check-kernels:
	@rc=0; for c in $(KERNEL_SRCS); do \
	  k=`basename $$c .c`; \
	  $(call kernel_ll,$$c,check-kernels-$$k.ll) || exit 1; \
	  diff -q examples/kernels/$$k.ll check-kernels-$$k.ll || rc=1; \
	  rm -f check-kernels-$$k.ll; \
	done; exit $$rc

# pgindent and pg_bsd_indent of the PostgreSQL tree in the workspace
PGINDENT ?= $(THESIS_ROOT)/code/src/tools/pgindent/pgindent
PG_BSD_INDENT ?= $(firstword $(wildcard $(THESIS_ROOT)/code/build-*/src/tools/pg_bsd_indent/pg_bsd_indent))

# plllvm_jit.h is skipped for its extern "C" block, as core skips llvmjit.h
pgindent: plllvm.typedefs
	'$(PGINDENT)' --indent='$(PG_BSD_INDENT)' --typedefs=plllvm.typedefs \
		$(filter-out src/plllvm_jit.h,$(wildcard src/*.c src/*.h))

endif # NO_PGXS
