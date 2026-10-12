#!/usr/bin/env bash
# Builds and installs idris2-curl (`curl`, and the rc2-only `curl-rc2`),
# then compiles every tests/src/*.idr program on Chez and rc2, runs it
# and diffs its output against tests/expected/<name>.out. Artifacts
# stay under tests/build/
#
# Needs ../idris2-rc-cg built (its env.sh and rc2 binary); gcc/gmp/
# curl/python3 come from nix-shell. No outbound network: transfers use
# file:// and a python3 http.server bound to 127.0.0.1.
#
# One test by hand (from tests/, inside the same nix-shell):
#   idris2 -p curl --build-dir build/chez/work/TestUrl \
#     --output-dir build/chez/bin -o TestUrl src/TestUrl.idr
#   ./build/chez/bin/TestUrl
# (rc2: ../../idris2-rc-cg/rc2/build/exec/idris2-rc2 --cg rc2 ...)
set -u
cd "$(dirname "$0")"

if [ -z "${IDRIS2CURL_VERIFY_SHELL:-}" ]; then
  IDRIS2CURL_VERIFY_SHELL=1 exec nix-shell -p gcc gmp pkg-config curl python3 --run "$(pwd)/verify.sh"
fi

source ../../idris2-rc-cg/env.sh
RC2="$(pwd)/../../idris2-rc-cg/rc2/build/exec/idris2-rc2"
export IDRIS2_LDFLAGS="$(pkg-config --libs-only-L libcurl)"
export LD_LIBRARY_PATH="$(pkg-config --variable=libdir libcurl):${LD_LIBRARY_PATH:-}"

rm -rf build
mkdir -p build

if ! (cd .. && idris2 --install package.ipkg && idris2 --install curl-rc2.ipkg && idris2 --install webapi.ipkg) > build/install.log 2>&1; then
  cat build/install.log
  echo "FAIL: install"
  exit 1
fi

python3 -u -m http.server 0 --bind 127.0.0.1 --directory data > build/http.log 2>&1 &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null' EXIT
PORT=
for _ in $(seq 50); do
  PORT="$(sed -n 's/.* port \([0-9]*\) .*/\1/p' build/http.log)"
  [ -n "$PORT" ] && break
  sleep 0.1
done
[ -n "$PORT" ] || { cat build/http.log; echo "FAIL: http server"; exit 1; }

python3 -u data/mock_api.py > build/mock.log 2>&1 &
MOCK_PID=$!
trap 'kill $HTTP_PID $MOCK_PID 2>/dev/null' EXIT
MOCK=
for _ in $(seq 50); do
  MOCK="$(sed -n 's/^port \([0-9]*\)$/\1/p' build/mock.log)"
  [ -n "$MOCK" ] && break
  sleep 0.1
done
[ -n "$MOCK" ] || { cat build/mock.log; echo "FAIL: mock api server"; exit 1; }

DATA="$(pwd)/data/hello.txt"
TESTS=(
  "TestUrl"
  "TestVersion"
  "TestGetinfo $DATA"
  "TestMulti $DATA"
  "TestHttp http://127.0.0.1:$PORT/hello.txt"
  "TestCapture $DATA"
  "TestCaptureText $DATA"
  "TestFetch http://127.0.0.1:$PORT"
  "TestWebAPIPure"
  "TestWebAPIChat http://127.0.0.1:$MOCK"
  "TestWebAPILogin http://127.0.0.1:$MOCK"
)
# Data.TextBuffer is an rc2 runtime type; these also get curl-rc2.
RC2_ONLY=" TestCaptureText "
WEBAPI=" TestWebAPIPure TestWebAPIChat TestWebAPILogin "

compile() {
  local be="$1" name="$2"
  local pkgs=(-p curl)
  [[ "$RC2_ONLY" == *" $name "* ]] && pkgs+=(-p curl-rc2 -p rc2base)
  [[ "$WEBAPI" == *" $name "* ]] && pkgs+=(-p contrib -p network -p webapi)
  local opts=("${pkgs[@]}" --build-dir "build/$be/work/$name" --output-dir "build/$be/bin" -o "$name" "src/$name.idr")
  case "$be" in
    chez) idris2 "${opts[@]}" ;;
    rc2)  "$RC2" --cg rc2 "${opts[@]}" ;;
  esac
}

pass=0
fail=0
for t in "${TESTS[@]}"; do
  read -r name args <<< "$t"
  backends="chez rc2"
  [[ "$RC2_ONLY" == *" $name "* ]] && backends="rc2"
  for be in $backends; do
    out="build/$be/$name.out"
    # The exit status alone misses a failed C compile: idris2 exits 0
    # without an executable (idris2-rc-cg/KNOWN-BUGS.md).
    if ! compile "$be" "$name" > "build/$be-$name.compile.log" 2>&1 || [ ! -x "build/$be/bin/$name" ]; then
      echo "FAIL: $name ($be) compile, see build/$be-$name.compile.log"
      fail=$((fail + 1))
      continue
    fi
    # A src/<name>.sh drives a test that needs more than arguments.
    # shellcheck disable=SC2086
    if [ -x "src/$name.sh" ]; then
      "src/$name.sh" "build/$be/bin/$name" $args > "$out" 2>&1
    else
      "./build/$be/bin/$name" $args > "$out" 2>&1
    fi
    if diff -u "expected/$name.out" "$out" > "build/$be-$name.diff"; then
      echo "ok:   $name ($be)"
      pass=$((pass + 1))
    else
      echo "FAIL: $name ($be), see build/$be-$name.diff"
      fail=$((fail + 1))
    fi
  done
done

echo "== $pass passed, $fail failed =="
[ "$fail" -eq 0 ]
