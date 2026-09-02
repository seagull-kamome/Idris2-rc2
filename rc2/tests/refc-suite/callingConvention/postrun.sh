#!/usr/bin/env bash
# Greps this test's own generated C (build/exec/test.c, from run.sh's
# `--cg rc2 ... -o test` invocation) for the three shapes Main.idr's
# own header comment lists. run.sh appends this script's own stdout to
# the program's stdout before diffing against `expected`.
set -u
c=build/exec/test.c

if [ "$(grep -c 'idris2rc2_worker_Main_eligibleAdd' "$c")" -ge 1 ]; then
    echo "dualabi_worker_present: PASS"
else
    echo "dualabi_worker_present: FAIL"
fi

if [ "$(grep -c 'idris2rc2_worker_Main_ineligibleShow' "$c")" -eq 0 ]; then
    echo "dualabi_ineligible_no_worker: PASS"
else
    echo "dualabi_ineligible_no_worker: FAIL"
fi

if [ "$(grep -c 'idris2rc2_ffiworker_' "$c")" -eq 0 ]; then
    echo "ffi_no_worker_indirection: PASS"
else
    echo "ffi_no_worker_indirection: FAIL"
fi

if [ "$(grep -cE '\babs\(' "$c")" -ge 2 ]; then
    echo "ffi_inlined_at_call_site: PASS"
else
    echo "ffi_inlined_at_call_site: FAIL"
fi

if awk '/idris2rc2_worker_Main_sumLoop_0/{c++; if (c==2) p=1} p{print} p&&/^}/{exit}' "$c" | grep -q 'loop:;'; then
    echo "loop_goto_conversion: PASS"
else
    echo "loop_goto_conversion: FAIL"
fi
