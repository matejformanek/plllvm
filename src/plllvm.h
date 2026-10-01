/*-------------------------------------------------------------------------
 *
 * plllvm.h
 *
 *			  internal declarations of the PL/LLVM procedural language
 *
 * by Matěj Formánek 2026
 *
 *-------------------------------------------------------------------------
 */
#ifndef PLLLVM_H
#define PLLLVM_H

#include "fmgr.h"

/*
 * The language is built on funccache (cached_function_compile), which
 * appeared in PostgreSQL 18.  Only 20devel is checked (see PG_PIN).
 */
#if PG_VERSION_NUM < 180000
#error "plllvm requires PostgreSQL 18 or later"
#endif

/* keep in sync with META.json; plllvm.control carries major.minor only */
#define PLLLVM_VERSION "0.1.0"

/* GUCs (plllvm.c) */
extern bool plllvm_regress_test_mode;

#endif							/* PLLLVM_H */
