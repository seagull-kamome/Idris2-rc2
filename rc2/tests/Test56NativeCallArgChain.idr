module Main

%foreign "C:abs,libc,stdlib.h"
prim__abs : Int -> Int

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

-- Regression test for Compiler.RC2.DualABI's own call-argument
-- promotion (Stage 4's RLet clause, via `callArgNativeReads`): when an
-- RLet-bound worker call's result is consumed only as *another*
-- worker's own native argument -- not an ROp/comparison operand, the
-- case `nativeArgTypes`/`bareTailNativeReads` already covered -- the
-- intermediate value should still be promoted straight to native,
-- skipping the box-then-immediately-unbox round trip. Verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".
--
-- `addAbs`'s own body isn't Compiler.RC2.Inline-eligible (it calls an
-- FFI declaration, so `isCallFree` is False -- see
-- `Compiler.RC2.Inline`), so its call from `chain` below survives to
-- exercise `Compiler.RC2.DualABI`'s own worker call-site rewriting
-- instead of being spliced away entirely before DualABI ever runs.
-- Its own first parameter, `x`, only becomes native-eligible via the
-- nested-RLet-`body` fix `Test13NativeArgChain.idr` covers (`x + ...`
-- sits inside a further `let`'s own body, not directly as an outer
-- RLet's value) -- deliberately reusing that same shape here so
-- `addAbs` genuinely has a *native* argument position for `chain`'s
-- own call-argument promotion to target.
addAbs : Int -> Int -> Int
addAbs x y = (x + prim__labs y) * 2

-- `prim__abs x`'s own result is bound here only to be fed straight
-- into `addAbs`'s native first argument -- exactly the shape that used
-- to box then immediately unbox again.
chain : Int -> Int -> Int
chain x y = addAbs (prim__abs x) y + 1

main : IO ()
main = printLn (chain (-123456) 654321)
