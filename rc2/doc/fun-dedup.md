# Merging functions with equal bodies: `Compiler.RC2.FunDedup`

Cloning and lifting leave many functions whose bodies are the same up to
the numbering of their locals: closures lifted from identical lambdas,
specialisation clones that came out equal, DualABI workers of equal
wrappers. On idris2-lsp's final IR (17,370 definitions) 5,157 definitions
(30%, 4.3% of the IR lines) had a twin; most were 3-line stubs, 239
groups had bodies over 6 lines.

`dedupFuns` is the last whole-program step of `toRCDefs` (after the final
Dup/drop cancel, before the program is emitted). Off with
`--directive nofundedup`, and not run in incremental mode, where a module
sees only its own definitions.

## How

1. **Candidates**: `MkRCFun` with at least one parameter. CAFs (`RMemoize`)
   are left alone, and so is a function holding an inlined FFI call or a
   constant constructor with fields (`hasFatConst`): the first is not
   compared structurally, the second can unfold to a huge tree.
2. **Shallow key**: the parameter count, the number of nodes, the
   parameter and return representations with the worker flag, and the set
   of functions the body refers to, with the function's own name replaced
   by a placeholder so that self-recursive twins agree, and a hash of the
   constants and constructors in walk order (`leafHash`), so that stubs
   differing only in a constant do not share a bucket. Only functions
   sharing it are compared further. A pre-order prefix hash of the first
   ten nodes was tried as well and gave the same result on idris2-lsp for
   a little more time, so it is not there.
3. **Structural comparison** (`sameFun`/`eqE`): the two bodies are walked
   together. The locals of one are paired with those of the other as they
   are bound (parameters, `let`, case alternatives, loop parameters), the
   pairing must stay one-to-one, and a use of a local has to hit its
   partner. A call to the function itself matches a call to the other
   function itself. The comparison stops at the first difference and builds
   nothing. Constructors it does not cover (struct access, inlined FFI
   calls, memoization) are never equal to anything.
4. In program order, roots (`main`, exports) first, each function is
   compared with the distinct functions of its bucket seen so far; if one
   is equal it is redirected to it (`renameNamesR` over every call,
   partial application, `delay` and closure constant). A root is never
   redirected.
5. A merge can make callers equal in turn, so this repeats up to four
   times; redirected functions leave the later rounds but stay in the list.
6. `pruneDeadDefs` removes what nothing refers to any more.

An earlier version keyed on the `dumprcexpr` text with the locals
renumbered. That cannot work: `Pretty` never finished printing a function
with an inlined FFI call on `libs/web/tests/TestWebAPI` (the same reason
`dumprcexpr` runs out of memory on it), and text for every candidate costs
far more than comparing two trees.

A `RCConstCon`'s fields are not renamed (its erased proof cannot be
rebuilt); a function named only there is kept, which is safe but less
thorough. Test114Inline/FunDedup found this the hard way: dropping a
merged function at once left a dangling `constclosure`.

## Results

idris2-lsp: 17,370 -> 12,705 definitions (-27%), `rcexpr-lint` clean; the
pass takes about 1.7 s. `libs/rc2base/tests` all pass (34).

## Test

`Test114Inline/FunDedup` (`check.sh`: one of two equal loops survives, the
loop with another constant keeps its own; `--directive nofundedup` fails
it).
