module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.ConstFold's new `RConCase`
-- scrutinee fold (its own module note): `directCase`'s scrutinee `x`
-- is a known-constant constructor (`RCConstCon`, from the `let`
-- immediately above it), so the whole `case` -- tag dispatch included
-- -- must fold away entirely at compile time, down to a single
-- `RPrimVal`. `areaOf`'s own two calls keep a genuinely dynamic
-- scrutinee (an ordinary function argument), exercising the pass's
-- required fallback (`RConCase` unchanged but for its own recursively-
-- folded alts) and doubling as the Reuse/Emit audit Test75's own
-- module note in the approved plan calls for -- a `RConCase` whose
-- scrutinee ConstFold *did* resolve must never reach Emit at all (see
-- ConstFold.idr's own doc comment for why: `EmitUtil.idr`'s `varName`
-- has no real rendering for `RCConstCon` reaching a runtime tag
-- check), which this test's own passing run (not just its output)
-- confirms.

data Shape = Circle Int64 | Square Int64

areaOf : Shape -> Int64
areaOf (Circle r) = r * r
areaOf (Square s) = s * s + 1

directCase : Int64
directCase =
  let x : Shape
      x = Circle 5
  in case x of
          Circle r => r * r
          Square s => s * s + 1

main : IO ()
main = do
  printLn directCase
  printLn (areaOf (Circle 5))
  printLn (areaOf (Square 3))
