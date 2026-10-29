module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Data.Seq.RC2: every sequence can be cut anywhere (take, drop) and indexed, and is
-- the list it should be, for every pair of sizes up to 24 joined by (++) whatever
-- way the two were built, and through a long run of mixed operations (what the
-- viewer of termui does with its lines: snoc, (++), and a splice of take ++ new ++
-- drop). contrib's Data.Seq.Unsized fails this (see KNOWN-BUGS.md).

import Data.List
import Data.Maybe
import Data.Seq.RC2 as Q

%default covering

-- `[a .. b]`, empty when `b` is below `a` (`Data.List`'s range counts down).
range : Nat -> Nat -> List Nat
range a b = if a > b then [] else [a .. b]

-- The first thing wrong with the sequence, if anything is.
check : Seq Nat -> List Nat -> Maybe String
check s xs =
  if toList s /= xs then Just "elements"
  else if Q.length s /= length xs then Just "length"
  else case find (\i => toList (Q.take i s) /= take i xs || toList (Q.drop i s) /= drop i xs) (range 0 (length xs + 1)) of
         Just i => Just ("cut at " ++ show i)
         Nothing => case find (\i => Q.index i s /= getAt i xs) (range 0 (length xs)) of
                      Just i => Just ("index " ++ show i)
                      Nothing => Nothing

-- The same elements built three ways.
shapes : List Nat -> List (String, Seq Nat)
shapes xs =
  [ ("fromList", Q.fromList xs)
  , ("snoc", foldl snoc Q.empty xs)
  , ("cons", foldr cons Q.empty xs) ]

pairs : IO ()
pairs = do
  let sizes = [0 .. 24]
  let bad = catMaybes
            [ map (\why => (sa ++ "/" ++ sb, a, b, why)) (check (x ++ y) (range 1 (a + b)))
            | a <- sizes, b <- sizes
            , (sa, x) <- shapes (range 1 a)
            , (sb, y) <- shapes (range (a + 1) (a + b)) ]
  putStrLn ("pairs of sizes up to 24, three ways each: " ++ show (length sizes * length sizes * 9) ++ " joins, wrong: " ++ show (length bad))
  traverse_ (\(w, a, b, why) => putStrLn ("  " ++ w ++ " " ++ show (a, b) ++ ": " ++ why)) (take 5 bad)

-- `x mod m`, `x div m` on Nat
modN : Nat -> Nat -> Nat
modN x m = integerToNat (natToInteger x `mod` natToInteger m)

divN : Nat -> Nat -> Nat
divN x m = integerToNat (natToInteger x `div` natToInteger m)

-- A deterministic stream of numbers.
next : Nat -> Nat
next x = modN (x * 1103515245 + 12345) 2147483648

record St where
  constructor MkSt
  seed : Nat
  fresh : Nat          -- the next element to add
  sq : Seq Nat
  model : List Nat

step : St -> St
step st =
  let r = next st.seed
      op = modN (divN r 65536) 7
      r2 = next r
      n = length st.model
      k = modN (divN r2 65536) 5 + 1              -- how many elements an operation adds
      i = modN (divN r2 4096) (n + 1)
      r3 = next r2
      j = i + modN (divN r3 4096) ((n + 1) `minus` i)
      new = range st.fresh (st.fresh + k `minus` 1)
      st' : St
      st' = { seed := r3, fresh := st.fresh + k } st
  in case op of
       0 => { sq := snoc st.sq st.fresh, model := st.model ++ [st.fresh], fresh := st.fresh + 1 } st'
       1 => { sq := cons st.fresh st.sq, model := st.fresh :: st.model, fresh := st.fresh + 1 } st'
       2 => { sq := st.sq ++ Q.fromList new, model := st.model ++ new } st'
       3 => { sq := Q.fromList new ++ st.sq, model := new ++ st.model } st'
       -- splices in the middle, as the viewer lays a segment out again
       4 => { sq := (Q.take i st.sq ++ Q.fromList new) ++ Q.drop j st.sq
            , model := take i st.model ++ new ++ drop j st.model } st'
       5 => { sq := Q.take i st.sq ++ Q.drop j st.sq, model := take i st.model ++ drop j st.model } st'
       _ => { sq := st.sq ++ Q.fromList (take 40 st.model), model := st.model ++ take 40 st.model } st'

run : Nat -> St -> Nat -> List (Nat, String) -> (Nat, List (Nat, String))
run Z st done bad = (done, reverse bad)
run (S k) st done bad =
  let st' = step st
      bad' = case check st'.sq st'.model of
               Nothing => bad
               Just why => (done, why) :: bad
  in if length st'.model > 300 then run k ({ sq := Q.fromList (take 50 st'.model), model := take 50 st'.model } st') (S done) bad'
     else run k st' (S done) bad'

main : IO ()
main = do
  pairs
  let (steps, bad) = run 600 (MkSt 42 1000 Q.empty []) 0 []
  putStrLn ("mixed operations: " ++ show steps ++ " steps, wrong: " ++ show (length bad))
  traverse_ (\(n, why) => putStrLn ("  step " ++ show n ++ ": " ++ why)) (take 5 bad)
