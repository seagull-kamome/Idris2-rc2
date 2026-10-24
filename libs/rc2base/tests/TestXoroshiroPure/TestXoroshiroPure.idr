module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for the pure `Gen` of System.Random.Xoroshiro128PlusPlus
-- and System.Random.Xoroshiro64StarStar: the same seed must give the
-- same sequence as the IOGen (whose known answers the sibling tests
-- check), and each jump variant must land on the IOGen's state.

import Data.List
import System.Random.Xoroshiro128PlusPlus as R128
import System.Random.Xoroshiro64StarStar as R64

%default covering

-- The first `n` outputs of a pure generator, and the generator after them.
take128 : Nat -> R128.Gen -> (List Bits64, R128.Gen)
take128 Z g = ([], g)
take128 (S k) g = let (v, g') = R128.genNext g
                      (vs, g'') = take128 k g'
                  in (v :: vs, g'')

take64 : Nat -> R64.Gen -> (List Bits32, R64.Gen)
take64 Z g = ([], g)
take64 (S k) g = let (v, g') = R64.genNext g
                     (vs, g'') = take64 k g'
                 in (v :: vs, g'')

io128 : Nat -> R128.IOGen -> IO (List Bits64)
io128 Z _ = pure []
io128 (S k) g = do v <- R128.next g
                   vs <- io128 k g
                   pure (v :: vs)

io64 : Nat -> R64.IOGen -> IO (List Bits32)
io64 Z _ = pure []
io64 (S k) g = do v <- R64.next g
                  vs <- io64 k g
                  pure (v :: vs)

-- After `pre` outputs and then `step` on the IOGen, and the same on the
-- Gen, the next 8 outputs agree.
same128 : String -> Bits64 -> Nat -> (R128.IOGen -> IO ()) -> (R128.Gen -> R128.Gen) -> IO ()
same128 name seed pre step pureStep = do
  Just g <- R128.newIOGen seed | Nothing => putStrLn (name ++ ": allocation failed")
  _ <- io128 pre g
  step g
  expected <- io128 8 g
  printLn (name ++ ": " ++ show (expected == fst (take128 8 (pureStep (snd (take128 pre (R128.mkGen seed)))))))

same64 : String -> Bits64 -> Nat -> (R64.IOGen -> IO ()) -> (R64.Gen -> R64.Gen) -> IO ()
same64 name seed pre step pureStep = do
  Just g <- R64.newIOGen seed | Nothing => putStrLn (name ++ ": allocation failed")
  _ <- io64 pre g
  step g
  expected <- io64 8 g
  printLn (name ++ ": " ++ show (expected == fst (take64 8 (pureStep (snd (take64 pre (R64.mkGen seed)))))))

main : IO ()
main = do
  putStrLn "--- Testing the pure Gen ---"

  -- Known answers: the seed-42 sequences of the IOGen tests.
  printLn (fst (take128 5 (R128.mkGen 42)))
  printLn (fst (take64 5 (R64.mkGen 42)))

  -- A long run agrees with the IOGen.
  Just a <- R128.newIOGen 1 | Nothing => putStrLn "allocation failed"
  xs <- io128 20000 a
  printLn (xs == fst (take128 20000 (R128.mkGen 1)))
  Just b <- R64.newIOGen 1 | Nothing => putStrLn "allocation failed"
  ys <- io64 20000 b
  printLn (ys == fst (take64 20000 (R64.mkGen 1)))

  -- The generator after a run is the continuation of the sequence.
  let (_, g128) = take128 100 (R128.mkGen 5)
  Just c <- R128.newIOGen 5 | Nothing => putStrLn "allocation failed"
  _ <- io128 100 c
  cNext <- R128.next c
  printLn (cNext == fst (R128.genNext g128))

  -- Jumps, from a fresh state and from one a few steps in, with edge seeds
  -- and distances (e = 0, n1 = 0, top bit of n0 set).
  same128 "jump128" 7 0 R128.jump R128.genJump
  same128 "jump128 after steps" 0xffffffffffffffff 5 R128.jump R128.genJump
  same128 "longJump128" 7 0 R128.longJump R128.genLongJump
  same128 "longJump128 seed 0" 0 3 R128.longJump R128.genLongJump
  same128 "jumpCE128" 7 0 (\g => R128.jumpCE g 3 70) (\g => R128.genJumpCE g 3 70)
  same128 "jumpCE128 e=0" 7 4 (\g => R128.jumpCE g 1000 0) (\g => R128.genJumpCE g 1000 0)
  same128 "jumpN128" 7 0 (\g => R128.jumpN g 123456789 5) (\g => R128.genJumpN g 123456789 5)
  same128 "jumpN128 n1=0" 7 2 (\g => R128.jumpN g 0x8000000000000001 0) (\g => R128.genJumpN g 0x8000000000000001 0)
  same64 "jump64" 7 0 R64.jump R64.genJump
  same64 "jump64 after steps" 0xffffffffffffffff 5 R64.jump R64.genJump
  same64 "longJump64" 7 0 R64.longJump R64.genLongJump
  same64 "longJump64 seed 0" 0 3 R64.longJump R64.genLongJump
  same64 "jumpCE64" 7 0 (\g => R64.jumpCE g 3 40) (\g => R64.genJumpCE g 3 40)
  same64 "jumpCE64 e=0" 7 4 (\g => R64.jumpCE g 1000 0) (\g => R64.genJumpCE g 1000 0)
  same64 "jumpN64" 7 0 (\g => R64.jumpN g 123456789) (\g => R64.genJumpN g 123456789)
  same64 "jumpN64 top bit" 7 2 (\g => R64.jumpN g 0x8000000000000001) (\g => R64.genJumpN g 0x8000000000000001)

  -- jumpN of a small distance is that many steps (independent of the jump polynomials).
  printLn (fst (take128 8 (R128.genJumpN (R128.mkGen 21) 1000 0)) == fst (take128 8 (snd (take128 1000 (R128.mkGen 21)))))
  printLn (fst (take64 8 (R64.genJumpN (R64.mkGen 21) 1000)) == fst (take64 8 (snd (take64 1000 (R64.mkGen 21)))))

  -- A generator is a value: stepping it does not change it, so two
  -- branches from one state see the same sequence.
  let g0 = R128.mkGen 9
  let (xs0, _) = take128 4 g0
  let (_, g1) = R128.genNext g0
  let (xs1, _) = take128 4 g0
  let (ys, _) = take128 3 g1
  printLn (xs0 == xs1 && drop 1 xs0 == ys)

  -- genNextDouble equals nextDouble of the IOGen, step for step.
  Just dg <- R128.newIOGen 11 | Nothing => putStrLn "allocation failed"
  d1 <- R128.nextDouble dg
  d2 <- R128.nextDouble dg
  let (e1, h1) = R128.genNextDouble (R128.mkGen 11)
  let (e2, _) = R128.genNextDouble h1
  printLn (d1 == e1 && d2 == e2)
  Just dg' <- R64.newIOGen 11 | Nothing => putStrLn "allocation failed"
  f1 <- R64.nextDouble dg'
  f2 <- R64.nextDouble dg'
  let (k1, m1) = R64.genNextDouble (R64.mkGen 11)
  let (k2, _) = R64.genNextDouble m1
  printLn (f1 == k1 && f2 == k2)

  -- nextDouble stays in [0,1).
  let ds128 = go128 1000 (R128.mkGen 3)
  let ds64 = go64 1000 (R64.mkGen 3)
  printLn (all (\d => d >= 0.0 && d < 1.0) (ds128 ++ ds64))

  putStrLn "--- Tests finished ---"
  where
    go128 : Nat -> R128.Gen -> List Double
    go128 Z _ = []
    go128 (S k) g = let (d, g') = R128.genNextDouble g in d :: go128 k g'
    go64 : Nat -> R64.Gen -> List Double
    go64 Z _ = []
    go64 (S k) g = let (d, g') = R64.genNextDouble g in d :: go64 k g'
