# rcexpr-lint

A static reference-counting checker over the `RCExp` IR that rc2 dumps
with `--directive dumprcexpr`.

It re-derives every definition's ownership counts from the dump and
reports the places where rc2's own passes have produced an
inconsistent program -- **before** that becomes a crash, a leak, or
silent corruption in the generated C.

```
$ rcexpr-lint build/exec/prog.rcexpr
build/exec/prog.rcexpr: Main.render: v42 use-after-free (op args)
build/exec/prog.rcexpr: Main.render: v42 double-drop (drop)
rcexpr-lint: 2 anomalies found
```

Exit code `0` with no anomalies, `1` otherwise (and also `1` if the
file can't be read or parsed), so it drops straight into a script.
The static metrics described under "Metrics" follow the report.

## Why it exists

`Compiler.RC2.Sink` shipped this exact bug class three separate times,
from three unrelated root causes, and each one was found by hours of
reading IR dumps by hand. The other two safety nets both miss it:

- **An output diff misses it entirely.** Dropping a reference one time
  too many changes nothing a program prints -- until the allocator
  hands that block to something else.
- **Valgrind only catches it by luck.** It needs a test that actually
  triggers the path *and* a freed block that actually gets reused
  before the read. rc2's own immortality convention
  (`IDRIS2RC2_REFCOUNT_MAX`) hides some of these outright.

This check needs neither. It reads the IR of any program that
compiles, so a single run over a large external package (idris2-lsp:
~26,000 definitions) exercises far more shapes than the smoke-test
suite ever will.

## What it checks

Two anomalies, both about a `Boxed` local whose owned reference count
has already reached zero:

| anomaly | meaning |
|---|---|
| `use-after-free` | the local is **read** again after its count reached zero |
| `double-drop` | the local is **dropped** again when its count is already zero |

A report line is `<def>: v<N> <anomaly> (<context>)`, where the context
names the node that did it -- `RV`, `drop`, `free`, `releaseReuse`,
`call`, `apply target`, `apply args`, `op args`, `op postDrop`, `con
args`, `con reuse`, `cmp args`, `case scrutinee`, `loop initial`,
`continue loop args`, `reuseOffer dupOnShared`, and so on. The context
is what tells you *which* of several reads on one line was the
offending one.

### How the count is derived

- Each definition starts from its own `args=[...]`: every `Boxed`
  parameter gets a live count of 1. A non-`Boxed` (native) local is
  never tracked at all -- it has no refcount to get wrong.
- `let v : Boxed = ...` introduces `v` with a count of 1.
- `dup v` adds 1; `dup v xN` adds N.
- `drop [...]`, `free`, `releaseReuse`, `reuseOffer`'s own
  `dropOnUnique`, and **every** `postDrop=` list each subtract 1.
- A field bound by a `case` alt owns **nothing** at first: it borrows
  its scrutinee's reference, and is readable only while the scrutinee
  (or, for a field of a field, any ancestor) is still alive, or after a
  `dup` has given it its own. This is the rule rc2's `annotate` and
  `Reuse` work to: a field still needed after its scrutinee is dropped
  must be `dup`'d first. `reuseOffer`'s `dupOnShared` fields each end up
  owning one reference; its `dropOnUnique` fields none.
- Any read of a tracked local with no reference to read through is a
  use-after-free; any subtraction from a local that owns none is a
  double-drop (for a field, releasing a reference only its scrutinee
  holds).
- A local absent from the map is untracked, never treated as zero --
  so an unknown local is silently skipped rather than falsely flagged.

## Metrics

After the anomaly report (or the "no anomalies found" line), every run
prints static counts over the whole dump. The run is idris2-lsp at
commit `5bddcb2`:

```
metrics (places in the IR, not executions):
  definitions    25556  (functions 23337, workers 561, constructors 1559, foreign 99, error 0)
  con            58973  (fresh 38257, reusing a cell 20716)
  partial        15788  (closures built)
  apply          10039  (closure calls)
  call           57237  (plain 54228, callRep 2948, FFI inline 61)
  op             11230  (op 9108, extprim 2122)
  let           114494  (Boxed 110981, native 3513)
  case           48159  (constructor 42151, constant 5544, cmp 464)
  dup           105738  (increments, in 92136 dup nodes)
  drop          201119  (decrements, in 75857 drop nodes)
  postDrop       16422  (decrements attached to another node: postDrop, dropOnUnique, prologueDrop)
  free             255
  reuseOffer     27628  (releaseReuse 10059)
  loop            2445  (continue 4128)
  memoize          426
  crash             78
```

Every figure counts **places in the IR**, not how often they run: a
`con` inside a loop body counts once. So they answer "did this pass
remove or add code of this kind", not "does the program allocate
less". Compare two dumps of the same program, typically with and
without one pass (`--directive no<stage>`, see
`rc2/doc/directives.md`); for run-time counts, run the program under
valgrind.

| figure | counts |
|---|---|
| `definitions` | every `def`, by kind; `workers` are DualABI's `worker=True` functions |
| `con` | constructor builds; `reusing a cell` has `reuse=`, `fresh` allocates |
| `partial` / `apply` | closures built, closures applied |
| `call` | direct calls: `call`, DualABI's `callRep`, inlined FFI calls |
| `op` | primitive operations and `extprim` calls |
| `let` | bindings, by representation |
| `case` | branches: on a constructor, on a constant, fused comparisons (`cmp`) |
| `dup` | reference-count increments (`dup v x3` counts 3), and the nodes holding them |
| `drop` | decrements in `drop [...]` nodes, and the nodes |
| `postDrop` | decrements riding on another node instead of a `drop` |
| `free`, `reuseOffer`, `releaseReuse` | unconditional frees and the reuse protocol |
| `loop`, `continue` | converted loops and their back edges |
| `memoize`, `crash` | memoized CAF bodies, `crash` nodes |

## What it deliberately does not check

- **Leaks.** A count left above zero at the end of a definition is not
  reported. Doing that properly needs full path enumeration and merging
  across branches, which this tool does not attempt.
- **Cross-branch consistency.** `cmp`/`case` fork the count map into
  each arm independently and the arms are never merged afterwards.
  That is correct for what this *does* check -- an anomaly inside one
  arm does not depend on what the other arm did -- but it means "these
  two arms leave `v` in different states" goes unreported.
- **Anything outside one definition.** There is no interprocedural
  reasoning; a callee's own `postDrop=` annotation is trusted as
  written.

## Known imprecision: a false positive is possible

A `case`-alt's own bound variables carry **no `Rep` in the dump** --
`Compiler.RC2.Pretty` never prints one, because
`Compiler.RC2.RCExp.RConAlt` does not carry one either (the field's
real type lives in the constructor's type information, which is not
part of this grammar).

They are therefore tracked as `Boxed` fields borrowing from their
scrutinee, which is the common case for a normalized RC tree. A
genuinely *native* field read after its scrutinee is dropped can
consequently be reported (none is, on idris2-lsp). That trade was deliberate: an occasional
false positive is easy to notice and dismiss by hand, whereas silently
skipping those fields would hide real bugs in exactly the
destructure-then-consume shapes `Reuse` and `ConAltNative` rewrite most
heavily.

If a report looks wrong, check whether the named variable is a
constructor field, and whether its type is a native scalar.

A loop's own parameters are *not* affected -- those do carry a `Rep` in
the dump, so a native one is correctly left untracked. They share only
the assumed initial count of 1, which is right for a local rebound on
every iteration.

## Usage

```sh
source env.sh

# Compile anything with the dump directive
rc2/build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr Prog.idr -o prog
tools/rcexpr-lint/build/exec/rcexpr-lint build/exec/prog.rcexpr
```

The dump lands next to the produced executable, as
`<output>.rcexpr`. See `rc2/doc/reading-the-ir.md` for how to read the
format by hand, and `rc2/doc/directives.md` for `dumprcexpr` itself.

A whole external package works the same way and is the more valuable
run -- it covers shapes no hand-written test does:

```sh
cd install/idris2-lsp
"$REPO/rc2/build/exec/idris2-rc2" --cg rc2 --directive dumprcexpr --build idris2-lsp.ipkg
"$REPO/tools/rcexpr-lint/build/exec/rcexpr-lint" build/exec/idris2-lsp.rcexpr
```

**Run this after changing any pass that inserts, moves or removes
`dup`/`drop`** -- `RC`'s own annotation, `Reuse`, `Sink`, `DupMerge`,
`DeadVars`, `LateInline`, `DualABI`.

## Building and testing

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

`verify.sh` builds the CLI and runs it over five hand-written fixtures,
checking both the exit code and the exact report text, metrics
included:

| fixture | covers |
|---|---|
| `clean.rcexpr` | a correct program produces no anomalies (guards against the check silently doing nothing) |
| `anomalies.rcexpr` | every anomaly/context combination fires: plain read after drop, double drop, a drop inside one `cmp` arm, and a `postDrop=`-consumed local read afterwards |
| `dupcount.rcexpr` | regression for a real parser bug -- `dup vN xM`'s repeat count was glued onto `x` as one token and silently undercounted if read as two |
| `fieldborrow.rcexpr` | field borrowing: a field read after its scrutinee is dropped (the exact shape of a real use-after-free in `refc-suite/clock`, 2026-09-25), a field of a field, and the correct forms -- dup before the drop, `reuseOffer` |
| `metrics.rcexpr` | every node kind the metrics count, so each figure is checked against a hand count at least once |

It builds with the plain Chez backend (`idris2 -p rc2base -p contrib`):
this tool only reads text files and never needs to run *through* rc2
itself. It needs `rc2base` already built and installed -- see
`libs/rc2base/README.md`.

## Layout

| file | |
|---|---|
| `RcexprLint.idr` | CLI: read, parse, report, set the exit code |
| `Lint.idr` | the check itself; its module note carries the rule list this README summarises |
| `Metrics.idr` | the static counts printed after the report |
| `tests/` | fixtures and `verify.sh` |

The `.rcexpr` grammar itself is **not** here: `Language.RCExpr.AST`,
`.Lexer` and `.Parser` live in `libs/rc2base/` as reusable library
modules, since other tools may want to read the same dumps. Only the
tool-specific logic lives in this directory.

This directory sits under `tools/`, not `rc2/`, because `rc2/` holds
the compiler backend and nothing else -- see `AGENT.md`'s "Layout".
