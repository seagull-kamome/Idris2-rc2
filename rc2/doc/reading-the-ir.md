# Reading rc2's IR: the `--directive dumprcexpr` dump and `RCExp` syntax

A practical reference for dumping and reading rc2's own reference-counted
IR (`Compiler.RC2.RCExp`) -- the tree `Compiler.RC2.Emit` lowers directly
to C. Useful whenever you need to answer "what did rc2 actually decide
here" without reading generated C or re-deriving it from the source
Idris. Companion to `doc/reuse-analysis.md`/`doc/native-type-inference.md`
(those explain *why* specific passes decide what they decide; this
document is about *reading the result* of all of them at once, plus the
tool that shows it to you).

## 1. Dumping the IR

```sh
cd rc2 && source ../env.sh
nix-shell -p gcc gmp pkg-config --run \
  './build/exec/idris2-rc2 --cg rc2 --directive dumprcexpr YourFile.idr -o out'
```

This writes `out.rcexpr` next to the generated `out.c`, in whatever
directory `-o` resolves to (`build/exec/` under the working directory
you invoke `idris2-rc2` from, same as the `.c`/executable). `--directive`
is upstream Idris2's own generic per-invocation string passthrough (the
same mechanism Chez/ES's own directives use) -- no idris2-src changes
were needed to wire this up, see `Compiler.RC2.RC2`'s `compileExpr`.

Combine with any other `idris2-rc2` flags freely (`-p`, `--cg rc2` itself,
etc.). Nothing about the dump changes what gets compiled or how the
program behaves -- it's a pure side effect, `prettyProgram defs` written
to a file, with `defs` being the exact same value `generateCSourceFile`
is about to consume.

**What state of the pipeline you're looking at**: the dump fires *after*
every non-disabled `toRCDefs` stage has run -- it's the exact `defs`
`generateCSourceFile` is about to consume:

```
Lifted (Compiler.LambdaLift)
  -> Compiler.RC2.Inline          (whole-program inlining, Lifted -> Lifted)
  -> Compiler.RC2.RC.normalize    (Phase 1: ANF-style, native type inference)
  -> Compiler.RC2.RC.annotate     (Phase 2: ownership -- RDup/RDrop/RFree)
  -> Compiler.RC2.Reuse           (constructor-reuse-in-place)
  -> Compiler.RC2.ConAltNative    (native-shadow field caching)
  -> Compiler.RC2.MutualLoop      (mutual tail recursion -> merged function)
  -> Compiler.RC2.Loop            (self-tail-call -> RLoop/RLoopContinue)
  -> Compiler.RC2.DualABI         (worker/wrapper synthesis, call-site rewrite)
  -> [ .rcexpr dumped here ]
  -> Compiler.RC2.Emit            (purely mechanical RCExp -> C)
```

-- so what you see is *exactly* what `Emit.idr` consumes: every
ownership decision, every reuse offer, every loop conversion, and every
dual-ABI worker/wrapper rewrite already baked in. There is currently no
hook to dump an *earlier* stage (e.g.
right after Phase 1, before ownership is decided); if you need that,
you'd add a similar `writeFile` call at the point you care about, same
pattern as `compileExpr`'s own.

**One file, whole program**: the dump contains one `def` block per
top-level name `Compiler.RC2.RC2.toRCDefs` produced -- not just
definitions from your own module, but every transitively-reachable
`Prelude`/library function too (`Prelude.EqOrd.==`, `Prelude.Show.show`,
...). This is often exactly what you want (e.g. to see how `Int`'s `==`
instance itself compiles), but means the file can be large; `grep -n
"^def "` first to find the definition you actually care about.

**Caveats**: purely a debugging aid. Never read back by the compiler
itself (unlike `.ttc`), and not guaranteed stable across rc2 versions --
formatting choices favour readability over completeness (see
`Compiler.RC2.Pretty`'s own module note: source spans are dropped
entirely, and every constructor gets a short keyword rather than its
real Idris constructor name -- the mapping is the whole point of
section 3 below). `.rcexpr` files are build artifacts (same directory as
generated `.c`), not committed; regenerate whenever you need one.

## 2. The shape of a dump

One block per definition, in `toRCDefs`'s own order:

```
def <Name>  (<kind> ...)
  <body, indented>

def <Name>  (<kind> ...)
  ...
```

Four `<kind>`s, one per `RCDef` constructor:

| Header | `RCDef` | Meaning |
|---|---|---|
| `(fun args=[v0, v1])` | `MkRCFun` | An ordinary function; body follows, indented one level. |
| `(con tag=Just 1 arity=2 newtype=Nothing)` | `MkRCCon` | A data constructor's own metadata (no body -- constructors aren't executed, just described for callers building/matching them). `tag=Nothing` means an untagged/single-constructor type; `newtype=Just k` means field `k` is the runtime representation and the constructor itself erases away. |
| `(foreign ["scheme:...", "C:foo,libfoo"] [CFInt, CFString] -> CFIORes CFUnit)` | `MkRCForeign` | An FFI declaration: the calling-convention strings tried in order, argument `CFType`s, return `CFType`. |
| `(error)` | `MkRCError` | A definition that failed to compile in a way Idris2 defers to runtime (rare); body is the crash expression. |

Only `(fun ...)`/`(error)` have a body to read further; the rest of this
document is about that body.

## 3. Values (`RCLocal`)

Every place a value is *read* (an operand, an argument, a scrutinee)
renders as one of four forms -- this is `Show RCLocal` in `RCExp.idr`,
and it's worth memorizing since it's everywhere:

| Syntax | Constructor | Meaning |
|---|---|---|
| `v0`, `v1`, `v42`, ... | `RCLoc n` | An ordinary local: a function parameter or something bound by a `let`/pattern match/loop param, identified by a compiler-allocated integer. **IDs are not stable across passes or across a definition's own args vs. body** -- a loop's native shadow gets a *fresh* id distinct from the original parameter's own (see section 8); don't read anything into the specific numbers beyond "same number = same value here." |
| `[__]` | `RCNull` | A literal C `NULL`. Three distinct sources: an erased-nullary-constructor value (`Nil`/`Nothing`/`Z`/`MkUnit` -- these need no heap allocation at all, matched by NULL-vs-non-NULL); the `%World` token threaded through IO-primitive calls (`extprim ... [[__], ...]`); or `Compiler.RC2.MutualLoop`'s own arity-padding for a smaller-arity group member's unused trailing slot. |
| `#0`, `#"hello"`, `#'x'`, ... | `RCConst c` | A native-eligible-or-cheap literal inlined directly, no `var_N`, no let-binding, no dup/drop -- see `doc/native-type-inference.md`'s "`RCLocal.RCConst`" section for exactly which constants qualify. |
| `#Main.NoShape@1`, `#Prelude.Show.Open@0`, ... | `RCEmptyCon n ci tag` | A zero-argument *tagged* data constructor other than the four `RCNull` ones above (e.g. `f Red` for a multi-constructor enum) -- `Name@tag`, inlined as a tagged-pointer constant, no allocation. |

## 4. Representation (`Rep`)

Shown on every `let`-binding and every `loop`'s own param list:

| Syntax | Meaning |
|---|---|
| `Boxed` | An ordinary heap-allocated-or-tagged-pointer `IDRIS2RC2_Value*`, reference-counted normally. |
| `Native <PrimType>` | A raw C scalar (`int64_t`, `double`, `uint8_t`, ...) living on the stack -- no heap allocation, no refcounting, ever, for this local. `<PrimType>` is Idris2's own type (`IntType`, `Int64Type`, `Bits8Type`, `DoubleType`, `CharType`, ...). |
| `InlineNative <PrimType>` | Like `Native`, but additionally never gets a C variable declared at all -- its computed expression is spliced directly into its one and only use site. A refinement Phase 2 promotes a plain `Native` into once it knows the local has zero Boxed operands of its own and exactly one use; you'll see the *value* it's Native-bound to, but no `let vN` line for it anywhere (it doesn't get one). |

## 5. Full expression syntax reference

Every `RCExp` constructor, in the terse keyword `Compiler.RC2.Pretty`
renders it as. `~<reason>` is an optional prefix meaning "lazy, under
this Idris `LazyReason`" (`~Rec`, `~Force`, ...) -- present on calls/ops
Idris2 marked lazy; most lines never show it.

| Syntax | `RCExp` | Meaning |
|---|---|---|
| `v0` (bare, no keyword) | `RV` | This expression's value *is* local `v0`, read as-is. Appears as a branch's own trailing value (e.g. `sumTo`'s base case, section 8) as often as inline. |
| `~r call Name [v0, v1]` | `RAppName` | Call `Name` with these arguments. In tail position with no `~`, this is what `Compiler.RC2.Emit`'s closure-building logic intercepts; elsewhere it's an ordinary (possibly-trampolined) call. |
| `partial Name missing=1 [v0]` | `RUnderApp` | A partial application: build a closure over `Name` with these arguments supplied, `missing` more still needed before it can actually run. |
| `~r apply v0 v1` | `RApp` | Apply an *already-built* closure `v0` to one more argument `v1` (as opposed to `call`, which names a top-level function directly). |
| `let v0 : Boxed =`<br>`  <value>`<br>`<body>` | `RLet` | Bind `v0` (with the shown `Rep`) to `<value>`'s result, then continue into `<body>`. The single most common wrapper -- almost every intermediate computation goes through one. |
| `con Name ConInfo tag=Just 1 [v0, v1]` | `RCon` | Construct a value of `Name` with these fields. `ConInfo` is Idris2's own short tag for what kind of constructor this is at the source level (`[cons]`/`[nil]` for list-shaped types, `[data]` for an ordinary constructor, `[record]`, `[zero]`/`[succ]` for `Nat`-shaped types, `[enum N]`, `[unit]`, `[just]`/`[nothing]`, ...); `tag=Nothing` for an untagged/single-shape type. A trailing `reuse=v2` means this construction may repurpose `v2`'s own storage in place -- see section 9's reuse example. |
| `op PrimFn [v0, v1] postDrop=[v0]` | `ROp` | A primitive operation (`+Int`, `-Integer`, `cast-Integer-Int`, `==Char`, ...). `postDrop=[...]`, when present, lists every *Boxed* operand this op needs dropped once it's read them -- there's no separate statement position to hang an ordinary wrapping `drop` around an op's own read, so this field carries it instead (see `doc/native-type-inference.md`). Whether this line renders as a raw C expression or a boxed runtime call at emission time depends on the *enclosing* `let`'s own `Rep`, not on anything visible in this line itself. |
| `extprim Name [[__], v0, v1]` | `RExtPrim` | A call into rc2's own runtime-primitive glue (`IORef`, arrays, FFI helper wrappers, `%World`-threaded IO primitives -- the first argument is very often `[__]`, the `%World` token). |
| `cmp PrimFn [v0, v1] postDrop=[...]`<br>`then`<br>`  <T>`<br>`else`<br>`  <F>` | `RCmpCase` | A native comparison (`LT`/`GT`/`EQ`/`LTE`/`GTE`) fused *directly* into a two-way branch -- the Boolean result never materializes as a value at all, not even natively. Only ever produced when a comparison is the sole, immediate scrutinee of a two-way match on Idris2's own `Bool` (`False=0`/`True=1`) encoding. See section 9's worked example. |
| `case v0 of`<br>`  Name ConInfo tag=Just 1 args=[v1, v2] ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConCase` | Dispatch on scrutinee `v0`'s constructor tag. `args=[...]` are the fields this alt destructures *directly out of* `v0`'s own storage (pointer aliasing, not independently refcounted -- see how they get `dup`'d before `v0` potentially dies, in section 9). `_ ->` is the optional default (absent entirely if coverage is already exhaustive without one). |
| `case v0 of`<br>`  0 ->`<br>`    <body>`<br>`  _ ->`<br>`    <default>` | `RConstCase` | Dispatch on scrutinee `v0`'s *value* against literal constants (an integer switch, or a `String`/`Double` equality chain) rather than a constructor tag. |
| `0`, `"hi"`, `'x'` (bare) | `RPrimVal` | A literal value in its own right (as opposed to `#c`/`RCConst`, which is specifically an *operand* reference with no let/allocation -- `RPrimVal` is what a synthetic `let` binds when a literal *does* need its own boxed identity, e.g. staged into a file-scope constant). |
| `erased` | `RErased` | A value Idris2's own multiplicity analysis proved is never inspected -- nothing to compute, nothing to represent. |
| `crash "msg"` | `RCrash` | An unreachable path (e.g. a `case` Idris2 proved exhaustive some other way) or an explicit runtime panic. Lowers to an `abort()`-style call. |
| `dup v0`<br>`<body>` | `RDup` | Increment `v0`'s refcount ("add a reference"), then continue -- what a borrowed use lowers to. |
| `drop [v0, v1]`<br>`<body>` | `RDrop` | Decrement each listed local's refcount (recursively freeing at zero), then continue. The single most common ownership-cleanup shape; `Compiler.RC2.RC`'s `annotate` wraps at most one of these around a branch's own entry. |
| `free v0`<br>`<body>` | `RFree` | *Unconditional*, unchecked deallocation of `v0` right now -- no refcount check at all. Only ever inserted where `annotate` can prove, from the binding's own shape alone, that `v0` is a brand-new heap allocation that's had no chance to be shared yet (skips a branch and a memory read `drop` would otherwise do). Rare in practice -- see `doc/native-type-inference.md`'s companion doc or `RCExp.idr`'s own module note for why. |
| `releaseReuse v0`<br>`<body>` | `RReleaseReuse` | Release a reuse reservation (see next row) that turned out *not* to be consumed on this execution path. |
| `reuseOffer v0 dupOnShared=[v1, v2]`<br>`<body>` | `RReuseOffer` | A runtime uniqueness check: if `v0` turns out to be the sole reference, its storage is reserved for a later `con ... reuse=v0` in the same tree; otherwise every field in `dupOnShared` gets an extra reference (they're about to survive `v0`'s own ordinary recursive drop) and `v0` is dropped normally. See section 9. |
| `loop ["v4:Native Int", "v5:Native Int"] initial=[v0, v1]`<br>`<body>` | `RLoop` | The whole of a self- or (post-`MutualLoop`-merge) mutually-tail-recursive loop. Each loop param's own id and `Rep`; `initial` supplies each one's starting value (same order, evaluated once, in the *enclosing* scope, before the loop first runs). See section 8. |
| `continue loop [v2, v3]` | `RLoopContinue` | Jump back to the nearest enclosing `loop`'s own top, supplying these as each param's new value -- positional, same order as that `loop`'s own param list. Lowers to a plain C `goto`. |

Alt syntax (used inside `case`, one line + indented body per alt):

| Syntax | Meaning |
|---|---|
| `Name ConInfo tag=Just 1 args=[v1, v2] ->` | An `RConAlt` -- matches `RConCase`'s scrutinee against this constructor, binding its fields to the listed fresh ids. |
| `<constant> ->` | An `RConstAlt` -- matches `RConstCase`'s scrutinee against this literal value. |
| `_ ->` | The optional default/fallthrough for either case kind (one extra indent level, since it's not itself an "alt"). |

## 6. Reading ownership at a glance

Every *use* of a local elsewhere in the tree is a bare, unannotated
`vN`/`[__]`/`#c` -- refcount adjustments are never implicit, they're
always their own preceding line (`dup`/`drop`/`free`) or, for an op's
own operands specifically, the `postDrop=[...]` field (there's no
separate statement position to hang a wrapping `drop` around an op's
read, since it reads its operands and produces a result in the same
breath). To audit whether some local `vN` is handled correctly:

1. Find where it's bound (its `let vN : ...` line, or its appearance in
   a `fun args=[...]`/`RConAlt args=[...]`/`loop [...]` list).
2. Walk forward through every path reachable from there, noting every
   bare use, every `dup vN`, every `drop [..., vN, ...]`/`free vN`
   (including inside `postDrop`).
3. Every path should hit *exactly* one net "final disposition" for an
   owned value: consumed by a call/return (no drop needed, ownership
   transferred), or dropped/freed exactly once. A path with a use after
   its only drop, or two drops with no re-acquisition (`dup`) between
   them, is a real bug (this is precisely the manual technique that
   found several of the leaks/use-after-frees documented in
   `doc/native-type-inference.md`'s "Bugs found" section).

The reuse protocol (`reuseOffer`/`con ... reuse=sc`/`releaseReuse`) is a
three-way handshake, not a simple linear thing to grep for in isolation
-- section 9 below works a real example end to end.

## 7. Reading whether a self-tail-call became a loop

A definition whose body starts with `loop [...] initial=[...]` had at
least one self- (or, after merging, cross-member mutual-) tail-call
converted to a `goto`; every `continue loop [...]` inside it is one such
converted call site. A definition that *still* contains an ordinary
`call SameName [...]` in tail position (or, for mutual recursion,
targets a `{rc2_mutualLoop:N}` merged function it isn't itself part of
via the ordinary closure/`call` path) was **not** converted -- it still
goes through the generic closure-build-and-trampoline path. Comparing
"does this def's body start with `loop`" before/after a change to
`Compiler.RC2.Loop`/`Compiler.RC2.MutualLoop` is the fastest way to
confirm a specific recursive function is or isn't hitting the
optimization at all, before ever looking at generated C.

## 8. Reading native-shadowed loop params

`loop`'s own param list shows each param's `Rep` directly:
`"v0:Boxed"` stays exactly as boxed as the enclosing function's own
calling convention; `"v4:Native Int"` means this loop param was
promoted to a fresh native shadow -- unboxed exactly once at loop
entry (from `initial`'s corresponding, still-Boxed value), used as a
raw scalar for the loop's *entire* lifetime, and only ever boxed again
if some Boxed-context use inside the loop needs it (a constructor
field, a call to a non-native-aware function, the loop's own eventual
Boxed result). Crucially, the shadow's own id is **not** the original
parameter's id -- `initial` still lists the *original* (always-Boxed)
argument ids, `loop`'s own param list shows the *fresh* shadow ids next
to them, positionally paired.

Worked example -- `BenchLoop.idr`'s `sumTo acc n = sumTo (acc + n) (n - 1)`:

```
def Main.sumTo  (fun args=[v0, v1])
  loop ["v4:Native Int", "v5:Native Int"] initial=[v0, v1]
  case v5 of
    0 ->
      v4
    _ ->
      let v2 : Native Int =
        op +Int [v4, v5]
      let v3 : Native Int =
        op -Int [v5, #1]
      continue loop [v2, v3]
```

Reading this: the function's own top-level args are `v0`(`acc`)/`v1`(`n`)
(always Boxed, per the external calling convention -- see `TODO.md`'s
"Dual calling convention" gap). The loop wraps them in fresh native
shadows `v4`/`v5`, unboxed once from `v0`/`v1` at entry (not shown in
this snippet -- that unboxing is itself just an ordinary function-entry
step, invisible in the `loop` line, only Emit-time). Every reference
inside the loop body reads/writes `v4`/`v5` directly, never `v0`/`v1`
again -- both the countdown check (`case v5 of 0 -> ...`) and the
arithmetic (`op +Int [v4, v5]`, `op -Int [v5, #1]`) are plain native
ops, no boxed intermediate anywhere. `continue loop [v2, v3]` supplies
the next iteration's values positionally (`v2` -> `v4`'s slot, `v3` ->
`v5`'s slot); base case `0 -> v4` returns the shadow directly (boxed on
the way out, at emission time, since the function's own return type is
Boxed). No `dup`/`drop`/`free` appears anywhere in the loop body at all
-- native values never need any (see `rc2/BENCHMARKS.md`'s 2026-08-14
entry for the resulting generated-C/timing comparison, and
`TODO.md`'s "Native-shadow eligibility stops at bare top-level scalars"
note for the real-world pattern -- a loop-carried value wrapped in a
single-field constructor -- this specific mechanism does *not* reach).

## 9. Worked examples

### Constructor-reuse-in-place (`List.takeUntil`-shaped code, from `Test1Basics.idr`)

```
case v1 of
  _builtin.CONS [cons] tag=Just 1 args=[v2, v3] ->
    reuseOffer v1 dupOnShared=[v2, v3]
    let v4 : Boxed =
      dup v0
      dup v2
      apply v0 v2
    case v4 of
      1 ->
        drop [v0, v3, v4]
        con _builtin.CONS [cons] tag=Just 1 [v2, [__]] reuse=v1
      0 ->
        drop [v4]
        let v5 : Boxed =
          let v6 : Boxed =
            apply v3 [__]
          call Prelude.Types.takeUntil [v0, v6]
        con _builtin.CONS [cons] tag=Just 1 [v2, v5] reuse=v1
```

Reading this: `v1` (the scrutinee, a `Cons` cell) is matched, destructuring
`v2`/`v3` (head/tail) directly out of its own storage. `reuseOffer v1
dupOnShared=[v2, v3]` immediately follows -- `v1` is about to die on
*every* path through this alt, and both branches build a fresh `Cons`
of the same shape, so this alt qualified for reuse (see
`doc/reuse-analysis.md`'s `resolveAlt` eligibility rules). Each branch's
own `con _builtin.CONS ... reuse=v1` is what actually claims the offer
-- at runtime, `idris2rc2_isUnique(v1)` decides whether that construction
repurposes `v1`'s own storage in place or allocates fresh; either way
`v2`/`v3` needed their own `dup` first (not shown as a separate `dup v2`
line here since it's folded into `reuseOffer`'s own `dupOnShared`
protocol -- both fields survive into the new `Cons` regardless of which
path the runtime check takes).

### Mutual tail recursion, merged (`isEvenM`/`isOddM`, from `Test9SelfTailLoop.idr`)

```
def Main.isEvenM  (fun args=[v0])
  call {rc2_mutualLoop:0} [#0, v0]

def Main.isOddM  (fun args=[v0])
  call {rc2_mutualLoop:0} [#1, v0]

def {rc2_mutualLoop:0}  (fun args=[v1, v2])
  loop ["v1:Boxed", "v2:Boxed"] initial=[v1, v2]
  case v1 of
    0 ->
      case v2 of
        0 ->
          drop [v2]
          1
        _ ->
          let v3 : Boxed =
            op -Integer [v2, #1] postDrop=[v2]
          continue loop [#1, v3]
    1 ->
      ...
```

`Main.isEvenM`/`Main.isOddM` each became a thin wrapper -- one `call` to
a synthesized `{rc2_mutualLoop:N}` function, passing their own tag
(`#0`/`#1`) plus their real argument. The merged function itself
dispatches on that tag (`case v1 of 0 -> ...isEvenM's own body...; 1 ->
...isOddM's...`); a *cross-member* transition (`isEvenM (S k) = isOddM
k`) is just `continue loop [#1, v3]` -- switching the tag to `1` and
looping, exactly as uniform as a same-member transition would be. This
is the concrete shape `TODO.md`'s "Mutual tail recursion loop
conversion" section describes: from the merged function's own point of
view every transition, self- or cross-member, is just an ordinary
self-tail-call, so `Compiler.RC2.Loop` (which runs immediately after
`Compiler.RC2.MutualLoop`) converts it with zero special-casing.

### Comparison/branch fusion (`Prelude.EqOrd.==` on `Char`)

```
def Prelude.EqOrd.==  (fun args=[v0, v1])
  cmp ==Char [v0, v1]
  then
    1
  else
    0
```

No boxed `Bool` value is ever built here, native or otherwise --
`cmp ==Char [v0, v1]` is a raw C `==` embedded straight into the `if`
that picks between `1`/`0` (`Bits8`-tagged, per `alwaysUnboxed`, so
those themselves cost nothing either). Contrast with an *unfused*
comparison (e.g. `Prelude.EqOrd.<` over `Integer`, which stays boxed
since `Integer` is never native-eligible): `let v2 : Boxed = op
<Integer [...] ...` followed by an ordinary `case v2 of 0 -> ...; _ ->
...` -- the Boolean genuinely materializes as a value there.

## 10. Quick recipes

- **"Did my self-tail-recursive function become a `goto` loop?"** --
  `grep -A1 "^def YourFn" out.rcexpr`; look for `loop [...]` as the very
  next line.
- **"Did a specific loop parameter get native-shadowed?"** -- check that
  same `loop [...]` line's own param list for `Native <ty>` at the
  position corresponding to your parameter (cross-reference against
  `initial=[...]`, same order as the function's own `args`).
- **"Did constructor-reuse fire for this match?"** -- look for
  `reuseOffer` right after the alt's own destructure, then find the
  paired `con ... reuse=<same id>` (claimed) or `releaseReuse <same id>`
  (released) somewhere in the alt's own body.
- **"Is this a leak/use-after-free?"** -- section 6's walk-every-path
  technique; the `postDrop`/`RFree` fields are exactly the places past
  bugs hid (see `doc/native-type-inference.md`'s "Bugs found" list --
  several were found by exactly this kind of manual trace before ever
  writing a regression test for them).
- **"What does `Prelude`/library function X actually compile to?"** --
  `grep -n "^def "` the whole file; the dump isn't scoped to your own
  module.

## 11. Limitations (repeated from section 1, for reference)

- Source spans (`FC`) are stripped entirely -- every node in `RCExp.idr`
  carries one, but they're pure noise for this purpose.
- Keywords (`let`, `case`, `dup`, ...) are deliberately terse and are
  **not** the real Idris constructor names -- section 5 is the
  authoritative mapping back to `RCExp.idr`.
- Never read back by the compiler; purely a debugging aid, no format
  stability guaranteed across rc2 changes.
- Reflects only the final, fully-Reuse'd/MutualLoop'd/Loop'd state --
  see section 1 if you need an earlier pipeline stage.

## Files

- `rc2/src/Compiler/RC2/Pretty.idr` -- the renderer itself
  (`prettyExp`/`prettyDef`/`prettyProgram`, all the syntax in section 5).
- `rc2/src/Compiler/RC2/RC2.idr` -- `compileExpr`'s own `--directive
  dumprcexpr` wiring (writes the `.rcexpr` file).
- `rc2/src/Compiler/RC2/RCExp.idr` -- the actual IR this all renders;
  authoritative doc comments on every constructor mentioned above.
