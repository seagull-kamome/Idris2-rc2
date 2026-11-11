#!/usr/bin/env bash
# Libraries (--directive staticlib/sharedlib, rc2/doc/library-output.md): builds AddLib.idr
# and Add2Lib.idr (the same definitions under other names) as static and as shared libraries and
# uses them from C hosts and from an rc2 host. Prints PASS/FAIL lines, like pool/run.sh.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RC2_DIR="$(cd "$HERE/../.." && pwd)"
REPO="$(cd "$RC2_DIR/.." && pwd)"
RC2="$RC2_DIR/build/exec/idris2-rc2"
OUT="${LIBRARY_TEST_OUT:-$RC2_DIR/tests/build/library}"
source "$REPO/env.sh"
RT="$(idris2 --libdir)/support/rc2"
rm -rf "$OUT" && mkdir -p "$OUT"
status=0
pass() { echo "PASS  library ($1)"; }
fail() { echo "FAIL  library ($1)"; status=1; }
check() { # check <what> <expected file> <actual file>
  if diff -u "$2" "$3" > "$OUT/diff.txt"; then pass "$1"; else fail "$1: see $OUT/diff.txt"; head -n 10 "$OUT/diff.txt"; fi
}

for kind in static shared; do
  for pair in "addlib AddLib" "add2lib Add2Lib"; do
    set -- $pair
    # the output goes to build/exec under the directory idris2-rc2 runs in
    ( cd "$OUT" && mkdir -p "$kind" && cd "$kind" && cp "$HERE/$2.idr" . && "$RC2" --cg rc2 --directive "${kind}lib" -o "$1" "$2.idr" > "$1.log" 2>&1 )
    ext=a; [ "$kind" = shared ] && ext=so
    if [ -f "$OUT/$kind/build/exec/lib$1.$ext" ]; then pass "$kind library $1 built"; else fail "$kind library $1 not built, see $OUT/$kind/$1.log"; continue; fi
    # only the exported functions are visible: everything else is static
    nm -g --defined-only "$OUT/$kind/build/exec/lib$1.$ext" | awk '$2 ~ /^[TDBR]$/ {print $3}' | sort > "$OUT/$kind/$1.syms"
    case $1 in addlib) printf 'libadd_two\nlibgreet\nlibtotal\n' ;; *) printf 'lib2_add_two\nlib2_greet\nlib2_total\n' ;; esac | sort > "$OUT/$kind/$1.want"
    check "$kind library $1 exports only its %export functions" "$OUT/$kind/$1.want" "$OUT/$kind/$1.syms"
  done
done

cat > "$OUT/host.want" <<'WANT'
42 3
hello, world / hi, world
12345678901000001
WANT

# the static libraries into one C program: the same internal names in both, no clash
S="$OUT/static/build/exec"
if gcc -I"$RT" -I"$S" "$HERE/host.c" "$S/libaddlib.a" "$S/libadd2lib.a" $(cat "$S/addlib.link") -o "$OUT/host_static" 2> "$OUT/host_static.log"; then
  "$OUT/host_static" > "$OUT/host_static.out" 2>&1; check "static libraries in a C host" "$OUT/host.want" "$OUT/host_static.out"
else fail "static libraries: link, see $OUT/host_static.log"; fi

# the shared libraries, the runtime shared as well
H="$OUT/shared/build/exec"
if gcc -I"$RT" -I"$H" "$HERE/host.c" -L"$H" -laddlib -ladd2lib $(cat "$H/addlib.link") -Wl,-rpath,"$H" -o "$OUT/host_shared" 2> "$OUT/host_shared.log"; then
  "$OUT/host_shared" > "$OUT/host_shared.out" 2>&1; check "shared libraries in a C host" "$OUT/host.want" "$OUT/host_shared.out"
else fail "shared libraries: link, see $OUT/host_shared.log"; fi

# a host that loads a library when it runs
printf '3\n' > "$OUT/dl.want"
if gcc -I"$RT" "$HERE/dl.c" $(cat "$H/addlib.link") -ldl -o "$OUT/host_dl" 2> "$OUT/host_dl.log"; then
  "$OUT/host_dl" "$H/libaddlib.so" > "$OUT/host_dl.out" 2>&1; check "a library loaded with dlopen" "$OUT/dl.want" "$OUT/host_dl.out"
else fail "dlopen host: link, see $OUT/host_dl.log"; fi

# an rc2 program as the host, with one runtime for it and for both libraries
mkdir -p "$OUT/rc2host" && cp "$HERE/Host.idr" "$OUT/rc2host/"
if ( cd "$OUT/rc2host" && IDRIS2_CFLAGS="-I$H" IDRIS2_LDFLAGS="-L$H -Wl,-rpath,$H" "$RC2" --cg rc2 --directive sharedruntime -o host Host.idr > build.log 2>&1 ); then
  "$OUT/rc2host/build/exec/host" > "$OUT/rc2host.out" 2>&1; printf '(3, 30)\n' > "$OUT/rc2host.want"
  check "an rc2 program using two shared libraries" "$OUT/rc2host.want" "$OUT/rc2host.out"
  if ldd "$OUT/rc2host/build/exec/host" | grep -q "libidris2rc2.so"; then pass "the rc2 host links the shared runtime"; else fail "the rc2 host does not use libidris2rc2.so"; fi
else fail "rc2 host: build, see $OUT/rc2host/build.log"; fi
exit $status
