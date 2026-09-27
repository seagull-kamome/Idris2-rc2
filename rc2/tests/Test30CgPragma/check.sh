#!/usr/bin/env bash
# Post-compile check run by verify.sh (see its "Per-test checks"
# comment); by hand: ./TestN/check.sh build TestN
set -u
TMP="$1"
name="$2"
pass() { echo "PASS  $name ($1)"; }
fail() { echo "FAIL  $name ($1)"; }

# `%cg rc2 dumpdualabi` in the source is the ONLY thing that can
# produce this build's `.dualabi` dump -- verify.sh passes no
# `--directive dumpdualabi` on the CLI. Confirms Compiler.RC2.RC2's
# `getDirectives (Other "rc2")` wiring picks up source-level %cg rc2
# directives, not just CLI ones.
if [ -f "$TMP/${name}_rc2.dualabi" ]; then
    pass "source %cg rc2 dumpdualabi honored -- $TMP/${name}_rc2.dualabi produced with no CLI --directive dumpdualabi"
else
    fail "source %cg rc2 dumpdualabi NOT honored -- $TMP/${name}_rc2.dualabi missing"
fi
