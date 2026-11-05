# Constructors in the stack frame (`Compiler.RC2.StackCon`)

Disable with `--directive nostackcon`.

## What it does

A constructor built with `let v = con C [..]` that never leaves the function is built in the
function's C frame instead of on the heap: `RStackCon`, a node only this pass makes, last
before `Emit`. It is a `IDRIS2RC2_ConstConstructor<n>` with the immortal header that static
constants have, so the `dup`, `drop` and `reuseOffer` of a callee that gets it do nothing at
run time.

`v` qualifies when
- the constructor is tagged, has one to twenty fields and no `reuse=`;
- every field is a local known to be Boxed or an immortal constant (a native literal such as a
  `Double` is boxed afresh when read, and nothing would release that box);
- no `dup v` exists (one owner at every point of every path);
- every read of `v` is the scrutinee of a `case`, or the argument of a direct call in the value
  position of a `let` (not a tail call) whose parameter does not let it escape.

## Parameters that do not escape

`paramDeps` reads a callee's body for each parameter `p`: a `case` on `p` and a `dup`/`drop` of it are
free; passing it on to a direct call adds that callee's parameter as a dependency; anything else
(`partial`, `delay`, `apply`, a field of a constructor, a returned or `continue`d value, a lazy
call) lets it escape, and so does a `reuseOffer` of `p`: the callee would have reused a heap cell
for free, and with a stack cell that allocation only moves into the callee. `nonEscaping` takes the
greatest fixed point: a parameter passed on is safe when the parameter it goes to is.

## The caller's RC

The stack cell owns one reference per boxed field. All `dup`/`drop` of `v` leave the IR (the
cell has no count), and:

- `drop [v]` becomes `drop` of the boxed fields;
- `reuseOffer v ds us` becomes `dup ds` and the `drop` of the fields (the shared path: the cell is never
  unique), and a `con` that reused `v` allocates;
- `free v` (a dead constructor: the runtime frees the cell with its fields) becomes `drop` of the fields,
  and `releaseReuse v` goes;
- a call that took `v` is followed by `drop` of the fields, since the callee's `drop` of an immortal cell does nothing.

The callee keeps its own `dup p`/`drop p`: the function is shared with callers that pass heap
cells. Removing them from the callee takes a clone with a borrowed parameter, which is not done.

## Flattening

A call is "in the value position of a `let`" even when the constructor is built inside that value:
`let x = (let v = con ..; call f [v])`. So `let x = (let y = a; b) in c` is read as `let y = a in let x = b in c`
(and `dup`/`drop` in front of the value move out in front of the `let`), only for a value whose
statements build a constructor, and kept only if one became a stack constructor. A function of more than
4000 nodes is left alone: each constructor looks through the rest of its function. Each stack constructor
adds its cell (8 bytes plus 8 per field) to the C frame.

## Measured

On `rc2-norepl` (final IR, 2026-11-05): 316 constructors are built in the frame, and the build takes as
long as before (10.5 minutes, C compilation included).

`Test167StackCon`: `once` and `twoLets` (its fields built in two `let`s inside the value) pass a fresh `MkP` to
`glue`, which only cases it; `twice` shares it, `kept` stores it and `withDouble` holds a `Double` literal, so
those stay on the heap.
