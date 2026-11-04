#!/usr/bin/env python3
"""Check the optimized IR of plpgsql_jit kernels against the hand-written ones.

Each kernel is created twice, as LANGUAGE plllvm from examples/kernels/<k>.ll
and as LANGUAGE plpgsql_jit, both run at opt level 2 with plllvm.dump_ir on.
For the innermost loop of each (opt -passes=print<loops>) the tool counts the
instructions outside the blocks that call ProcessInterrupts, the "hot" ones,
and fails if

  - the function keeps a local slot (alloca),
  - the loop loads or stores anything but the interrupt flag and the position
    slot of the context, or calls anything but ProcessInterrupts,
  - the hot count is more than 1.5 times that of the hand-written code.

fib has no loop and calls itself by design: the whole function is counted
(the hand-written one has two), it must keep no local slot and make exactly two
calls through a site, and the ratio is printed, not checked.

A script of the standard library, run by make check-pj-ir against a running
cluster; it has no dependencies to manage.

Usage: pj_ircheck.py --psql <psql> --host <dir> --port <port> --opt <opt>
                     --kernels <dir> [kernel ...]
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter

MAX_RATIO = 1.5

# name: (result type, body), and the argument of the first and the second call
KERNELS = {
    "loop": ("integer", """
DECLARE
  i integer := 0;
BEGIN
  WHILE i < n LOOP
    i := i + 1;
  END LOOP;
  RETURN i;
END""", "3"),
    "is_prime": ("boolean", """
DECLARE
  idx integer := 2;
BEGIN
  LOOP
    IF idx > n/2 THEN
      RETURN TRUE;
    END IF;
    IF mod(n, idx) = 0 THEN
      RETURN FALSE;
    END IF;
    idx := idx + 1;
  END LOOP;
END""", "7"),
    "fib": ("integer", """
BEGIN
  IF n < 2 THEN
    RETURN n;
  END IF;
  RETURN fib_pj(n - 1) + fib_pj(n - 2);
END""", "10"),
    "mandelbrot": ("text", """
DECLARE
  two CONSTANT float8 := 2.0;
  four CONSTANT float8 := 4.0;
  one CONSTANT float8 := 1.0;
  onehalf CONSTANT float8 := 1.5;
  fsz float8;
  x integer; y integer; k integer;
  cr float8; ci float8; zr float8; zi float8; tr float8; ti float8;
  cnt integer := 0;
  h bigint := 0;
BEGIN
  fsz := n;
  FOR y IN 0..n-1 LOOP
    ci := two * y / fsz - one;
    FOR x IN 0..n-1 LOOP
      cr := two * x / fsz - onehalf;
      zr := 0; zi := 0; tr := 0; ti := 0; k := 0;
      WHILE k < 50 AND tr + ti <= four LOOP
        zi := two * zr * zi + ci;
        zr := tr - ti + cr;
        tr := zr * zr;
        ti := zi * zi;
        k := k + 1;
      END LOOP;
      IF tr + ti <= four THEN
        cnt := cnt + 1;
        h := (h * 31 + x * 7 + y) % 1000000007;
      END IF;
    END LOOP;
  END LOOP;
  RETURN cnt::text || '/' || h::text;
END""", "9"),
}

SCRIPT = """\
SET plllvm.opt_level = 2;
SET plllvm.pj_opt_level = 2;
SET plllvm.dump_ir = on;
SET client_min_messages = log;
\\set ll_ir `cat {ir}`
CREATE FUNCTION {k}_ll(n integer) RETURNS {ret}
  LANGUAGE plllvm IMMUTABLE AS :'ll_ir';
CREATE FUNCTION {k}_pj(n integer) RETURNS {ret}
  LANGUAGE plpgsql_jit IMMUTABLE AS $$ {body} $$;
DO $$ BEGIN RAISE LOG 'pjcheck ll'; END $$;
SELECT {k}_ll({arg});
DO $$ BEGIN RAISE LOG 'pjcheck pj'; END $$;
SELECT {k}_pj({arg});
SELECT {k}_pj({arg});
DROP FUNCTION {k}_ll(integer);
DROP FUNCTION {k}_pj(integer);
"""


def psql(args, sql, dbname=None):
    """Run sql, return what psql wrote to stderr."""
    cmd = [args.psql, "-X", "-q", "-h", args.host, "-p", str(args.port),
           "-d", dbname or args.dbname, "-v", "ON_ERROR_STOP=1"]
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr)
    return r.stderr


def dump(args, kernel):
    """The optimized IR of the ll and the pj function of a kernel."""
    ret, body, arg = KERNELS[kernel]
    ir = os.path.join(args.kernels, kernel + ".ll")
    err = psql(args, SCRIPT.format(k=kernel, ret=ret, body=body, arg=arg,
                                   ir=ir))

    out = {}
    which = None
    block = None
    for line in err.splitlines():
        m = re.match(r"LOG:  pjcheck (\w+)", line)
        if m:
            which = m.group(1)
        elif re.match(r"LOG:  PL/LLVM IR of", line):
            if which in out:
                sys.exit("%s: two modules for %s" % (kernel, which))
            block = out[which] = []
        elif block is not None:
            block.append(line)
    if set(out) != {"ll", "pj"}:
        sys.exit("%s: no IR dumped for both (got %s)" % (kernel, sorted(out)))
    return {k: "\n".join(v) + "\n" for k, v in out.items()}


def parse(text):
    """Blocks of the one defined function: label -> instruction lines."""
    blocks = {}
    cur = None
    for line in text.splitlines():
        if re.match(r"define .*@([\w.\"$]+)\(", line):
            cur = "entry"
            blocks[cur] = []
        elif cur is None:
            continue
        elif line == "}":
            break
        elif re.match(r"^([\w.$\-]+):", line):
            cur = line.split(":")[0]
            blocks[cur] = []
        elif line.strip() and not line.strip().startswith(";"):
            blocks[cur].append(line.strip())
    return blocks


def innermost_loop(text, opt):
    """The blocks of the deepest loop."""
    with tempfile.NamedTemporaryFile("w", suffix=".ll") as f:
        f.write(text)
        f.flush()
        out = subprocess.run([opt, "-passes=print<loops>", "-disable-output",
                              f.name], capture_output=True,
                             text=True).stderr
    found = []
    for line in out.splitlines():
        m = re.match(r"\s*Loop at depth (\d+) containing: (.*)", line)
        if m:
            found.append((int(m.group(1)),
                          [re.sub(r"<.*?>", "", b).lstrip("%")
                           for b in m.group(2).split(",")]))
    if not found:
        sys.exit("no loop in the IR")
    return max(found)[1]


def analyze_whole(text):
    """Hot count of every function of the module, the calls through a site,
    and the local slots."""
    hot = sites = 0
    problems = []
    insts = None
    blocks = []
    for line in text.splitlines():
        if re.match(r"define .*@([\w.\"$]+)\(", line):
            insts = []
            blocks.append(insts)
        elif insts is None or not line.strip() or line.startswith(";"):
            continue
        elif line == "}":
            insts = None
        elif re.match(r"^([\w.$\-]+):", line):
            insts = []
            blocks.append(insts)
        else:
            insts.append(line.strip())
    for insts in blocks:
        cold = any("@ProcessInterrupts" in i for i in insts)
        hot += 0 if cold else len(insts)
        sites += sum("call " in i and "@plllvm_pj_site(" in i for i in insts)
        problems += ["local slot: " + i for i in insts if " = alloca " in i]
    return hot, sites, problems


def analyze(text, opt):
    """Hot count, position stores, calls, and what the loop must not do."""
    blocks = parse(text)
    hot = stores = 0
    calls = Counter()
    problems = []
    for name in innermost_loop(text, opt):
        insts = blocks.get(name, [])
        cold = any("@ProcessInterrupts" in i for i in insts)
        for i in insts:
            hot += not cold
            if "= load volatile" in i:
                continue
            if "= load " in i:
                problems.append("load in the loop: " + i)
            if i.startswith("store "):
                if re.search(r"ptr %ctx\b", i):
                    stores += 1
                else:
                    problems.append("store in the loop: " + i)
            m = re.search(r"\bcall [^@]*@([\w.$\"]+)\(", i)
            if m:
                calls[m.group(1)] += 1
    for callee in calls:
        if callee != "ProcessInterrupts" and not callee.startswith("llvm."):
            problems.append("call in the loop: " + callee)
    allocas = [i for b in blocks.values() for i in b if " = alloca " in i]
    if allocas:
        problems.append("local slots left: " + ", ".join(allocas))
    return hot, stores, calls, problems


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--psql", required=True)
    ap.add_argument("--host", required=True)
    ap.add_argument("--port", required=True)
    ap.add_argument("--opt", required=True)
    ap.add_argument("--kernels", required=True)
    ap.add_argument("--dbname", default="pj_ircheck")
    ap.add_argument("kernel", nargs="*", default=sorted(KERNELS))
    args = ap.parse_args()

    psql(args, "DROP DATABASE IF EXISTS %s;\nCREATE DATABASE %s;\n" %
         ((args.dbname,) * 2), dbname="postgres")
    psql(args, "CREATE EXTENSION plllvm;\n")

    failed = False
    print("%-10s %7s %7s %6s  %s" % ("kernel", "ll hot", "pj hot", "ratio",
                                     "pj loop"))
    try:
        for kernel in args.kernel:
            ir = dump(args, kernel)
            if kernel == "fib":
                ll_hot = analyze_whole(ir["ll"])[0]
                hot, sites, problems = analyze_whole(ir["pj"])
                print("%-10s %7d %7d %6.2f  %d calls through a site" %
                      (kernel, ll_hot, hot, hot / ll_hot, sites))
                if sites != 2:
                    problems.append("%d calls through a site, want 2" % sites)
                for p in problems:
                    print("  FAIL %s: %s" % (kernel, p))
                    failed = True
                continue
            ll_hot = analyze(ir["ll"], args.opt)[0]
            hot, stores, calls, problems = analyze(ir["pj"], args.opt)
            ratio = hot / ll_hot
            print("%-10s %7d %7d %6.2f  %d position stores, calls %s" %
                  (kernel, ll_hot, hot, ratio, stores, dict(calls) or "-"))
            if ratio > MAX_RATIO:
                problems.append("hot count %.2f times the hand-written code "
                                "(limit %.1f)" % (ratio, MAX_RATIO))
            for p in problems:
                print("  FAIL %s: %s" % (kernel, p))
                failed = True
    finally:
        psql(args, "DROP DATABASE IF EXISTS %s;\n" % args.dbname,
             dbname="postgres")

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
