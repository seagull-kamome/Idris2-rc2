module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Compiler.RC2.Sink's branch-local sinking as a general,
-- loop-independent pass (unlike Test21BoxedInvariantNotHoisted.idr,
-- which exercises the same pass but specifically inside a self-tail
-- loop): `sinkable`'s `ctx` is only ever read on the `True` arm, so
-- its own construction should move into that arm entirely, leaving
-- the `False` arm untouched; `notSinkable`'s `ctx` is read on *both*
-- arms, so it must stay exactly where it is -- sinking it into either
-- one would leave the other with no value to read at all.
data Pair2 = MkPair2 Int Int

sinkable : Bool -> Int -> Int -> Int
sinkable flag a b =
  let ctx = MkPair2 a b
  in if flag
        then case ctx of MkPair2 x y => x + y
        else 0

notSinkable : Bool -> Int -> Int -> Int
notSinkable flag a b =
  let ctx = MkPair2 a b
  in if flag
        then case ctx of MkPair2 x y => x + y
        else case ctx of MkPair2 x y => x - y

-- Exercises applySinkExp re-feeding a successful sink through itself:
-- `ctx` is read only when *both* flags are True -- one sink moves it
-- into `flag`'s own True arm, landing it directly above another
-- branch (`flag2`), which should trigger a second sink one level
-- deeper in the very same pass.
deepSinkable : Bool -> Bool -> Int -> Int -> Int
deepSinkable flag flag2 a b =
  let ctx = MkPair2 a b
  in if flag
        then if flag2
                then case ctx of MkPair2 x y => x + y
                else 0
        else 0

-- Exercises sinking a plain function call (RAppName), not just
-- ROp/RCon: `buildMsg tag n`'s own call is only read on the `True`
-- arm, so the call itself -- and the drop of its own Boxed arguments
-- it would otherwise perform via ownership transfer -- should move
-- into that arm; the `False` arm gets an explicit `drop [tag, n]`
-- instead of ever making the call.
buildMsg : String -> Int -> String
buildMsg tag n = tag ++ show n

callSinkable : Bool -> String -> Int -> String
callSinkable flag tag n =
  let msg = buildMsg tag n
  in if flag
        then msg
        else "none"

-- Exercises sinking `x` *past* an unrelated `let y = ...` sitting
-- between it and the branch: `y` itself is read on both arms (so it
-- can't sink anywhere and stays exactly where it is), but `x` doesn't
-- appear in `y`'s own computation, so `x`'s own binding should still
-- reach through `y` and land inside the one arm (`True`) that reads
-- it.
skipUnrelatedLet : Bool -> Int -> Int -> Int -> Int
skipUnrelatedLet flag a b c =
  let x = a + b
      y = c * 2
  in if flag
        then x + y
        else y

-- Regression test for a real miscompile found while building the
-- "peel through an unrelated RLet" extension of the pass above
-- (formerly a separate Test23SinkPastSelfDrop.idr, merged in below --
-- see rc2/doc/branch-sinking.md's own "Sinking past an unrelated
-- let"/"Not peeling through var's own death" sections): a chain of
-- `do`-notation IO actions whose own `()` result is immediately
-- discarded lowers to `let v5 = call sideEffect [..] in drop [v5]; let
-- v6 = call sideEffect [..] in drop [v6]; ...` -- each one wrapped by
-- exactly one `RDrop [vN]` that's *its own* death, not an unrelated
-- ownership wrapper to see past. Before this fix, `trySinkInto`'s old
-- unconditional "peel through any RDrop" clause treated that as just
-- another wrapper, and kept searching straight through the whole
-- chain to a distant, unrelated branch -- producing a real miscompile
-- (`refc-suite/buffer`'s own `TestBuffer.idr`, which has exactly this
-- do-notation shape via `setByte`/`setBits8`/`setBits16`/...,
-- generated C referencing `var_5`/`var_6`/... without ever declaring
-- them). This test reproduces the same shape directly, independent of
-- Data.Buffer, so it stays a dedicated rc2/tests/ regression rather
-- than relying on refc-suite alone catching it again.
sideEffect : Int -> IO ()
sideEffect n = pure ()

chainThenBranch : Bool -> Int -> Int -> IO Int
chainThenBranch flag a b = do
  sideEffect a
  sideEffect b
  sideEffect a
  sideEffect b
  pure (if flag then a else b)

main : IO ()
main = do
  printLn (sinkable True 3 4)
  printLn (sinkable False 3 4)
  printLn (notSinkable True 10 3)
  printLn (notSinkable False 10 3)
  printLn (deepSinkable True True 5 6)
  printLn (deepSinkable True False 5 6)
  printLn (deepSinkable False True 5 6)
  putStrLn (callSinkable True "n=" 5)
  putStrLn (callSinkable False "n=" 5)
  printLn (skipUnrelatedLet True 3 4 5)
  printLn (skipUnrelatedLet False 3 4 5)
  -- absorbed from former Test23SinkPastSelfDrop
  r1 <- chainThenBranch True 3 4
  printLn r1
  r2 <- chainThenBranch False 3 4
  printLn r2
