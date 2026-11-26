# Join points

Tail subtrees of one function that are equal up to the numbering of
their locals become one block, a join point, and each copy becomes a
jump to it that passes its own free locals (`Compiler.RC2.JoinPoints`).
In C the jump is a few assignments and a `goto`.

## Why

`ShareSubtrees` (`shared-subtrees.md`) makes a repeated subtree a new
function, before RC. Three kinds of copy are still in the final IR of
`rc2-norepl` (2026-11-26, 595k lines, of which 99k are second or later
copies of a subtree of at least five lines):

- A copy that tail-calls the function itself, or a function of its
  tail-call cycle. `ShareSubtrees` leaves it: in a new function the call
  would join the cycle, which takes a trampoline. `Loop` and `MutualLoop`
  then make the call a `continue loop`, and `LateInline` moves the loop,
  copies and all, into its one caller. `mkRHSargs` holds a 1,908-line
  subtree 5 times this way. About 24k lines.
- A copy smaller than `ShareSubtrees`' `minNodes` (24) before RC, which
  RC's dups and drops make bigger: `snfVector`'s 27 lines, 108 times.
  About 46k lines in tail position.
- A copy in a `let`'s value, mostly a small function inlined at each of
  its calls (`perrorRaw`'s `<+>` of `Doc`, 13 lines, 159 times). As a
  function it would only bring the call back.

A jump to a join point is no call, so neither the cycle nor the size
matters, and an inlined copy stays inlined.

## The nodes

```idris
RJoin : FC -> (label : Nat) -> (params : List (LocalId, Rep)) -> (scope : RCExp) -> (body : RCExp) -> RCExp
RJump : FC -> (label : Nat) -> (args : List RCLocal) -> RCExp
```

`RJoin` runs `scope`; a tail of `scope` that is `RJump label args` runs
`body` with `params` bound to `args`. The dump shows

```
join j1 ["v528:Boxed", "v530:Native Int"]
<scope>
at j1 ->
  <body>
```

and `jump j1 [v302, v522]`. `Emit` declares the params, emits `scope`,
then `join_N:;` and `body`, both into the sink the `RJoin` has; `RJump`
assigns the params and `goto`s the label. When that sink is a variable
(the join point is in a `let`'s value), `scope` falls through where it
has assigned it, so `goto join_N_end;` comes before the label and
`join_N_end:;` after `body`. Arguments move as `continue loop`'s do: RC
has decided every ownership already, and the copy that was there
consumed what it read. Unlike a `continue`, a jump assigns its params
directly, without temporaries: they are fresh, so no argument reads one.

## How

The pass runs last in `toRCDefs`, after `StackCon`, so no pass that
rewrites a body sees the nodes: only `Emit` and the generic walkers in
`RCExp.idr` know them. Per function:

1. Every subtree of at least `minJoinNodes` (8) nodes in a tail of its
   region is a candidate, of at least `minJoinNodesInLoop` (24) inside a
   loop: there each jump moves its arguments on every iteration (see
   "Measured"). A region is the body, a `let`'s value or a memoized CAF's
   body, and the path from it goes only through a `let`'s body, an ownership
   wrapper, an arm of a branch, or a loop's body. A `let`'s value counts
   because `LateInline` splices loops there: `mkRHSargs`' loop is in a
   `let`'s value of `mkSpecDef`'s twelfth lambda. Its free
   locals are what it mentions (`mentionedLocals`, so the locals of
   `continue loop` and of a `drop` count) less what it binds, in the
   order a walk first reads them.
2. Candidates are grouped and compared as in `ShareSubtrees`: by size,
   largest first, then free-local count and `leafHash`, then
   `FunDedup.sameUpToLocals`; classes in the order they first appear in
   the body. A candidate inside a chosen member is not looked at again.
3. A class is split by region and by the innermost `RLoop` above its
   members. Its join point goes at the members' lowest common ancestor,
   which is then in a tail of that region and inside that loop, so a
   `continue` in the body continues the same loop.
4. The params are fresh ids above the function's largest, with the `Rep`s
   of the first member's free locals; the body is that member with its
   free locals renamed to them. Every member becomes a jump with its own.

A copy is left where it is when a free local

- is `RInlineNative` (no variable of its own) or a struct (`RRet`);
- is a field of a struct: its `Rep` is what the struct's layout says
  (`DualABI.fieldReps`), which the pass does not read, so it has none;
- has another `Rep` than the first member's;
- is a constructor built in the C frame (`StackCon`): its cell lives in
  the C block of its `let`, and the join point may be outside it;
- is reused (`reuse=`, `RReleaseReuse`, `RReuseOffer`): the C reuse
  slot is named after the local.

Every member and so their common ancestor is in a tail of one region, so
whatever `scope` does not jump with ends the region: it returns,
continues a loop, or assigns the region's variable and falls through to
`join_N_end`.

`Pending` (`trampoline-elision.md`) counts what a jump returns as
nothing: the body's tails are the join point's, which the `RJoin` already
counts. Taken for any unknown tail, a jump made each function holding one
look as if it could return a pending closure, and so every call of it
went through the trampoline.

Off with `--directive nojoinpoints`.

## Measured

`rc2-norepl` (2026-11-26), clang `-O2`, against the same compiler with
`--directive nojoinpoints`:

| | without | with |
|---|---|---|
| C | 87.49 MB | 82.21 MB (−6.0%) |
| IR lines | 609,695 | 576,681 (−5.4%) |
| `.o` text | 15.51 MB | 15.32 MB (−1.2%) |
| `clang -O2 -c` | 325 s | 311 s |
| binary | 17.12 MB | 16.93 MB (−1.1%) |
| join points | | 485, 1,369 jumps |

The pass takes 2.6 s. The `rc2-norepl` built from each C, generating
its own C (`--directive nocc`), took 109.3 s without and 107.0 s with, in
each of three runs.

`bench.sh` is within noise. With 8 nodes inside loops as well, the C was
80.21 MB, but `BenchListSort` took 3.8% longer: `mergeBy`'s TRMC loop got
a join point of 12 nodes whose five arguments moved on every iteration.
