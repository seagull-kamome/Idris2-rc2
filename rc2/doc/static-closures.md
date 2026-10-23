# Static closures

`Compiler.RC2.Emit.Util.staticClosure`. A closure whose captured values are all
constants is a file-scope static, immortal like an `RCConstCon`, instead of an
`idris2rc2_mkClosure` and one store per field each time it is built.

## Why in Emit

`pure ()` in `Control.Task` is a tail call of `pure` with the unit and the world.
At the IR it is an `RAppName`; a tail call becomes a closure for the trampoline
only in `Emit` (`tryBuildClosureInto`), so `ConstFold` never sees a closure there.
`RCConstClosure` also holds no captured values, and giving it some means changing
every place that matches an `RCLocal` (about 55). The `Emit` rule needs only the
captured values at the point where the closure is built.

## The rule

Every captured value is `RCNull`, `RCErased`, `RCWorld`, a constant form
(`RCConstCon`, `RCConstClosure`) or a literal (`RCConst`, rendered as a boxed
constant: an immediate integer, or a static such as a string), and its C expression
is an address, `NULL` or `IDRIS2RC2_IMM_*`. Anything else, `RCEmptyCon` among them
(its expression is a `mk...` call), keeps the heap closure. Then `makeClosureInto` stages

```c
static IDRIS2RC2_ConstClosureArgs2 const constclosure_N =
  { .header = IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CLOSURE), .arity = 3, .filled = 2,
    .fn = (void *)f, .args = { NULL, NULL } };
```

and the sink gets its address. `IDRIS2RC2_ConstClosureArgsN` (1 to 20, the range of
the dispatch switch in `idris2rc2_rt.c`) is `IDRIS2RC2_Closure` with a fixed `args[N]`
(C has no static initializer for a flexible array member).

Why this is sound: the header is immortal, so `dup` and `drop` of the closure and of
its captured values do nothing, `idris2rc2_isUnique` is false (no in-place growth of a
shared static) and the trampoline's release of a dispatched closure is skipped. A
saturated static closure is run by the trampoline as often as it is returned; the
arguments it passes on are constants that nothing frees. A static closure is
never freed: `RFree` of a dead `let` is chosen only for a partial application with a
variable among its captured values (`RC.idr`, `freeableShape`). Statics are not shared
between sites (no dedupe); each is a few words.

## Measured

`TestAsyncHTTPServer`: 15 statics. Instructions in user space per `GET /hello`,
one connection, one thread: 259 000 -> 251 000 (about 3 per cent).

Test: `rc2/tests/Test133StaticClosure/`.
