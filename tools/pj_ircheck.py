#!/usr/bin/env python3
"""Check the optimized IR of plpgsql_jit kernels against the hand-written ones.

Each kernel is created twice, as LANGUAGE plllvm from examples/kernels/<k>.ll
and as LANGUAGE plpgsql_jit, both run at plllvm's opt level 2 with
plllvm.dump_ir on.  For the innermost loop of each (opt -passes=print<loops>)
the tool counts the instructions outside the blocks that call
ProcessInterrupts, the "hot" instructions, and fails if

  - the function keeps a local slot (alloca),
  - the loop loads or stores anything but the position slot of the context
    and the interrupt flag, or calls anything but ProcessInterrupts,
  - the hot count is more than 1.5 times that of the hand-written code.

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

KERNELS = {
    "loop": """
CREATE FUNCTION loop_{s}(n integer) RETURNS integer
LANGUAGE {lang} IMMUTABLE AS $$
DECLARE
  i integer := 0;
BEGIN
  WHILE i < n LOOP
    i := i + 1;
  END LOOP;
  RETURN i;
END
$$;
""",
    "is_prime": """
CREATE FUNCTION is_prime_{s}(n integer) RETURNS boolean
LANGUAGE {lang} IMMUTABLE AS $$
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
END
$$;
""",
}

# an argument for the first call, which plans what it runs, and for the
# call that compiles
ARGS = {"loop": "3", "is_prime": "7"}


def run_psql(args, sql):
    cmd = [args.psql, "-X", "-q", "-h", args.host, "-p", str(args.port),
           "-d", args.dbname, "-v", "ON_ERROR_STOP=1"]
    r = subprocess.run(cmd, input=sql, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("psql failed:\n" + r.stderr)
    return r.stderr


def dump(args, kernel):
    """The optimized IR of the ll and the pj function of a kernel."""
    arg = ARGS[kernel]
    sql = "SET plllvm.opt_level = 2;\nSET plllvm.pj_opt_level = 2;\n"
    sql += "SET plllvm.dump_ir = on;\nSET client_min_messages = log;\n"
    sql += "\\set ll_ir `cat %s`\n" % os.path.join(args.kernels, kernel + ".ll")
    sql += "CREATE FUNCTION %s_ll(n integer) RETURNS %s LANGUAGE plllvm IMMUTABLE AS :'ll_ir';\n" % (
        kernel, "boolean" if kernel == "is_prime" else "integer")
    sql += KERNELS[kernel].format(s="pj", lang="plpgsql_jit")
    sql += "DO $$ BEGIN RAISE LOG 'pjcheck ll'; END $$;\n"
    sql += "SELECT %s_ll(%s);\n" % (kernel, arg)
    sql += "DO $$ BEGIN RAISE LOG 'pjcheck pj'; END $$;\n"
    sql += "SELECT %s_pj(%s);\nSELECT %s_pj(%s);\n" % ((kernel, arg) * 2)
    sql += "DROP FUNCTION %s_ll(integer);\nDROP FUNCTION %s_pj(integer);\n" % (kernel, kernel)
    err = run_psql(args, sql)

    out = {}
    which = None
    block = None
    for line in err.splitlines():
        m = re.match(r"LOG:  pjcheck (\w+)", line)
        if m:
            which = m.group(1)
            continue
        if re.match(r"LOG:  PL/LLVM IR of", line):
            block = []
            if which in out:
                sys.exit("%s: two modules for %s" % (kernel, which))
            out[which] = block
            continue
        if block is not None:
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
            continue
        if cur is None:
            continue
        if line == "}":
            break
        m = re.match(r"^([\w.$\-]+):", line)
        if m:
            cur = m.group(1)
            blocks[cur] = []
            continue
        s = line.strip()
        if s and not s.startswith(";"):
            blocks[cur].append(s)
    return blocks


def loops(path, opt):
    out = subprocess.run([opt, "-passes=print<loops>", "-disable-output", path],
                         capture_output=True, text=True).stderr
    res = []
    for line in out.splitlines():
        m = re.match(r"\s*Loop at depth (\d+) containing: (.*)", line)
        if m:
            names = [re.sub(r"<.*?>", "", b).lstrip("%") for b in m.group(2).split(",")]
            res.append((int(m.group(1)), names))
    return res


def analyze(text, opt):
    blocks = parse(text)
    allocas = [i for b in blocks.values() for i in b if " = alloca " in i]
    with tempfile.NamedTemporaryFile("w", suffix=".ll") as f:
        f.write(text)
        f.flush()
        found = loops(f.name, opt)
    if not found:
        sys.exit("no loop in the IR")
    depth, names = max(found, key=lambda l: l[0])
    c = Counter()
    calls = Counter()
    problems = []
    for name in names:
        insts = blocks.get(name, [])
        cold = any("@ProcessInterrupts" in i for i in insts)
        for i in insts:
            c["instr"] += 1
            if not cold:
                c["hot"] += 1
            if re.search(r"= load volatile", i):
                continue
            if re.search(r"= load ", i):
                problems.append("load in the loop: " + i)
            if i.startswith("store "):
                if re.search(r"ptr %ctx\b", i):
                    c["ctx_stores"] += 1
                else:
                    problems.append("store in the loop: " + i)
            m = re.search(r"\bcall [^@]*@([\w.$\"]+)\(", i)
            if m:
                calls[m.group(1)] += 1
    for callee in calls:
        if callee != "ProcessInterrupts" and not callee.startswith("llvm."):
            problems.append("call in the loop: " + callee)
    if allocas:
        problems.append("local slots left: " + ", ".join(allocas))
    return c, calls, problems


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

    adm = subprocess.run([args.psql, "-X", "-q", "-h", args.host, "-p",
                          str(args.port), "-d", "postgres", "-c",
                          "DROP DATABASE IF EXISTS %s" % args.dbname, "-c",
                          "CREATE DATABASE %s" % args.dbname],
                         capture_output=True, text=True)
    if adm.returncode != 0:
        sys.exit(adm.stderr)
    run_psql(args, "CREATE EXTENSION plllvm;\n")

    failed = False
    print("%-10s %8s %8s %6s  %s" % ("kernel", "ll hot", "pj hot", "ratio", "pj loop"))
    try:
        for kernel in args.kernel:
            ir = dump(args, kernel)
            ll, _, _ = analyze(ir["ll"], args.opt)
            pj, calls, problems = analyze(ir["pj"], args.opt)
            ratio = pj["hot"] / ll["hot"]
            print("%-10s %8d %8d %6.2f  %d instructions, %d position stores, calls %s" % (
                kernel, ll["hot"], pj["hot"], ratio, pj["instr"],
                pj["ctx_stores"], dict(calls) or "-"))
            if ratio > MAX_RATIO:
                problems.append("hot count %.2f times the hand-written code (limit %.1f)" % (
                    ratio, MAX_RATIO))
            for p in problems:
                print("  FAIL %s: %s" % (kernel, p))
                failed = True
    finally:
        subprocess.run([args.psql, "-X", "-q", "-h", args.host, "-p",
                        str(args.port), "-d", "postgres", "-c",
                        "DROP DATABASE IF EXISTS %s" % args.dbname],
                       capture_output=True, text=True)

    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
