module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression + known-answer test for System.Random.Xoroshiro128PlusPlus.
-- The values below (seed 42) were cross-checked against a from-scratch
-- local C build of the reference algorithm (rotl/splitmix64 straight off
-- prng.di.unimi.it's own published source, not derived from this
-- module's own C port or its Idris FFI wrapper), so a bug shared between
-- the reference and this port is the only way this test could pass while
-- still being wrong.

import Data.Maybe
import System.Random.Entropy
import System.Random.Xoroshiro128PlusPlus

printSeq : Nat -> IOGen -> IO ()
printSeq Z _ = pure ()
printSeq (S k) g = do
  v <- next g
  printLn v
  printSeq k g

main : IO ()
main = do
  -- The global generator, before any setSystemSeed, starts from the fixed
  -- default state (seed 1): not the all-zero state, which would yield 0 forever.
  Just g1 <- newIOGen 1
    | Nothing => putStrLn "newIOGen: allocation failed"
  d1 <- next g1
  d1' <- nextIO
  putStrLn $ "default global generator is seed 1: " ++ show (d1 == d1' && d1 /= 0)

  -- The largest output maps below 1.0 (cast v / 2^64 would round up to it).
  putStrLn $ "toUnit maxBound < 1: " ++ show (toUnit 0xffffffffffffffff < 1.0)
  putStrLn $ "toUnit 0 == 0: " ++ show (toUnit 0 == 0.0)

  -- Per-instance generator.
  Just g <- newIOGen 42
    | Nothing => putStrLn "newIOGen: allocation failed"
  printSeq 5 g

  -- g has already drawn 5 values above, so this is the 6th step in the
  -- same seed-42 sequence (cross-checked against the reference's
  -- next[5] = 6324094075403496319, converted to [0,1) via its top 53 bits).
  d <- nextDouble g
  printLn d

  -- Single global generator -- same two-step splitmix64 mixing as
  -- newIOGen, so seeding it with 42 reproduces the sequence's own start.
  setSystemSeed 42
  nextIO >>= printLn
  nextIO >>= printLn

  -- newSeeded is seeded from the kernel (getrandom) and therefore
  -- non-deterministic -- not compared against a fixed value; two generators
  -- made one after the other must not give the same stream (they would if
  -- the seed were a clock reading shared by processes started together).
  Just eg <- newSeeded
    | Nothing => putStrLn "newSeeded: allocation failed"
  Just eg2 <- newSeeded
    | Nothing => putStrLn "newSeeded: allocation failed"
  xs <- traverse (\_ => next eg) (the (List Nat) [1 .. 4])
  ys <- traverse (\_ => next eg2) (the (List Nat) [1 .. 4])
  putStrLn "newSeeded: ok"
  putStrLn $ "two newSeeded streams differ: " ++ show (xs /= ys)

  -- the operating system's source itself (POSIX open/read/close of /dev/urandom)
  Just e1 <- entropy64
    | Nothing => putStrLn "entropy64: unavailable"
  Just e2 <- entropy64
    | Nothing => putStrLn "entropy64: unavailable"
  putStrLn $ "two entropy64 draws differ: " ++ show (e1 /= e2)

  -- jump/longJump/jumpN cross-checked against jumpCE's own documented
  -- equivalences (prng.di.unimi.it's reference comment: "jump_ce(1, 64)
  -- is equivalent to jump()", "jump_ce(1, 96) is equivalent to
  -- long_jump()") rather than a second independent reference
  -- implementation of the F2X jump-polynomial arithmetic -- a real bug
  -- in the void*-cast plumbing or in f2x.c would very likely break this
  -- self-consistency too.
  Just ja <- newIOGen 7 | Nothing => putStrLn "jump: allocation failed"
  Just jb <- newIOGen 7 | Nothing => putStrLn "jump: allocation failed"
  jump ja
  jumpCE jb 1 64
  va <- next ja
  vb <- next jb
  printLn (va == vb)

  Just la <- newIOGen 7 | Nothing => putStrLn "longJump: allocation failed"
  Just lb <- newIOGen 7 | Nothing => putStrLn "longJump: allocation failed"
  longJump la
  jumpCE lb 1 96
  vla <- next la
  vlb <- next lb
  printLn (vla == vlb)

  Just na <- newIOGen 7 | Nothing => putStrLn "jumpN: allocation failed"
  Just nb <- newIOGen 7 | Nothing => putStrLn "jumpN: allocation failed"
  jump na
  jumpN nb 0 1  -- n = 0 + 1*2^64 = 2^64
  vna <- next na
  vnb <- next nb
  printLn (vna == vnb)

  -- Same cross-check against the single global generator, plus its own
  -- *IO jump variants agreeing with the per-instance ones from the same
  -- seed (setSystemSeed/newIOGen share the same splitmix64 mixing).
  Just ga <- newIOGen 7 | Nothing => putStrLn "jumpIO: allocation failed"
  jump ga
  vga <- next ga
  setSystemSeed 7
  jumpIO
  vgb <- nextIO
  printLn (vga == vgb)

  -- copyIOGen: the copy must be independent of the original -- mutating
  -- the original after copying must not affect the copy, checked by
  -- comparing the untouched copy against a third, never-touched
  -- generator seeded identically (rather than against the mutated
  -- original itself, which would trivially differ either way).
  Just oa <- newIOGen 99 | Nothing => putStrLn "copyIOGen: allocation failed"
  Just ob <- copyIOGen oa | Nothing => putStrLn "copyIOGen: allocation failed"
  Just oc <- newIOGen 99 | Nothing => putStrLn "copyIOGen: allocation failed"
  _ <- next oa
  _ <- next oa
  vob <- next ob
  voc <- next oc
  printLn (vob == voc)

  -- Raw state: save it, restore it elsewhere, rewind with it.
  Just sa <- newIOGen 7 | Nothing => putStrLn "newIOGen: allocation failed"
  _ <- next sa
  _ <- next sa
  (a0, a1) <- getState sa
  Just sb <- newIOGenFromState a0 a1 | Nothing => putStrLn "newIOGenFromState: failed"
  x <- next sa
  y <- next sb
  rewound <- setState sb a0 a1
  y2 <- next sb
  zeroSet <- setState sb 0 0
  zeroNew <- newIOGenFromState 0 0
  putStrLn ("state restored: " ++ show (x == y) ++ " " ++ show rewound ++ " " ++ show (x == y2))
  putStrLn ("zero state refused: " ++ show (not zeroSet) ++ " " ++ show (isNothing zeroNew))
  setSystemSeed 5
  _ <- nextIO
  (g0, g1) <- getSystemState
  v1 <- nextIO
  okg <- setSystemState g0 g1
  v2 <- nextIO
  zeroSys <- setSystemState 0 0
  putStrLn ("global state restored: " ++ show okg ++ " " ++ show (v1 == v2) ++ " " ++ show (not zeroSys))

  -- The state of a seed agrees across the kinds; a refused state changes nothing;
  -- the two words of the global state are not swapped, at their extremes too.
  Just s42 <- newIOGen 42 | Nothing => putStrLn "newIOGen: allocation failed"
  (p0, p1) <- getState s42
  putStrLn ("seed 42 state agrees with Gen: " ++ show ((p0, p1) == genState (mkGen 42)))
  case genFromState p0 p1 of
    Nothing => putStrLn "genFromState: refused"
    Just gg => do
      vi <- next s42
      putStrLn ("IOGen state continues as Gen: " ++ show (vi == fst (genNext gg)))
  Just sr <- newIOGen 9 | Nothing => putStrLn "newIOGen: allocation failed"
  before <- getState sr
  _ <- setState sr 0 0
  after <- getState sr
  setSystemSeed 9
  sysBefore <- getSystemState
  _ <- setSystemState 0 0
  sysAfter <- getSystemState
  putStrLn ("refused state changes nothing: " ++ show (before == after) ++ " " ++ show (sysBefore == sysAfter))
  setSystemSeed 42
  sys42 <- getSystemState
  putStrLn ("global state agrees with seed 42: " ++ show (sys42 == (p0, p1)))
  _ <- setSystemState 0xFFFFFFFFFFFFFFFF 1
  st1 <- getSystemState
  Just e1 <- newIOGenFromState 0xFFFFFFFFFFFFFFFF 1 | Nothing => putStrLn "newIOGenFromState: failed"
  w1 <- nextIO
  w2 <- next e1
  _ <- setSystemState 0 0xFFFFFFFFFFFFFFFF
  st2 <- getSystemState
  putStrLn ("global words: " ++ show (st1 == (0xFFFFFFFFFFFFFFFF, 1)) ++ " " ++ show (st2 == (0, 0xFFFFFFFFFFFFFFFF)) ++ " " ++ show (w1 == w2))
