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

Two anomalies about a `Boxed` local whose owned reference count has
already reached zero, plus the leak check described in "The leak check"
below:

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
| `retpack` | constructors a struct-returning worker returns by value (rc2's `doc/struct-return.md`), no cell at all |
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

## The leak check

A second, independent walk (`Leak.idr`) keeps its own count of the
references each tracked local owns and checks, per path, that every
owned reference is **consumed exactly once** before the path ends.

| finding | meaning |
|---|---|
| `leak` | a path ended (return, tail call, ...) while a local still owned a reference; also a loop parameter not consumed before the next iteration |
| `reuse-token-leak` | a `reuseOffer` reservation that no `con ... reuse=` or `releaseReuse` consumed on some path |
| `branch-imbalance` | the arms of a `case`/`cmp` in value position (the value of a `let`) leave a local owning different numbers of references |
| `loop-imbalance` | a `continue` hands back a different number of references than the loop had at its top (a local from outside the loop consumed, or leaked, per iteration) |
| `over-consume` | a `case` field that owns nothing (borrowed from its scrutinee) is passed on or dropped without a `dup` |

A report line is `<def>: v<N> <finding> (<where>)`. Cases the walk
cannot decide are not findings but are counted in one extra line,
`leak check: N cases not decided (...)`: a `releaseReuse` without an
offer, a `con ... reuse=` without one, a `continue` outside a loop.

### What consumes a reference

Derived from `RC.annotate`, `Reuse.resolveAlt`, `DualABI.postDropFor` and
`Loop.applyLoop`; each row names what spends one reference of each
`Boxed` operand.

| node | consumes |
|---|---|
| function parameter, `let v : Boxed`, loop parameter | creates one reference |
| `dup v xN` | creates N |
| `drop [..]`, `free`, every `postDrop=` list, `prologueDrop`, `dropOnUnique` | one per listed occurrence |
| `call`, `partial`, `delay`, `apply` (callee too), `con`, `retpack`, `fill`'s value | every `Boxed` operand |
| `callRep` | operands at a `Boxed` parameter of its signature; the rest are read natively and dropped through `postDrop=` |
| `callFFIInline` | operands whose type `Compiler.RC2.Types.cfTypeNative` does not read natively (`%World`, `Ptr`, ...); the rest through `postDrop=` |
| `op`, `extprim`, `cmp`, `force`, `structGet`/`structSet`, `case` scrutinee | nothing (reads); `postDrop=` only |
| `let v = x` | `x`'s reference moves to `v` (a read when `v` is native) |
| bare value, as the function's result or as a `let` value | the returned local, when the destination is `Boxed` |
| `reuseOffer sc ...` | `sc`'s reference, becoming a reuse token; each `dupOnShared` field gains one |
| `con ... reuse=sc`, `releaseReuse sc` | the token |
| `loop initial=` / `continue` | arguments at `Boxed` parameters; the parameters then own one reference again |
| matching an erased alt (`nil`, `nothing`, `zero`, `unit`) | `sc` becomes NULL: whatever the IR still counts for it is dropped from the books |
| `crash` | a path that owes nothing |

`case` fields start owning nothing (as in the use-after-free check) and
become owned by a `dup`; the fields of a `RetN` struct scrutinee own
their `Boxed` fields outright.

### What the walk does not track

- **Native locals, immortal constants.** A local bound to a constant or
  to `[__]` is never tracked. A `Boxed` local that is shown to hold an
  always-unboxed value (`Char`, `Int8`..`Bits32`: an op/cmp operand at
  such a type or a `callRep` argument at such a `Native` parameter with
  no `postDrop=` entry, or a read into a `Native` local of such a type)
  is never tracked either: rc2 neither pairs nor omits `dup`/`drop` on it
  consistently, and at run time they are no-ops. A `case` on a `Char`
  literal is not used as evidence: the dump prints it like a one-character
  string.
- **State-padded loop parameters.** `MutualLoop` pads the parameters of
  the member that is not running with constants, so whether such a
  parameter owns a reference depends on the state tag, which the walk
  does not follow. A loop parameter that is passed a constant on entry or
  on some `continue` is not tracked.
- **Value-position joins.** The arms of a `case` in value position are
  compared by their total (the walk goes on once, not once per arm). Arms
  that only differ by a matched erased alt's scrutinee agree, because
  whether that scrutinee is dead afterwards is not visible from the arm.
- **Anything outside one definition.** A callee's own `postDrop=`
  annotation is trusted as written.

## What it deliberately does not check

- **Cross-branch consistency** in the use-after-free/double-drop walk:
  `cmp`/`case` fork the count map into each arm independently there and
  the arms are never merged afterwards (the leak check above does merge
  value-position arms).
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

`rcexpr-lint --borrow-stats <file.rcexpr>` prints the borrow statistics
and `rcexpr-lint --pushdown-stats <file.rcexpr>` the push-down statistics
instead of the anomaly report.

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

## Borrow statistics

`rcexpr-lint --borrow-stats` evaluates **borrow inference on the final IR**
(after `Reuse`, `Loop`, `Sink`, `DualABI`), where `dup`/`drop`, reuse and
loops are explicit. A `Boxed` parameter that carries a refcount (not native, not
shown to be an always-unboxed value) is *borrowable* when every
reference to it that the leak walk sees being spent (including the ones
`dup` created) is one of:

- a `drop`, a `postDrop=` entry (the callee would no longer own it), or
- an argument at a parameter position of a direct call (`call`, `callRep`)
  to a definition whose parameter is itself borrowable, **not** in tail
  position, or a `continue` that hands a loop parameter back unchanged
  (loop-invariant).

The fixpoint is the greatest one over the call graph, so a cycle of calls
that only pass the parameter along stays borrowable. A parameter is
rejected, with the first matching reason of: stored into a
constructor/closure/lazy cell; returned; reused (reuse token); passed to
an owned position (a callee parameter that is not borrowable);
passed to `apply`, an FFI call or a call to something that is not a
definition of the program; loop-carried (changes across iterations);
argument of a non-loop tail call. `more than one reason` counts the
rejected parameters with at least two of them.

Definitions referenced indirectly (`partial`, a lazy thunk, a
`#Name/n~closure` constant) are **not** excluded; the ones with a
borrowable parameter are counted as needing an owned-convention wrapper.

The effect is counted over places in the IR, for every borrowable parameter at once:

| figure | counts |
|---|---|
| callee drops removed | every `drop`/`postDrop=` entry on the parameter (and on locals that alias it) |
| callee dups removed | every `dup` of it (`dup v xN` is N) |
| caller dups removed | a call that passes a reference of a local that still owns more afterwards: the `dup` made for the call goes away |
| caller drops added | a call that passes the last reference of a local: it has to be dropped after the call (counted separately when the call was in tail position, which then stops being one) |
| net | the first three minus the last, as a share of all `dup`s (xN) plus all `drop`/`postDrop`/`prologueDrop`/`dropOnUnique` entries in the dump (`free` and `releaseReuse` excluded) |
| in loops | the same operations when they sit inside an `RLoop` body: a proxy for how often they run |

Arguments that come from a borrowable parameter of the caller itself cost
nothing either way (their `dup`s and `drop`s are already in the callee
column). A `dup` of a `case` field made to pass it on is reported
separately and **not** in the net: borrowing it needs the scrutinee kept
alive until the call, which `annotate` has usually dropped before.

Not verified: `%export` (not in the dump), calls through a closure whose
callee is only known at run time, and whether keeping a scrutinee alive
would defeat constructor reuse.

## Push-down statistics

`rcexpr-lint --pushdown-stats <file.rcexpr>` measures, on the **final IR**,
how many `dup`/`drop` operations are still not where a `case` arm that needs
them would put them. It is read-only and purely syntactic: every figure is
a count of **places in the IR**, not of executions, and "in loops" is the
same proxy `--borrow-stats` uses (the place sits inside an `RLoop` body).
"All dup/drop operations" is the `--borrow-stats` denominator: `dup xN`
counts N, plus every entry of `drop [..]`, `postDrop=`, `prologueDrop` and
`dropOnUnique` (not `free`, not `releaseReuse`). Every pattern is looked for
along the straight-line chain below its start node (through `dup`, `drop`,
`free`, `reuseOffer`, and past a `let` whose value does not mention the
local); a `case`, `cmp` or `loop` ends the chain.

An arm is classified per local over **every path** through it: the local is
*consumed* (passed to a `call`/`con`/`apply`/`partial`/..., returned, `let w
= v`, `continue` argument), only *read* (`op`/`cmp`/`structGet`/`force`
operands, a nested `dup`), and *dropped* a least-over-paths number of times
(`drop`, `postDrop=` entries). An arm that ends in `crash` is neutral.

| kind | what is counted | `ops` column | `extra` column |
|---|---|---|---|
| **A** | `dup v xN` whose chain reaches a `case`/`cmp` without mentioning `v` (the case's own scrutinee may be `v`), where **some arm neither consumes `v` nor, for a case field, reads it, and drops it** (min over paths) -- the dup is cancelled there. Sub-keys: `needed by no arm` (every live arm cancels: the dup is dead) or `some arm`; and `field: a drop sits between` when `v` is a `case` field (it borrows its parent) and a `drop` sits between the dup and the case: moving the dup into the arms then means moving that parent drop too, so it is not a local rewrite. The keys without it still include `case` fields whose parent is not dropped on the way; the parent's later liveness is not checked. When the case is on `v` itself, an arm that drops `v` and then reads an alt field that was not `dup`'d first is not counted as cancelling (the extra reference keeps that field alive) | static net: `N - N*(arms that need it) + sum(min(N, drops) over cancelling arms)`; negative when many arms need it, because the dup is then repeated | cancelling arms |
| **B** | `dup v xN` followed, on the straight line, by drops of `v` with no consumption of `v` in between (reads are passed; for a case field a read after another drop is not). `closed by a drop node` is what `DupMerge.cancelDupDrop` should already have removed; `closed by a postDrop on op/extprim/callRep` is `dup v; op f [v] postDrop=[v]` (the node kind is part of the key); `DupMerge.cancelRun` now removes those when the node only reads its operands, so what is left is an Integer/Int64/Double arithmetic `op` (its `postDrop` is ignored by `Emit`, the `dup` is real) or a call that consumes another operand. A `cmp` closing the pair is not counted (the scan stops at it) though `cancelRun` handles it | 2 x pairs | pairs |
| **C0** | `let v : Boxed` whose first mention on the straight-line chain is a `drop` naming it: dead, only its drop remains. `constant` values (immortal) and `fill` results (the TRMC hole protocol) are left out as by design. Not counted when the chain reaches a `case` first (that is C1/C2) | the drop (plus a pure value's leading `dup`s) | 1 |
| **C1** | `let v : Boxed` whose chain reaches a `case`/`cmp` (not on `v`), where `v` is mentioned only by drops, on **every** non-crash arm. Keyed by the value's kind | the arms' drops (plus the value's leading `dup`s when the value is a pure allocation, which could then vanish) | arms |
| **C2** | the same, but exactly one arm reads `v` and every other arm only drops it: a `Sink` candidate. Keyed by whether `Sink.sinkEligible` could take it (a fresh `con`, a non-lazy `op`, a `call`/`callRep`), whether the `let` is immediately followed by the branch (Sink does not look further), and whether a consumed, not-`dup`'d operand of the value is also mentioned by the branch (`Sink.addOperandDrops` gives up then) | the drops in the other arms | arms that drop |
| **D** | in an arm of a `case` on `p`, `dup f` of the alt's fields (all of them, `xN` counted) followed by a `drop` of the parent `p` with no other mention of `p` before it. Split by whether the arm builds a fresh `con` somewhere (a reuse that was not taken). Whether `p` is unique at run time is not in the IR | field dups (the ones a unique-parent shortcut or a borrow would remove; the parent drop does not go away, it turns into freeing the shell) | parent drops |
| **D0** | context for D: arms whose chain reaches `reuseOffer p ...`. They already have the unique-parent form (`dupOnShared`) | `dupOnShared` fields | arms |
| **E** | census: the entries of the `drop` nodes that open an arm of a `case`/`cmp`. This is the push-down that already works; the other kinds are leftovers. Reported both as a share of all dup/drop operations and, on its own line, of the drop-type entries alone | entries | -- |

The percentages are `ops` over all dup/drop operations, and `ops loop` over
the same total restricted to places in loops. **The kinds overlap and must
not be added**: A with `field: a drop sits between` and D describe the same
dups from two sides (field dups made right before the parent is dropped),
and a C2 `let` can carry dups that B or A also see.

What the figures do **not** show. They are static places. They do not
follow a local across a `let` value that is a `case` (an arm in value
position is analysed on its own, with the drops that follow the `let`
outside it), and a `postDrop=` on a call node that drops a *parent* is only
recognised by D when it sits on a leaf node. `A`'s cancelling arm may also
simply be one where the dup is needed later in the continuation; removing
the dup and the compensating drop is still count-neutral there, so the
static net is right, but the extra liveness is not checked. Whether
removing a given dup is *worth* it (a dup is an increment, an arm-local dup
costs the same) is not modelled. The `Sink` classification is a reading of
`rc2/doc/branch-sinking.md`, not a re-run of the pass.

Measured on idris2-lsp (`master` at `8558fb7`, 25.5k definitions, about 22 s
against 19 s for the plain lint, almost all of it parsing):

```
                                                    places  in loop     ops  %all
  all dup/drop operations                                            290924
  A  dup above a case, cancelled in some arm         12271    6496   19274  6.6%
       needed by no arm                                877     492    2582  0.8%
       needed by no arm, field + drop between         2944    1119    8400  2.8%
       needed by some arm                             1947     996    1876  0.6%
       needed by some arm, field + drop between       6503    3889    6416  2.2%
  B  dup ... postDrop of the same local               3361    1059    6722  2.3%
       on extprim 2416, on op 805, on callRep 140; none closed by a drop node
  C0 let dead on a straight line                      3166    2457    3190  1.0%   (alias 2567)
  C1 let dropped on every arm                            0       0       0
  C2 let read by one arm, dropped on the rest         1234     379    1313  0.4%   (3 with no visible obstacle)
  D  field dups, then the parent drop                19616    9056   30004 10.3%
  D0 same arm shape, parent reuseOffer'd             14259    5867   32831
  E  drops at the start of an arm                    46566   19147  150409 51.7%  (73.4% of all drop entries)
```

After `DupMerge.cancelRun` and the alias rename (`master` at `e874cd0`
plus that change; 281497 operations in all), the same dump gives B 227
places (`callRep` 80, `op` 147) and C0 614 places (alias 15).

D counts every field dup made before the parent is dropped (30004); the
`4342` that `--borrow-stats` reports as "dups of a case field passed
borrowed" on the same dump are only those whose field is then passed to a
call, so the two are not comparable.

## Building and testing

```sh
cd tools/rcexpr-lint/tests
./verify.sh
```

`verify.sh` builds the CLI and runs it over the hand-written fixtures,
checking both the exit code and the exact report text (the fixture's
`.expected` file), metrics included:

| fixture | covers |
|---|---|
| `clean.rcexpr` | a correct program produces no anomalies (guards against the check silently doing nothing) |
| `anomalies.rcexpr` | every anomaly/context combination fires: plain read after drop, double drop, a drop inside one `cmp` arm, and a `postDrop=`-consumed local read afterwards |
| `dupcount.rcexpr` | regression for a real parser bug -- `dup vN xM`'s repeat count was glued onto `x` as one token and silently undercounted if read as two |
| `fieldborrow.rcexpr` | field borrowing: a field read after its scrutinee is dropped (the exact shape of a real use-after-free in `refc-suite/clock`, 2026-09-25), a field of a field, and the correct forms -- dup before the drop, `reuseOffer` |
| `metrics.rcexpr` | every node kind the metrics count, so each figure is checked against a hand count at least once |
| `leakclean.rcexpr` | the balanced shapes the leak check has to accept: erased alts, always-unboxed locals, immortal lets, value-position joins, loops (invariant and padded), struct fields, reuse, FFI and `callRep` consumption |
| `leak.rcexpr` | one definition per leak-check finding |
| `borrow.rcexpr` | the borrow statistics, with hand-counted figures (run with `--borrow-stats`) |
| `pushdown.rcexpr` | the push-down statistics: one definition per pattern with its negative neighbours (a dup needed by every arm, a use before the case, a consumed operand, a sub-field read after the drop), hand-counted (run with `--pushdown-stats`) |

It builds with the plain Chez backend (`idris2 -p rc2base -p contrib`):
this tool only reads text files and never needs to run *through* rc2
itself. It needs `rc2base` already built and installed -- see
`libs/rc2base/README.md`.

## Layout

| file | |
|---|---|
| `RcexprLint.idr` | CLI: read, parse, report, set the exit code |
| `Lint.idr` | the use-after-free/double-drop check; its module note carries the rule list this README summarises |
| `Leak.idr` | the leak check, and the spend/`dup` events the borrow statistics are built from |
| `Borrow.idr` | the borrow statistics |
| `Pushdown.idr` | the push-down statistics |
| `Metrics.idr` | the static counts printed after the report |
| `tests/` | fixtures and `verify.sh` |

The `.rcexpr` grammar itself is **not** here: `Language.RCExpr.AST`,
`.Lexer` and `.Parser` live in `libs/rc2base/` as reusable library
modules, since other tools may want to read the same dumps. Only the
tool-specific logic lives in this directory.

This directory sits under `tools/`, not `rc2/`, because `rc2/` holds
the compiler backend and nothing else -- see `AGENT.md`'s "Layout".
