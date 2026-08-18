module Test17ConstFold

import System.Info

-- Regression test for Compiler.RC2.ConstFold: ROp/RConstCase/RCmpCase/
-- Cast constant folding, run between Compiler.RC2.RC's Phase 1 and
-- Phase 2 (see ConstFold.idr's own module note). `cmpConst` below also
-- covers Compiler.RC2.Inline's own `allLiteralArgs` guard, narrowed to
-- admit exactly the calls ConstFold can now make safe to inline (see
-- its own doc comment).

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

-- Cast folding: fixed-width int -> fixed-width int, entirely within
-- one function body -- both source and target admit intKind (see
-- ConstFold.idr's own foldableOp), so this now folds instead of
-- reaching Emit as a runtime cast.
castInt8ToInt64 : Int64
castInt8ToInt64 =
  let a : Int8
      a = 100
  in cast a

-- Sign-extension check: -56 as Int8 cast up to Int64 must stay -56,
-- not zero-extend.
castNegativeWiden : Int64
castNegativeWiden =
  let a : Int8
      a = -56
  in cast a

-- Bits64 -> Integer: the unsigned magnitude must be preserved in
-- full, not reinterpreted as a negative signed value.
castBits64ToInteger : Integer
castBits64ToInteger =
  let a : Bits64
      a = 18446744073709551615
  in cast a

-- Narrowing wraparound: Int32 -> Int8 truncates, matching rc2's own
-- runtime (int8_t) cast bit for bit (300 mod 256 = 44).
castNarrowWrap : Int8
castNarrowWrap =
  let a : Int32
      a = 300
  in cast a

-- Should NOT be folded: Double/Int(unsuffixed)/Char on either side of
-- Cast -- ConstFold.idr's own foldableOp excludes these via intKind
-- returning Nothing (Double/Char) or the explicit Cast IntType _ /
-- Cast _ IntType clauses (unsuffixed Int).
castDoubleNotFolded : Int64
castDoubleNotFolded =
  let a : Double
      a = 3.999
  in cast a

castIntNotFolded : Int64
castIntNotFolded =
  let a : Int
      a = 42
  in cast a

castCharNotFolded : Int64
castCharNotFolded =
  let a : Char
      a = 'A'
  in cast a

-- Cast-to-String folding: fixed-width int/Integer -> String, entirely
-- within one function body -- `from` admits intKind, `to = StringType`
-- is its own foldableOp case (see ConstFold.idr's own doc comment for
-- why Char/Double stay excluded from this direction).
castInt8PosToString : String
castInt8PosToString =
  let a : Int8
      a = 100
  in cast a

castInt8NegToString : String
castInt8NegToString =
  let a : Int8
      a = -56
  in cast a

castBits64MaxToString : String
castBits64MaxToString =
  let a : Bits64
      a = 18446744073709551615
  in cast a

-- Small enough for `bindOne` (RC.idr) to resolve straight to an
-- `RCConst` rather than a `bindCompound`-built RLet.
castIntegerSmallToString : String
castIntegerSmallToString =
  let a : Integer
      a = 42
  in cast a

-- Large enough for `bindOne` to go through `bindCompound`'s RLet path
-- instead -- exercises `foldConst`'s RLet-folding branch, not just the
-- direct RCConst-resolution one.
castIntegerBigToString : String
castIntegerBigToString =
  let a : Integer
      a = 123456789012345678901234567890
  in cast a

-- Should NOT be folded: Char as Cast's source into String -- see
-- ConstFold.idr's own foldableOp doc comment for the stripQuotes bug
-- this avoids inheriting from upstream's Core.Primitives.castString.
-- Deliberately a non-ASCII codepoint (above '\DEL'), not just any
-- Char: Show Char's own multi-character numeric escape for such
-- codepoints is exactly what stripQuotes mishandles, so folding this
-- (if the exclusion ever regressed) would produce a visibly different,
-- wrong string instead of silently matching by coincidence.
castCharToStringNotFolded : String
castCharToStringNotFolded =
  let a : Char
      a = 'あ'
  in cast a

-- Should NOT be folded: Double as Cast's source into String -- belt-
-- and-suspenders with `safeConst`'s own `Db` exclusion.
castDoubleToStringNotFolded : String
castDoubleToStringNotFolded =
  let a : Double
      a = 3.999
  in cast a

-- Should NOT be folded: String as Cast's source (either direction) --
-- see rc2/doc/cast-fold-scope.md for why parsing stays out of scope.
castStringToIntegerNotFolded : Integer
castStringToIntegerNotFolded =
  let a : String
      a = "42"
  in cast a

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
  printLn castInt8ToInt64
  printLn castNegativeWiden
  printLn castBits64ToInteger
  printLn castNarrowWrap
  printLn castDoubleNotFolded
  printLn castIntNotFolded
  printLn castCharNotFolded
  putStrLn castInt8PosToString
  putStrLn castInt8NegToString
  putStrLn castBits64MaxToString
  putStrLn castIntegerSmallToString
  putStrLn castIntegerBigToString
  putStrLn castCharToStringNotFolded
  putStrLn castDoubleToStringNotFolded
  printLn castStringToIntegerNotFolded
