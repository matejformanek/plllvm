#!/bin/sh
# Pins that need a loaded C module, so they are not part of installcheck.
#
# raise: an output function that sends a message, in a RAISE whose later
#   parameter is not planned yet, runs once, as in PL/pgSQL, not again after
#   a deopt.
# t3: an object access hook that raises at a function's EXECUTE check.  The
#   entry check of plpgsql_jit runs the hook for every function of the
#   planned expressions, so a call that does not reach the function fails
#   where PL/pgSQL returns (T3, a stated difference).
#
# usage: pj_cmodule_pins.sh <pg bindir> <port> [opt level]
set -e
bin=$1 port=$2 opt=${3:-2}
here=$(dirname "$0")
cc=${CC:-cc}

case $(uname -s) in
Darwin) shlib="-bundle -undefined dynamic_lookup -isysroot $(xcrun --show-sdk-path 2>/dev/null)" ;;
Linux) shlib="-shared" ;;
*) echo "pj_cmodule_pins: skipped, no recipe to build a module on $(uname -s)"; exit 0 ;;
esac
command -v "$cc" >/dev/null 2>&1 ||
	{ echo "pj_cmodule_pins: skipped, no C compiler ($cc)"; exit 0; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for m in nout oat_deny; do
	$cc -fPIC -I"$("$bin/pg_config" --includedir-server)" $shlib \
		-o "$tmp/$m.so" "$here/$m.c" 2>"$tmp/cc.log" ||
		{ echo "pj_cmodule_pins: skipped, cannot build $m.c:"; cat "$tmp/cc.log"; exit 0; }
done

# $1 = extension to create, $2 = PGOPTIONS, $3 = the script
run() {
	"$bin/psql" -X -q -h /tmp -p "$port" -d postgres \
		-c "DROP DATABASE IF EXISTS pj_effect" -c "CREATE DATABASE pj_effect" 2>&1 |
		grep -v 'does not exist, skipping' || true
	PGOPTIONS="$2" "$bin/psql" -X -q -At -h /tmp -p "$port" -d pj_effect 2>&1 <<SQL | sed 's/^psql:[^ ]* //'
\\set SHOW_CONTEXT never
$1
$3
SQL
}

# $1 = language
raise_sql() {
	cat <<SQL
CREATE TYPE nint;
CREATE FUNCTION nint_in(cstring) RETURNS nint LANGUAGE internal IMMUTABLE STRICT AS 'int4in';
CREATE FUNCTION nint_out(nint) RETURNS cstring LANGUAGE c IMMUTABLE STRICT AS '$tmp/nout.so', 'nout';
CREATE TYPE nint (input = nint_in, output = nint_out, internallength = 4, passedbyvalue, alignment = int4);
CREATE FUNCTION d1(a nint, m int) RETURNS int LANGUAGE $1 AS \$\$
BEGIN
  RAISE EXCEPTION 'd1 % %', a, m + 1;
END \$\$;
SELECT d1('0', 1);
SELECT d1('0', 1);
SELECT d1('0', 1);
SELECT d1('1', 1);
SELECT d1('2', 1);
SQL
}

# $1 = language
t3_sql() {
	cat <<SQL
LOAD '$tmp/oat_deny.so';
CREATE FUNCTION t3_d(n int) RETURNS int LANGUAGE plpgsql STABLE AS \$\$
BEGIN RETURN n + 1; END \$\$;
CREATE FUNCTION t3(n int) RETURNS int LANGUAGE $1 STABLE AS \$\$
BEGIN
  IF n > 0 THEN RETURN n; END IF;
  RETURN t3_d(n);
END \$\$;
SELECT t3(0);
SELECT t3(0);
SELECT t3(1);
SET pj_oat.deny = 't3_d';
SELECT t3(1);
SELECT t3(0);
RESET pj_oat.deny;
SELECT t3(1);
SQL
}

jit="-c session_preload_libraries=plllvm -c plllvm.pj_opt_level=$opt"
rc=0

run "" "" "$(raise_sql plpgsql)" >"$tmp/stock"
run "CREATE EXTENSION plllvm;" "$jit" "$(raise_sql plpgsql_jit)" >"$tmp/jit"
if diff "$tmp/stock" "$tmp/jit"; then
	echo "pj_cmodule_pins raise: same as PL/pgSQL"
else
	echo "pj_cmodule_pins raise: differs from PL/pgSQL" >&2
	rc=1
fi

# after the SET, t3(1) does not reach t3_d, t3(0) does
cat >"$tmp/t3_stock.want" <<'WANT'
1
1
1
1
ERROR:  hook denies execution of function "t3_d"
1
WANT
cat >"$tmp/t3_jit.want" <<'WANT'
1
1
1
ERROR:  hook denies execution of function "t3_d"
ERROR:  hook denies execution of function "t3_d"
1
WANT
run "" "" "$(t3_sql plpgsql)" >"$tmp/t3_stock"
run "CREATE EXTENSION plllvm;" "$jit" "$(t3_sql plpgsql_jit)" >"$tmp/t3_jit"
if diff "$tmp/t3_stock.want" "$tmp/t3_stock" &&
	diff "$tmp/t3_jit.want" "$tmp/t3_jit"; then
	echo "pj_cmodule_pins t3: PL/pgSQL returns, plpgsql_jit raises, as stated"
else
	echo "pj_cmodule_pins t3: not as stated" >&2
	rc=1
fi

"$bin/psql" -X -q -h /tmp -p "$port" -d postgres -c "DROP DATABASE pj_effect"
exit $rc
