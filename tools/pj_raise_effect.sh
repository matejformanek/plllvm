#!/bin/sh
# An output function that sends a message, in a RAISE whose later parameter is
# not planned yet: the output function must run once, as in PL/pgSQL, not
# again after a deopt.  Needs a C module, so it is not part of installcheck.
#
# usage: pj_raise_effect.sh <pg bindir> <port> [opt level]
set -e
bin=$1 port=$2 opt=${3:-2}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
here=$(dirname "$0")
cc -fPIC -I"$("$bin/pg_config" --includedir-server)" -bundle -undefined dynamic_lookup \
	-isysroot "$(xcrun --show-sdk-path)" -o "$tmp/nout.so" "$here/nout.c"

# $1 = language, $2 = extension to create, $3 = PGOPTIONS
run() {
	"$bin/psql" -X -q -h /tmp -p "$port" -d postgres \
		-c "DROP DATABASE IF EXISTS pj_effect" -c "CREATE DATABASE pj_effect"
	PGOPTIONS="$3" "$bin/psql" -X -q -h /tmp -p "$port" -d pj_effect 2>&1 <<SQL | sed 's/^psql:[^ ]* //'
\\set SHOW_CONTEXT never
$2
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

run plpgsql "" "" >"$tmp/stock"
run plpgsql_jit "CREATE EXTENSION plllvm;" \
	"-c session_preload_libraries=plllvm -c plllvm.pj_opt_level=$opt" >"$tmp/jit"
"$bin/psql" -X -q -h /tmp -p "$port" -d postgres -c "DROP DATABASE pj_effect"
diff "$tmp/stock" "$tmp/jit" && echo "pj_raise_effect: same as PL/pgSQL"
