module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Off-by-one regression for Compiler.RC2.RC2's `maxConstFoldIterations`
-- (4): a 3-hop CAF alias chain (`capC = capB`, `capB = capA`,
-- `capA = MkBox op1`) over a record type (not a bare function type --
-- `capA = op1` alone would type-elaborate to an eta-expanded 1-arg
-- `Main.capA`, not a genuine 0-arg CAF, so `Box` keeps each hop a real
-- CAF). Each `RAppName fc lazy "Main.cap_" []` hop only resolves once
-- the CAF one hop further down the chain has itself already been
-- entered into `Compiler.RC2.ConstFold.CafTable` by a PRIOR whole-
-- program fixpoint round (`RC2.idr`'s own `foldConstProgram`) --
-- resolving the whole chain therefore needs multiple rounds, not one.
-- If the iteration cap were off by one (too low to let the chain fully
-- resolve), `main` would still produce the correct answer (an
-- unresolved `RAppName` call chain still runs correctly, just less
-- optimised) but `--directive dumprcexpr` would show a residual
-- `RAppName "Main.capB"`/`"Main.capA"` reference instead of `main`
-- applying a single folded `RCConstClosure` directly (confirmed by
-- hand: with the cap actually at 4, `Main.capA`/`capB`/`capC`
-- disappear from the dump entirely, pruned by
-- `Compiler.RC2.DeadCode` once nothing calls them by name anymore).

-- Two fields, not one -- a single-field record is optimised as a
-- transparent newtype (no real boxing at all), which would silently
-- put us right back in the eta-expanded-1-arg-function situation this
-- test exists to avoid (see this module's own doc comment above).
record Box where
  constructor MkBox
  run : Int -> Int
  tag : Int

op1 : Int -> Int
op1 x = x + 1

capA : Box
capA = MkBox op1 0

capB : Box
capB = capA

capC : Box
capC = capB

main : IO ()
main = printLn (capC.run 41)
