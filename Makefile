# plllvm/Makefile

MODULE_big = plllvm
# src/plllvm_types.c is compiled to bitcode only (like llvmjit_types.c)
OBJS = $(patsubst %.c,%.o,$(filter-out src/plllvm_types.c,$(wildcard src/*.c))) \
	src/plllvm_error.o
EXTENSION = plllvm
DATA = plllvm--0.1.sql
PGFILEDESC = "plllvm - PL/LLVM procedural language"

REGRESS = plllvm_setup \
		plllvm_types \
		plllvm_teardown

REGRESS_OPTS = --dbname=$(PL_TESTDB)

EXTRA_CLEAN = stage src/plllvm_types.bc src/plllvm_types_stale.bc

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
subdir = contrib/plllvm
top_builddir = ../..
include $(top_builddir)/src/Makefile.global
include $(top_srcdir)/contrib/contrib-global.mk
else
PG_CONFIG ?= pg_config
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
	-Wno-ignored-attributes -Wno-empty-body
ifdef PG_SYSROOT
PLLLVM_BCFLAGS += -isysroot $(PG_SYSROOT)
endif

# the .bc and plllvm_jit.o must come from the same sources (see plllvm.h)
PLLLVM_TYPES_VERSION := $(shell cat src/plllvm_types.c src/plllvm.h | cksum | cut -d' ' -f1)

all: src/plllvm_types.bc

src/plllvm_types.bc: src/plllvm_types.c src/plllvm.h
	$(PLLLVM_CLANG) $(PLLLVM_BCFLAGS) $(CPPFLAGS) \
		-DPLLLVM_TYPES_VERSION=$(PLLLVM_TYPES_VERSION)U -c -o $@ $<

# PGXS sets CPPFLAGS with override, so a plain += would be ignored
src/plllvm_jit.o: override CPPFLAGS += -DPLLLVM_TYPES_VERSION=$(PLLLVM_TYPES_VERSION)U
src/plllvm_jit.o: src/plllvm_types.c

# the .bc of slightly different sources, for the plllvm_types test
src/plllvm_types_stale.bc: src/plllvm_types.c src/plllvm.h
	{ cat $<; echo '/* stale */'; } > $@.tmp
	$(PLLLVM_CLANG) $(PLLLVM_BCFLAGS) $(CPPFLAGS) -Isrc \
		-DPLLLVM_TYPES_VERSION=`cat $@.tmp src/plllvm.h | cksum | cut -d' ' -f1`U \
		-x c -c -o $@ $@.tmp
	rm -f $@.tmp

installcheck: src/plllvm_types_stale.bc

install: install-types
uninstall: uninstall-types

.PHONY: install-types uninstall-types

install-types: src/plllvm_types.bc
	$(MKDIR_P) '$(DESTDIR)$(pkglibdir)/plllvm'
	$(INSTALL_DATA) src/plllvm_types.bc '$(DESTDIR)$(pkglibdir)/plllvm/'

uninstall-types:
	rm -f '$(DESTDIR)$(pkglibdir)/plllvm/plllvm_types.bc'
	rmdir '$(DESTDIR)$(pkglibdir)/plllvm' 2>/dev/null || true

plllvm.typedefs: $(OBJS)
	./typedefs_gen.py

ifndef NO_PGXS

#
# Development in the thesis workspace: a cluster on PLLLVM_PORT that loads
# the extension from ./stage, so the PostgreSQL installation stays clean.
#
THESIS_ROOT ?= $(abspath $(dir $(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))/..)
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

.PHONY: port-ok doctor stage cluster-init cluster-start cluster-stop pgindent

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
# the checkout (or worktree) that started it
cluster-start: port-ok
	printf "extension_control_path = '\$$system:$(STAGE)/share'\ndynamic_library_path = '$(STAGE)/lib:\$$libdir'\n" \
	  > '$(PLLLVM_DATA)/stage.conf'
	'$(bindir)/pg_ctl' -D '$(PLLLVM_DATA)' -l '$(PLLLVM_DATA).log' -w start

cluster-stop:
	'$(bindir)/pg_ctl' -D '$(PLLLVM_DATA)' -w -m fast stop

# pgindent and pg_bsd_indent of the PostgreSQL tree in the workspace
PGINDENT ?= $(THESIS_ROOT)/code/src/tools/pgindent/pgindent
PG_BSD_INDENT ?= $(firstword $(wildcard $(THESIS_ROOT)/code/build-*/src/tools/pg_bsd_indent/pg_bsd_indent))

# plllvm_jit.h is skipped for its extern "C" block, as core skips llvmjit.h
pgindent: plllvm.typedefs
	'$(PGINDENT)' --indent='$(PG_BSD_INDENT)' --typedefs=plllvm.typedefs \
		$(filter-out src/plllvm_jit.h,$(wildcard src/*.c src/*.h))

endif # NO_PGXS
