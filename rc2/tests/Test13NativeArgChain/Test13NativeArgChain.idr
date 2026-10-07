module Main

import System

import Data.Bits

-- Regression test for a gap in Compiler.RC2.Loop's `nativeArgTypes`
-- (shared by Compiler.RC2.DualABI's own worker-parameter eligibility):
-- `opNativeUsesThrough` only looked for a top-level parameter directly
-- inside the *value* of an `RNative`/`RInlineNative`-typed `RLet` --
-- when a multi-operation chain (ANF-normalized into nested `RLet`s)
-- put the parameter's own read in an *inner* let's `body` instead
-- (its own final operation), that read was invisible to the scan, so
-- the parameter stayed `RBoxed` regardless of how it was actually
-- used. `chain`'s own body below is exactly that shape: a two-
-- operation chain (`cast` then `xor`) mirroring a textbook hash-step
-- update. Fixed by having `opNativeUsesThrough` also recurse through a
-- nested `RLet`'s own `body`, still gated by the *outer* `RLet`'s
-- already-decided native `Rep` (unchanged: `flat` below, whose whole
-- body is a single, *unguarded* `ROp` with no enclosing `let` at all,
-- deliberately stays `RBoxed` -- an earlier, broader fix that treated
-- any bare `ROp` as native regardless of context caused a real,
-- `valgrind`-caught leak in Test110Loop/SelfTailLoop.idr; see
-- rc2/doc/native-type-inference.md and TODO.md's git history for the
-- full investigation, which originally misattributed this gap to a
-- newtype-style constructor wrapper -- ruled out by reproducing with a
-- plain Bits64 parameter, no constructor involved at all).
--
-- Values are deliberately pushed well outside the small-int cache
-- range ([0,100), immortal) so a real heap allocation -- and a real
-- leak if this fix's own ownership-stripping ever regresses -- is
-- unavoidable; verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".
--
-- Also covers Compiler.RC2.DualABI's own call-argument promotion
-- (Stage 4's RLet clause, via `callArgNativeReads` -- formerly a
-- separate Test56NativeCallArgChain.idr, merged in below as
-- `chainCallArg`/`addAbsCallArg`): when an RLet-bound worker call's
-- result is consumed only as *another* worker's own native argument --
-- not an ROp/comparison operand, the case `nativeArgTypes`/
-- `bareTailNativeReads` already covered -- the intermediate value
-- should still be promoted straight to native, skipping the
-- box-then-immediately-unbox round trip. `addAbsCallArg`'s own body
-- isn't Compiler.RC2.Inline-eligible (it calls an FFI declaration, so
-- `isCallFree` is False), so its call from `chainCallArg` below
-- survives to exercise DualABI's own worker call-site rewriting
-- instead of being spliced away entirely before DualABI ever runs.
-- Its own first parameter, `x`, only becomes native-eligible via the
-- nested-RLet-`body` fix this file's own `chain` above covers (`x +
-- ...` sits inside a further `let`'s own body, not directly as an
-- outer RLet's value) -- deliberately reusing that same shape here so
-- `addAbsCallArg` genuinely has a *native* argument position for
-- `chainCallArg`'s own call-argument promotion to target.

chain : Bits64 -> Bits8 -> Bits64
chain v b = (v `xor` cast b) * 0x100000001b3

-- Deliberately still RBoxed (see above) -- kept as a control so a
-- future change to this analysis that starts promoting it is a
-- visible prompt to re-check the Test110Loop/SelfTailLoop.idr hazard, not a
-- silent behaviour change.
flat : Bits64 -> Bits64 -> Bits64
flat v k = v * k

loop : Bits64 -> List Bits8 -> Bits64
loop acc [] = acc
loop acc (b :: bs) = loop (chain acc b) bs

%foreign "C:llabs,libc,stdlib.h"
prim__abs : Int -> Int

%foreign "C:labs,libc,stdlib.h"
prim__labs : Int -> Int

-- `prim__abs x`'s own result is bound here only to be fed straight
-- into `addAbsCallArg`'s native first argument -- exactly the shape
-- that used to box then immediately unbox again.
addAbsCallArg : Int -> Int -> Int
addAbsCallArg x y = (x + prim__labs y) * 2

chainCallArg : Int -> Int -> Int
chainCallArg x y = addAbsCallArg (prim__abs x) y + 1

-- Also covers Compiler.RC2.DualABI's own constant-`case` scrutinee
-- promotion (`constCaseScrutineeNativeReads`), the fourth read source
-- Stage 4 gained after the three above. `scaledAbs`'s own worker
-- returns a native `int64_t`, and `classify` reads that result *only*
-- as a constant-`case` scrutinee: not an ROp operand, not a bare tail,
-- not another worker's argument -- so none of the earlier three ever
-- saw it and the result was boxed on the way out of the call, unboxed
-- again by the dispatch, and dropped (a no-op) in every arm.
-- `Compiler.RC2.Emit`'s own `emitConstCaseInto` has rendered a native
-- scrutinee per its own `Rep` since `Compiler.RC2.Loop`'s native-shadow
-- promotion needed it; only the eligibility question was missing.
--
-- Both callees call an FFI declaration, so `Compiler.RC2.Inline`'s own
-- `isCallFree` is False for each and the call genuinely survives to
-- Stage 4 instead of being spliced away first -- the same precaution
-- `addAbsCallArg` above takes. Each also needs a *second* caller, or
-- `Compiler.RC2.LateInline`'s own single-caller inlining splices it
-- into its one call site and there is no worker call left to promote
-- at all -- hence the `*Neg` pair below rather than one caller each.
scaledAbs : Int -> Int
scaledAbs x = prim__labs x * 2

classify : Int -> String
classify x = case scaledAbs x of
                  0 => "zero"
                  2 => "two"
                  _ => "other"

classifyNeg : Int -> String
classifyNeg x = case scaledAbs (0 - x) of
                     0 => "n-zero"
                     2 => "n-two"
                     _ => "n-other"

-- The same shape one type down, and by far its most common instance in
-- real code: rc2 renders Idris2's own `Bool` as `Bits8`, so a
-- Bool-returning worker feeding an `if` is exactly this pattern (114 of
-- the 118 promotions this closes, across a whole idris2-lsp build, are
-- this one).
isBig : Int -> Bool
isBig x = prim__labs x > 1000

describe : Int -> String
describe x = if isBig x then "big" else "small"

describeNeg : Int -> String
describeNeg x = if isBig (0 - x) then "n-big" else "n-small"

-- And the branching-value promotion (`branchValueNativeType`): `&&`
-- desugars to `if isBig x then isBig y else False`, so the value bound
-- here is a *branch* whose arms are a native worker call and a native
-- constant -- not a single worker call, which is all Stage 4's own
-- promotion used to recognise. C has no expression form for a `case`,
-- so a Boxed slot for it costs one box PER ARM plus the consumer's own
-- unbox; a native slot costs none. This is verbatim the shape
-- `Prelude.Show`'s own `showPrec` produces (`d >= App && firstCharIs
-- ...`), which is why it is the single most common instance of it.
describeBoth : Int -> Int -> String
describeBoth x y = if isBig x && isBig y then "both" else "not-both"

-- Bool-producing comparison results (`Integer`/`String`): a `case` on
-- one is now a fused `cmp` over Boxed operands, so no Bool local exists
-- there at all; where one is still let-bound, `let v : Boxed = op <Integer ..` binds an
-- `Int8` immediate (`mkBool`), so `Compiler.RC2.RC`'s
-- `alwaysUnboxedBoxedLocalsR` treats the local like an `alwaysUnboxed`
-- operand: no `dup`, no `drop`, however it is used (doc/native-type-
-- inference.md, "Bool-producing comparison results"). check.sh asserts
-- none is left in the `boolcmp*` definitions; the outputs below check
-- the uses that make the elision matter: `if`, `&&`/`||`/`not`, stored
-- in a constructor, returned to unknown code, a Boolean loop
-- accumulator, and a closure result.
boolcmpIf : Integer -> Integer -> String
boolcmpIf a b = if a < b then "lt" else "ge"

boolcmpTwice : Integer -> Integer -> (Bool, Bool)
boolcmpTwice a b = let c = a <= b in (c, not c)

boolcmpStr : String -> String -> Bool
boolcmpStr a b = a == b

boolcmpMix : Integer -> Integer -> String -> String -> Bool
boolcmpMix a b s t = (a < b && s == t) || a > 10 || not (s >= t)

boolcmpAcc : Integer -> List Integer -> Bool -> Bool
boolcmpAcc k [] acc = acc
boolcmpAcc k (x :: xs) acc = boolcmpAcc k xs (acc && x < k)

boolcmpMap : Integer -> List Integer -> List Bool
boolcmpMap k xs = map (\x => x >= k) xs

-- A value the compiler cannot fold away, so the calls below keep their
-- comparisons.
opaqueK : Integer
opaqueK = natToInteger (length (unpack (show (the Integer 1234))))

boolcmps : List String
boolcmps =
    [ boolcmpIf 1 2, boolcmpIf 2 1, boolcmpIf 3 3
    , show (boolcmpTwice 1 2), show (boolcmpTwice 2 1)
    , show (boolcmpStr "ab" "ab"), show (boolcmpStr "ab" "ba")
    , show (boolcmpMix 1 2 "x" "x"), show (boolcmpMix 20 2 "x" "y")
    , show (boolcmpMix 1 2 "x" "y"), show (boolcmpMix 1 2 "y" "x")
    , show (boolcmpAcc 100 [1, 2, 3] True), show (boolcmpAcc 100 [1, 200, 3] True)
    , show (boolcmpMap 2 [1, 2, 3])
    , show (boolcmpAcc 18446744073709551616 [18446744073709551615] True)
    , show (boolcmpTwice opaqueK 3), show (boolcmpTwice 5 opaqueK)
    , show (boolcmpStr (pack (unpack "ab")) "ab"), show (boolcmpMap opaqueK [3, 4, 5])
    ]

-- Bool return (doc/dual-abi.md, "Bool return"): a function whose every
-- tail is a `Bool` producer (a literal, a comparison, or a saturated
-- call to another such function) gets a worker returning a native
-- `Bits8`, so callers branching on the result skip the box/unbox and the
-- arm-start drop of the 0/1 scrutinee. check.sh asserts the `ret=
-- Native Bits8` workers and that `--directive noboolret` has none of
-- them. The shapes: a self-recursive `==` on a tree (an `Integer`
-- comparison tail, a non-tail call as the `&&` condition, a tail
-- call into a loop), a delegation chain `f x y = g x y` through two
-- functions that also have their own producer tails, a tail mixing
-- literals, native and `String` comparisons and calls, a `Bool` out
-- of `case`, a deep non-tail recursion, and a `Bool` function used
-- through a closure (`filter`, so the Boxed wrapper path).
data BTree = BLeaf Integer | BNode BTree BTree

eqBTree : BTree -> BTree -> Bool
eqBTree (BLeaf a) (BLeaf b) = a == b
eqBTree (BNode l1 r1) (BNode l2 r2) = eqBTree l1 l2 && eqBTree r1 r2
eqBTree _ _ = False

-- Self tail call (a loop) with a native-comparison exit.
brCountLt : Int -> Int -> Bool
brCountLt a b = if a <= 0 then b > 0 else brCountLt (a - 1) (b - 1)

-- Delegation chain: `brDelegA` is only a call; `brDelegB` has its own
-- literal tail and a call; both end in the loop above.
brDelegB : Int -> Int -> Bool
brDelegB x y = if x == 77 then True else brCountLt x y

brDelegA : Int -> Int -> Bool
brDelegA x y = brDelegB y x

-- Two more call-tail functions (no producer of their own beyond the
-- callees'): a branch of calls, and a pure delegation of it.
brSel : Int -> BTree -> BTree -> Bool
brSel k t u = if k > 3 then eqBTree t u else brCountLt 1 k

brSel2 : Int -> BTree -> BTree -> Bool
brSel2 k t u = brSel (k + 1) u t

-- Literals, an `Integer` comparison, a `String` comparison and calls in
-- one tail set, through a `case`.
brMixed : Integer -> String -> Integer -> Bool
brMixed 0 _ _ = False
brMixed n s m = case compare n m of
                     LT => s == "lt"
                     EQ => True
                     GT => brMixed (n - 1) s m && s >= "b"

-- `&&`/`||` chains over calls and comparisons.
brChain : Integer -> BTree -> BTree -> Bool
brChain k t u = (eqBTree t u || k < 0) && not (k == 99) && (brDelegA 1 2 || k >= 5)

-- A deep non-tail recursion (the depth is the C stack's).
brDeepNot : Int -> Bool
brDeepNot 0 = False
brDeepNot n = not (brDeepNot (n - 1))

brSample : List BTree
brSample = [BLeaf 1, BNode (BLeaf 1) (BLeaf 2), BNode (BLeaf 1) (BLeaf 3), BLeaf 100000000000000000000]

brs : List String
brs =
    [ show (eqBTree (BNode (BLeaf 1) (BLeaf 2)) (BNode (BLeaf 1) (BLeaf 2)))
    , show (eqBTree (BNode (BLeaf 1) (BLeaf 2)) (BNode (BLeaf 1) (BLeaf 3)))
    , show (eqBTree (BLeaf 100000000000000000000) (BLeaf 100000000000000000000))
    , show (eqBTree (BLeaf 1) (BNode (BLeaf 1) (BLeaf 1)))
    , show (map (\t => eqBTree t (BNode (BLeaf 1) (BLeaf 2))) brSample)
    , show (length (filter (eqBTree (BLeaf 1)) brSample))
    , show [brCountLt 5 7, brCountLt 5 3, brCountLt 0 1, brCountLt 0 0]
    , show (brDelegA 3 77, brDelegA 3 4, brDelegA 4 3)
    , show [brMixed 0 "a" 1, brMixed 1 "lt" 2, brMixed 2 "x" 2, brMixed 3 "b" 1, brMixed 3 "a" 1]
    , show [brChain 1 (BLeaf 1) (BLeaf 1), brChain 99 (BLeaf 1) (BLeaf 1), brChain (-1) (BLeaf 1) (BLeaf 2), brChain 1 (BLeaf 1) (BLeaf 2)]
    , show [brSel2 1 (BLeaf 1) (BLeaf 1), brSel2 5 (BLeaf 1) (BLeaf 1), brSel2 5 (BLeaf 1) (BLeaf 2), brSel2 (-3) (BLeaf 1) (BLeaf 2)]
    , show (brDeepNot 50000, brDeepNot 50001)
    ]

-- Typed-constant case scrutinees (doc/native-type-inference.md): a `case`
-- on `Bits8`/enum constants with a default branch. The scrutinee is a
-- tagged immediate (no refcount) but NOT a 0/1 Bool: 2 and 255 must take
-- the default branch, never an "other of 0/1" one.
tcOne : Bits8 -> String
tcOne x = case x of
               1 => "one"
               _ => "other"

tcZero : Bits8 -> String
tcZero x = case x of
                0 => "zero"
                _ => "nonzero"

tcThree : Bits8 -> String
tcThree x = case x of
                 0 => "z"
                 1 => "o"
                 _ => "many"

data TcBox = MkTcBox Bits8 Int String

-- The scrutinee is a constructor field (Boxed, read from a heap cell).
tcField : TcBox -> String
tcField (MkTcBox x n s) = case x of
                               1 => s ++ show n
                               _ => "f" ++ s ++ show (n + 1)

tcFieldZ : TcBox -> String
tcFieldZ (MkTcBox x n s) = case x of
                                0 => "z" ++ s
                                _ => "nz" ++ show n

-- The same scrutinee read from a list of boxes by a self-recursive
-- function with two callers (so it is neither inlined nor folded): the
-- `Bits8` field is a Boxed local read from a heap cell.
tcFields : List TcBox -> List String -> List String
tcFields [] acc = reverse acc
tcFields (MkTcBox x n s :: rest) acc =
    tcFields rest ((case x of
                         1 => s ++ show n
                         _ => "f" ++ s ++ show (n + 1)) :: acc)

-- Constructor reuse with an always-unboxed field: the `Bits8` field is
-- scrutinised, so it takes no part in the reuse offer's dup/drop lists
-- (the other fields do). Shared (`bs` used twice) and unique inputs.
tcBump : TcBox -> TcBox
tcBump (MkTcBox x n s) = case x of
                              1 => MkTcBox 7 (n + 1) s
                              _ => MkTcBox (x + 1) n s

-- The scrutinee is a Boxed call result (a `Bits8` read out of a list).
tcHead : List Bits8 -> Bits8
tcHead (x :: _) = x
tcHead [] = 0

tcUse : List Bits8 -> String
tcUse xs = case tcHead xs of
                1 => "H1"
                _ => "Hn" ++ show (length xs)

tcUseZ : List Bits8 -> String
tcUseZ xs = case tcHead xs of
                 0 => "HZ"
                 _ => "HN" ++ show (length xs)

data TcColor = TcRed | TcGreen | TcBlue | TcBlack

-- A `Bits8` parameter scrutinised with a default branch in a self-recursive
-- function with two callers (so it keeps its own worker/loop): 2 and 255
-- must take the default branch.
tcP1 : Bits8 -> Nat -> String
tcP1 x Z = case x of
                1 => "p1"
                _ => "po"
tcP1 x (S k) = tcP1 x k

tcP0 : Bits8 -> Nat -> String
tcP0 x Z = case x of
                0 => "q0"
                _ => "qn"
tcP0 x (S k) = tcP0 x k

-- An enum with more than two constructors, chosen at run time.
tcPick : Bits8 -> TcColor
tcPick 0 = TcRed
tcPick 1 = TcGreen
tcPick 2 = TcBlue
tcPick _ = TcBlack

-- A loop-carried `Bits8` (wraps past 255) tested with a default branch.
tcLoop : Bits8 -> Int -> Int -> Int
tcLoop x 0 acc = acc
tcLoop x k acc = case x of
                      1 => tcLoop (x + 100) (k - 1) (acc + 1000)
                      _ => tcLoop (x + 100) (k - 1) (acc + cast x)

-- Matched with a default branch.
tcColor : TcColor -> String
tcColor c = case c of
                 TcGreen => "g"
                 TcBlack => "k"
                 _ => "other"

tcColorNext : TcColor -> TcColor
tcColorNext TcRed = TcGreen
tcColorNext TcGreen = TcBlue
tcColorNext TcBlue = TcBlack
tcColorNext TcBlack = TcRed

-- `z` is 0, but only known at run time (no argument besides the program
-- name), so none of this is constant-folded away.
tcs : Bits8 -> List String
tcs z =
    [ show [ case z + 2 of { 1 => "i1"; _ => "io" }, case z + 255 of { 1 => "i1"; _ => "io" }
           , case z + 2 of { 0 => "j0"; _ => "jn" }, case z + 255 of { 0 => "j0"; _ => "jn" }
           , case z of { 1 => "i1"; _ => "io" }, case z of { 0 => "j0"; _ => "jn" } ]
    , show (map tcOne [z, z + 1, z + 2, z + 255])
    , show (map tcZero [z, z + 1, z + 2, z + 255])
    , show (map tcThree [z, z + 1, z + 2, z + 255])
    , show (map (\x => tcField (MkTcBox x 5 "s")) [z, z + 1, z + 2, z + 255])
    , show (map (\x => tcFieldZ (MkTcBox x 7 "t")) [z, z + 1, z + 2, z + 255])
    , show (tcFields (map (\x => MkTcBox x 5 "s") [z, z + 1, z + 2, z + 255]) [])
    , show (tcFields (map (\x => MkTcBox x 9 "u") [z + 1, z + 200]) [])
    , let bs = [MkTcBox z 5 "a", MkTcBox (z + 1) 5 "b", MkTcBox (z + 255) 5 "c"]
      in show (map (tcField . tcBump) bs, map tcField bs)
    , show (map (tcField . tcBump) (map (\x => MkTcBox x 9 "u") [z, z + 1, z + 255]))
    , show (map tcUse [[z + 1, z], [z + 2], [z + 255, z, z], []])
    , show (map tcUseZ [[z + 1, z], [z + 2], [z + 255, z, z], [z]])
    , show [tcLoop (z + 1) 3 0, tcLoop (z + 2) 3 0, tcLoop (z + 255) 4 0]
    , show (map (tcColor . tcColorNext) [TcRed, TcGreen, TcBlue, TcBlack])
    , show (map (tcColor . tcPick) [z, z + 1, z + 2, z + 3, z + 9])
    , show [tcP1 (z + 1) 2, tcP1 (z + 2) 1, tcP1 (z + 255) 0, tcP1 z 3, tcP1 (z + 1) 0]
    , show [tcP0 z 2, tcP0 (z + 2) 1, tcP0 (z + 255) 0, tcP0 (z + 1) 3, tcP0 z 0]
    ]

main : IO ()
main = do
    printLn (loop 0xcbf29ce484222325 [1,2,3,4,5,6,7,8,9,10])
    printLn (flat 0xdeadbeef00000001 0x100000001b3)
    printLn (chainCallArg (-123456) 654321)
    putStrLn (classify 0)
    putStrLn (classify (-1))
    putStrLn (classify 7)
    putStrLn (classifyNeg 1)
    putStrLn (describe 2000)
    putStrLn (describe (-3))
    putStrLn (describeNeg (-5000))
    putStrLn (describeBoth 2000 3000)
    putStrLn (describeBoth 2000 1)
    traverse_ putStrLn boolcmps
    traverse_ putStrLn brs
    args <- getArgs
    traverse_ putStrLn (tcs (cast (length args) - 1))
