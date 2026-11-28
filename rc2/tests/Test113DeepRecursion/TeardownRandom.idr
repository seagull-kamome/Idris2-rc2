module Test113DeepRecursion.TeardownRandom

-- Random shapes for the runtime's teardown, which walks an earlier field
-- with children without recursing (idris2rc2_teardownWaiting in
-- support/rc2/idris2rc2_memory.c). TeardownShapes has the long chains,
-- each a fixed shape; this has bushy values built at random from
-- constructors of one to five fields, the child that is still to be walked
-- in any of them, closures, lazy cells and IORefs (holding a value with
-- children or a string), strings between fields, and subtrees that the
-- value shares with a list kept alive across its drop. Each is a hundred
-- thousand nodes, built bottom-up on an explicit stack so building takes
-- no C stack, and dies in one drop. verify.sh runs it under valgrind,
-- which reports a cell freed twice, read after it was freed or never freed.

import Data.IORef

data T = L Int
       | N1 T
       | N2 T T
       | N3 T T T
       | N4 T T T T
       | N5 Int T T T T
       | S String T
       | F (Int -> Int) T
       | Z (Lazy T) T
       | R (IORef T) T
       | M T String T
       | Q (IORef String) T

top : T -> Int
top (L k) = k
top (N1 _) = 1
top (N2 _ _) = 2
top (N3 _ _ _) = 3
top (N4 _ _ _ _) = 4
top (N5 k _ _ _ _) = k
top (S s _) = cast (length s)
top (F f _) = f 0
top (Z _ _) = 8
top (R _ _) = 9
top (M _ s _) = cast (length s)
top (Q _ _) = 10

-- A closure that holds a subtree.
holding : T -> Int -> Int
holding t x = x + top t

-- Only for the shared subtrees, which are small.
sumT : T -> Int
sumT (L k) = k
sumT (N1 a) = 1 + sumT a
sumT (N2 a b) = sumT a + sumT b
sumT (N3 a b c) = sumT a + sumT b + sumT c
sumT (N4 a b c d) = sumT a + sumT b + sumT c + sumT d
sumT (N5 k a b c d) = k + sumT a + sumT b + sumT c + sumT d
sumT (S s a) = cast (length s) + sumT a
sumT (F f a) = f 0 + sumT a
sumT (Z l a) = sumT l + sumT a
sumT (R _ a) = sumT a
sumT (M a s b) = sumT a + cast (length s) + sumT b
sumT (Q _ a) = sumT a

next : Int -> Int
next s = (s * 1103515245 + 12345) `mod` 2147483648

pick : Int -> Int -> Int
pick s m = (s `div` 65536) `mod` m

-- Takes k fields off the stack; a leaf or a shared subtree stands in for
-- some, and for all once the stack is empty.
takeFields : Int -> Nat -> List T -> List T -> Int -> (List T, List T, Int)
takeFields s 0 st _ _ = ([], st, s)
takeFields s (S k) st sh n =
  let s1 = next s in
  case st of
    (x :: rest) =>
      if pick s1 5 == 0
        then let (xs, st', s2) = takeFields s1 k st sh n in (L (pick s1 100) :: xs, st', s2)
        else let (xs, st', s2) = takeFields s1 k rest sh n in (x :: xs, st', s2)
    [] => let (xs, st', s2) = takeFields s1 k [] sh n
              v = case sh of
                    (y :: _) => if pick s1 3 == 0 then y else L n
                    [] => L n
          in (v :: xs, st', s2)

-- Rotates the fields, so the one taken first (the deepest) lands anywhere.
rot : Int -> List T -> List T
rot 0 xs = xs
rot k [] = []
rot k (x :: xs) = rot (k - 1) (xs ++ [x])

firstN : Nat -> List a -> List a
firstN Z _ = []
firstN _ [] = []
firstN (S k) (x :: xs) = x :: firstN k xs

arity : Int -> Nat
arity 1 = 2
arity 2 = 3
arity 3 = 4
arity 4 = 4
arity 10 = 2
arity _ = 1

-- One node per step on the stack `st`; `sh` are the subtrees to share.
build : Int -> Int -> List T -> List T -> IO (List T, List T)
build 0 _ st sh = pure (st, sh)
build n s st sh = do
  let s1 = next s
  let c = pick s1 12
  let (xs0, st', s2) = takeFields s1 (arity c) st sh n
  node <- case (c, rot (pick s2 5) xs0) of
            (0, [a]) => pure (N1 a)
            (1, [a, b]) => pure (N2 a b)
            (2, [a, b, d]) => pure (N3 a b d)
            (3, [a, b, d, e]) => pure (N4 a b d e)
            (4, [a, b, d, e]) => pure (N5 n a b d e)
            (5, [a]) => pure (S (show n) a)
            (6, [a]) => pure (F (holding a) (L n))
            (7, [a]) => pure (Z (Delay a) (L n))
            (8, [a]) => do r <- newIORef a; pure (R r (L n))
            (10, [a, b]) => pure (M a (show n) b)
            (11, [a]) => do r <- newIORef (show n); pure (Q r a)
            (_, [a]) => do r <- newIORef (L n); pure (R r a)
            _ => pure (L 0)
  -- Forces some lazy cells, so both kinds die.
  k <- case node of
         Z l _ => pure (if pick s2 2 == 0 then top l else 0)
         _ => pure 0
  let sh' = if pick s2 50 == 0 && n `mod` 7 == 0 then N2 (L (n + k)) (L 1) :: firstN 8 sh else sh
  build (n - 1) (next s2) (node :: st') sh'

-- One value of what is left on the stack, its spine alternating between
-- the first and the last field.
join : Bool -> T -> List T -> T
join _ acc [] = acc
join b acc (x :: xs) = join (not b) (if b then N2 x acc else N2 acc x) xs

once : Int -> IO ()
once seed = do
  (st, sh) <- build 100000 seed [] [N3 (L 7) (N2 (L 1) (L 2)) (L 8), N1 (L 5)]
  let t = join True (L 0) st
  putStrLn "seed \{show seed}: \{show (top t)} \{show (length st)}"
  -- the value is dead here; what it shared must still be whole
  printLn (map sumT sh)

export
run : IO ()
run = traverse_ once [1, 2, 3, 4, 5]
