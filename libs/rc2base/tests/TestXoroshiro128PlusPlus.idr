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

import System.Random.Xoroshiro128PlusPlus

printSeq : Nat -> IOGen -> IO ()
printSeq Z _ = pure ()
printSeq (S k) g = do
  v <- next g
  printLn v
  printSeq k g

main : IO ()
main = do
  -- Per-instance generator.
  Just g <- newIOGen 42
    | Nothing => putStrLn "newIOGen: allocation failed"
  printSeq 5 g

  -- g has already drawn 5 values above, so this is the 6th step in the
  -- same seed-42 sequence (cross-checked against the reference's
  -- next[5] = 6324094075403496319, converted to [0,1) via /2^64).
  d <- nextDouble g
  printLn d

  -- Single global generator -- same two-step splitmix64 mixing as
  -- newIOGen, so seeding it with 42 reproduces the sequence's own start.
  setSystemSeed 42
  nextIO >>= printLn
  nextIO >>= printLn

  -- newSeeded is entropy-seeded (clock + pid) and therefore
  -- non-deterministic -- only checked for "doesn't crash", not compared
  -- against a fixed value.
  Just eg <- newSeeded
    | Nothing => putStrLn "newSeeded: allocation failed"
  _ <- next eg
  putStrLn "newSeeded: ok"

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
