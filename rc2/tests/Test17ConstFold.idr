module Test17ConstFold

import System.Info

-- Regression test for Compiler.RC2.ConstFold: ROp/RConstCase/RCmpCase
-- constant folding, run between Compiler.RC2.RC's Phase 1 and Phase 2
-- (see ConstFold.idr's own module note). `cmpConst` below also covers
-- Compiler.RC2.Inline's own `allLiteralArgs` guard, narrowed to admit
-- exactly the calls ConstFold can now make safe to inline (see its own
-- doc comment).

-- ROp folding: fixed-width int arithmetic and string append, entirely
-- within one function body.
addConst : Int64
addConst =
  let a : Int64
      a = 1
      b : Int64
      b = 2
  in a + b

strConst : String
strConst = "foo" ++ "bar"

-- Same-width wraparound check, mirroring Test6NativeInts.idr's own
-- chainInt8 (100+100 style) -- both operands compile-time constants,
-- so Compiler.RC2.ConstFold folds the whole chain at compile time
-- instead of Emit ever seeing a `+` (which is what Compiler.RC2.
-- Inline's own `allLiteralArgs` guard exists to avoid gcc statically
-- flagging as overflow, see its own doc comment -- this test checks
-- the *other* way overflow-safety could break: that ConstFold's own
-- compile-time computation matches rc2's runtime two's-complement
-- wraparound bit for bit).
overflowChain : Int8
overflowChain =
  let a : Int8
      a = 100
      b : Int8
      b = 100
  in a + b

-- RConstCase folding: case on a known-constant scrutinee, entirely
-- within one function body (no call-boundary/inlining involved).
caseConst : String
caseConst =
  let x : Int64
      x = 10
  in case x of
          10 => "ten"
          _  => "other"

-- RCmpCase folding: comparison on known-constant operands, entirely
-- within one function body. Reaching this needs Compiler.RC2.RC's own
-- `tryFuseCompare` to fire on a *direct* primitive comparison -- which
-- means Ord Int64's own `<` implementation (an interface method call,
-- invisible to `tryFuseCompare` on its own) first has to be spliced in
-- by Compiler.RC2.Inline. Before Inline's own `allLiteralArgs` guard
-- was narrowed to only block Int/Double literal chains (this pass is
-- exactly why it could be: whatever chain inlining produces here gets
-- folded down to a single RPrimVal well before Emit), a call whose
-- arguments were both compile-time literals like this one never got
-- inlined at all, so `tryFuseCompare` never even got a direct
-- comparison to look at -- this is the case that guard was blocking.
cmpConst : String
cmpConst =
  let a : Int64
      a = 3
  in if a < 5 then "less" else "not less"

-- Chained with ConstExtPrim's own prim__codegen fold: whether or not
-- this particular call site happens to get inlined into `codegen`'s
-- own body (that's Compiler.RC2.Inline's call, not ConstFold's), the
-- output must be correct either way.
codegenChain : String
codegenChain = codegen ++ "-suffix"

-- Should NOT be folded: Int/Double operands (host-width-unsafe, see
-- ConstFold.idr's own `safeConst`) -- regression check for the guard
-- itself, not just its absence of a crash.
intNotFolded : Int
intNotFolded = 1 + 2

doubleNotFolded : Double
doubleNotFolded = 1.0 + 2.0

main : IO ()
main = do
  printLn addConst
  putStrLn strConst
  printLn overflowChain
  putStrLn caseConst
  putStrLn cmpConst
  putStrLn codegenChain
  printLn intNotFolded
  printLn doubleNotFolded
