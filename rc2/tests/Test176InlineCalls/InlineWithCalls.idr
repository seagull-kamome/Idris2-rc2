module Test176InlineCalls.InlineWithCalls

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Criterion A' (rc2/doc/inlining.md): a small body with calls is spliced too, so the caller
-- sees what the callee calls. `viaTwice` calls `shrink`, which is recursive and so never inlined;
-- `bigCalls` has the same shape but is over the bound. check.sh counts the calls of each in the IR,
-- with and without --directive noinlinecalls. The drivers are loops over a runtime count so the
-- callers stay real functions.

shrink : Int -> Int
shrink x = if x <= 0 then 0 else 1 + shrink (x - 1)

viaTwice : Int -> Int
viaTwice x = shrink (shrink x) + 1

bigCalls : Int -> Int
bigCalls x = shrink (x + 1) + shrink (x + 2) + shrink (x + 3) + shrink (x + 4) + shrink (x + 5) + shrink (x + 6)

loopA : Nat -> Int -> Int
loopA Z acc = acc
loopA (S k) acc = loopA k (viaTwice (acc `mod` 50) + viaTwice (acc `mod` 7))

loopB : Nat -> Int -> Int
loopB Z acc = acc
loopB (S k) acc = loopB k ((bigCalls (acc `mod` 50) + bigCalls (acc `mod` 7)) `mod` 1000)

export
run : Nat -> IO ()
run n = do
  printLn (loopA n 7)
  printLn (loopB n 3)
