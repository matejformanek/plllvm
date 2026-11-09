#!/usr/bin/env python3
"""Differential fuzzer for LANGUAGE plpgsql_jit against LANGUAGE plpgsql.

A seeded generator writes a PL/pgSQL function over the statements and types
that plpgsql_jit compiles (assignment, IF, LOOP, WHILE, FOR over integers,
EXIT and CONTINUE, nested blocks, RETURN; smallint, integer, bigint, real,
double precision, boolean) and a script that calls it: warm calls, then edge
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
the function the program revoked (stricter).  Any other step is searched for
a history: each call run by PL/pgSQL under auto, generic or custom, or not at
all (only a call plpgsql_jit answered with that 42501).
One that is found is class "history" and printed.  Not found: PERMISSIVE if
PL/pgSQL raised 42501, else MISMATCH, except that a step where PL/pgSQL raises
42501 and plpgsql_jit returns without an error, in a SECURITY DEFINER program
after an earlier 42501 of plpgsql_jit in the same transaction, in a call
that reaches a nested frame, is class stale-privilege.  XX000 or a lost connection is always a MISMATCH.
--mode ref writes programs over text, varchar, numeric and integer variables,
arguments and results, in the same steps as flat ones; a bit of the first
argument inverts each condition, so that a few warm calls reach every branch.

A third of the programs call f directly instead of through the wrapper.  The
schema name is normalised.  Every statement of a script is a step.

Usage: pj_fuzz.py --psql <psql> --host <dir> --port <port> [--n N] [--start I]
                  [--seed S] [--opt-level 0|2|3] [--out dir] [--floor 0.5]
                  [--mode flat|rec|ref]
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
    def __init__(self, rng, cat):
        self.r = rng
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

    def stmt(self, depth):
        r = self.r
        x = r.random()
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
    def __init__(self, seed, cat):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.cat = cat
        g = Gen(r, cat)
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

    def __init__(self, rng, cat):
        self.r = rng
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

    def stmts(self, depth, n):
        return [self.stmt(depth) for _ in range(n)]

    def stmt(self, depth):
        r = self.r
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

    def decl(self):
        r = self.r
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

    def __init__(self, seed, cat):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        self.cat = cat
        g = RefGen(r, cat)
        self.g = g
        self.params = [{"name": "sel", "ty": "int4", "assign": False}]
        for i in range(r.choice([1, 1, 2, 2, 3])):
            v = {"name": "p%d" % (i + 1), "ty": r.choice(REF_POOL), "assign": True}
            self.params.append(v)
            g.scope.append(v)
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
        for _ in range(8):
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
                "  IF n <= 0 THEN RETURN %s; END IF;\n"
                "  %s\n  %s\nEND" % (guard, r.choice(REC_BASE), r.choice(REC_ASG),
                                      rec_shape(r, e)))
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


def rec_compare(args, prog, a, b, tally):
    """The verdict of a program and the step of it that decides.  equal;
    plan-choice, when every step that differs is what PL/pgSQL gives under
    force_generic_plan or force_custom_plan or a 42501 for the revoked
    function; history, when a history of PL/pgSQL gives all of them; stale-privilege;
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
    bad = None
    for i in diff:
        x, y = sa.get(str(i), []), sb.get(str(i), [])
        if y == forced["generic"].get(str(i)):
            tally["generic-steps"] += 1
        elif y == forced["custom"].get(str(i)):
            tally["custom-steps"] += 1
        elif denied_fn(prog, y):
            tally["stricter-steps"] += 1
        else:
            bad = i
            break
    if bad is None:
        return "plan-choice", diff[0]
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
        if args.v or verdict not in ("equal", "plan-choice", "history", "stale-privilege"):
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
          "history=%d stale-privilege=%d permissive=%d compiled=%d (%.1f%%)"
          % (args.seed, args.n, args.opt_level, tally["equal"], tally["plan-choice"],
             tally["MISMATCH"], tally["history"], tally["stale-privilege"], tally["PERMISSIVE"],
             tally["compiled"],
             100.0 * tally["compiled"] / max(args.n, 1)))
    print("pj_fuzz rec: steps that differ, as plpgsql_jit gives under force_generic_plan %d, "
          "force_custom_plan %d, 42501 where plpgsql has a value %d"
          % (tally["generic-steps"], tally["custom-steps"], tally["stricter-steps"]))
    if tally["compiled"] < args.floor * args.n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
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
        elif s == "@wrapper":
            o += prog.wrapper()
        else:
            o += s + "\n"
    o += "\\echo @@ end\nROLLBACK;\nRESET ROLE;\n\\echo @@ leak\n" + LEAK
    if status:
        o += ("\\echo @@ status\n"
              "SELECT state, coalesce(reason, ''), compiled_calls, calls FROM "
              "plllvm_pj_status('%s.f%s'::regprocedure);\n" % (sch, prog.sig()))
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
            steps[cur].append(line)
    return steps


def compare(prog, a, b, tally):
    """The verdict of the program and the first step of it; the first
    PERMISSIVE or MISMATCH ends the comparison, a stricter step does not."""
    sa, sb = split(a, SCHEMAS["plpgsql"]), split(b, SCHEMAS["plpgsql_jit"])
    verdict, first = "equal", None
    for i in range(len(prog.steps)):
        x, y = sa.get(str(i), []), sb.get(str(i), [])
        if i in prog.real:
            tally["walk-calls"] += 1
            tally["walk-calls-aborted"] += any("25P02" in l for l in x)
        if x == y:
            continue
        x2 = [l for l in x if not EXPRCTX.match(l)]
        y2 = [l for l in y if not EXPRCTX.match(l)]
        if x2 == y2:
            tally["allowed-context"] += 1
            continue
        ex = any(l.startswith(DENIED) for l in x)
        ey = any(l.startswith(DENIED) for l in y)
        if ex and not ey:
            return "PERMISSIVE", i
        if ey and (ex or prog.real.get(i)):
            tally["stricter-steps"] += 1
            verdict, first = "stricter", i if first is None else first
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
    ap.add_argument("--psql", required=True)
    ap.add_argument("--host", default="/tmp")
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--n", type=int, default=100)
    ap.add_argument("--start", type=int, default=0, help="index of the first program")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--opt-level", type=int, default=None)
    ap.add_argument("--out", default="results-fuzz")
    ap.add_argument("--floor", type=float, default=0.5)
    ap.add_argument("--mode", choices=["flat", "rec", "ref"], default="flat")
    ap.add_argument("-v", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    setup(args)
    if args.mode == "rec":
        sys.exit(main_rec(args))
    cat = load_catalog(lambda q: admin(args, q))
    if args.mode == "ref":
        universe = cat.universe
        cat = RefCat(lambda q: admin(args, q, DB))
        cat.universe = universe
    tally = Counter()
    reasons = Counter()
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = (RefProgram if args.mode == "ref" else Program)(seed, cat)
        a, b = run_pair(args, prog)
        verdict, step = compare(prog, a, b, tally)
        tally[verdict] += 1
        tally["walk-programs"] += prog.priv
        tally["stock-42501"] += a.count("ERROR:  42501") + a.count("\n42501 ")
        tally["jit-42501"] += b.count("ERROR:  42501") + b.count("\n42501 ")
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = m.group(1).strip().split("\n")[0].split("|") if m else []
        if len(st) == 4 and int(st[2]) > 0:
            tally["compiled"] += 1
        else:
            reasons["%s %s" % tuple(st[:2]) if len(st) == 4 else "no status"] += 1
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
    print("pj_fuzz: seed=%d programs=%d opt_level=%s equal=%d stricter=%d permissive=%d "
          "mismatch=%d compiled=%d (%.1f%%)"
          % (args.seed, args.n, args.opt_level, tally["equal"], tally["stricter"],
             tally["PERMISSIVE"], tally["MISMATCH"], comp, 100.0 * comp / max(args.n, 1)))
    print("pj_fuzz: 42501 raised: stock %d, plpgsql_jit %d; stricter steps %d; "
          "steps equal but for the SPI CONTEXT line %d"
          % (tally["stock-42501"], tally["jit-42501"], tally["stricter-steps"],
             tally["allowed-context"]))
    print("pj_fuzz: walk programs %d, their calls %d, of which %d after the "
          "transaction aborted in plpgsql"
          % (tally["walk-programs"], tally["walk-calls"], tally["walk-calls-aborted"]))
    for k, v in reasons.most_common(12):
        print("  not compiled: %5d  %s" % (v, k))
    if comp < args.floor * args.n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
