module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Criterion A eligibility is judged on the callee's own rewritten body,
-- callees first (rc2/doc/inlining.md, "Eligibility: Criterion A"). The
-- driver functions are loops over a runtime count so the callers stay
-- real functions; check.sh asserts on their dumped bodies.

-- A chain: h is call-free, g calls only h, f calls only g.
h : Int -> Int
h x = x * 2 + 1

g : Int -> Int
g x = h x + h (x + 1)

f : Int -> Int
f x = g x * 3 - g (x - 1)

chainLoop : Nat -> Int -> Int
chainLoop Z acc = acc
chainLoop (S k) acc = chainLoop k (f acc `mod` 1000003)

-- Self-recursion and a mutually recursive pair: never inlined.
selfRec : Int -> Int
selfRec x = if x <= 0 then 0 else x + selfRec (x - 1)

mutual
  isEv : Nat -> Bool
  isEv Z = True
  isEv (S k) = isOd k

  isOd : Nat -> Bool
  isOd Z = False
  isOd (S k) = isEv k

cycleLoop : Nat -> Int -> Int
cycleLoop Z acc = acc
cycleLoop (S k) acc = cycleLoop k (acc + selfRec 5 + (if isEv k then 1 else 0) + (if isOd k then 2 else 0))

-- Each piece is small; the rewritten body of `big` is not.
piece : Int -> Int
piece x = (x + 1) * (x + 2) + (x + 3) * (x + 4)

big : Int -> Int
big x = piece x + piece (x + 5)

bigLoop : Nat -> Int -> Int
bigLoop Z acc = acc
bigLoop (S k) acc = bigLoop k ((big acc + big (acc + 1)) `mod` 1000003)

-- `<=` composed from `compare` and `/=`.
leqInt : Int -> Int -> Bool
leqInt x y = compare x y /= GT

leqNat : Nat -> Nat -> Bool
leqNat x y = compare x y /= GT

cmpLoop : Nat -> Int -> Int
cmpLoop Z acc = acc
cmpLoop (S k) acc =
    cmpLoop k (acc + (if leqInt (cast k) 50 then 1 else 0) + (if leqNat k 50 then 10 else 0))

main : IO ()
main = do
    printLn (chainLoop 1000 7)
    printLn (chainLoop 500 9)
    printLn (cycleLoop 100 0)
    printLn (cycleLoop 50 1)
    printLn (bigLoop 1000 3)
    printLn (bigLoop 400 5)
    printLn (cmpLoop 100 0)
    printLn (cmpLoop 60 1)
