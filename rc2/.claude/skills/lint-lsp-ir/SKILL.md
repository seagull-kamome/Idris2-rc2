---
name: lint-lsp-ir
description: Dump the RCExp IR of idris2-lsp with the current rc2 and run tools/rcexpr-lint over it (use-after-free, double-drop, leak check, static metrics). Use after changing any pass that inserts, moves or removes dup/drop (RC annotate, Reuse, Sink, DupMerge, DeadVars, LateInline, DualABI, PushDown), when the user asks to "lspのIRをlintにかけて", "lintを流して", re-measure the static counts, or wants a smoke test on a large external program.
---

# Lint idris2-lsp's IR

Paths are relative to the `idris2-rc-cg` repo root. Takes about 3 minutes
for the dump and under a minute for the lint; the dump needs up to 12 GB.

## 1. Check the binaries are current

`rc2/build/exec/idris2-rc2` and `tools/rcexpr-lint/build/exec/rcexpr-lint`
must be built from the working tree you want to test. A stale compiler
binary gives dumps of old code. If `rc2/src` or `tools/rcexpr-lint`
changed since the binaries, rebuild first (`idris2 --build rc2.ipkg` in
`rc2/`, `idris2 --build` in `tools/rcexpr-lint/`, after `source env.sh`).

## 2. Dump in a scratch copy

Do not build in the shared `install/idris2-lsp`: its `build/` is shared
with other jobs. Copy the sources, leaving `build/` behind:

```sh
REPO=$PWD
W=$REPO/../tmp/lsplint           # ~/projects/tmp/lsplint; never /tmp
mkdir -p "$W" && rsync -a --exclude=build install/idris2-lsp/ "$W/lsp/"
source env.sh && export TMPDIR="$W"
cd "$W/lsp"
( ulimit -v 12000000
  timeout 900 "$REPO/rc2/build/exec/idris2-rc2" --cg rc2 \
      --directive dumprcexpr --build idris2-lsp.ipkg > "$W/dump.log" 2>&1
  echo "exit $?" >> "$W/dump.log" )
```

- **`exit 1` is expected.** The build stops after the dump with
  `INTERNAL ERROR: [rc2] FFI not found for
  Libraries_Utils_Scheme_unsafeVectorToList` (a known upstream gap, not
  a regression). What matters is that `build/exec/idris2-lsp.rcexpr`
  (about 44 MB, about 660,000 lines) exists. Any *other* error in
  `dump.log` is a real failure.
- Start it with `run_in_background` and wait on the completion notice or
  the PID. Never `pgrep -f` / `pkill -f`.

## 3. Lint

```sh
( ulimit -v 12000000
  timeout 600 "$REPO/tools/rcexpr-lint/build/exec/rcexpr-lint" \
      build/exec/idris2-lsp.rcexpr > "$W/lint.out" 2>&1
  echo "exit $?" >> "$W/lint.out" )
```

Exit 0 means no anomalies; 1 means at least one `use-after-free` or
`double-drop` (one report line per anomaly, `<def>: v<N> <anomaly>
(<context>)`). The first lines are the verdict, the `leak check` line and
the static metrics (`tools/rcexpr-lint/README.md`, "Metrics").

## 4. Report

State: the commit (`git rev-parse --short HEAD`, and whether the tree is
dirty), the definition count, the anomaly count (list each anomaly line),
the `leak check` line, and the metrics that the change was meant to move
(`dup`, `drop`, `reuseOffer`, `con` reusing a cell, `retpack`, ...). For a
before/after comparison, run the same steps on the other tree and give
both columns. Reference values: 17,549 definitions, no anomalies, 2,069
leak-check cases not decided, `dup` 78,462 and `drop` 159,243
(2026-10-13).

## 5. Clean up

`cd` back into the repo, then remove `$W` (`rm -rf` on a directory you are
standing in is refused). Keep the dump instead if the user wants to
analyse it, and say where it is.
