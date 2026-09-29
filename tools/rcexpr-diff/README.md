# rcexpr-diff

Compares two IR dumps (`--directive dumprcexpr`) definition by
definition.

rc2 numbers variables from one counter for the whole program, so one
changed node shifts every id after it, and a byte diff of two dumps
shows the whole file. This tool checks whether a change to rc2 did only
what it was meant to: which definitions changed, and how.

```
$ rcexpr-diff before.rcexpr after.rcexpr
rcexpr-diff: 19019 same, 126 differ, 2 only in A, 2 only in B
differ: Compiler.CaseOpts.caseOfCase
...
only in A: ...
only in B: ...
```

Exit code `0` when nothing differs, `1` when something does, `2` on a
usage or read error.

## What counts as the same

Before comparing, each definition is normalized:

- **Variables** are renamed `v0`, `v1`, ... in order of first
  appearance within the definition.
- **Names rc2 generates** (`{rc2_...:N}`, `{idris2rc2_...:N}`: clones,
  workers, raised functions) lose their counters, the `:N` and a
  trailing `_N` in the name, so `{rc2_specClosure_Main_map_12:40}` and
  `{rc2_specClosure_Main_map_15:41}` are both
  `{rc2_specClosure_Main_map:*}`. Definitions whose names normalize
  alike are paired in the order they appear; the second is shown as
  `#2`, and so on.
- With `--loose`, every other `{name:N}` loses its `:N` too: lifted
  lambdas (`Main.{f:3}`) renumbered by a change before lambda lifting.

`--show K` prints, for the first `K` differing definitions, the lines
between their common prefix and suffix (at most 40 of each side).

## Usage

```sh
tools/rcexpr-diff/build/exec/rcexpr-diff [--loose] [--show K] A.rcexpr B.rcexpr
```

For the smoke tests, `rc2/tests/snapshot.sh` keeps a copy of every
dump and C file to compare after a change; when its byte comparison
reports a dump, this tool says what changed in it. For idris2-lsp, two
dumps of about 45 MB take about 20 s.

## Building and testing

```sh
cd tools/rcexpr-diff/tests
./verify.sh
```

`verify.sh` builds the tool with the plain Chez backend (it reads text
files only, no dependency beyond `base`) and checks its report and exit
code on `a.rcexpr`/`b.rcexpr`, which differ in each way above.
