#!/usr/bin/env python3
"""Differential fuzzer for LANGUAGE plpgsql_jit against LANGUAGE plpgsql.

A seeded generator writes a PL/pgSQL function over the statements and types
that plpgsql_jit compiles (assignment, IF, LOOP, WHILE, FOR over integers,
EXIT and CONTINUE, nested blocks, RAISE at every level, RETURN; smallint,
integer, bigint, real, double precision, boolean) and a script that calls it: warm calls, then edge
arguments.  Most programs then open a transaction and walk through role
switches, REVOKE and GRANT of the functions the body calls (operators, casts,
abs, sqrt, mod), a group membership that is revoked, savepoints and
rollbacks.  The script runs in two sessions of one cluster, once with the
function created as plpgsql and once as plpgsql_jit, and the output of each
step (value, SQLSTATE, message, CONTEXT) is compared.

Every privilege change is made inside the transaction that the script rolls
back, and a check at the end fails the run if one leaked into the database.

A step is one of

  equal       the same output, or the same once the CONTEXT line of
              PL/pgSQL's expression and assignment (SPI path) is dropped
  stricter    plpgsql_jit raises 42501 where plpgsql returns or raises
              something else, or both raise it at different expressions; the
              role must really lack a function the body needs at that step,
              else it is a MISMATCH
  stale-privilege  plpgsql raises 42501 and plpgsql_jit does not, after a call
              that plpgsql_jit refused with 42501 where plpgsql went on; it
              is that only if plpgsql, run without the refused call, answers
              as plpgsql_jit does (L2)
  PERMISSIVE  plpgsql raises 42501 and plpgsql_jit does not: a bug
  MISMATCH    anything else

The comparison goes on after a stricter step.  A program is named by its
seed: "--seed S --start I --n 1" runs it again, and --out holds its script
and both outputs.  The compiled fraction is the share of programs whose
function ran compiled at least once (plllvm_pj_status()).  No timing.
Standard library only, run by make fuzz-pj against a running cluster.

--mode rec writes recursive programs instead: a function that calls itself
through a wrapper that catches, or through a SECURITY DEFINER one whose owner
lacks a function, with the recursive expression in an IF, ELSIF, WHILE, LOOP,
FOR, DECLARE, assignment or RETURN, and sometimes DISCARD PLANS or
CREATE OR REPLACE of the function in the middle of a call.  PL/pgSQL's inner
frames evaluate the expression an outer frame is running through SPI, and
SPI plans a custom plan for its first five runs, which plpgsql_jit's
compiled frames do not.  So a step may differ from PL/pgSQL, and is the stated
difference only if plpgsql_jit gives what PL/pgSQL gives under
plan_cache_mode = force_generic_plan or force_custom_plan, each step by
itself, so that a history of one then the other is allowed, or a 42501 for
the function the program revoked (stricter).  A step may also be a mix: an
answer that one of the modes gives, with the effects (NOTICE and the like) of
the custom plan as a prefix of them and they of the generic plan's, as
frames that took the custom plan and frames that took the generic one give;
the class is frame-mix.  Any other step is searched for a history: each call
run by PL/pgSQL under auto, generic or custom, or not at all (only a call
plpgsql_jit answered with that 42501).
One that is found is class "history" and printed.  Not found: PERMISSIVE if
PL/pgSQL raised 42501, else MISMATCH, except that a step where PL/pgSQL raises
42501 and plpgsql_jit returns without an error, in a SECURITY DEFINER program
after an earlier 42501 of plpgsql_jit in the same transaction, in a call
that reaches a nested frame, is class stale-privilege.  XX000 or a lost
connection is always a MISMATCH.
--mode ref writes programs over text, varchar, numeric and integer variables,
arguments and results, and int4[] locals with element stores, appends,
slices and subscripts past the ends, in the same steps as flat ones; a bit
of the first argument inverts each condition, so that a few warm calls reach
every branch.
--mode elem writes programs of one element type, int4, int8 or float8, whose
only work on arrays is to read and store elements, with a scalar sum, loops,
IF and the rare branch that no warm call takes, so that the function is
compiled by itself and the call that takes the branch is a deopt.  Arguments
are arrays of the other lower bounds, with NULL elements, empty, two-dimensional
or NULL; subscripts are NULL, raising, out of range, past either end or at the
ends of int4.  The run fails if no program had a deopt, or if fewer than
--floor-elem of the programs have a variant without a call of the executor.
--mode sql writes functions of PERFORM, of statements with no INTO and of
SELECT INTO over a small table, that run through SPI in compiled code:
parameters of every kind the statement may name, statements that raise, the
plan of 1 / n over no rows that tells a custom plan from a generic one, a
callee that says when it runs, branches, loops.  A SELECT INTO has one target
or several, STRICT or not, over no row, one or two, with a column more or
fewer than the targets.  Between the calls the script truncates and refills
the table, analyses it, creates and drops an index, discards the plans, changes
plan_cache_mode, the extra checks of PL/pgSQL and the type of a column, adds a
column; a second argument that is NULL sends a call to the interpreter, so
that the plans of the two paths are the same ones.  Equal output is also what
a function gives that PL/pgSQL ran, so the run fails if fewer than --floor-sql
of the programs ran a statement through SPI in compiled code
(plllvm_pj_stats() sql_execs), and if fewer than --floor-into of the programs
whose statements are all SELECT INTO did.  Of the 1500 programs of seeds 21 to
23 about 61% and 43% did.
--mode dml writes the same programs of INSERT, UPDATE, DELETE and a
RETURNING INTO over the table sq_w, which also has its default, a trigger and a
rule that the script creates and drops between the calls (so a function goes
from compiled to PL/pgSQL's and back), and a table that is truncated and
refilled.  The table is printed after every call, so a write that differs is
a difference.  The run fails if fewer than --floor-dml of the programs ran a
statement that writes through SPI in compiled code.
--cx adds CASE statements, searched and simple (a selector of any type of the
mode, a list of values in a WHEN, with and without ELSE), and SELECT
expression INTO a variable to a flat or ref program.  The choices of these
come from a generator of their own, so that a program without --cx is the
same as it was; with --cx the programs are other ones.  Equal output is also
what a function gives that PL/pgSQL ran, so the programs that contain each
construct are counted, and so are those among them whose function ran
compiled: --floor-cx is the share of those in the body that must have.  The CASE or
SELECT INTO then counts only if it stands in the body outside any branch,
and the function had compiled calls and no deopt (a RETURN before it is not
excluded).

A third of the programs call f directly instead of through the wrapper.  The
schema name is normalised.  Every statement of a script is a step.

Usage: pj_fuzz.py --psql <psql> --host <dir> --port <port> [--n N] [--start I]
                  [--seed S] [--opt-level 0|2|3] [--out dir] [--floor 0.5]
                  [--mode flat|rec|ref|elem|sql|dml] [--cx] [--floor-cx 0.15]
                  [--floor-elem 0.9] [--floor-sql 0.4] [--floor-into 0.3]
                  [--floor-dml 0.25]
"""
import argparse
import os
import random
import re
import subprocess
import sys
from collections import Counter

TYPES = {"int2": "smallint", "int4": "integer", "int8": "bigint",
         "float4": "real", "float8": "double precision", "bool": "boolean"}
INTS = ["int2", "int4", "int8"]
FLTS = ["float4", "float8"]
NUMS = INTS + FLTS
SQL2PG = {v: k for k, v in TYPES.items()}
DB = "pj_fuzz"
SCHEMAS = {"plpgsql": "fzs", "plpgsql_jit": "fzj"}
ROLE = "fz_r1"
GROUP = "fz_grp"
OWNER = "fz_own"

# int4, int8, float8 and boolean are what the compilers handle; the other
# types are declined, kept rare so that they do not drown the rest
POOL = ["int4"] * 8 + ["int8"] * 4 + ["float8"] * 4 + ["bool"] * 3
RARE = ["int2", "float4"]
INT_MIN = "(-2147483647 - 1)"

INT_LITS = [0, 0, 1, 1, 2, 3, 5, 7, 10, 100, -1, -1, -2, 2147483647, -2147483647]
EDGE = {"int2": ["0", "1", "-1", "32767", "-32768", "2", "100"],
        "int4": ["0", "1", "-1", "-1", "2147483647", "-2147483647", "-2147483648",
                 "-2147483648", "2", "46341", "65536", "100"],
        "int8": ["0", "1", "-1", "-1", "9223372036854775807", "-9223372036854775808",
                 "-9223372036854775807", "3037000500", "2", "100000", "2147483648"],
        "float4": ["0", "1", "-1", "1.5", "'NaN'", "'Infinity'", "3.5e38", "-0.5",
                   "1e-30"],
        "float8": ["0", "1", "-1", "1.5", "'NaN'", "'Infinity'", "'-Infinity'",
                   "1e308", "-1e308", "-0.5", "0.1", "1e-200", "1e-160", "-1e-200",
                   "1e-308", "4.9e-324", "1e200"],
        "bool": ["true", "false"]}
HARMLESS = {"int2": ["1", "2", "3", "5"], "int4": ["1", "2", "3", "5"],
            "int8": ["1", "2", "3", "5"], "float4": ["1.5", "2", "0.5"],
            "float8": ["1.5", "2", "0.5"], "bool": ["true", "false"]}


class Catalog:
    """The operator, cast and other functions of the six types as regprocedure
    text: ops by (left, name, right), unary by (name, type), casts by (from,
    to), fns by (name, first argument type).  universe is all of them."""

    def __init__(self, ops, unary, casts, fns):
        self.ops, self.unary, self.casts, self.fns = ops, unary, casts, fns
        self.universe = sorted(set(ops.values()) | set(unary.values()) |
                               set(casts.values()) | set(fns.values()))


def load_catalog(run_sql):
    tl = ",".join("'%s'::regtype" % t for t in TYPES.values())
    ops, unary, casts, fns = {}, {}, {}, {}
    for line in run_sql(
            "SELECT format_type(oprleft, NULL), oprname, format_type(oprright, NULL),"
            " oprcode::regprocedure FROM pg_operator"
            " WHERE oprleft IN (%s) AND oprright IN (%s)" % (tl, tl)):
        a, op, b, code = line.split("\t")
        ops[(SQL2PG[a], op, SQL2PG[b])] = code
    for line in run_sql(
            "SELECT oprname, format_type(oprright, NULL), oprcode::regprocedure"
            " FROM pg_operator WHERE oprleft = 0 AND oprright IN (%s)" % tl):
        op, a, code = line.split("\t")
        unary[(op, SQL2PG[a])] = code
    for line in run_sql(
            "SELECT format_type(castsource, NULL), format_type(casttarget, NULL),"
            " castfunc::regprocedure FROM pg_cast WHERE castfunc <> 0"
            " AND castsource IN (%s) AND casttarget IN (%s)" % (tl, tl)):
        a, b, code = line.split("\t")
        casts[(SQL2PG[a], SQL2PG[b])] = code
    for line in run_sql(
            "SELECT proname, format_type(proargtypes[0], NULL), oid::regprocedure"
            " FROM pg_proc WHERE pronamespace = 'pg_catalog'::regnamespace"
            " AND proname IN ('abs', 'sqrt', 'mod') AND proargtypes[0] IN (%s)" % tl):
        n, a, code = line.split("\t")
        fns[(n, SQL2PG[a])] = code
    return Catalog(ops, unary, casts, fns)


class Gen:
    def __init__(self, rng, cat, cx=None):
        self.r = rng
        self.cx = cx                # a generator for CASE and SELECT INTO, or None
        self.used = set()           # the constructs of cx the program has
        self.top = set()            # those that stand in the body, outside any branch
        self.cat = cat
        self.procs = set()          # the functions the program may call
        self.nvar = 0
        self.scope = []             # visible variables, innermost last
        self.loops = []             # (label, is_loop)
        self.extra = []             # loop counters, declared at the top
        self.nlabel = 0

    # ---- expressions: each returns (text, type) with type <= the wanted one

    def lit(self, ty):
        r = self.r
        if ty == "bool":
            return r.choice(["true", "false", "NULL::boolean"]), "bool"
        if ty != "int2" and r.random() < 0.07:
            nt = {"int4": "int2", "int8": r.choice(["int4", "int2"]),
                  "float4": "float4",
                  "float8": r.choice(["float4", "int4", "float8"])}[ty]
            return "(NULL::%s)" % TYPES[nt], nt
        if ty in INTS:
            v = r.choice(INT_LITS)
            if ty == "int4" and r.random() < 0.1:
                return INT_MIN, ty
            if ty == "int2":
                return "(%d)::smallint" % max(-32767, min(32767, v)), ty
            if ty == "int8":
                return r.choice(["(%d)::bigint" % v, "9223372036854775807",
                                 "3037000500"]), ty
            return ("(%d)" % v if v < 0 else str(v)), ty
        v = r.choice(["0", "1", "0.5", "-1.5", "2", "1e10", "1e308", "'NaN'",
                      "'Infinity'", "3.5e38", "1e-200", "1e-160", "1e-308", "-1e-200"])
        return "(%s)::%s" % (v, TYPES[ty]), ty

    def var(self, ty):
        """A visible variable of a type that widens to ty, or None."""
        ok = {"int2": ["int2"], "int4": ["int2", "int4"],
              "int8": INTS, "float4": ["float4"], "float8": FLTS,
              "bool": ["bool"]}[ty]
        seen = {}
        for v in self.scope:
            seen[v["name"]] = v
        c = [v for v in seen.values() if v["ty"] in ok]
        return self.r.choice(c) if c else None

    def pty(self):
        t = self.r.choice(POOL)
        return self.r.choice(RARE) if self.r.random() < 0.015 else t

    def wider(self, a, b):
        return a if NUMS.index(a) >= NUMS.index(b) else b

    def note_cast(self, src, dst):
        """The function of the implicit cast of an assignment, a declaration
        or a RETURN, which a role without it must be refused."""
        f = self.cat.casts.get((src, dst)) if src != dst else None
        if f:
            self.procs.add(f)

    def op2(self, a, op, b):
        """The operand texts and types for 'a op b'; operands without a
        direct operator are cast to the wider type."""
        (ta, tb) = (a[1], b[1])
        if (ta, op, tb) in self.cat.ops:
            self.procs.add(self.cat.ops[(ta, op, tb)])
            return a[0], b[0], ta, tb
        to = "float8" if (ta in FLTS or tb in FLTS) else self.wider(ta, tb)
        ca = self.cast(a, to)
        cb = self.cast(b, to)
        self.procs.add(self.cat.ops.get((to, op, to), "int4pl(integer,integer)"))
        return ca[0], cb[0], to, to

    def cast(self, e, to):
        if e[1] == to:
            return e
        self.note_cast(e[1], to)
        return "(%s)::%s" % (e[0], TYPES[to]), to

    def num(self, ty, d):
        r = self.r
        if d <= 0 or r.random() < 0.25:
            v = self.var(ty) if r.random() < 0.7 else None
            if v:
                return v["name"], v["ty"]
            return self.lit(ty)
        x = r.random()
        if ty in INTS:
            if x < 0.52:
                op = r.choice(["+", "+", "-", "-", "*", "/", "%"])
                a = self.num(ty, d - 1)
                b = self.num(ty, d - 1)
                if op in "/%" and r.random() < 0.25:
                    b = ("(-1)", ty)
                ta, tb, rta, rtb = self.op2(a, op, b)
                return "(%s %s %s)" % (ta, op, tb), self.wider(rta, rtb)
            if x < 0.56:
                op = r.choice(["&", "|", "#"])
                a, b = self.num(ty, d - 1), self.num(ty, d - 1)
                ta, tb, rta, rtb = self.op2(a, op, b)
                return "(%s %s %s)" % (ta, op, tb), self.wider(a[1], b[1])
            if x < 0.57:
                a = self.num(ty, d - 1)
                op = r.choice(["<<", ">>"])
                if (a[1], op, "int4") in self.cat.ops:
                    self.procs.add(self.cat.ops[(a[1], op, "int4")])
                return "(%s %s %d)" % (a[0], op, r.choice([0, 1, 2, 31, 40])), a[1]
            if x < 0.62:
                a, b = self.num(ty, d - 1), self.num(ty, d - 1)
                ta, tb, rta, rtb = self.op2(a, "%", b)
                self.procs.add(self.cat.fns[("mod", self.wider(rta, rtb))])
                return "mod(%s, %s)" % (ta, tb), self.wider(rta, rtb)
            if x < 0.72:
                a = self.num(ty, d - 1)
                self.procs.add(self.cat.unary[("-", a[1])])
                return "(- %s)" % a[0], a[1]
            if x < 0.78:
                a = self.num(ty, d - 1)
                self.procs.add(self.cat.fns[("abs", a[1])])
                return "abs(%s)" % a[0], a[1]
            if x < 0.9:
                return self.case(ty, d)
            if x < 0.95:
                a, b = self.num(ty, d - 1), self.num(ty, d - 1)
                return "COALESCE(%s, %s)" % (a[0], b[0]), self.wider(a[1], b[1])
            src = r.choice(["int4", "int8", "float8"])
            a = self.num(src, d - 1)
            return self.cast(a, ty)
        # floats
        if x < 0.55:
            op = r.choice(["+", "-", "*", "/"])
            a = self.num(ty, d - 1)
            b = self.num(ty, d - 1)
            if a[1] in INTS:
                a = self.cast(a, "float8")
            if b[1] in INTS:
                b = self.cast(b, "float8")
            ta, tb, rta, rtb = self.op2(a, op, b)
            res = "float8" if "float8" in (a[1], b[1]) else "float4"
            return "(%s %s %s)" % (ta, op, tb), res
        if x < 0.65:
            a = self.num(ty, d - 1)
            self.procs.add(self.cat.unary[("-", a[1])])
            return "(- %s)" % a[0], a[1]
        if x < 0.75:
            a = self.num(ty, d - 1)
            self.procs.add(self.cat.fns[("abs", a[1])])
            return "abs(%s)" % a[0], a[1]
        if x < 0.82 and ty == "float8":
            a = self.cast(self.num(ty, d - 1), "float8")
            self.procs.add(self.cat.fns[("sqrt", "float8")])
            return "sqrt(%s)" % a[0], "float8"
        if x < 0.9:
            return self.case(ty, d)
        src = r.choice(["int4", "int8", "float8"])
        a = self.num(src, d - 1)
        return self.cast(a, ty)

    def result(self, a, b):
        if a in FLTS or b in FLTS:
            return "float8" if "float8" in (a, b) else "float4"
        return self.wider(a, b)

    def case(self, ty, d):
        c = self.boolean(d - 1)
        a, b = self.num(ty, d - 1), self.num(ty, d - 1)
        return ("CASE WHEN %s THEN %s ELSE %s END" % (c[0], a[0], b[0]),
                self.result(a[1], b[1]) if (a[1] in NUMS and b[1] in NUMS)
                else a[1])

    def boolean(self, d):
        r = self.r
        if d <= 0 or r.random() < 0.15:
            v = self.var("bool") if r.random() < 0.6 else None
            if v:
                return v["name"], "bool"
            return self.lit("bool")
        x = r.random()
        if x < 0.5:
            ty = r.choice(["int4", "int4", "int8", "float8", "float8"])
            a, b = self.num(ty, d - 1), self.num(ty, d - 1)
            op = r.choice(["=", "<>", "<", "<=", ">", ">="])
            if a[1] in INTS and b[1] in FLTS:
                a = self.cast(a, "float8")
            if b[1] in INTS and a[1] in FLTS:
                b = self.cast(b, "float8")
            ta, tb, _, _ = self.op2(a, op, b)
            return "(%s %s %s)" % (ta, op, tb), "bool"
        if x < 0.65:
            a, b = self.boolean(d - 1), self.boolean(d - 1)
            return "(%s %s %s)" % (a[0], r.choice(["AND", "OR"]), b[0]), "bool"
        if x < 0.72:
            return "(NOT %s)" % self.boolean(d - 1)[0], "bool"
        if x < 0.8:
            a = self.num(r.choice(NUMS[1:3] + ["float8"]), d - 1)
            return "(%s IS %sNULL)" % (a[0], r.choice(["", "NOT "])), "bool"
        if x < 0.84:
            ty = r.choice(INTS)
            a, b = self.num(ty, d - 1), self.num(ty, d - 1)
            ta, tb, _, _ = self.op2(a, "=", b)
            return "(%s IS %sDISTINCT FROM %s)" % (ta, r.choice(["", "NOT "]), tb), "bool"
        if x < 0.95:
            a = self.boolean(d - 1)
            return "(%s IS %s)" % (a[0], r.choice(["TRUE", "NOT TRUE", "FALSE", "UNKNOWN"])), "bool"
        c = self.boolean(d - 1)
        return "CASE WHEN %s THEN %s ELSE %s END" % (
            c[0], self.boolean(d - 1)[0], self.boolean(d - 1)[0]), "bool"

    def expr(self, ty, d=2):
        return self.boolean(d) if ty == "bool" else self.num(ty, d)

    # ---- statements

    def newvar(self, ty, assignable=True):
        self.nvar += 1
        return {"name": "v%d" % self.nvar, "ty": ty, "assign": assignable}

    def assignable(self):
        seen = {}
        for v in self.scope:
            seen[v["name"]] = v
        return [v for v in seen.values() if v["assign"]]

    def assign_expr(self, ty):
        r = self.r
        x = r.random()
        if x < 0.04:
            nt = "bool" if ty == "bool" else r.choice(NUMS)
            e = ("NULL::%s" % TYPES[nt], nt)
        elif x < 0.06 and ty in INTS[:2] + ["float4"]:
            e = self.expr(r.choice(NUMS), 2)             # a narrowing cast
        elif x < 0.14 and ty in INTS[1:]:
            e = self.expr(INTS[INTS.index(ty) - 1], 2)
        elif x < 0.25 and ty == "float8":
            e = self.expr(r.choice(["int4", "int4", "int8"]), 2)
        else:
            e = self.expr(ty, 2)
        self.note_cast(e[1], ty)
        return e[0]

    def return_expr(self, ty):
        e = self.expr(ty, 2)
        self.note_cast(e[1], ty)
        return e[0]

    def stmts(self, depth, n):
        return [self.stmt(depth) for _ in range(n)]

    def raise_stmt(self):
        """RAISE at some level, with a message, a condition or nothing; the
        arguments are expressions, which can fail at any level."""
        r = self.r
        level = r.choice(["DEBUG", "LOG", "INFO", "NOTICE", "NOTICE", "WARNING",
                          "EXCEPTION"])
        x = r.random()
        if x < 0.03:
            return {"k": "raise", "text": "RAISE"}
        if x < 0.15:
            cond = r.choice(["division_by_zero", "SQLSTATE '22012'",
                             "unique_violation", "SQLSTATE '01000'"])
            return {"k": "raise", "text": "RAISE %s %s" % (level, cond)}
        args = [self.expr(r.choice(POOL), 1)[0] for _ in range(r.choice([0, 1, 1, 2, 3]))]
        msg = "r%d" % r.randint(0, 99)
        for a in args:
            msg += r.choice([" %", ": %", "%%%", " (%)"])
        if r.random() < 0.2:
            msg += " %%"
        return {"k": "raise", "text": "RAISE %s '%s'%s" % (
            level, msg, "".join(", " + a for a in args))}

    def cx_stmt(self, depth):
        """A CASE or a SELECT INTO.  The selector and the values of a simple
        CASE have one type, so the operator of each WHEN is known, and a role
        that lacks it is refused (42501) by the walk of privileges like any
        other function the body calls."""
        c = self.cx
        av = self.assignable()
        if av and c.random() < 0.3:
            v = c.choice(av)
            self.used.add("into")
            if depth == 3:
                self.top.add("into")
            return {"k": "into", "v": v["name"], "e": self.assign_expr(v["ty"])}
        self.used.add("case")
        if depth == 3:
            self.top.add("case")
        whens, simple = [], c.random() < 0.55
        sel = None
        if simple:
            ty = c.choice(["int4", "int4", "int8", "float8", "bool"])
            sel = self.cast(self.expr(ty, 1), ty)
            # parenthesised: a selector that is itself a CASE expression
            # would take the END of the statement's WHEN list for its own
            sel = ("(%s)" % sel[0], sel[1])
        for _ in range(c.randint(1, 3)):
            body = self.stmts(depth - 1, c.randint(1, 2))
            if simple:
                vals = [self.cast(self.expr(sel[1], 1), sel[1])
                        for _ in range(c.choice([1, 1, 1, 2, 3]))]
                for x in vals:
                    self.op2(sel, "=", x)
                whens.append((", ".join("(%s)" % x[0] for x in vals), body))
            else:
                whens.append((self.boolean(2)[0], body))
        other = self.stmts(depth - 1, c.randint(1, 2)) if c.random() < 0.6 else None
        return {"k": "case", "sel": sel[0] if sel else None, "whens": whens,
                "else": other}

    def stmt(self, depth):
        r = self.r
        if self.cx is not None and depth > 0 and self.cx.random() < 0.15:
            return self.cx_stmt(depth)
        x = r.random()
        if depth > 0 and r.random() < 0.08:
            return self.raise_stmt()
        av = self.assignable()
        if depth <= 0 or x < 0.35:
            if av:
                v = r.choice(av)
                return {"k": "assign", "v": v["name"], "e": self.assign_expr(v["ty"])}
            if depth <= 0:
                return {"k": "return", "e": self.return_expr(self.rettype)}
            x = 0.4
        if x < 0.5:
            node = {"k": "if", "c": self.boolean(2)[0],
                    "then": self.stmts(depth - 1, r.randint(1, 2)),
                    "elifs": [], "else": None}
            for _ in range(r.choice([0, 0, 1, 2])):
                node["elifs"].append((self.boolean(2)[0],
                                      self.stmts(depth - 1, r.randint(1, 2))))
            if r.random() < 0.5:
                node["else"] = self.stmts(depth - 1, r.randint(1, 2))
            return node
        if x < 0.72:
            return self.loop(depth)
        if x < 0.8:
            return self.block(depth)
        if x < 0.9 and self.can_exit():
            return self.exit()
        return {"k": "return", "e": self.return_expr(self.rettype)}

    def label(self, p):
        if self.r.random() < 0.4:
            self.nlabel += 1
            return "%s%d" % (p, self.nlabel)
        return None

    def bounds(self):
        """Bounds and step of a FOR: mostly small, some at the ends of int4
        where the loop variable or the step can overflow."""
        r = self.r
        k = r.randint(0, 6)
        x = r.random()
        if x < 0.2:
            return ("(2147483647 - %d)" % k, "2147483647",
                    r.choice([None, "1", "2", "3", "5"]))
        if x < 0.4:
            return (INT_MIN, "(%s + %d)" % (INT_MIN, k),
                    r.choice([None, "1", "2", "3", "5"]))
        if x < 0.5:
            return (INT_MIN, "2147483647",
                    r.choice(["2147483647", "1073741824", "2147483646"]))
        return (self.bound(), self.bound(),
                r.choice([None, None, "1", "2", "3", "0", self.bound()]))

    def loop(self, depth):
        r = self.r
        label = self.label("l")
        kind = r.choice(["loop", "while", "for", "for"])
        self.loops.append((label, True))
        try:
            if kind == "for":
                lo, hi, step = self.bounds()
                v = {"name": "i%d" % r.randint(1, 9), "ty": "int4", "assign": False}
                self.scope.append(v)
                body = self.stmts(depth - 1, r.randint(1, 3))
                self.scope.pop()
                return {"k": "fori", "label": label, "var": v["name"],
                        "rev": r.random() < 0.25, "lo": lo, "hi": hi,
                        "step": step, "body": body}
            cnt = "lc%d" % (len(self.extra) + 1)
            self.extra.append(cnt)
            body = self.stmts(depth - 1, r.randint(1, 3))
            if kind == "loop":
                return {"k": "loop", "label": label, "cnt": cnt,
                        "limit": r.randint(1, 6), "cond": self.boolean(1)[0]
                        if r.random() < 0.5 else None, "body": body}
            return {"k": "while", "label": label, "cnt": cnt,
                    "limit": r.randint(1, 6), "cond": self.boolean(2)[0], "body": body}
        finally:
            self.loops.pop()

    def bound(self):
        r = self.r
        if r.random() < 0.5:
            return str(r.randint(-2, 7))
        e = self.num("int4", 1)
        return "((%s) %% 9)" % e[0] if e[1] == "int4" else "(((%s)::int) %% 9)" % e[0]

    def can_exit(self):
        return any(loop for _, loop in self.loops) or \
            any(l for l, _ in self.loops)

    def exit(self):
        r = self.r
        cont = r.random() < 0.4 and any(loop for _, loop in self.loops)
        named = [l for l, loop in self.loops if l and (loop or not cont)]
        label = r.choice(named) if named and r.random() < 0.5 else None
        if label is None and not any(loop for _, loop in self.loops):
            label = r.choice(named)
        return {"k": "exit", "cont": cont, "label": label,
                "cond": self.boolean(2)[0] if r.random() < 0.8 else None}

    def block(self, depth):
        r = self.r
        label = self.label("b")
        n = len(self.scope)
        decls = []
        taken = set()
        for _ in range(r.randint(0, 2)):
            decls.append(self.decl(taken))
        self.loops.append((label, False))
        body = self.stmts(depth - 1, r.randint(1, 3))
        self.loops.pop()
        del self.scope[n:]
        return {"k": "block", "label": label, "decls": decls, "body": body}

    def decl(self, taken=None):
        r = self.r
        ty = self.pty()
        d = None
        if r.random() < 0.7:
            if r.random() < 0.1:
                nt = "bool" if ty == "bool" else r.choice(NUMS)
                d = "NULL::%s" % TYPES[nt]
                self.note_cast(nt, ty)
            else:
                e = self.expr(ty, 1)
                self.note_cast(e[1], ty)
                d = e[0]
        const = d is not None and r.random() < 0.15
        notnull = d is not None and not d.startswith("NULL") and r.random() < 0.15
        v = self.newvar(ty, not const)
        if taken is not None:
            free = [x["name"] for x in self.scope if x["name"] not in taken]
            if free and r.random() < 0.15:
                v["name"] = r.choice(free)                  # shadow
            taken.add(v["name"])
        self.scope.append(v)
        return (v["name"], ty, const, notnull, d)


def render_stmts(stmts, ind):
    return "".join(render(s, ind) for s in stmts)


def render(s, ind):
    p = "  " * ind
    k = s["k"]
    if k == "assign":
        return "%s%s := %s;\n" % (p, s["v"], s["e"])
    if k == "return":
        return "%sRETURN %s;\n" % (p, s["e"])
    if k == "raise":
        return "%s%s;\n" % (p, s["text"])
    if k == "into":
        return "%sSELECT %s INTO %s;\n" % (p, s["e"], s["v"])
    if k == "case":
        o = "%sCASE%s\n" % (p, " " + s["sel"] if s["sel"] else "")
        for w, b in s["whens"]:
            o += "%sWHEN %s THEN\n%s" % (p, w, render_stmts(b, ind + 1))
        if s["else"] is not None:
            o += "%sELSE\n%s" % (p, render_stmts(s["else"], ind + 1))
        return o + "%sEND CASE;\n" % p
    if k == "exit":
        return "%s%s%s%s;\n" % (p, "CONTINUE" if s["cont"] else "EXIT",
                                " " + s["label"] if s["label"] else "",
                                " WHEN " + s["cond"] if s["cond"] else "")
    lab = "%s<<%s>> " % (p, s["label"]) if s.get("label") else p
    if k == "if":
        o = "%sIF (%s) THEN\n%s" % (p, s["c"], render_stmts(s["then"], ind + 1))
        for c, b in s["elifs"]:
            o += "%sELSIF (%s) THEN\n%s" % (p, c, render_stmts(b, ind + 1))
        if s["else"] is not None:
            o += "%sELSE\n%s" % (p, render_stmts(s["else"], ind + 1))
        return o + "%sEND IF;\n" % p
    if k == "loop":
        o = "%s%s := 0;\n%sLOOP\n  %s%s := %s + 1;\n%s  EXIT WHEN %s > %d%s;\n" % (
            p, s["cnt"], lab, p, s["cnt"], s["cnt"], p, s["cnt"], s["limit"],
            " OR " + s["cond"] if s["cond"] else "")
        return o + render_stmts(s["body"], ind + 1) + "%sEND LOOP;\n" % p
    if k == "while":
        return ("%s%s := 0;\n%sWHILE (%s) AND %s < %d LOOP\n%s  %s := %s + 1;\n%s%sEND LOOP;\n"
                % (p, s["cnt"], lab, s["cond"], s["cnt"], s["limit"], p, s["cnt"], s["cnt"],
                   render_stmts(s["body"], ind + 1), p))
    if k == "fori":
        lo, hi = (s["hi"], s["lo"]) if s["rev"] else (s["lo"], s["hi"])
        return "%sFOR %s IN %s%s..%s%s LOOP\n%s%sEND LOOP;\n" % (
            lab, s["var"], "REVERSE " if s["rev"] else "", lo, hi,
            " BY " + s["step"] if s["step"] else "",
            render_stmts(s["body"], ind + 1), p)
    if k == "block":
        o = "%s<<%s>>\n" % (p, s["label"]) if s["label"] else ""
        if s["decls"]:
            o += "%sDECLARE\n" % p
            for n, ty, const, nn, d in s["decls"]:
                o += "%s  %s %s%s%s%s;\n" % (
                    p, n, "CONSTANT " if const else "", TYPES.get(ty, ty),
                    " NOT NULL" if nn else "", " := " + d if d else "")
        return "%s%sBEGIN\n%s%sEND;\n" % (o, p, render_stmts(s["body"], ind + 1), p)
    raise ValueError(k)


class Program:
    def __init__(self, seed, cat, cx=False):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.cat = cat
        g = Gen(r, cat, random.Random("cx " + seed) if cx else None)
        self.g = g
        self.params = []
        for i in range(r.choice([0, 1, 1, 2, 2, 3])):
            v = {"name": "p%d" % (i + 1), "ty": g.pty(), "assign": True}
            self.params.append(v)
            g.scope.append(v)
        self.rettype = g.pty()
        g.rettype = self.rettype
        self.attrs = r.choice(["", "", "IMMUTABLE", "STABLE", "STRICT", "IMMUTABLE STRICT"])
        self.decls = [g.decl() for _ in range(r.randint(0, 3))]
        self.body = g.stmts(3, r.randint(1, 4))
        self.ret = None
        if r.random() < 0.95:
            ty = self.rettype
            if r.random() < 0.04:
                ty = {"int2": "int4", "int4": "int8", "float4": "float8"}.get(ty, ty)
            self.ret = g.return_expr(ty)
        self.priv = r.random() < 0.75
        self.real = {}              # step -> the role really lacks a needed function
        self.steps = self.make_steps()

    def sig(self):
        return "(%s)" % ",".join(TYPES[p["ty"]] for p in self.params)

    def function(self):
        o = "CREATE FUNCTION f(%s) RETURNS %s LANGUAGE :lang %s AS $f$\n" % (
            ", ".join("%s %s" % (p["name"], TYPES[p["ty"]]) for p in self.params),
            TYPES[self.rettype], self.attrs)
        o += "DECLARE\n"
        for n, ty, const, nn, d in self.decls:
            o += "  %s %s%s%s%s;\n" % (n, "CONSTANT " if const else "", TYPES[ty],
                                       " NOT NULL" if nn else "", " := " + d if d else "")
        for c in self.g.extra:
            o += "  %s int;\n" % c
        o += "BEGIN\n" + render_stmts(self.body, 1)
        if self.ret:
            o += "  RETURN %s;\n" % self.ret
        return o + "END\n$f$;\n"

    def wrapper(self):
        a = ", ".join("%s %s" % (p["name"], TYPES[p["ty"]]) for p in self.params)
        n = ", ".join(p["name"] for p in self.params)
        return ("CREATE FUNCTION w(%s) RETURNS text LANGUAGE plpgsql AS $w$\n"
                "BEGIN PERFORM f(%s); RETURN 'ok';\n"
                "EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;\nEND $w$;\n"
                % (a, n))

    def args(self, kind):
        r = self.rng
        out = []
        for p in self.params:
            t = p["ty"]
            if kind == "harmless":
                v = r.choice(HARMLESS[t])
            else:
                v = "NULL" if r.random() < 0.08 else r.choice(EDGE[t] + HARMLESS[t])
            out.append("(%s)::%s" % (v, TYPES[t]))
        return ", ".join(out)

    def call(self, kind, fn="f"):
        return "SELECT %s(%s);" % (fn, self.args(kind))

    def make_steps(self):
        r = self.rng
        st = ["@create", "@wrapper"]
        for _ in range(3):
            st.append(self.call("harmless"))
        for _ in range(r.randint(4, 10)):
            st.append(self.call(r.choice(["harmless", "edge", "edge", "edge"])))
        if self.params:
            gs = ", ".join("%s::%s" % (
                {"bool": "(i % 2 = 0)"}.get(p["ty"], "(i - 3)"), TYPES[p["ty"]])
                for p in self.params)
            st.append("SELECT f(%s) FROM generate_series(1, 6) i;" % gs)
        if not self.priv:
            st.append(self.call("edge", "w"))
            return st
        self.walk(st)
        return st

    def walk(self, st):
        """A random walk in one transaction.  A call that may fail is made
        through w(), which catches, or between SAVEPOINT and ROLLBACK TO, so
        that an error does not abort the rest.  A model of the role, the
        revoked functions and the group membership says at each call whether
        the role really lacks a function the body needs."""
        r = self.rng
        procs = sorted(self.g.procs)
        m = {"role": "su", "revoked": set(), "granted": set(), "member": True}

        def lacks():
            return m["role"] == "r1" and any(
                p in m["revoked"] and not (m["member"] and p in m["granted"])
                for p in procs)

        def add(s, call=False):
            if call:
                self.real[len(st)] = lacks()
            st.append(s)

        def pick():
            if procs and r.random() < 0.7:
                return r.choice(procs)
            return r.choice(self.cat.universe)

        def snapshot():
            return {k: (set(v) if isinstance(v, set) else v) for k, v in m.items()}

        def owner_change():
            was = m["role"]
            if was == "r1":
                add("RESET ROLE;")
                m["role"] = "su"
            p, x = pick(), r.random()
            if x < 0.5:
                add("REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC;" % p)
                m["revoked"].add(p)
            elif x < 0.62:
                add("GRANT EXECUTE ON FUNCTION %s TO PUBLIC;" % p)
                m["revoked"].discard(p)
            elif x < 0.74:
                add("GRANT EXECUTE ON FUNCTION %s TO %s;" % (p, GROUP))
                m["granted"].add(p)
            elif x < 0.9:
                add("REVOKE %s FROM %s;" % (GROUP, ROLE))
                m["member"] = False
            else:
                add("GRANT %s TO %s;" % (GROUP, ROLE))
                m["member"] = True
            if was == "r1":
                add("SET ROLE %s;" % ROLE)
                m["role"] = "r1"

        nsp = 0
        add("BEGIN;")
        for _ in range(r.randint(8, 18)):
            x = r.random()
            if x < 0.28:
                add(self.call("edge", "w"), True)
            elif x < 0.5:
                nsp += 1
                add("SAVEPOINT s%d;" % nsp)
                add(self.call(r.choice(["harmless", "edge", "edge"])), True)
                add("ROLLBACK TO s%d;" % nsp)
            elif x < 0.64:
                if m["role"] == "su":
                    add(r.choice(["SET ROLE %s;", "SET LOCAL ROLE %s;"]) % ROLE)
                    m["role"] = "r1"
                else:
                    add("RESET ROLE;")
                    m["role"] = "su"
            elif x < 0.9:
                owner_change()
            else:
                # a change that is undone by ROLLBACK TO, then a call
                nsp += 1
                saved = snapshot()
                add("SAVEPOINT s%d;" % nsp)
                owner_change()
                add(self.call("edge", "w"), True)
                add("ROLLBACK TO s%d;" % nsp)
                m.update(saved)
                add(self.call("edge", "w"), True)
        add("ROLLBACK;")


# ---- programs over text, varchar and numeric (--mode ref)

RT = {"text": "text", "varchar": "varchar", "numeric": "numeric", "int4": "integer"}
REF_POOL = ["text"] * 5 + ["varchar"] * 2 + ["numeric"] * 4 + ["int4"] * 3
REF_HARMLESS = {"text": ["'abc'", "'Hello'", "'x y z'", "'a'", "'some more text'", "'bb'"],
                "varchar": ["'abc'", "'Hello'", "'x y z'", "'a'", "'bb'"],
                "numeric": ["1", "2", "3", "1.5", "4.25", "7"],
                "int4": ["1", "2", "3", "5"]}
REF_EDGE = {"text": ["''", "' '", "'  pad  '", "repeat('ab', 5000)", "'%_x'",
                     "repeat(md5('1'), 400)", "'é'", "NULL"],
            "varchar": ["''", "' '", "repeat('ab', 5000)", "'é'", "NULL"],
            "numeric": ["0", "-1", "0.5", "'NaN'", "'Infinity'", "1e100", "-0.5",
                        "123456789.123456789", "99999.995", "NULL"],
            "int4": ["0", "-1", "-2", "2147483647", "-2147483648", "100", "NULL"]}
REF_LITS = {"text": ["'abc'", "''", "' '", "'Hello World'", "'x'", "'aXb'", "'%a%'"],
            "numeric": ["0", "1", "2", "(-1)", "1.5", "0.25", "100.125", "(-2.5)"],
            "int4": ["0", "1", "2", "3", "(-1)", "5"]}
REF_DECL = {"text": ["text"] * 5 + ["name"],
            "varchar": ["varchar"] * 7 + ["varchar(6)"],
            "numeric": ["numeric"] * 9 + ["numeric(8,2)"],
            "int4": ["int4"]}


class RefCat:
    """Functions, operators and casts of text, numeric and integer as
    regprocedure text, looked up when first used."""

    def __init__(self, run_sql):
        self.run = run_sql
        self.cache = {}
        self.oid = {t: int(run_sql("SELECT '%s'::regtype::oid" % t)[0])
                    for t in ("text", "numeric", "integer", "boolean", "name",
                              "character varying")}

    def _one(self, key, q):
        if key not in self.cache:
            rows = self.run(q)
            self.cache[key] = rows[0] if rows else None
        return self.cache[key]

    def fn(self, name, *types):
        vec = " ".join(str(self.oid[t]) for t in types)
        return self._one(("fn", name, vec),
                         "SELECT oid::regprocedure FROM pg_proc WHERE pronamespace = "
                         "'pg_catalog'::regnamespace AND proname = '%s' AND "
                         "proargtypes::text = '%s'" % (name, vec))

    def op(self, left, name, right):
        return self._one(("op", left, name, right),
                         "SELECT oprcode::regprocedure FROM pg_operator WHERE oprname = '%s' "
                         "AND oprleft = '%s'::regtype AND oprright = '%s'::regtype"
                         % (name, left, right))

    def cast(self, src, dst):
        return self._one(("cast", src, dst),
                         "SELECT castfunc::regprocedure FROM pg_cast WHERE castsource = "
                         "'%s'::regtype AND casttarget = '%s'::regtype AND castfunc <> 0"
                         % (src, dst))


class RefGen:
    """Statements over variables of text, varchar, numeric and integer, where
    every condition can be flipped by a bit of the first argument, so that a
    few calls reach every branch."""

    def __init__(self, rng, cat, cx=None):
        self.r = rng
        self.cx = cx                # as in Gen
        self.used = set()
        self.top = set()
        self.cat = cat
        self.procs = set()
        self.nvar = 0
        self.scope = []
        self.extra = []
        self.nbit = 0
        self.nlabel = 0
        self.loops = []

    def use(self, f):
        if f:
            self.procs.add(f)

    def base(self, ty):
        return "text" if ty == "varchar" else ty

    def var(self, kind):
        seen = {}
        for v in self.scope:
            seen[v["name"]] = v
        ok = ("text", "varchar") if kind == "text" else (kind,)
        c = [v for v in seen.values() if v["ty"] in ok]
        return self.r.choice(c) if c else None

    def text(self, d):
        r = self.r
        v = self.var("arr") if r.random() < 0.04 else None
        if v:
            return "COALESCE(%s::text, 'n')" % v["name"]
        if d <= 0 or r.random() < 0.25:
            v = self.var("text") if r.random() < 0.75 else None
            if v:
                return v["name"]
            return r.choice(REF_LITS["text"]) if r.random() < 0.92 else "NULL::text"
        x = r.random()
        c = self.cat
        a = self.text(d - 1)
        if x < 0.25:
            b = self.text(d - 1)
            self.use(c.op("text", "||", "text"))
            return "(%s || %s)" % (a, b)
        if x < 0.32:
            n = self.num(d - 1)
            self.use(c.op("text", "||", "text"))
            return "(%s || (%s)::text)" % (a, n)
        if x < 0.4:
            f = r.choice(["upper", "lower", "initcap", "btrim", "reverse"])
            self.use(c.fn(f, "text"))
            return "%s(%s)" % (f, a)
        if x < 0.5:
            f = r.choice(["left", "right", "repeat"])
            self.use(c.fn(f, "text", "integer"))
            k = r.choice(["0", "1", "2", "3", "(-1)", "length(%s) %% 4" % a])
            if "length" in k:
                self.use(c.fn("length", "text"))
                self.use(c.op("integer", "%", "integer"))
            if f == "repeat":
                k = r.choice(["0", "1", "2", "3"])
            return "%s(%s, %s)" % (f, a, k)
        if x < 0.6:
            self.use(c.fn("substr", "text", "integer", "integer"))
            return "substr(%s, %s, %s)" % (a, r.choice(["1", "2", "0", "(-1)"]),
                                           r.choice(["1", "2", "3", "0", self.int(0)]))
        if x < 0.66:
            self.use(c.fn("replace", "text", "text", "text"))
            return "replace(%s, 'a', %s)" % (a, r.choice(["'cc'", "''", "'a'"]))
        if x < 0.72:
            self.use(c.fn("lpad", "text", "integer", "text"))
            return "lpad(%s, %s, 'x')" % (a, r.choice(["0", "1", "4", "6"]))
        if x < 0.82:
            b = self.text(d - 1)
            return "COALESCE(%s, %s)" % (a, b)
        if x < 0.88:
            b = self.text(d - 1)
            self.use(c.op("text", "=", "text"))
            return "NULLIF(%s, %s)" % (a, b)
        b = self.text(d - 1)
        e = self.boolean(d - 1, flip=False)
        return "CASE WHEN %s THEN %s ELSE %s END" % (e, a, b)

    def num(self, d):
        r = self.r
        c = self.cat
        if d <= 0 or r.random() < 0.25:
            v = self.var("numeric") if r.random() < 0.7 else None
            if v:
                return v["name"]
            return r.choice(REF_LITS["numeric"]) if r.random() < 0.93 else "NULL::numeric"
        x = r.random()
        a = self.num(d - 1)
        if x < 0.45:
            op = r.choice(["+", "-", "*", "/"])
            b = self.num(d - 1)
            if op == "/" and not b.startswith("p"):
                self.use(c.fn("abs", "numeric"))
                self.use(c.op("numeric", "+", "numeric"))
                b = "(abs(%s) + 1)" % b
            self.use(c.op("numeric", op, "numeric"))
            return "(%s %s %s)" % (a, op, b)
        if x < 0.55:
            self.use(c.fn("round", "numeric", "integer"))
            return "round(%s, %s)" % (a, r.choice(["0", "1", "2"]))
        if x < 0.62:
            self.use(c.fn("abs", "numeric"))
            return "abs(%s)" % a
        if x < 0.7:
            i = self.int(d - 1)
            self.use(c.cast("integer", "numeric"))
            self.use(c.op("numeric", "+", "numeric"))
            return "(%s + (%s)::numeric)" % (a, i)
        if x < 0.76:
            self.use(c.fn("sqrt", "numeric"))
            self.use(c.fn("abs", "numeric"))
            return "sqrt(abs(%s))" % a
        if x < 0.84:
            b = self.num(d - 1)
            return "COALESCE(%s, %s)" % (a, b)
        if x < 0.9:
            t = self.text(d - 1)
            self.use(c.fn("length", "text"))
            self.use(c.cast("integer", "numeric"))
            return "(length(%s))::numeric" % t
        b = self.num(d - 1)
        e = self.boolean(d - 1, flip=False)
        return "CASE WHEN %s THEN %s ELSE %s END" % (e, a, b)

    def int(self, d):
        r = self.r
        c = self.cat
        if d <= 0 or r.random() < 0.3:
            v = self.var("int4") if r.random() < 0.7 else None
            if v:
                return v["name"]
            return r.choice(REF_LITS["int4"])
        x = r.random()
        v = self.var("arr") if r.random() < 0.1 else None
        if v:
            return "COALESCE(%s[%s], 7)" % (v["name"], self.subscript())
        if x < 0.4:
            self.use(c.fn("length", "text"))
            return "length(%s)" % self.text(d - 1)
        if x < 0.55:
            self.use(c.fn("strpos", "text", "text"))
            return "strpos(%s, %s)" % (self.text(d - 1), self.text(d - 1))
        op = r.choice(["+", "-", "*"])
        self.use(c.op("integer", op, "integer"))
        return "(%s %s %s)" % (self.int(d - 1), op, self.int(d - 1))

    def boolean(self, d, flip=True):
        """A condition.  With flip, one bit of sel inverts it."""
        r = self.r
        c = self.cat
        x = r.random()
        if d <= 0 or x < 0.3:
            op = r.choice(["=", "<>", "<", ">="])
            self.use(c.op("text", op, "text"))
            e = "%s %s %s" % (self.text(d - 1), op, self.text(d - 1))
        elif x < 0.5:
            op = r.choice(["=", "<", ">", "<>"])
            self.use(c.op("numeric", op, "numeric"))
            e = "%s %s %s" % (self.num(d - 1), op, self.num(d - 1))
        elif x < 0.65:
            op = r.choice(["<", ">", "="])
            self.use(c.op("integer", op, "integer"))
            e = "%s %s %s" % (self.int(d - 1), op, r.choice(["0", "1", "2", "3"]))
        elif x < 0.78:
            e = "%s IS %sNULL" % (self.text(d - 1), r.choice(["", "NOT "]))
        elif x < 0.88:
            self.use(c.op("text", "~~", "text"))
            e = "%s LIKE %s" % (self.text(d - 1), r.choice(["'%a%'", "'x%'", "'_'"]))
        else:
            a = self.boolean(d - 1, flip=False)
            b = self.boolean(d - 1, flip=False)
            e = "%s %s %s" % (a, r.choice(["AND", "OR"]), b)
        e = "(%s)" % e
        if not flip:
            return e
        bit = self.nbit
        self.nbit += 1
        for op in (">>", "&", "="):
            self.use(c.op("integer", op, "integer"))
        return "(COALESCE(%s, false) IS DISTINCT FROM ((sel >> %d) & 1 = 1))" % (e, bit)

    def value(self, ty, d=2):
        if ty in ("text", "varchar", "name"):
            return self.text(d)
        if ty == "numeric":
            return self.num(d)
        return self.int(d)

    def assignable(self):
        seen = {}
        for v in self.scope:
            seen[v["name"]] = v
        return [v for v in seen.values() if v["assign"]]

    def assign(self):
        r = self.r
        v = r.choice(self.assignable())
        ty = v["ty"]
        if v["ty"] == "int4" and r.random() < 0.08:
            self.use(self.cat.cast("numeric", "integer"))
            e = self.num(2)
        elif ty == "numeric" and r.random() < 0.1:
            self.use(self.cat.cast("integer", "numeric"))
            e = self.int(2)
        elif r.random() < 0.15 and ty in ("text", "varchar"):
            o = self.var("text")
            e = o["name"] if o else self.text(1)
        else:
            e = self.value(ty)
        self.note_typmod(v)
        return {"k": "assign", "v": v["name"], "e": e}

    def note_typmod(self, v):
        """The coercion function of an assignment to varchar(n) or numeric(p,s)
        is in the tree, and a role without it is refused."""
        decl = v.get("decl", "")
        if decl.startswith("varchar("):
            self.use(self.cat.fn("varchar", "character varying", "integer", "boolean"))
        elif decl.startswith("numeric("):
            self.use(self.cat.fn("numeric", "numeric", "integer"))

    def subscript(self):
        # below, inside and past the ends of a small array
        r = self.r
        if r.random() < 0.6:
            return r.choice(["1", "2", "3", "4", "0", "(-1)"])
        for op in ("%", "+"):
            self.use(self.cat.op("integer", op, "integer"))
        return "(COALESCE(%s, 2) %% 4 + 1)" % self.int(1)

    def arr_stmt(self):
        r = self.r
        a = self.var("arr")["name"]
        x = r.random()
        if x < 0.5:
            return {"k": "assign", "v": "%s[%s]" % (a, self.subscript()),
                    "e": self.int(1)}
        if x < 0.65:
            return {"k": "assign", "v": a, "e": "%s || %s" % (a, self.int(1))}
        if x < 0.8:
            return {"k": "assign", "v": a, "e": "ARRAY[%s, %s, %s]::int4[]" % (
                self.int(1), self.int(1), self.int(0))}
        if x < 0.9:
            return {"k": "assign", "v": a, "e": "%s[%s:%s]" % (
                a, self.subscript(), self.subscript())}
        return {"k": "assign", "v": a, "e": a}

    def stmts(self, depth, n):
        return [self.stmt(depth) for _ in range(n)]

    def cx_stmt(self, depth):
        """A CASE over a selector of text, varchar, numeric or integer, or a
        SELECT INTO a variable of one of them."""
        c = self.cx
        av = self.assignable()
        if av and c.random() < 0.3:
            v = c.choice(av)
            self.used.add("into")
            if depth == 3:
                self.top.add("into")
            e = self.value(v["ty"])
            self.note_typmod(v)
            return {"k": "into", "v": v["name"], "e": e}
        self.used.add("case")
        if depth == 3:
            self.top.add("case")
        whens, sel = [], None
        if c.random() < 0.4:
            for _ in range(c.randint(1, 3)):
                whens.append((self.boolean(2), self.stmts(depth - 1, c.randint(1, 2))))
        else:
            # the selector takes one of four values, by two bits of the first
            # argument, so that every arm is reached by some call
            ty = c.choice(["text", "text", "varchar", "numeric", "int4"])
            pool = [c.choice(REF_LITS["text" if ty == "varchar" else ty])
                    if c.random() < 0.9 else "NULL" for _ in range(4)]
            bit = self.nbit
            self.nbit += 2
            for op in (">>", "&", "+"):
                self.use(self.cat.op("integer", op, "integer"))
            self.use(self.cat.op(self.base(ty), "=", self.base(ty)))
            sel = "(ARRAY[%s]::%s[])[((sel >> %d) & 3) + 1]" % (
                ", ".join(pool), self.base(ty), bit)
            if ty == "varchar":
                sel = "(%s)::varchar" % sel
            sel = "(%s)" % sel
            for _ in range(c.randint(1, 3)):
                vals = ["(%s)" % c.choice(pool) for _ in range(c.choice([1, 1, 2]))]
                whens.append((", ".join(vals), self.stmts(depth - 1, c.randint(1, 2))))
        other = self.stmts(depth - 1, c.randint(1, 2)) if c.random() < 0.6 else None
        return {"k": "case", "sel": sel, "whens": whens, "else": other}

    def stmt(self, depth):
        r = self.r
        if self.cx is not None and depth > 0 and self.cx.random() < 0.18:
            return self.cx_stmt(depth)
        if r.random() < 0.1 and self.var("arr") is not None:
            return self.arr_stmt()
        x = r.random()
        if depth <= 0 or x < 0.4:
            return self.assign()
        if x < 0.5:
            a = self.assign()
            v = self.var("text")
            if v is None:
                return a
            # y := x; x := ...; the copy outlives the assignment to its source
            y = r.choice(self.assignable())
            body = [{"k": "assign", "v": y["name"], "e": v["name"]
                     if y["ty"] in ("text", "varchar") else self.value(y["ty"])}, a]
            return {"k": "block", "label": None, "decls": [], "body": body}
        if x < 0.68:
            node = {"k": "if", "c": self.boolean(2),
                    "then": self.stmts(depth - 1, r.randint(1, 2)),
                    "elifs": [], "else": None}
            for _ in range(r.choice([0, 0, 1])):
                node["elifs"].append((self.boolean(2),
                                      self.stmts(depth - 1, r.randint(1, 2))))
            if r.random() < 0.5:
                node["else"] = self.stmts(depth - 1, r.randint(1, 2))
            return node
        if x < 0.84:
            return self.loop(depth)
        if x < 0.94:
            return self.block(depth)
        if r.random() < 0.5:
            return {"k": "return", "e": self.value(self.rettype)}
        return self.assign()

    def label(self, p):
        if self.r.random() < 0.4:
            self.nlabel += 1
            return "%s%d" % (p, self.nlabel)
        return None

    def loop(self, depth):
        r = self.r
        label = self.label("l")
        kind = r.choice(["fori", "fori", "while", "loop"])
        self.loops.append(label)
        try:
            if kind == "fori":
                v = {"name": "i%d" % r.randint(1, 9), "ty": "int4", "assign": False}
                self.scope.append(v)
                body = self.stmts(depth - 1, r.randint(1, 3))
                self.scope.pop()
                hi = r.choice(["1", "2", "3", "3", "2", "0"] if r.random() < 0.1 else
                              ["1", "2", "3"])
                return {"k": "fori", "label": label, "var": v["name"],
                        "rev": r.random() < 0.2, "lo": "1", "hi": hi, "step": None,
                        "body": body}
            cnt = "lc%d" % (len(self.extra) + 1)
            self.extra.append(cnt)
            body = self.stmts(depth - 1, r.randint(1, 3))
            if kind == "loop":
                return {"k": "loop", "label": label, "cnt": cnt, "limit": r.randint(1, 3),
                        "cond": None, "body": body}
            return {"k": "while", "label": label, "cnt": cnt, "limit": r.randint(1, 3),
                    "cond": self.boolean(2), "body": body}
        finally:
            self.loops.pop()

    def block(self, depth):
        r = self.r
        n = len(self.scope)
        decls = [self.decl() for _ in range(r.randint(1, 2))]
        body = self.stmts(depth - 1, r.randint(1, 3))
        del self.scope[n:]
        return {"k": "block", "label": None, "decls": decls, "body": body}

    def arr_decl(self):
        r = self.r
        d = r.choice(["'{}'", "'{1,2,3}'", "NULL", "ARRAY[%s, %s]::int4[]" % (
            self.int(1), self.int(0))])
        self.nvar += 1
        v = {"name": "a%d" % self.nvar, "ty": "arr", "assign": False}
        self.scope.append(v)
        return (v["name"], "int4[]", False, False, d)

    def decl(self):
        r = self.r
        if r.random() < 0.1:
            return self.arr_decl()
        ty = r.choice(REF_POOL)
        decl = r.choice(REF_DECL[ty])
        d = None
        if r.random() < 0.75:
            d = "NULL" if r.random() < 0.08 else self.value(ty, 1)
            if decl == "name" and d != "NULL":
                d = "'nm'"
        notnull = d is not None and d != "NULL" and r.random() < 0.1
        self.nvar += 1
        v = {"name": "v%d" % self.nvar, "ty": ty, "assign": True, "decl": decl}
        self.note_typmod(v)
        self.scope.append(v)
        if decl == "name":
            v["ty"] = "text"
        return (v["name"], decl, False, notnull, d)


class RefProgram(Program):
    """f(sel, ...) over text, varchar, numeric and integer arguments, locals
    and results; w(), the steps and the walk are those of Program."""

    def __init__(self, seed, cat, cx=False):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.cat = cat
        g = RefGen(r, cat, random.Random("cx " + seed) if cx else None)
        self.g = g
        self.params = [{"name": "sel", "ty": "int4", "assign": False}]
        for i in range(r.choice([1, 1, 2, 2, 3])):
            v = {"name": "p%d" % (i + 1), "ty": r.choice(REF_POOL), "assign": True}
            self.params.append(v)
            g.scope.append(v)
        self.cx = cx
        self.rettype = r.choice(["text", "text", "numeric", "int4", "varchar"])
        g.rettype = self.rettype
        self.attrs = r.choice(["", "", "IMMUTABLE", "STABLE", "IMMUTABLE STRICT"])
        self.decls = [g.decl() for _ in range(r.randint(1, 3))]
        self.body = g.stmts(3, r.randint(2, 4))
        self.ret = g.value(self.rettype, 2)
        self.priv = r.random() < 0.5
        self.real = {}
        self.steps = self.make_steps()

    def sig(self):
        return "(%s)" % ",".join(RT[p["ty"]] for p in self.params)

    def function(self):
        o = "CREATE FUNCTION f(%s) RETURNS %s LANGUAGE :lang %s AS $f$\n" % (
            ", ".join("%s %s" % (p["name"], RT[p["ty"]]) for p in self.params),
            RT[self.rettype], self.attrs)
        o += "DECLARE\n"
        for n, ty, const, nn, d in self.decls:
            o += "  %s %s%s%s;\n" % (n, ty, " NOT NULL" if nn else "",
                                     " := " + d if d else "")
        for c in self.g.extra:
            o += "  %s int;\n" % c
        o += "BEGIN\n" + render_stmts(self.body, 1)
        return o + "  RETURN %s;\nEND\n$f$;\n" % self.ret

    def wrapper(self):
        a = ", ".join("%s %s" % (p["name"], RT[p["ty"]]) for p in self.params)
        n = ", ".join(p["name"] for p in self.params)
        return ("CREATE FUNCTION w(%s) RETURNS text LANGUAGE plpgsql AS $w$\n"
                "BEGIN PERFORM f(%s); RETURN 'ok';\n"
                "EXCEPTION WHEN OTHERS THEN RETURN format('%%s %%s', SQLSTATE, SQLERRM);\nEND $w$;\n"
                % (a, n))

    def args(self, kind, mask=None):
        r = self.rng
        nb = max(self.g.nbit, 1)
        out = []
        for p in self.params:
            t = p["ty"]
            if p["name"] == "sel":
                v = str(r.randrange(1 << min(nb, 20)) if mask is None else mask)
                if kind == "edge" and r.random() < 0.05:
                    v = "NULL"
            elif kind == "harmless":
                v = r.choice(REF_HARMLESS[t])
            else:
                v = r.choice(REF_EDGE[t] + REF_HARMLESS[t])
            out.append("(%s)::%s" % (v, RT[t]))
        return ", ".join(out)

    def make_steps(self):
        r = self.rng
        nb = min(max(self.g.nbit, 1), 20)
        full = (1 << nb) - 1
        st = ["@create", "@wrapper"]
        # every condition both ways: a mask and its complement
        st.append("SELECT f(%s);" % self.args("harmless", 0))
        st.append("SELECT f(%s);" % self.args("harmless", full))
        for _ in range(24 if self.cx else 8):
            m = r.randrange(full + 1)
            st.append("SELECT f(%s);" % self.args("harmless", m))
            st.append("SELECT f(%s);" % self.args("harmless", full ^ m))
        for _ in range(r.randint(4, 8)):
            st.append(self.call(r.choice(["harmless", "edge", "edge"])))
        gs = ", ".join("%s::%s" % ("(i * 5)" if p["name"] == "sel" else
                                   {"text": "('t' || i)", "varchar": "('v' || i)",
                                    "numeric": "(i - 3)", "int4": "(i - 3)"}[p["ty"]],
                                   RT[p["ty"]]) for p in self.params)
        st.append("SELECT f(%s) FROM generate_series(1, 6) i;" % gs)
        if not self.priv:
            st.append(self.call("edge", "w"))
            return st
        self.walk(st)
        return st


# ---- recursive programs (--mode rec)

# the recursive expression, a base case, and what f assigns before it
REC_E = ["wr(n - 1, m - 1) / m + v", "wr(n - 1, m) + v", "wr(n - 1, m - 1) + 100 / m",
         "(10 / m) + wr(n - 1, m - 1) + v", "wr(n - 1, nullif(m, 2)) + 10 / m",
         "mod(wr(n - 1, m - 1), m) + v", "wr(n - 1, m) * 2 + abs(m) / (n + m)",
         "wr2(n - 1, m - 1) / m + v"]
REC_BASE = ["10 / m", "10 / m + v", "abs(m) / m", "mod(n, m)", "v % 7", "1"]
REC_ASG = ["v := 1;", "v := NULL;", "v := length(t);", "t := t || 'q'; v := length(t) % 3;",
           "IF n = 2 THEN t := NULL; END IF; v := coalesce(length(t), 2);", "IF n = 3 THEN v := NULL; ELSE v := 1; END IF;",
           "v := abs(m);", "v := 5 / m;", "IF n = 2 THEN v := NULL; ELSE v := 1; END IF;"]
REC_RAISE = ["", "", "", "RAISE NOTICE 'f % %', n, m;", "RAISE WARNING 'w %', n + m;",
             "RAISE INFO 'i %', t;", "RAISE DEBUG 'd %', n / m;", "RAISE LOG 'l %', v;",
             "IF n = 2 THEN RAISE NOTICE 'two % %%', n, t; END IF;"]
REC_PRIV = ["int4mod(int4,int4)", "int4div(int4,int4)", "int4mul(int4,int4)",
            "int4pl(int4,int4)", "int4abs(int4)"]


def rec_shape(r, e):
    """The statement that holds the recursive expression e."""
    k = r.randrange(9)
    if k == 0:
        return "RETURN %s;" % e
    if k == 1:
        return "v := %s; RETURN v;" % e
    if k == 2:
        return "IF n = 99 THEN RETURN 0; ELSIF %s > 100 THEN RETURN 7; END IF; RETURN v;" % e
    if k == 3:
        return "WHILE i < 2 AND (%s) IS NOT NULL LOOP i := i + 1; END LOOP; RETURN i;" % e
    if k == 4:
        return "FOR j IN 1..%s LOOP i := i + 1; EXIT WHEN i > 2; END LOOP; RETURN i;" % e
    if k == 5:
        return "FOR j IN %s..2 LOOP i := i + 1; EXIT WHEN i > 2; END LOOP; RETURN i;" % e
    if k == 6:
        return "DECLARE d int := %s; BEGIN RETURN d + coalesce(v, 0); END;" % e
    if k == 7:
        return "LOOP EXIT WHEN (%s) IS NULL OR i > 1; i := i + 1; END LOOP; RETURN i;" % e
    return "IF n = 2 THEN v := wr(n - 1, m - 1); RETURN v; END IF; RETURN %s;" % e


class RecProgram:
    """f(n, m) calls itself through wr(), which catches an error or is
    SECURITY DEFINER with an owner that lacks the function f needs.  Every
    statement of the script is a step."""

    def __init__(self, seed, cat=None):
        r = random.Random(seed)
        self.seed = seed
        self.priv = r.random() < 0.5
        self.real = {}
        self.fn = r.choice(REC_PRIV) if self.priv else None
        e = r.choice(REC_E)
        guard = ("IF m IS NULL THEN RETURN 3; END IF;" if r.random() < 0.6
                 else "IF m IS NULL THEN m := 1; END IF;")
        body = ("DECLARE v int; i int := 0; t text := 'r';\nBEGIN\n  %s\n  t := upper(t) || n::text;\n"
                "  %s\n  IF n <= 0 THEN RETURN %s; END IF;\n"
                "  %s\n  %s\nEND" % (guard, r.choice(REC_RAISE), r.choice(REC_BASE),
                                      r.choice(REC_ASG), rec_shape(r, e)))
        self.again = "WHILE" in body or "LOOP EXIT WHEN" in body
        sd = self.priv and r.random() < 0.5
        self.direct = r.random() < 0.3
        if self.direct:
            # f calls itself; wr is still there for the steps that name it
            body = body.replace("wr2(", "f(").replace("wr(", "f(")
        self.sd = sd
        pre, helpers, x = "", [], r.random()
        if x < 0.1:
            pre = "IF n = 2 THEN PERFORM dp(); END IF;"
            helpers.append("CREATE FUNCTION dp() RETURNS void LANGUAGE plpgsql VOLATILE AS $d$ "
                           "BEGIN DISCARD PLANS; END $d$;")
        elif x < 0.2:
            pre = "IF n = 2 THEN PERFORM rp(); END IF;"
            helpers.append(
                "CREATE FUNCTION rp() RETURNS void LANGUAGE plpgsql VOLATILE AS $d$ BEGIN EXECUTE "
                "$q$CREATE OR REPLACE FUNCTION f(n int, m int) RETURNS int LANGUAGE XLANGX STABLE "
                "AS $f$ %s $f$ $q$; END $d$;" % body.replace("v int;", "v int; /* new */", 1))
        catch = r.random() < 0.85
        wbody = ("BEGIN %s RETURN f(n, m); EXCEPTION WHEN division_by_zero THEN RETURN %d; END"
                 % (pre, r.choice([0, 1, -1])) if catch else
                 "BEGIN %s RETURN f(n, m); END" % pre)
        st = helpers
        st.append("CREATE FUNCTION f(n int, m int) RETURNS int LANGUAGE XLANGX STABLE AS $f$\n%s $f$;"
                  % body)
        st.append("CREATE FUNCTION wr(n int, m int) RETURNS int LANGUAGE plpgsql STABLE %s AS $w$ %s $w$;"
                  % ("SECURITY DEFINER" if sd else "", wbody))
        # a catch further from the failing frame
        st.append("CREATE FUNCTION wr2(n int, m int) RETURNS int LANGUAGE plpgsql STABLE AS $w$ "
                  "BEGIN RETURN wr(n, m); EXCEPTION WHEN numeric_value_out_of_range THEN RETURN 2; "
                  "END $w$;")
        if sd:
            st.append("ALTER FUNCTION wr(int,int) OWNER TO %s;" % OWNER)

        def call():
            return "SELECT f(%d, %s);" % (r.randint(0, 4),
                                          r.choice([1, 1, 2, 3, 0, -1, -2, 5, "NULL"]))
        for _ in range(4):
            st.append("SELECT f(%d, %d);" % (r.randint(0, 3), r.choice([1, 2, 3, 5, 9])))
        # the sequence that left PL/pgSQL with a SPI plan source and no flags
        st += ["SELECT f(0,NULL);", "SELECT f(4,NULL);", "SELECT f(0,1);", "SELECT f(4,5);",
               "SELECT f(0,1);", "SELECT f(3,3);", "SELECT f(0,1);", "SELECT f(3,4);",
               "SELECT f(0,1);", "SELECT f(3,4);"]
        if self.priv:
            st.append("REVOKE EXECUTE ON FUNCTION %s FROM PUBLIC; GRANT EXECUTE ON FUNCTION %s TO %s;"
                      % (self.fn, self.fn, ROLE))
        for _ in range(r.randint(1, 3)):
            st.append("BEGIN;")
            for _ in range(r.randint(2, 7)):
                k = r.random()
                if self.priv and k < 0.15:
                    st.append("SET ROLE %s;" % ROLE)
                elif self.priv and k < 0.3:
                    st.append("RESET ROLE;")
                elif self.priv and k < 0.4:
                    st.append("SET ROLE %s;" % OWNER)
                else:
                    st += ["SAVEPOINT s;", call(), "ROLLBACK TO s;"]
            st += [r.choice(["COMMIT;", "ROLLBACK;"]), "RESET ROLE;"]
        self.steps = st

    def restore(self):
        if not self.priv:
            return ""
        # the default ACL again, which GRANT and REVOKE cannot give
        return ("RESET ROLE;\nUPDATE pg_proc SET proacl = NULL WHERE oid = '%s'::regprocedure;\n"
                % self.fn)


def rec_script(prog, lang, status=False):
    sch = SCHEMAS[lang]
    o = CLEAN + ("\\set VERBOSITY verbose\n\\set SHOW_CONTEXT never\n"
                 "SET search_path = %s, public;\nSET statement_timeout = '10s';\n" % sch)
    for i, s in enumerate(prog.steps):
        o += "\\echo @@ %d\n%s\n" % (i, s.replace("XLANGX", lang))
    o += "\\echo @@ end\nROLLBACK;\nRESET ROLE;\n" + prog.restore() + "\\echo @@ leak\n" + LEAK
    if status:
        o += ("\\echo @@ status\n"
              "SELECT state, coalesce(reason, ''), compiled_calls, calls FROM "
              "plllvm_pj_status('%s.f(int,int)'::regprocedure);\n" % sch)
    return o + CLEAN


# the replacing role cannot use an untrusted language: the same refusal in
# another text
LANGDENIED = "permission denied for language plpgsql_jit"


def rec_split(out, schema):
    steps = split(out, schema)
    return {k: [l.replace(LANGDENIED, "must be owner of function f")
                .replace("schema fzs", "schema fzX").replace("schema fzj", "schema fzX")
                for l in v] for k, v in steps.items()}


FATAL = ("XX000", "server closed the connection", "terminated abnormally",
         "unrecognized node type")
MODES = ("auto", "generic", "custom", "drop")
SETMODE = {"auto": "SET plan_cache_mode = auto; ",
           "generic": "SET plan_cache_mode = force_generic_plan; ",
           "custom": "SET plan_cache_mode = force_custom_plan; "}
HISTORY_RUNS = 600


def denied_fn(prog, lines):
    """Is it the 42501 for the function the program revoked?"""
    if not prog.priv:
        return False
    name = prog.fn.split("(")[0]
    return any(("permission denied for function %s" % name) in l for l in lines)


def history(args, prog, want):
    """Does a history of PL/pgSQL explain the outputs of plpgsql_jit?  A
    history says for each call: run under auto, generic or custom, or not
    run, which only a call that plpgsql_jit answered with its 42501 may be.
    Depth first, a bounded number of replays.  Returns the non-auto choices
    or None."""
    base = list(prog.steps)
    runs = [0]

    def replay(hist):
        runs[0] += 1
        st = []
        for i, s in enumerate(base):
            if i < len(hist) and hist[i] == "drop":
                st.append("SELECT 'dropped';")
            elif i < len(hist) and hist[i] is not None and s.startswith("SELECT f("):
                st.append(SETMODE[hist[i]] + s)
            else:
                st.append(s)
        prog.steps = st
        try:
            out = run_psql(args, rec_script(prog, "plpgsql"))
        finally:
            prog.steps = base
        return rec_split(out, SCHEMAS["plpgsql"])

    def strip(lines):
        return [l for l in (lines or []) if not l.startswith("SET")]

    def dfs(hist):
        i = len(hist)
        if i >= len(base):
            return hist
        if not base[i].startswith("SELECT f("):
            return dfs(hist + [None])
        w = want.get(str(i), [])
        for md in MODES:
            if runs[0] > HISTORY_RUNS:
                return None
            if md == "drop":
                ok = denied_fn(prog, w)
            else:
                ok = strip(replay(hist + [md]).get(str(i))) == w
            if ok:
                r = dfs(hist + [md])
                if r is not None:
                    return r
        return None

    r = dfs([])
    return None if r is None else [(i, base[i][:16], m) for i, m in enumerate(r)
                                   if m not in (None, "auto")]


def stale_shape(prog, sb, bad):
    """A call that reaches a nested frame (f(n, ...) with n >= 1), in the
    transaction of an earlier 42501 of plpgsql_jit."""
    m = re.match(r"SELECT f\((\d+),", prog.steps[bad])
    if not m or int(m.group(1)) < 1:
        return False
    for j in range(bad - 1, -1, -1):
        if prog.steps[j] in ("BEGIN;", "COMMIT;", "ROLLBACK;"):
            return prog.steps[j] == "BEGIN;" and any(
                denied_fn(prog, sb.get(str(k), [])) for k in range(j, bad))
    return False


EFFECT = re.compile(r"^(NOTICE|INFO|WARNING|LOG|DEBUG[1-5]):  ")


def effects(lines):
    """The effects of a step (messages) and its answer (the rest)."""
    return ([l for l in lines if EFFECT.match(l)], [l for l in lines if not EFFECT.match(l)])


def subseq(a, b):
    it = iter(b)
    return all(l in it for l in a)


def prefix(a, b):
    return b[:len(a)] == a


def frame_mix(j, a, c, g, again=False):
    """Is the output j of plpgsql_jit what a recursion gets when some frames
    take SPI's custom plan and others the generic one?  A frame prints
    before it recurses, so the effects of j are a prefix of generic's and
    have custom's as a prefix.  The answer is generic's when j reaches the
    last effect of generic, else that of auto or custom.  A wrong value, an
    effect that no mode has or one dropped from the middle is not a mix.
    A body that evaluates the recursive expression again (again: WHILE or
    LOOP) prints once per descent, so there the effects need only be
    subsequences, custom's of j's and j's of generic's, and the answer one
    of the three."""
    if c is None or g is None:
        return False
    je, ja = effects(j)
    ce, ca = effects(c)
    ge, ga = effects(g)
    if again:
        return ja in (effects(a)[1], ca, ga) and subseq(ce, je) and subseq(je, ge)
    if not (prefix(ce, je) and prefix(je, ge)):
        return False
    return ja == ga if len(je) == len(ge) else ja in (effects(a)[1], ca)


def selftest():
    """The shapes of fuzz cases 21:597 and the reduction minA2, and the
    mutants that must not pass."""
    n = lambda *v: ["NOTICE:  00000: mb %d" % i for i in v]
    c, g = n(4, 3) + ["N"], n(4, 3, 2, 1, 0) + ["ERROR:  22012: division by zero"]
    ok = [(n(4, 3, 2) + ["N"], c, c, g), (n(4, 3, 2, 1, 0) + ["ERROR:  22012: division by zero"], g, c, g),
          (n(4, 3) + ["N"], c, c, g)]
    bad = [(n(4, 3, 2) + ["7"], c, c, g),                 # a wrong value
           (n(4, 3, 2, 9) + ["N"], c, c, g),              # an effect no mode has
           (n(4, 2) + ["N"], c, c, g),                    # custom's effects lost
           (n(4, 3, 2, 1, 0, 0) + ["N"], c, c, g),        # more than generic's
           (n(4, 3, 2) + ["ERROR:  22003: x"], c, c, g),  # an error no mode raises
           (n(4, 3, 1) + ["N"], c, c, g),                 # a middle effect dropped
           (n(4, 3, 0) + ["N"], c, c, g),
           (n(4, 3, 2, 1, 0) + ["N"], c, c, g),           # generic's effects, custom's value
           (n(4, 3) + ["ERROR:  22012: division by zero"], c, c, g)]  # the reverse
    assert all(frame_mix(*t) for t in ok), "frame-mix refused a mix"
    assert not any(frame_mix(*t) for t in bad), "frame-mix accepted a mutant"
    # a loop descends twice: 4,3,2,1,0,4,3 is no prefix but a subsequence
    twice = (n(4, 3, 2, 4, 3) + ["N"], c, c, g + n(4, 3, 2, 1, 0))
    assert not frame_mix(*twice) and frame_mix(*twice, True), "frame-mix again"
    assert not any(frame_mix(*t, True) for t in bad[:5]), "frame-mix again accepted a mutant"
    print("pj_fuzz: selftest ok")


def rec_compare(args, prog, a, b, tally):
    """The verdict of a program and the step of it that decides.  equal;
    plan-choice, when every step that differs is what PL/pgSQL gives under
    force_generic_plan or force_custom_plan or a 42501 for the revoked
    function; frame-mix, when a step that does not is a mix of the two (see
    frame_mix); history, when a history of PL/pgSQL gives all of them; stale-privilege;
    otherwise PERMISSIVE or MISMATCH.  XX000 and a lost connection are
    MISMATCH at once."""
    sa, sb = rec_split(a, SCHEMAS["plpgsql"]), rec_split(b, SCHEMAS["plpgsql_jit"])
    for k, v in sb.items():
        if any(f in l for l in v for f in FATAL):
            return "MISMATCH", int(k) if k.isdigit() else None
    if any(f in b for f in FATAL):
        return "MISMATCH", None
    diff = [i for i in range(len(prog.steps)) if sa.get(str(i)) != sb.get(str(i))]
    if not diff:
        return "equal", None
    forced = {}
    for mode in ("generic", "custom"):
        out = run_psql(args, rec_script(prog, "plpgsql"),
                       extra=" -c plan_cache_mode=force_%s_plan" % mode)
        forced[mode] = rec_split(out, SCHEMAS["plpgsql"])
    bad, mixed = None, False
    for i in diff:
        x, y = sa.get(str(i), []), sb.get(str(i), [])
        if y == forced["generic"].get(str(i)):
            tally["generic-steps"] += 1
        elif y == forced["custom"].get(str(i)):
            tally["custom-steps"] += 1
        elif denied_fn(prog, y):
            tally["stricter-steps"] += 1
        elif frame_mix(y, x, forced["custom"].get(str(i)), forced["generic"].get(str(i)),
                           prog.again):
            tally["mix-steps"] += 1
            mixed = True
        else:
            bad = i
            break
    if bad is None:
        return ("frame-mix" if mixed else "plan-choice"), diff[0]
    h = history(args, prog, sb)
    if h is not None:
        print("  history of seed %s: %s" % (prog.seed, h))
        return "history", bad
    x = sa.get(str(bad), [])
    y = sb.get(str(bad), [])
    if any(l.startswith(DENIED) for l in x):
        if (prog.sd and not prog.direct and stale_shape(prog, sb, bad)
                and not any("ERROR" in l for l in y)):
            return "stale-privilege", bad
        return "PERMISSIVE", bad
    return "MISMATCH", bad


def main_rec(args):
    tally = Counter()
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = RecProgram(seed)
        a = run_psql(args, rec_script(prog, "plpgsql"))
        b = run_psql(args, rec_script(prog, "plpgsql_jit", True), args.opt_level)
        for out in (a, b):
            if "@@ leak\n%s\n" % args.leak not in out:
                sys.exit("pj_fuzz: seed %s left a privilege change in the database:\n%s"
                         % (seed, out[-400:]))
        verdict, step = rec_compare(args, prog, a, b, tally)
        tally[verdict] += 1
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = m.group(1).strip().split("\n")[0].split("|") if m else []
        tally["compiled"] += len(st) == 4 and int(st[2]) > 0
        if args.v or verdict not in ("equal", "plan-choice", "frame-mix", "history",
                                     "stale-privilege"):
            print("seed %s: %s%s" % (seed, verdict, "" if step is None else " at step %d" % step))
        if verdict in ("MISMATCH", "PERMISSIVE"):
            failed = True
            f = os.path.join(args.out, "fuzz-%s.txt" % seed.replace(":", "-"))
            with open(f, "w") as fh:
                fh.write("-- %s at step %s, seed %s, opt level %s\n== plpgsql script\n%s"
                         "== plpgsql_jit script\n%s== plpgsql output\n%s\n"
                         "== plpgsql_jit output\n%s\n"
                         % (verdict, step, seed, args.opt_level, rec_script(prog, "plpgsql"),
                            rec_script(prog, "plpgsql_jit", True), a, b))
            print("  program and outputs: %s" % f)
    print("pj_fuzz rec: seed=%d programs=%d opt_level=%s equal=%d plan-choice=%d mismatch=%d "
          "frame-mix=%d history=%d stale-privilege=%d permissive=%d compiled=%d (%.1f%%)"
          % (args.seed, args.n, args.opt_level, tally["equal"], tally["plan-choice"],
             tally["MISMATCH"], tally["frame-mix"], tally["history"], tally["stale-privilege"],
             tally["PERMISSIVE"],
             tally["compiled"],
             100.0 * tally["compiled"] / max(args.n, 1)))
    print("pj_fuzz rec: steps that differ, as plpgsql_jit gives under force_generic_plan %d, "
          "force_custom_plan %d, in between %d, 42501 where plpgsql has a value %d"
          % (tally["generic-steps"], tally["custom-steps"], tally["mix-steps"],
             tally["stricter-steps"]))
    if tally["compiled"] < args.floor * args.n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
        failed = True
    return 1 if failed else 0


# ---- programs of element reads and stores only (--mode elem)

ELEM = {"int4": "integer", "int8": "bigint", "float8": "double precision"}
ELEM_DEFAULT = ["'{1,NULL,3}'", "'[0:2]={4,5,6}'", "'[-3:-1]={7,8,9}'", "'{}'",
                "'{1,2,3}'", "'{1,2,3,4,5,6,7,8}'", None]
ELEM_ARGS = ["'{1,NULL,3}'", "'[0:2]={4,5,6}'", "'[-3:-1]={7,8,9}'", "'{}'",
             "'{1,2,3}'", "'{{1,2},{3,4}}'", "'[5:6]={1,2}'", "NULL"]
ELEM_RARE = 99                  # the argument no warm call passes
ELEM_BAD = 7                    # the one that makes the raising subscripts raise


class ElemGen:
    """Statements over the arrays a and b of one element type, the scalar s,
    the loop variable i and the arguments k and n."""

    def __init__(self, rng, ety):
        self.r = rng
        self.t = ety
        self.arrs = ["a", "b"]

    def idx(self, loop):
        r = self.r
        c = ["1", "2", "3", "0", "(-1)", "4", "(-3)", "5", "k % 4 + 1", "n",
             "nullif(k, %d)" % ELEM_BAD, "10 / (k - %d)" % ELEM_BAD]
        if loop:
            c += ["i", "i", "i", "i + 1", "i - 1", "n - i"]
        x = r.random()
        if x < 0.08:
            return r.choice(["2147483647", "(-2147483647 - 1)", "2147483640 + k"])
        if x < 0.2:
            return "%s[%s]" % (r.choice(self.arrs), r.choice(c[:6]))
        return r.choice(c)

    def sub(self, loop):
        """A subscript of a store: no extreme value, which would end the call."""
        e = self.idx(loop)
        while "21474836" in e or "[" in e:
            e = self.idx(loop)
        return e

    def val(self, loop, d):
        r = self.r
        if d <= 0 or r.random() < 0.25:
            return r.choice(["0", "1", "2", "(-1)", "100", "s", "s", "k", "n",
                             "nullif(k, %d)" % ELEM_BAD,
                             "(10 / (k - %d))" % ELEM_BAD, "i" if loop else "3"])
        x = r.random()
        arr = r.choice(self.arrs)
        if x < 0.4:
            return "%s[%s]" % (arr, self.idx(loop))
        if x < 0.5:
            return "coalesce(%s[%s], %s)" % (arr, self.idx(loop), r.choice(["0", "1", "s"]))
        op = r.choice(["+", "-", "*"])
        return "(%s %s %s)" % (self.val(loop, d - 1), op, self.val(loop, d - 1))

    def cond(self, loop):
        r = self.r
        x = r.random()
        if x < 0.3:
            return "%s[%s] IS NULL" % (r.choice(self.arrs), self.idx(loop))
        if x < 0.6:
            return "%s %s %s" % (self.val(loop, 1), r.choice(["<", ">", "="]),
                                 self.val(loop, 1))
        return "k %s %d" % (r.choice(["<", ">", "="]), r.randint(0, 5))

    def stmt(self, d, loop):
        r = self.r
        x = r.random()
        if x < 0.35:
            return "%s[%s] := %s;" % (r.choice(self.arrs), self.sub(loop),
                                       self.val(loop, 2))
        if x < 0.6:
            return "s := %s;" % self.val(loop, 3)
        if d > 0 and not loop and x < 0.75:
            body = " ".join(self.stmt(d - 1, True) for _ in range(r.randint(1, 3)))
            return "FOR i IN 1..n LOOP %s END LOOP;" % body
        if d > 0 and x < 0.9:
            then = " ".join(self.stmt(d - 1, loop) for _ in range(r.randint(1, 2)))
            els = ""
            if r.random() < 0.4:
                els = " ELSE " + " ".join(self.stmt(d - 1, loop) for _ in range(r.randint(1, 2)))
            return "IF %s THEN %s%s END IF;" % (self.cond(loop), then, els)
        return "s := s + coalesce(%s[%s], 1);" % (r.choice(self.arrs), self.idx(loop))


class ElemProgram:
    def __init__(self, seed, cat=None, cx=False):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.ety = r.choice(["int4", "int8", "float8"])
        self.t = ELEM[self.ety]
        g = ElemGen(r, self.ety)
        self.g = g
        self.default = r.choice(ELEM_DEFAULT)
        self.body = [g.stmt(2, False) for _ in range(r.randint(2, 6))]
        rare = " ".join(g.stmt(0, False) for _ in range(r.randint(1, 2)))
        self.body.insert(r.randint(0, len(self.body)),
                         "IF k = %d THEN %s END IF;" % (ELEM_RARE, rare))
        self.ret = r.choice(["s", "s + coalesce(b[1], 0)", "b", "a", "b"])
        self.priv = False
        self.real = {}
        self.status_cols = ("state, coalesce(reason, ''), compiled_calls, calls, deopts, "
                            "coalesce(boxed::text, '-')")
        self.steps = self.make_steps()

    def array(self):
        return self.ret in ("a", "b")

    def sig(self):
        return "(%s[],integer,integer)" % self.t

    def function(self):
        o = "CREATE FUNCTION f(a %s[], k integer, n integer) RETURNS %s LANGUAGE :lang AS $f$\n" % (
            self.t, self.t + "[]" if self.array() else self.t)
        o += "DECLARE\n  b %s[]%s;\n  s %s := 0;\n  i integer;\nBEGIN\n" % (
            self.t, " := " + self.default if self.default else "", self.t)
        for st in self.body:
            o += "  %s\n" % st
        return o + "  RETURN %s;\nEND\n$f$;\n" % self.ret

    def wrapper(self):
        return ("CREATE FUNCTION w(a %s[], k integer, n integer) RETURNS text LANGUAGE plpgsql AS $w$\n"
                "BEGIN PERFORM f(a, k, n); RETURN 'ok';\n"
                "EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;\nEND $w$;\n"
                % self.t)

    def call(self, kind, fn="f"):
        r = self.rng
        if kind == "harmless":
            a = r.choice(["'{1,2,3}'", "'{4,5,6,7}'", "'{1,NULL,3}'"])
            k, n = r.randint(0, 5), r.randint(0, 4)
        elif kind == "rare":
            a, k, n = "'{1,2,3}'", ELEM_RARE, r.randint(0, 3)
        else:
            a = r.choice(ELEM_ARGS)
            k = r.choice([0, 1, 2, ELEM_BAD, ELEM_BAD, -1, 5, 2147483647])
            n = r.choice([0, 1, 2, 3, 6, -1])
        return "SELECT %s((%s)::%s[], %s, %s);" % (fn, a, self.t, k, n)

    def make_steps(self):
        r = self.rng
        st = ["@create", "@wrapper"]
        for _ in range(3):
            st.append(self.call("harmless"))
        for _ in range(r.randint(4, 9)):
            st.append(self.call(r.choice(["harmless", "edge", "edge"])))
        st.append(self.call("edge", "w"))
        st.append(self.call("rare"))
        st.append(self.call("harmless"))
        st.append(self.call("harmless"))
        st.append(self.call("rare"))
        return st


def main_elem(args):
    tally = Counter()
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = ElemProgram(seed)
        a, b = run_pair(args, prog)
        verdict, step = compare(args, prog, a, b, tally)
        tally[verdict] += 1
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = m.group(1).strip().split("\n")[0].split("|") if m else []
        ok = len(st) == 6
        if ok and int(st[2]) > 0:
            tally["compiled"] += 1
        if ok and st[5] == "false":
            tally["native"] += 1
        if ok:
            tally["deopts"] += int(st[4])
            tally["deopt-programs"] += int(st[4]) > 0
        if args.v or verdict != "equal":
            print("seed %s: %s%s" % (seed, verdict, "" if step is None else " at step %d" % step))
        if verdict in ("MISMATCH", "PERMISSIVE"):
            failed = True
            f = os.path.join(args.out, "fuzz-%s.txt" % seed.replace(":", "-"))
            with open(f, "w") as fh:
                fh.write("-- %s at step %s, seed %s, opt level %s\n== plpgsql script\n%s"
                         "== plpgsql_jit script\n%s== plpgsql output\n%s\n"
                         "== plpgsql_jit output\n%s\n"
                         % (verdict, step, seed, args.opt_level, script(prog, "plpgsql"),
                            script(prog, "plpgsql_jit", True), a, b))
            print("  program and outputs: %s" % f)
    print("pj_fuzz elem: seed=%d programs=%d opt_level=%s equal=%d permissive=%d mismatch=%d "
          "compiled=%d (%.1f%%) without the executor=%d (%.1f%%) deopts=%d in %d programs"
          % (args.seed, args.n, args.opt_level, tally["equal"], tally["PERMISSIVE"],
             tally["MISMATCH"], tally["compiled"], 100.0 * tally["compiled"] / max(args.n, 1),
             tally["native"], 100.0 * tally["native"] / max(args.n, 1), tally["deopts"],
             tally["deopt-programs"]))
    if tally["compiled"] < args.floor * args.n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
        failed = True
    if tally["native"] < args.floor_elem * args.n:
        print("pj_fuzz: programs without a call of the executor below the floor of %.0f%%"
              % (100 * args.floor_elem))
        failed = True
    if tally["deopts"] == 0 and args.n >= 20:
        print("pj_fuzz: no program deopted")
        failed = True
    return 1 if failed else 0



# ---- statements for SPI (--mode sql)

SQL_BAD = 4                      # the n that makes 1 / (n - SQL_BAD) raise
SQL_RARE = 9                     # the n of the branch no warm call takes


class SqlGen:
    """Statements over the table sq_t, the arguments n and t, the local
    r that collects what each statement saw, the loop variable i.  The
    targets of an INTO are tx, ty (text), ix, iy (integer), big (bigint) and
    nn (integer NOT NULL), which a statement's collect() appends to r."""

    def __init__(self, rng, into=False, writes=False):
        self.r = rng
        self.into = into
        self.writes = writes

    def collect(self):
        return " r := r || found::text || coalesce(tx, '-') || coalesce(ix::text, '-') || coalesce(big::text, '-');"

    def select_into(self, loop, raising=False):
        """A SELECT INTO.  Most of them have one row for every n of the
        warm-up calls, since a call that raises leaves the statements after it
        unplanned; those that raise by the argument are RAISING ones, which
        stand where only an edge call goes."""
        r = self.r
        v = "i" if loop else "n"
        k = "1 + abs(%s) %% 5" % v      # a key that has a row
        if raising:
            return r.choice([
                "SELECT b INTO STRICT tx FROM sq_t WHERE a = %s;" % v,
                "SELECT a INTO STRICT ix FROM sq_t WHERE a > %s;" % v,
                "SELECT a, b INTO STRICT ix, tx FROM sq_t WHERE a > %s;" % v,
                "SELECT a INTO nn FROM sq_t WHERE a = %s;" % v,
                "SELECT 1 / (%s - %d) INTO ix FROM sq_t WHERE a = %s;" % (v, SQL_BAD, k)])
        x = r.random()
        if x < 0.15:
            return "SELECT b INTO tx FROM sq_t WHERE a = %s;" % v
        if x < 0.27:
            return "SELECT a, b INTO ix, tx FROM sq_t WHERE a > %s ORDER BY a;" % v
        if x < 0.35:
            return "SELECT a, b INTO ix, ty FROM sq_t WHERE a > %s ORDER BY a DESC;" % v
        if x < 0.45:
            return "SELECT count(*) INTO big FROM sq_t WHERE a > %s AND b <> t;" % v
        if x < 0.52:
            return "SELECT b INTO STRICT tx FROM sq_t WHERE a = %s;" % k
        if x < 0.58:
            return "SELECT a, b INTO STRICT ix, tx FROM sq_t WHERE a = %s;" % k
        if x < 0.65:
            return "SELECT a INTO ix, iy FROM sq_t WHERE a = %s;" % v
        if x < 0.72:
            return "SELECT a, b, a + 1 INTO ix, tx FROM sq_t WHERE a = %s;" % v
        if x < 0.78:
            return "SELECT a INTO nn FROM sq_t WHERE a = %s;" % k
        if x < 0.84:
            return "SELECT 1 / n INTO ix FROM sq_t WHERE false;"
        if x < 0.90:
            return "SELECT sq_noisy(%s) INTO ix FROM sq_t WHERE a = 1;" % v
        if x < 0.95:
            return "SELECT false, 1 INTO found, ix FROM sq_t WHERE a = %s;" % v
        return "SELECT %s + 1 INTO ix FROM sq_t WHERE a = %s;" % (v, v)

    def dml(self, loop, raising=False):
        """A statement that writes to sq_w (a int primary key, b text, c int
        default).  The keys 21 and up are the statements' own, and the rows 1
        and 2 are never deleted, so that a STRICT one finds its row in every
        call and does not leave the statements after it unplanned.  A RAISING
        one stands where only an edge call goes."""
        r = self.r
        v = "i" if loop else "n"
        k = "1 + abs(%s) %% 5" % v      # a key that has a row, at first
        s = "1 + abs(%s) %% 2" % v      # a key that always has
        if raising:
            return r.choice([
                "INSERT INTO sq_w VALUES (%s, 'dup', 1);" % k,
                "UPDATE sq_w SET c = 1 / (a - %d) WHERE a = %s;" % (SQL_BAD, SQL_BAD),
                "INSERT INTO sq_w VALUES (%s, 'x', 1) RETURNING a INTO STRICT ix;" % k,
                "UPDATE sq_w SET c = c + 1 WHERE a > %s RETURNING a INTO ix;" % v,
                "UPDATE sq_w SET c = c + 1 WHERE a = %s + 40 RETURNING a INTO STRICT ix;" % v])
        x = r.random()
        if x < 0.12:
            return "INSERT INTO sq_w VALUES (%s + 20, 'i' || %s, DEFAULT) ON CONFLICT DO NOTHING;" % (v, v)
        if x < 0.20:
            return "INSERT INTO sq_w VALUES (%s + 20, t, DEFAULT) ON CONFLICT (a) DO UPDATE SET b = sq_w.b || t;" % v
        if x < 0.30:
            return "UPDATE sq_w SET b = b || 'u' WHERE a = %s;" % v
        if x < 0.38:
            return "UPDATE sq_w SET c = c + 1 WHERE a > %s AND b <> t;" % v
        if x < 0.46:
            return "DELETE FROM sq_w WHERE a = %s + 20;" % v
        if x < 0.52:
            return "DELETE FROM sq_w WHERE a = 3 + abs(%s) %% 5;" % v
        if x < 0.62:
            return "UPDATE sq_w SET c = c + 1 WHERE a = %s RETURNING a, b INTO ix, tx;" % v
        if x < 0.68:
            return "DELETE FROM sq_w WHERE a = %s + 20 RETURNING b INTO tx;" % v
        if x < 0.75:
            return ("INSERT INTO sq_w VALUES (%s + 30, 'r', 2) ON CONFLICT DO NOTHING "
                    "RETURNING a, b, c INTO ix, tx, iy;" % v)
        if x < 0.81:
            return "UPDATE sq_w SET c = c + 1 WHERE a = %s RETURNING a INTO STRICT ix;" % s
        if x < 0.87:
            return "UPDATE sq_w SET b = b WHERE false RETURNING a INTO ix;"
        if x < 0.93:
            return "WITH d AS (DELETE FROM sq_w WHERE a = %s + 20 RETURNING a) SELECT count(*) INTO big FROM d;" % v
        return "UPDATE sq_w SET c = c + 1 WHERE a = %s RETURNING c INTO nn;" % s

    def cond(self):
        r = self.r
        return r.choice(["n > 2", "n % 2 = 0", "t = 'row3'", "n < %d" % SQL_BAD,
                         "found", "n = %d" % r.randint(0, 6)])

    def perform(self, loop):
        r = self.r
        x = r.random()
        v = "i" if loop else "n"
        if x < 0.2:
            return "PERFORM 1 FROM sq_t WHERE a = %s;" % v
        if x < 0.35:
            return "PERFORM 1 FROM sq_t WHERE a < %s AND b <> t;" % v
        if x < 0.45:
            return "PERFORM count(*) FROM sq_t WHERE a > %s;" % v
        if x < 0.55:
            return "PERFORM 1 / (%s - %d) FROM sq_t WHERE a = %s;" % (v, SQL_BAD, v)
        if x < 0.65:
            return "PERFORM 1 / n FROM sq_t WHERE false;"
        if x < 0.75:
            return "PERFORM sq_noisy(%s) FROM sq_t WHERE a = 1;" % v
        if x < 0.82:
            return "PERFORM 1 WHERE found;"
        if x < 0.9:
            return "PERFORM %s;" % v
        return "PERFORM 1 FROM sq_t WHERE b = t || %s::text;" % v

    def stmt(self, d, loop):
        r = self.r
        x = r.random()
        if x < 0.55 or d <= 0:
            if self.writes:
                return self.dml(loop) + self.collect()
            if self.into or r.random() < 0.35:
                return self.select_into(loop) + self.collect()
            return self.perform(loop) + " r := r || found::text;"
        if x < 0.75 and not loop:
            body = " ".join(self.stmt(d - 1, True) for _ in range(r.randint(1, 3)))
            return "FOR i IN 1..least(n, 5) LOOP %s END LOOP;" % body
        then = " ".join(self.stmt(d - 1, loop) for _ in range(r.randint(1, 2)))
        els = ""
        if r.random() < 0.4:
            els = " ELSE " + " ".join(self.stmt(d - 1, loop) for _ in range(r.randint(1, 2)))
        return "IF %s THEN %s%s END IF;" % (self.cond(), then, els)


class SqlProgram:
    def __init__(self, seed, cat=None, cx=False, dml=False):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.dml = dml
        # a part of the programs has no PERFORM at all, to count them
        self.into = r.random() < 0.4
        g = SqlGen(r, self.into, dml)
        # (a loop in a branch that a call does not take leaves its statements
        # unplanned and the function waiting, so the programs of writes are shallow)
        self.body = [g.stmt(1 if dml else 2, False) for _ in range(r.randint(2, 5))]
        # a statement no warm call reaches: planned by the call that takes it
        if dml:
            rare = g.dml(False) + g.collect()
        else:
            rare = g.select_into(False) + g.collect() if self.into else \
                g.perform(False) + " r := r || found::text;"
        self.body.insert(r.randint(0, len(self.body)),
                         "IF n = %d THEN %s END IF;" % (SQL_RARE, rare))
        if r.random() < 0.15:
            # SELECT with no INTO, which raises
            self.body.append("IF n = %d THEN SELECT n; END IF;" % (SQL_RARE + 1))
        if dml and r.random() < 0.5:
            self.body.append("IF n = %d THEN %s END IF;"
                             % (SQL_RARE + 1, g.dml(False, True) + g.collect()))
        elif self.into and not dml and r.random() < 0.5:
            # an INTO that raises, which only an edge call reaches
            self.body.append("IF n = %d THEN %s END IF;"
                             % (SQL_RARE + 1, g.select_into(False, True) + g.collect()))
        self.priv = False
        self.real = {}
        self.status_cols = ("state, coalesce(reason, ''), compiled_calls, calls, deopts, "
                            "(SELECT sql_execs FROM plllvm_pj_stats()), last_path")
        self.steps = self.make_steps()

    def sig(self):
        return "(integer,integer,text)"

    def function(self):
        o = ("CREATE FUNCTION f(n integer, h integer, t text) RETURNS text "
             "LANGUAGE :lang AS $f$\nDECLARE\n  r text := '';\n  i integer;\n"
             "  tx text; ty text; ix integer; iy integer; big bigint; nn integer NOT NULL := 1;\n"
             "BEGIN\n")
        for st in self.body:
            o += "  %s\n" % st
        return o + "  RETURN r;\nEND\n$f$;\n"

    def wrapper(self):
        return ("CREATE FUNCTION w(n integer, h integer, t text) RETURNS text LANGUAGE plpgsql AS $w$\n"
                "BEGIN RETURN f(n, h, t);\n"
                "EXCEPTION WHEN OTHERS THEN RETURN SQLSTATE || ' ' || SQLERRM;\nEND $w$;\n")

    def setup(self):
        o = ("CREATE TABLE sq_t (a int PRIMARY KEY, b text);\n"
             "INSERT INTO sq_t SELECT i, 'row' || i FROM generate_series(1, 8) i;\n"
             "ANALYZE sq_t;\n"
             "CREATE FUNCTION sq_noisy(n int) RETURNS int LANGUAGE plpgsql STABLE AS "
             "$q$ BEGIN RAISE NOTICE 'noisy %', n; RETURN n; END $q$;\n")
        if self.dml:
            o += ("CREATE TABLE sq_w (a int PRIMARY KEY, b text, c int DEFAULT 7);\n"
                  "INSERT INTO sq_w SELECT i, 'row' || i, i FROM generate_series(1, 8) i;\n"
                  "ANALYZE sq_w;\n"
                  "CREATE TABLE sq_w_log (a int);\n"
                  "CREATE FUNCTION sq_w_fn() RETURNS trigger LANGUAGE plpgsql AS "
                  "$q$ BEGIN RAISE NOTICE 'sq_w %', tg_op; RETURN coalesce(new, old); END $q$;\n"
                  "CREATE FUNCTION sq_vol() RETURNS int LANGUAGE plpgsql VOLATILE AS "
                  "$q$ BEGIN RAISE NOTICE 'sq_vol'; RETURN 3; END $q$;\n")
        return o

    def call(self, kind, fn="f"):
        r = self.rng
        n = {"harmless": r.randint(0, 6), "rare": SQL_RARE,
             "edge": r.choice([0, 1, SQL_BAD, SQL_BAD, SQL_RARE + 1, -1, 7])}[kind]
        h = r.choice(["1", "1", "1", "NULL"])
        t = r.choice(["'row3'", "'x'", "'row1'"])
        return "SELECT %s(%d, %s, %s);" % (fn, n, h, t)

    def between(self):
        if self.dml and self.rng.random() < 0.6:
            return self.rng.choice([
                "TRUNCATE sq_w; INSERT INTO sq_w SELECT i, 'row' || i, i FROM generate_series(1, 8) i; ANALYZE sq_w;",
                "ANALYZE sq_w;",
                "CREATE OR REPLACE TRIGGER sq_w_t BEFORE INSERT OR UPDATE OR DELETE ON sq_w "
                "FOR EACH ROW EXECUTE FUNCTION sq_w_fn();",
                "DROP TRIGGER IF EXISTS sq_w_t ON sq_w;",
                "ALTER TABLE sq_w ALTER COLUMN c SET DEFAULT sq_vol();",
                "ALTER TABLE sq_w ALTER COLUMN c SET DEFAULT 7;",
                # an INSERT or UPDATE rule would make ON CONFLICT an error at planning
                "CREATE OR REPLACE RULE sq_w_r AS ON DELETE TO sq_w DO ALSO INSERT INTO sq_w_log VALUES (old.a);",
                "DROP RULE IF EXISTS sq_w_r ON sq_w;",
                "DELETE FROM sq_w WHERE a > 2;",
                "DISCARD PLANS;",
            ])
        return self.rng.choice([
            "TRUNCATE sq_t; INSERT INTO sq_t SELECT i, 'row' || i FROM generate_series(1, 8) i; ANALYZE sq_t;",
            "ANALYZE sq_t;",
            "CREATE INDEX IF NOT EXISTS sq_b ON sq_t (b);",
            "DROP INDEX IF EXISTS sq_b;",
            "DISCARD PLANS;",
            "SET plan_cache_mode = force_custom_plan;",
            "SET plan_cache_mode = force_generic_plan;",
            "SET plan_cache_mode = auto;",
            "DELETE FROM sq_t WHERE a > 5;",
            "SET plpgsql.extra_warnings = 'too_many_rows, strict_multi_assignment';",
            "RESET plpgsql.extra_warnings;",
            # an error check for one call, which a persistent one would fail
            # every call after it
            "SET plpgsql.extra_errors = '%s'; SELECT w(%d, 1, 'x'); RESET plpgsql.extra_errors;"
            % (self.rng.choice(["too_many_rows", "strict_multi_assignment", "all"]),
               self.rng.randint(0, 6)),
            # a column of another type for one call, which converts it; for
            # more the statements would be declined, as a cast is
            "ALTER TABLE sq_t ALTER COLUMN a TYPE bigint; SELECT w(%d, 1, 'x'); "
            "ALTER TABLE sq_t ALTER COLUMN a TYPE integer;" % self.rng.randint(0, 6),
        ])

    def make_steps(self):
        r = self.rng
        st = ["@setup", "@create", "@wrapper"]
        # every n a condition tests, with each t, so that the branches are
        # planned before the code is translated
        # (and the n that takes the branch with a statement that raises)
        for n in list(range(7)) + [SQL_RARE + 1]:
            st.append("SELECT f(%d, 1, '%s');" % (n, ["row3", "x", "row1"][n % 3]))
        for _ in range(r.randint(5, 10)):
            if r.random() < 0.4:
                st.append(self.between())
            st.append(self.call(r.choice(["harmless", "edge", "edge"]),
                                r.choice(["f", "f", "w"])))
        st.append(self.call("rare"))
        # the plans the DDL above made stale are made again by the interpreter
        # (h is NULL), at each branch, and the function is then run compiled
        for n in list(range(0, 7)) + [SQL_RARE, SQL_RARE + 1]:
            st.append("SELECT w(%d, NULL, '%s');" % (n, ["row3", "x", "row1"][n % 3]))
        for n in list(range(0, 7)) + [SQL_RARE, SQL_RARE + 1]:
            st.append("SELECT w(%d, 1, '%s');" % (n, ["row3", "x", "row1"][n % 3]))
        for _ in range(3):
            st.append(self.call("harmless"))
        st.append(self.call("rare", "w"))
        st.append(self.call("harmless"))
        st.append(self.call("harmless"))
        if self.dml:
            # what each call wrote
            dump = ("SELECT coalesce(string_agg(x::text, ' ' ORDER BY x.a), '-') FROM sq_w x;")
            st = [t for s in st for t in ([s, dump] if s.startswith("SELECT ") else [s])]
        return st


def main_sql(args):
    tally = Counter()
    reasons = Counter()
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = SqlProgram(seed, dml=args.mode == "dml")
        a, b = run_pair(args, prog)
        verdict, step = compare(args, prog, a, b, tally)
        tally[verdict] += 1
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = m.group(1).strip().split("\n")[0].split("|") if m else []
        ok = len(st) == 7
        if ok and int(st[2]) > 0:
            tally["compiled"] += 1
        if prog.into:
            tally["into-programs"] += 1
        if ok and int(st[5]) > 0:
            tally["ran-sql"] += 1
            tally["sql-execs"] += int(st[5])
            if prog.into:
                tally["into-ran-sql"] += 1
        else:
            reasons["%s %s, last path %s" % (st[0], st[1], st[6]) if ok else "no status"] += 1
        if ok:
            tally["deopts"] += int(st[4])
        if args.v or verdict != "equal":
            print("seed %s: %s%s" % (seed, verdict, "" if step is None else " at step %d" % step))
        if verdict in ("MISMATCH", "PERMISSIVE"):
            failed = True
            f = os.path.join(args.out, "fuzz-%s.txt" % seed.replace(":", "-"))
            with open(f, "w") as fh:
                fh.write("-- %s at step %s, seed %s, opt level %s\n== plpgsql script\n%s"
                         "== plpgsql_jit script\n%s== plpgsql output\n%s\n"
                         "== plpgsql_jit output\n%s\n"
                         % (verdict, step, seed, args.opt_level, script(prog, "plpgsql"),
                            script(prog, "plpgsql_jit", True), a, b))
            print("  program and outputs: %s" % f)
    print("pj_fuzz %s: seed=%d programs=%d opt_level=%s equal=%d permissive=%d mismatch=%d "
          "compiled=%d (%.1f%%) ran SQL compiled=%d (%.1f%%), %d statements, deopts=%d, "
          "SELECT INTO programs=%d ran SQL compiled=%d"
          % (args.mode, args.seed, args.n, args.opt_level, tally["equal"], tally["PERMISSIVE"],
             tally["MISMATCH"], tally["compiled"], 100.0 * tally["compiled"] / max(args.n, 1),
             tally["ran-sql"], 100.0 * tally["ran-sql"] / max(args.n, 1), tally["sql-execs"],
             tally["deopts"], tally["into-programs"], tally["into-ran-sql"]))
    for k, v in reasons.most_common(8):
        print("  no SQL compiled: %5d  %s" % (v, k))
    floor = args.floor_dml if args.mode == "dml" else args.floor_sql
    if tally["ran-sql"] < floor * args.n:
        print("pj_fuzz: programs that ran SQL compiled below the floor of %.0f%%"
              % (100 * floor))
        failed = True
    if args.mode == "sql" and tally["into-ran-sql"] < args.floor_into * tally["into-programs"]:
        print("pj_fuzz: programs of SELECT INTO that ran SQL compiled below the floor of %.0f%%"
              % (100 * args.floor_into))
        failed = True
    return 1 if failed else 0


# ---- running

CLEAN = ("SET client_min_messages = warning;\n"
         "DROP SCHEMA IF EXISTS fzs, fzj CASCADE;\n"
         "CREATE SCHEMA fzs; CREATE SCHEMA fzj;\n"
         "GRANT USAGE ON SCHEMA fzs, fzj TO %s, %s;\n"
         "RESET client_min_messages;\n" % (ROLE, OWNER))

# what a leaked privilege change would change: the ACLs of the functions of
# pg_catalog (some have one from initdb), the membership of the group
LEAK = ("SELECT (SELECT count(*) FROM pg_proc WHERE proacl IS NOT NULL"
        " AND pronamespace = 'pg_catalog'::regnamespace)::text || ' ' ||"
        " (SELECT count(*) FROM pg_auth_members WHERE roleid = '%s'::regrole)::text;\n"
        % GROUP)


def script(prog, lang, status=False):
    sch = SCHEMAS[lang]
    o = CLEAN + ("\\set VERBOSITY verbose\n\\set SHOW_CONTEXT always\n"
                 "SET search_path = %s, public;\nSET statement_timeout = '10s';\n"
                 "\\set lang %s\n" % (sch, lang))
    for i, s in enumerate(prog.steps):
        o += "\\echo @@ %d\n" % i
        if s == "@create":
            o += prog.function()
        elif s == "@setup":
            o += prog.setup()
        elif s == "@wrapper":
            o += prog.wrapper()
        else:
            o += s + "\n"
    o += "\\echo @@ end\nROLLBACK;\nRESET ROLE;\n\\echo @@ leak\n" + LEAK
    if status:
        cols = getattr(prog, "status_cols",
                       "state, coalesce(reason, ''), compiled_calls, calls, deopts")
        o += ("\\echo @@ status\n"
              "SELECT %s FROM plllvm_pj_status('%s.f%s'::regprocedure);\n"
              % (cols, sch, prog.sig()))
    return o + CLEAN


def run_psql(args, sql, opt=None, extra=""):
    env = dict(os.environ)
    env["PGOPTIONS"] = "-c session_preload_libraries=plllvm" + extra
    if opt is not None:
        env["PGOPTIONS"] += " -c plllvm.pj_opt_level=%d" % opt
    p = subprocess.run([args.psql, "-X", "-q", "-At", "-h", args.host, "-p", str(args.port),
                        "-d", DB, "-v", "ON_ERROR_STOP=0", "-f", "-"],
                       input=sql, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       text=True, env=env, timeout=300)
    return p.stdout


def admin(args, sql, db="postgres"):
    p = subprocess.run([args.psql, "-X", "-q", "-At", "-F", "\t", "-h", args.host,
                        "-p", str(args.port), "-d", db, "-v", "ON_ERROR_STOP=1", "-c", sql],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if p.returncode:
        sys.exit("psql: " + p.stderr)
    return [l for l in p.stdout.split("\n") if l]


def setup(args):
    admin(args, "DROP DATABASE IF EXISTS %s" % DB)
    admin(args, "CREATE DATABASE %s" % DB)
    for r in (ROLE, GROUP, OWNER):
        admin(args, "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '%s') "
                    "THEN CREATE ROLE %s; END IF; END $$" % (r, r))
    admin(args, "GRANT %s TO %s" % (GROUP, ROLE))
    admin(args, "CREATE EXTENSION plllvm; CREATE SCHEMA fzs; CREATE SCHEMA fzj;"
                "GRANT USAGE ON SCHEMA fzs, fzj TO %s, %s;" % (ROLE, OWNER), DB)
    args.leak = admin(args, LEAK, DB)[0]


STEP = re.compile(r"^@@ (\S+)$")
LOC = re.compile(r"^LOCATION:  .*$")
PSQLPFX = re.compile(r"^psql:<stdin>:\d+: ")
EXPRCTX = re.compile(r'^PL/pgSQL (expression|assignment) ".*"$')
DENIED = ("ERROR:  42501", "42501 ")       # an error, or w()'s caught one
CTXPFX = re.compile(r"^CONTEXT:  ")


def split(out, schema):
    steps, cur = {}, None
    for line in out.split("\n"):
        m = STEP.match(line)
        if m:
            cur = m.group(1)
            steps[cur] = []
        elif cur is not None and not LOC.match(line):
            line = CTXPFX.sub("", PSQLPFX.sub("", line)).replace(schema + ".", "")
            # the schema of a constraint or table in an error of the verbose kind
            if line.startswith("SCHEMA NAME:"):
                line = "SCHEMA NAME:  fzX"
            steps[cur].append(line)
    return steps


def replay_without(args, prog, drop):
    """The output of plpgsql with the calls of steps drop left out."""
    base = list(prog.steps)
    prog.steps = ["SELECT 'dropped';" if i in drop else s for i, s in enumerate(base)]
    try:
        return split(run_psql(args, script(prog, "plpgsql")), SCHEMAS["plpgsql"])
    finally:
        prog.steps = base


def compare(args, prog, a, b, tally):
    """The verdict of the program and the first step of it; the first
    PERMISSIVE or MISMATCH ends the comparison, a stricter step does not.
    A PERMISSIVE step after calls that plpgsql_jit refused with 42501 where
    plpgsql went on is looked up in a run of plpgsql without those calls (L2):
    if plpgsql then answers as plpgsql_jit does, the program is
    stale-privilege, and the comparison goes on against that run, which
    hides a mask of later steps: they are counted as replay-steps.  Leaving
    out a refused call is exact only for a refusal at entry (E1), where the
    call did nothing before it; a refusal further in is not modelled."""
    sa, sb = split(a, SCHEMAS["plpgsql"]), split(b, SCHEMAS["plpgsql_jit"])
    verdict, first = "equal", None
    refused, skip = [], set()
    i = 0
    while i < len(prog.steps):
        x, y = sa.get(str(i), []), sb.get(str(i), [])
        if i in prog.real:
            tally["walk-calls"] += 1
            tally["walk-calls-aborted"] += any("25P02" in l for l in x)
        if skip and i not in skip:
            tally["replay-steps"] += 1
        if i in skip or x == y:
            i += 1
            continue
        x2 = [l for l in x if not EXPRCTX.match(l)]
        y2 = [l for l in y if not EXPRCTX.match(l)]
        if x2 == y2:
            tally["allowed-context"] += 1
            i += 1
            continue
        ex = any(l.startswith(DENIED) for l in x)
        ey = any(l.startswith(DENIED) for l in y)
        if ex and not ey:
            if not refused or skip:
                return "PERMISSIVE", i
            sa = replay_without(args, prog, set(refused))
            skip = set(refused)
            tally["replay-steps"] += 1
            if [l for l in sa.get(str(i), []) if not EXPRCTX.match(l)] != y2:
                return "PERMISSIVE", i
            verdict, first = "stale-privilege", i
            i += 1
            continue
        if ey and (ex or prog.real.get(i)):
            tally["stricter-steps"] += 1
            if not ex:
                refused.append(i)
            if verdict == "equal":
                verdict, first = "stricter", i
            i += 1
            continue
        return "MISMATCH", i
    return verdict, first


def run_pair(args, prog):
    a = run_psql(args, script(prog, "plpgsql"))
    b = run_psql(args, script(prog, "plpgsql_jit", True), args.opt_level)
    for out in (a, b):
        if "@@ leak\n%s\n" % args.leak not in out:
            sys.exit("pj_fuzz: seed %s left a privilege change in the database:\n%s"
                     % (prog.seed, out[-400:]))
    return a, b


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--psql")
    ap.add_argument("--host", default="/tmp")
    ap.add_argument("--port", type=int)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--start", type=int, default=0, help="index of the first program")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--opt-level", type=int, default=None)
    ap.add_argument("--out", default="results-fuzz")
    ap.add_argument("--floor", type=float, default=0.5)
    ap.add_argument("--mode", choices=["flat", "rec", "ref", "elem", "sql", "dml"], default="flat")
    ap.add_argument("--cx", action="store_true", help="CASE and SELECT INTO (flat, ref)")
    ap.add_argument("--floor-cx", type=float, default=0.15, dest="floor_cx")
    ap.add_argument("--floor-elem", type=float, default=0.9, dest="floor_elem")
    ap.add_argument("--floor-sql", type=float, default=0.4, dest="floor_sql")
    ap.add_argument("--floor-into", type=float, default=0.3, dest="floor_into")
    ap.add_argument("--floor-dml", type=float, default=0.25, dest="floor_dml")
    ap.add_argument("-v", action="store_true")
    ap.add_argument("--selftest", action="store_true", help="check frame_mix, no cluster")
    args = ap.parse_args()
    if args.selftest:
        return selftest()
    if args.psql is None or args.port is None:
        ap.error("--psql and --port are required")

    os.makedirs(args.out, exist_ok=True)
    setup(args)
    if args.mode == "rec":
        if args.cx:
            ap.error("--cx is for flat and ref programs")
        sys.exit(main_rec(args))
    if args.mode == "elem":
        if args.cx:
            ap.error("--cx is for flat and ref programs")
        sys.exit(main_elem(args))
    if args.mode in ("sql", "dml"):
        if args.cx:
            ap.error("--cx is for flat and ref programs")
        sys.exit(main_sql(args))
    cat = load_catalog(lambda q: admin(args, q))
    if args.mode == "ref":
        universe = cat.universe
        cat = RefCat(lambda q: admin(args, q, DB))
        cat.universe = universe
    tally = Counter()
    reasons = Counter()
    cx_reasons = {"case": Counter(), "into": Counter()}
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = (RefProgram if args.mode == "ref" else Program)(seed, cat, args.cx)
        a, b = run_pair(args, prog)
        verdict, step = compare(args, prog, a, b, tally)
        tally[verdict] += 1
        tally["walk-programs"] += prog.priv
        tally["stock-42501"] += a.count("ERROR:  42501") + a.count("\n42501 ")
        tally["jit-42501"] += b.count("ERROR:  42501") + b.count("\n42501 ")
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = m.group(1).strip().split("\n")[0].split("|") if m else []
        ok = len(st) == 5
        ran = ok and int(st[2]) > 0
        if ran:
            tally["compiled"] += 1
        else:
            reasons["%s %s" % tuple(st[:2]) if ok else "no status"] += 1
        for k in prog.g.used:
            tally["has-" + k] += 1
            # the construct ran compiled: it stands outside any branch, and no
            # call left the code at a deopt point
            if k in prog.g.top:
                tally["top-" + k] += 1
            if ran and k in prog.g.top and int(st[4]) == 0:
                tally["compiled-" + k] += 1
            elif ran and k in prog.g.top:
                cx_reasons[k]["deopt"] += 1
            elif ran:
                cx_reasons[k]["nested in a branch"] += 1
            else:
                cx_reasons[k]["%s %s" % tuple(st[:2]) if ok else "no status"] += 1
        if args.v or verdict != "equal":
            print("seed %s: %s%s" % (seed, verdict, "" if step is None else " at step %d" % step))
        if verdict in ("MISMATCH", "PERMISSIVE"):
            failed = True
            f = os.path.join(args.out, "fuzz-%s.txt" % seed.replace(":", "-"))
            with open(f, "w") as fh:
                fh.write("-- %s at step %s, seed %s, opt level %s\n== plpgsql script\n%s"
                         "== plpgsql_jit script\n%s== plpgsql output\n%s\n"
                         "== plpgsql_jit output\n%s\n"
                         % (verdict, step, seed, args.opt_level, script(prog, "plpgsql"),
                            script(prog, "plpgsql_jit", True), a, b))
            print("  program and outputs: %s" % f)
    comp = tally["compiled"]
    print("pj_fuzz: seed=%d programs=%d opt_level=%s equal=%d stricter=%d stale-privilege=%d "
          "permissive=%d mismatch=%d compiled=%d (%.1f%%)"
          % (args.seed, args.n, args.opt_level, tally["equal"], tally["stricter"],
             tally["stale-privilege"], tally["PERMISSIVE"], tally["MISMATCH"], comp,
             100.0 * comp / max(args.n, 1)))
    print("pj_fuzz: 42501 raised: stock %d, plpgsql_jit %d; stricter steps %d; "
          "steps equal but for the SPI CONTEXT line %d"
          % (tally["stock-42501"], tally["jit-42501"], tally["stricter-steps"],
             tally["allowed-context"]))
    print("pj_fuzz: walk programs %d, their calls %d, of which %d after the "
          "transaction aborted in plpgsql; steps compared against the replay %d"
          % (tally["walk-programs"], tally["walk-calls"], tally["walk-calls-aborted"],
             tally["replay-steps"]))
    for k, v in reasons.most_common(12):
        print("  not compiled: %5d  %s" % (v, k))
    if comp < args.floor * args.n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
        failed = True
    if args.cx:
        for k in ("case", "into"):
            print("pj_fuzz: %s: programs with it %d, in the body %d, compiled %d" % (
                k, tally["has-" + k], tally["top-" + k], tally["compiled-" + k]))
            for why, v in cx_reasons[k].most_common(6):
                print("  with %s, not compiled: %5d  %s" % (k, v, why))
            if tally["top-" + k] < 5 or \
                    tally["compiled-" + k] < args.floor_cx * tally["top-" + k]:
                print("pj_fuzz: %s: too few programs, or compiled below the floor of "
                      "%.0f%%" % (k, 100 * args.floor_cx))
                failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
