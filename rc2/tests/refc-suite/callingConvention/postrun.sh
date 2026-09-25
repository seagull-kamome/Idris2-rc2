#!/usr/bin/env bash
# Prints the actual generated-C fragments this test exists to pin down
# (build/exec/test.c, from run.sh's `--cg rc2 ... -o test` invocation)
# verbatim, not a self-graded PASS/FAIL -- run.sh appends this script's
# own stdout to the program's stdout before diffing against `expected`,
# so any real change to these shapes shows up as an ordinary diff, the
# same way every other test in this suite pins its own output.
# Trailing `// <file>:<line>:<col>--...` source-location comments are
# stripped since they shift with unrelated line-number edits to
# Main.idr, not with a genuine shape change.
# Definitions are matched by their own header line (a prototype first,
# then the body), with the worker's numeric suffix as `[0-9]+`: the
# suffix is a counter that shifts whenever another worker is added.
set -u
c=build/exec/test.c
strip_loc() { sed -E 's#[[:space:]]+// [A-Za-z_.]+:[0-9]+:[0-9]+.*$##'; }
# C locals are numbered from rc2's whole-program id counter, so any pass
# that mints ids shifts them. Renumbered here in order of first
# appearance: which names coincide is kept, the counter values aren't.
# A worker's own numeric suffix is the same kind of counter.
renumber() {
    sed -E 's/(idris2rc2_worker_Main_[A-Za-z]+)_[0-9]+/\1_N/g' |
    awk '{ out = ""; s = $0
           while (match(s, /var_[0-9]+/)) {
               v = substr(s, RSTART, RLENGTH)
               if (!(v in m)) m[v] = "var_" (++n)
               out = out substr(s, 1, RSTART - 1) m[v]; s = substr(s, RSTART + RLENGTH)
           }
           print out s }'
}

{

echo "--- DualABI worker for eligibleAdd (native return, rc2/doc/dual-abi.md) ---"
awk '/^int64_t idris2rc2_worker_Main_eligibleAdd_[0-9]+$/{p=1} p{print} p&&/^\);$/{exit}' "$c"

echo "--- DualABI worker count for ineligibleShow (want: none) ---"
grep -c 'idris2rc2_worker_Main_ineligibleShow' "$c"

echo "--- FFI worker-indirection count (want: none, inline splicing only) ---"
grep -c 'idris2rc2_ffiworker_' "$c"

echo "--- FFI call-site shape (wrapper body + inlined non-tail call site + tailAbs's own inlined tail call) ---"
grep -E '\babs\(' "$c" | strip_loc

echo "--- Compiler.RC2.Loop goto conversion for sumLoop's own worker body ---"
awk '/^int64_t idris2rc2_worker_Main_sumLoop_[0-9]+$/{n++; if (n==2) p=1} p{print} p&&/^}/{exit}' "$c" | strip_loc

echo "--- Tail-position FFI call for tailAbs (want: inlined call + immediate return, no closure defer, rc2/doc/dual-abi.md Stage 4b) ---"
awk '/^IDRIS2RC2_Value \*Main_tailAbs$/{n++; if (n==2) p=1} p{print} p&&/^}/{exit}' "$c" | strip_loc
} | renumber
