#!/usr/bin/env python3
"""Differential fuzzer for LANGUAGE plpgsql_jit against LANGUAGE plpgsql.

A seeded generator writes a PL/pgSQL function over the statements and types
that plllvm compiles (assignment, IF, LOOP, WHILE, FOR over integers, EXIT and
CONTINUE, nested blocks, RETURN; smallint, integer, bigint, real, double
precision, boolean) and a script that calls it: warm calls, edge arguments,
and for half of the programs a random walk of role switches, REVOKE of the
functions it uses, savepoints and rollbacks inside one transaction.  The
script runs in two sessions of one cluster, once with the function created as
plpgsql and once as plpgsql_jit, and the output of each step (value, SQLSTATE,
message, CONTEXT) is compared.

A difference is one of

  equal     the same output, or the same once the "PL/pgSQL expression" CONTEXT
            lines are dropped (plan section 2.6 (a), (d), (f): counted)
  stricter  plpgsql_jit raises 42501 where plpgsql returns or raises something
            else, or both raise it at different expressions (section 2.4
            T1-T3: classified, the rest of the script is not compared)
  PERMISSIVE plpgsql raises 42501 and plpgsql_jit does not: a bug
  MISMATCH  anything else

A mismatch is minimised and written as a script that reproduces it with
"psql -v lang=plpgsql" and "psql -v lang=plpgsql_jit".  The compiled fraction,
the programs whose function ran compiled at least once, comes from
plllvm_pj_status().  No timing.  Standard library only, run by make fuzz-pj
against a running cluster.

Usage: pj_fuzz.py --psql <psql> --host <dir> --port <port> [--n N] [--seed S]
                  [--opt-level 0|2|3] [--out dir] [--floor 0.5]
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

# what the compilers handle is int4, int8, float8 and boolean; the other
# types are the declined rows, kept rare so that they do not drown the rest
POOL = ["int4"] * 8 + ["int8"] * 4 + ["float8"] * 4 + ["bool"] * 3 + ["int2", "float4"] * 0
RARE = ["int2", "float4"]

INT_LITS = [0, 0, 1, 1, 2, 3, 5, 7, 10, 100, -1, -2, 2147483647, -2147483647]
EDGE = {"int2": ["0", "1", "-1", "32767", "-32768", "2", "100"],
        "int4": ["0", "1", "-1", "2147483647", "-2147483647", "-2147483648",
                 "2", "46341", "100"],
        "int8": ["0", "1", "-1", "9223372036854775807", "-9223372036854775808",
                 "3037000500", "2", "100000"],
        "float4": ["0", "1", "-1", "1.5", "'NaN'", "'Infinity'", "3.5e38", "-0.5"],
        "float8": ["0", "1", "-1", "1.5", "'NaN'", "'Infinity'", "'-Infinity'",
                   "1e308", "-0.5", "0.1"],
        "bool": ["true", "false"]}
HARMLESS = {"int2": ["1", "2", "3", "5"], "int4": ["1", "2", "3", "5"],
            "int8": ["1", "2", "3", "5"], "float4": ["1.5", "2", "0.5"],
            "float8": ["1.5", "2", "0.5"], "bool": ["true", "false"]}

class Catalog:
    """Operator and cast functions of the numeric types, by their names."""

    def __init__(self, ops, casts):
        self.ops = ops
        self.casts = casts


def load_catalog(run_sql):
    tl = ",".join("'%s'::regtype" % t for t in TYPES.values())
    ops, casts = {}, {}
    for line in run_sql(
            "SELECT format_type(oprleft, NULL), oprname, format_type(oprright, NULL),"
            " oprcode::regprocedure FROM pg_operator"
            " WHERE oprleft IN (%s) AND oprright IN (%s)" % (tl, tl)):
        a, op, b, code = line.split("\t")
        ops[(SQL2PG[a], op, SQL2PG[b])] = code
    for line in run_sql(
            "SELECT format_type(castsource, NULL), format_type(casttarget, NULL),"
            " castfunc::regprocedure FROM pg_cast WHERE castfunc <> 0"
            " AND castsource IN (%s) AND casttarget IN (%s)" % (tl, tl)):
        a, b, code = line.split("\t")
        casts[(SQL2PG[a], SQL2PG[b])] = code
    return Catalog(ops, casts)


class Gen:
    def __init__(self, rng, cat):
        self.r = rng
        self.cat = cat
        self.procs = set()
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
        if ty in INTS:
            v = r.choice(INT_LITS)
            if ty == "int2":
                return "(%d)::smallint" % max(-32767, min(32767, v)), ty
            if ty == "int8":
                return r.choice(["(%d)::bigint" % v, "9223372036854775807",
                                 "3037000500"]), ty
            return ("(%d)" % v if v < 0 else str(v)), ty
        v = r.choice(["0", "1", "0.5", "-1.5", "2", "1e10", "1e308", "'NaN'",
                      "'Infinity'", "3.5e38"])
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

    def pty(self, bools=True):
        t = self.r.choice(POOL if bools else [x for x in POOL if x != "bool"])
        return self.r.choice(RARE) if self.r.random() < 0.015 else t

    def wider(self, a, b):
        order = NUMS
        return a if order.index(a) >= order.index(b) else b

    def op2(self, a, op, b):
        """The operand texts and result type for 'a op b' with both operand
        types known; casts that have no direct operator are explicit."""
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
        f = self.cat.casts.get((e[1], to))
        if f:
            self.procs.add(f)
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
                return "mod(%s, %s)" % (ta, tb), self.wider(rta, rtb)
            if x < 0.72:
                a = self.num(ty, d - 1)
                return "(- %s)" % a[0], a[1]
            if x < 0.78:
                a = self.num(ty, d - 1)
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
            return "(- %s)" % a[0], a[1]
        if x < 0.75:
            a = self.num(ty, d - 1)
            return "abs(%s)" % a[0], a[1]
        if x < 0.82 and ty == "float8":
            a = self.num(ty, d - 1)
            return "sqrt(%s)" % a[0], "float8"
        if x < 0.9:
            return self.case(ty, d)
        src = r.choice(["int4", "int8", "float8"])
        a = self.num(src, d - 1)
        return self.cast(a, ty)

    def result(self, a, op, b):
        if a in FLTS or b in FLTS:
            return "float8" if "float8" in (a, b) else "float4"
        return self.wider(a, b)

    def case(self, ty, d):
        c = self.boolean(d - 1)
        a, b = self.num(ty, d - 1), self.num(ty, d - 1)
        return ("CASE WHEN %s THEN %s ELSE %s END" % (c[0], a[0], b[0]),
                self.result(a[1], "+", b[1]) if (a[1] in NUMS and b[1] in NUMS)
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
        v = {"name": "v%d" % self.nvar, "ty": ty, "assign": assignable}
        return v

    def assignable(self):
        seen = {}
        for v in self.scope:
            seen[v["name"]] = v
        return [v for v in seen.values() if v["assign"]]

    def assign_expr(self, ty):
        r = self.r
        x = r.random()
        if x < 0.03:
            return "NULL"
        if x < 0.045 and ty in INTS[:2] + ["float4"]:
            return self.expr(r.choice(NUMS), 2)[0]      # a narrowing cast
        if x < 0.12 and ty in INTS[1:]:
            return self.expr(INTS[INTS.index(ty) - 1], 2)[0]
        if x < 0.25 and ty == "float8":
            return self.expr(r.choice(["int4", "int4", "int8"]), 2)[0]
        return self.expr(ty, 2)[0]

    def stmts(self, depth, n):
        out = []
        for _ in range(n):
            out.append(self.stmt(depth))
        return out

    def stmt(self, depth):
        r = self.r
        x = r.random()
        av = self.assignable()
        if depth <= 0 or x < 0.35:
            if av:
                v = r.choice(av)
                return {"k": "assign", "v": v["name"], "e": self.assign_expr(v["ty"])}
            if depth <= 0:
                return {"k": "return", "e": self.expr(self.rettype, 2)[0]}
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
        return {"k": "return", "e": self.expr(self.rettype, 2)[0]}

    def label(self, p):
        if self.r.random() < 0.4:
            self.nlabel += 1
            return "%s%d" % (p, self.nlabel)
        return None

    def loop(self, depth):
        r = self.r
        label = self.label("l")
        kind = r.choice(["loop", "while", "for", "for"])
        self.loops.append((label, True))
        try:
            if kind == "for":
                lo, hi = self.bound(), self.bound()
                step = r.choice([None, None, "1", "2", "3", "0", self.bound()])
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
            d = "NULL" if r.random() < 0.1 else self.expr(ty, 1)[0]
        const = d is not None and r.random() < 0.15
        notnull = d is not None and d != "NULL" and r.random() < 0.15
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
        return "%sFOR %s IN %s%s..%s%s LOOP\n%s%sEND LOOP;\n" % (
            lab, s["var"], "REVERSE " if s["rev"] else "", s["lo"], s["hi"],
            " BY " + s["step"] if s["step"] else "",
            render_stmts(s["body"], ind + 1), p)
    if k == "block":
        o = "%s<<%s>>\n" % (p, s["label"]) if s["label"] else ""
        if s["decls"]:
            o += "%sDECLARE\n" % p
            for n, ty, const, nn, d in s["decls"]:
                o += "%s  %s %s%s%s%s;\n" % (
                    p, n, "CONSTANT " if const else "", TYPES[ty],
                    " NOT NULL" if nn else "", " := " + d if d else "")
        return "%s%sBEGIN\n%s%sEND;\n" % (o, p, render_stmts(s["body"], ind + 1), p)
    raise ValueError(k)


class Program:
    def __init__(self, seed, cat):
        r = random.Random(seed)
        self.rng = r
        self.seed = seed
        g = Gen(r, cat)
        self.g = g
        np_ = r.choice([0, 1, 1, 2, 2, 3])
        self.params = []
        for i in range(np_):
            ty = g.pty()
            v = {"name": "p%d" % (i + 1), "ty": ty, "assign": True}
            self.params.append(v)
            g.scope.append(v)
        self.rettype = g.pty()
        g.rettype = self.rettype
        self.attrs = r.choice(["", "", "IMMUTABLE", "STABLE", "STRICT", "IMMUTABLE STRICT"])
        self.decls = [g.decl() for _ in range(r.randint(0, 3))]
        self.body = g.stmts(3, r.randint(1, 4))
        self.final = r.random() < 0.95
        self.ret = g.expr(self.rettype, 2)[0] if self.final else None
        if r.random() < 0.04 and self.final:
            wide = {"int2": "int4", "int4": "int8", "float4": "float8"}.get(self.rettype)
            if wide:
                self.ret = g.expr(wide, 2)[0]
        self.priv = r.random() < 0.6
        self.steps = self.make_steps()

    def sig(self):
        return "(%s)" % ",".join(TYPES[p["ty"]] for p in self.params)

    def function(self):
        decls = list(self.decls)
        o = "CREATE FUNCTION f(%s) RETURNS %s LANGUAGE :lang %s AS $f$\n" % (
            ", ".join("%s %s" % (p["name"], TYPES[p["ty"]]) for p in self.params),
            TYPES[self.rettype], self.attrs)
        o += "DECLARE\n"
        for n, ty, const, nn, d in decls:
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
            out.append("%s::%s" % (v, TYPES[t]))
        return ", ".join(out)

    def call(self, kind, fn="f"):
        return "SELECT %s(%s);" % (fn, self.args(kind))

    def make_steps(self):
        r = self.rng
        st = ["@create", "@wrapper"]
        for _ in range(3):
            st.append(self.call("harmless"))
        for _ in range(r.randint(3, 8)):
            st.append(self.call(r.choice(["harmless", "edge", "edge"])))
        if self.params:
            gs = ", ".join("%s::%s" % (
                {"bool": "(i % 2 = 0)"}.get(p["ty"], "(i - 3)"), TYPES[p["ty"]])
                for p in self.params)
            st.append("SELECT f(%s) FROM generate_series(1, 6) i;" % gs)
        if not self.priv:
            st.append(self.call("edge", "w"))
            return st
        cands = sorted(self.g.procs) or ["int4pl(integer,integer)"]
        sp = 0
        st.append("BEGIN;")

        def calls(n):
            nonlocal sp
            for _ in range(n):
                x = r.random()
                if x < 0.5:
                    st.append(self.call(r.choice(["harmless", "edge"])))
                elif x < 0.75:
                    st.append(self.call("edge", "w"))
                elif x < 0.9:
                    sp += 1
                    st.append("SAVEPOINT s%d;" % sp)
                    st.append(self.call("edge", r.choice(["f", "w"])))
                    st.append("ROLLBACK TO s%d;" % sp)
                else:
                    st.append(self.call("harmless"))

        # the sequences that went wrong before: calls, an owner's REVOKE, a role
        # without the privilege, calls; with the walk's other moves between
        calls(r.randint(0, 3))
        for _ in range(r.choice([1, 1, 1, 2])):
            st.append("RESET ROLE;")
            verb = r.choice(["REVOKE"] * 5 + ["GRANT"])
            st.append("%s EXECUTE ON FUNCTION %s %s PUBLIC;" % (
                verb, r.choice(cands), "FROM" if verb == "REVOKE" else "TO"))
            calls(r.randint(0, 1))
        st.append(r.choice(["SET ROLE %s;", "SET LOCAL ROLE %s;"]) % ROLE)
        calls(r.randint(1, 4))
        if r.random() < 0.4:
            st.append("RESET ROLE;")
            calls(r.randint(1, 2))
        if r.random() < 0.3:
            st.append("SET ROLE %s;" % ROLE)
            calls(r.randint(1, 2))
        st.append("ROLLBACK;")
        return st


# ---- running

CLEAN = ("SET client_min_messages = warning;\n"
         "DROP SCHEMA IF EXISTS fzs, fzj CASCADE;\n"
         "CREATE SCHEMA fzs; CREATE SCHEMA fzj;\n"
         "GRANT USAGE ON SCHEMA fzs, fzj TO %s;\n"
         "RESET client_min_messages;\n" % ROLE)


def script(prog, lang, tail=False, inject=False):
    sch = SCHEMAS[lang]
    o = ("\\set VERBOSITY verbose\n\\set SHOW_CONTEXT always\n"
         "SET search_path = %s, public;\nSET statement_timeout = '10s';\n" % sch)
    o = CLEAN + o
    if lang == "plpgsql_jit":
        o += "\\set lang plpgsql_jit\n"
        if inject:
            o += "\\pset null '(null)'\n"
    else:
        o += "\\set lang plpgsql\n"
    for i, s in enumerate(prog.steps):
        o += "\\echo @@ %d\n" % i
        if s == "@create":
            o += prog.function()
        elif s == "@wrapper":
            o += prog.wrapper()
        else:
            o += s + "\n"
    o += "\\echo @@ end\nROLLBACK;\nRESET ROLE;\n"
    if tail:
        o += ("\\echo @@ status\n"
              "SELECT state, coalesce(reason, ''), compiled_calls, calls FROM "
              "plllvm_pj_status('%s.f%s'::regprocedure);\n" % (sch, prog.sig()))
    return o + CLEAN


def run_psql(args, sql, lang=None, opt=None):
    env = dict(os.environ)
    env["PGOPTIONS"] = "-c session_preload_libraries=plllvm"
    if lang == "plpgsql_jit" and opt is not None:
        env["PGOPTIONS"] += " -c plllvm.pj_opt_level=%d" % opt
    p = subprocess.run([args.psql, "-X", "-q", "-At", "-h", args.host, "-p", str(args.port),
                        "-d", DB, "-v", "ON_ERROR_STOP=0", "-f", "-"],
                       input=sql, capture_output=False, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, env=env, timeout=300)
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
    for r in (ROLE,):
        admin(args, "DO $$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '%s') "
                    "THEN CREATE ROLE %s; END IF; END $$" % (r, r))
    admin(args, "CREATE EXTENSION plllvm; CREATE SCHEMA fzs; CREATE SCHEMA fzj;"
                "GRANT USAGE ON SCHEMA fzs, fzj TO %s;" % ROLE, DB)


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


def compare(prog, a, b):
    """('equal'|'stricter'|'PERMISSIVE'|'MISMATCH', step, note, allowed-count)."""
    sa, sb = split(a, SCHEMAS["plpgsql"]), split(b, SCHEMAS["plpgsql_jit"])
    allowed = 0
    for i in range(len(prog.steps)):
        x, y = sa.get(str(i), []), sb.get(str(i), [])
        if x == y:
            continue
        x2 = [l for l in x if not EXPRCTX.match(l)]
        y2 = [l for l in y if not EXPRCTX.match(l)]
        if x2 == y2:
            allowed += 1
            continue
        ex = any(l.startswith(DENIED) for l in x)
        ey = any(l.startswith(DENIED) for l in y)
        if ex and not ey:
            return "PERMISSIVE", i, "", allowed
        if ey:
            # raised where stock returns a value or another error, or both
            # raise 42501 and stock's stale ExprState reports another expression
            return "stricter", i, "", allowed
        return "MISMATCH", i, "", allowed
    return "equal", None, "", allowed


def run_pair(args, prog):
    a = run_psql(args, script(prog, "plpgsql"))
    b = run_psql(args, script(prog, "plpgsql_jit", True, args.inject), "plpgsql_jit",
                 args.opt_level)
    return a, b, compare(prog, a, b)


# ---- minimising

def shrink_lists(stmts):
    """Candidates with one statement removed or replaced by its body."""
    for i, s in enumerate(stmts):
        yield stmts[:i] + stmts[i + 1:]
        subs = []
        if s["k"] == "if":
            subs = [s["then"]] + [b for _, b in s["elifs"]] + ([s["else"]] if s["else"] else [])
        elif s["k"] in ("loop", "while", "fori", "block"):
            subs = [s["body"]]
        for b in subs:
            yield stmts[:i] + b + stmts[i + 1:]
        for key in ("then", "else", "body"):
            if isinstance(s.get(key), list):
                for c in shrink_lists(s[key]):
                    t = dict(s)
                    t[key] = c
                    yield stmts[:i] + [t] + stmts[i + 1:]
        if s["k"] == "if":
            for j, (c, b) in enumerate(s["elifs"]):
                for cc in shrink_lists(b):
                    t = dict(s)
                    t["elifs"] = s["elifs"][:j] + [(c, cc)] + s["elifs"][j + 1:]
                    yield stmts[:i] + [t] + stmts[i + 1:]


def minimise(args, prog, kind):
    def bad(p):
        return run_pair(args, p)[2][0] == kind

    import copy
    best = copy.deepcopy(prog)
    changed = True
    while changed:
        changed = False
        for k in range(len(best.steps) - 1, 0, -1):
            if best.steps[k] in ("@create", "@wrapper"):
                continue
            c = copy.deepcopy(best)
            del c.steps[k]
            if bad(c):
                best, changed = c, True
        for cand in shrink_lists(best.body):
            c = copy.deepcopy(best)
            c.body = cand
            if bad(c):
                best, changed = c, True
                break
        for key in ("decls",):
            for k in range(len(getattr(best, key)) - 1, -1, -1):
                c = copy.deepcopy(best)
                del getattr(c, key)[k]
                if bad(c):
                    best, changed = c, True
    return best


def repro(prog, note, opt=None):
    o = ("-- pj_fuzz reproduction: %s\n-- psql -X -v lang=plpgsql -f this   (stock)\n"
         "-- psql -X -v lang=plpgsql_jit -f this   (compiled; plllvm preloaded)\n"
         "-- needs the role %s and the extension plllvm\n"
         "\\if :{?lang}\\else \\set lang plpgsql \\endif\n"
         "\\set VERBOSITY verbose\n\\set SHOW_CONTEXT always\n"
         "SELECT CASE :'lang' WHEN 'plpgsql' THEN 'fzs' ELSE 'fzj' END || ', public' AS sp \\gset\n"
         % (note, ROLE))
    o += CLEAN + "SET search_path = :sp;\n"
    if opt is not None:
        o += "SET plllvm.pj_opt_level = %d;  -- ignored by plpgsql\n" % opt
    for s in prog.steps:
        if s == "@create":
            o += prog.function()
        elif s == "@wrapper":
            o += prog.wrapper()
        else:
            o += s + "\n"
    return o


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
    ap.add_argument("--no-minimise", action="store_true")
    ap.add_argument("--inject", action="store_true",
                    help="self-test: make plpgsql_jit print NULL differently, "
                         "to see a mismatch minimised")
    ap.add_argument("-v", action="store_true")
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    setup(args)
    cat = load_catalog(lambda q: admin(args, q))
    tally = Counter()
    reasons = Counter()
    failed = False
    for i in range(args.start, args.start + args.n):
        seed = "%d:%d" % (args.seed, i)
        prog = Program(seed, cat)
        a, b, (verdict, step, _, allowed) = run_pair(args, prog)
        tally[verdict] += 1
        tally["allowed-context"] += allowed
        tally["stock-42501"] += a.count("ERROR:  42501") + a.count("\n42501 ")
        tally["jit-42501"] += b.count("ERROR:  42501") + b.count("\n42501 ")
        m = re.search(r"@@ status\n(.*)", b, re.S)
        st = (m.group(1).strip().split("\n")[0].split("|") if m else [])
        if len(st) == 4:
            tally["programs-with-status"] += 1
            if int(st[2]) > 0:
                tally["compiled"] += 1
            else:
                reasons["%s %s" % (st[0], st[1])] += 1
        else:
            reasons["no status"] += 1
        if args.v or verdict not in ("equal",):
            print("seed %s: %s%s" % (seed, verdict, "" if step is None else " at step %d" % step))
        if verdict in ("MISMATCH", "PERMISSIVE"):
            failed = True
            best = prog if args.no_minimise else minimise(args, prog, verdict)
            f = os.path.join(args.out, "fuzz-%s.sql" % seed.replace(":", "-"))
            with open(f, "w") as fh:
                fh.write(repro(best, "%s, seed %s" % (verdict, seed), args.opt_level))
            a2, b2, _ = run_pair(args, best)
            with open(f[:-4] + ".out", "w") as fh:
                fh.write("== plpgsql\n%s\n== plpgsql_jit\n%s\n" % (a2, b2))
            print("  reproduction: %s" % f)
    n = args.n
    comp = tally["compiled"]
    print("pj_fuzz: seed=%d programs=%d opt_level=%s equal=%d stricter=%d permissive=%d "
          "mismatch=%d allowed_context_steps=%d compiled=%d (%.1f%%) "
          "42501_raised: stock %d, plpgsql_jit %d"
          % (args.seed, n, args.opt_level, tally["equal"], tally["stricter"],
             tally["PERMISSIVE"], tally["MISMATCH"], tally["allowed-context"], comp,
             100.0 * comp / max(n, 1), tally["stock-42501"], tally["jit-42501"]))
    for k, v in reasons.most_common(12):
        print("  not compiled: %5d  %s" % (v, k))
    if comp < args.floor * n:
        print("pj_fuzz: compiled fraction below the floor of %.0f%%" % (100 * args.floor))
        failed = True
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
