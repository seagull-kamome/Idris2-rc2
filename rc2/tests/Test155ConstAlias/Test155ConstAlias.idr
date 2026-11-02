module Main

-- Constants passed to inlined functions: `Compiler.RC2.DeadVars` replaces the
-- variable a constant argument is bound to, see `doc/dead-vars.md`.

import Data.IORef
import Data.List
import Data.String
import System

%noinline
b64 : Bits64 -> Int -> Bits64
b64 acc 0 = acc
b64 acc n = b64 (acc * 6364136223846793005 + 1442695040888963407) (n - 1)

%noinline
b32 : Bits32 -> Int -> Bits32
b32 acc 0 = acc
b32 acc n = b32 (acc * 1664525 + 1013904223) (n - 1)

%noinline
countVowels : Int -> List Char -> Int
countVowels acc [] = acc
countVowels acc (c :: cs) = countVowels (if c == 'a' || c == 'e' then acc + 1 else acc) cs

%noinline
sumList : List Int -> Int
sumList xs = foldl (+) 0 xs

%noinline
maybeStep : Int -> Maybe Int
maybeStep n = if n > 0 then Just (n - 1) else Nothing

%noinline
runMaybe : Int -> Int -> Int
runMaybe acc n = case maybeStep n of
                      Nothing => acc
                      Just m => runMaybe (acc + n) m

%noinline
pairStep : (Int, Int) -> (Int, Int)
pairStep (a, b) = (b, (a + b) `mod` 1000003)

%noinline
fibPair : Int -> (Int, Int) -> (Int, Int)
fibPair 0 p = p
fibPair n p = fibPair (n - 1) (pairStep p)

%noinline
ioLoop : IORef Int -> Int -> IO ()
ioLoop r 0 = pure ()
ioLoop r n = modifyIORef r (+ n) >> ioLoop r (n - 1)

%noinline
natSum : Nat -> Nat -> Nat
natSum acc Z = acc
natSum acc (S k) = natSum (acc + k) k

%noinline
eitherStep : Int -> Either String Int
eitherStep n = if n < 0 then Left "neg" else Right (n * 2)

%noinline
runEither : Int -> Int -> Int
runEither acc 0 = acc
runEither acc n = case eitherStep n of
                       Left _ => acc
                       Right v => runEither (acc + v) (n - 1)

%noinline
sumPairs : List (Int, Int) -> Int
sumPairs [] = 0
sumPairs ((a, b) :: r) = a * b + sumPairs r

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args) + 999
  printLn (b64 1 k)
  printLn (b32 1 k)
  printLn (countVowels 0 (unpack "abcdeaabbee"))
  printLn (sumList [1, 2, 3, cast k])
  printLn (runMaybe 0 k)
  printLn (fibPair k (0, 1))
  r <- newIORef 0
  ioLoop r k
  printLn !(readIORef r)
  printLn (natSum 0 (cast k))
  printLn (runEither 0 k)
  printLn (sumPairs [(1, 2), (3, cast k)])
