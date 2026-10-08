module Main

import Data.IORef
import System
import Data.List
import Data.String
import System.Concurrency
import System.Concurrency.RC2

-- Regression test for a leak in Compiler.RC2.Reuse's constructor
-- reuse-in-place offer (RReuseOffer): a destructured-but-unreferenced
-- field of the reuse candidate `sc` used to never get dropped on the
-- *unique* path (where `sc` itself is repurposed in place rather than
-- dropped), because Reuse.idr's `resolveAlt` assumed such a field's
-- release always rides `sc`'s own eventual drop -- true only on the
-- *not-unique* path. Found via a real leak surfaced by
-- Test35NetworkLoopback's own valgrind run (Network.Socket.accept/
-- recv, both HasIO-polymorphic functions with an outer do-block of 2+
-- binds followed by a nested do in the else-branch of an if) -- this
-- is the minimal, socket-free shape that reproduces it: `myFn` mirrors
-- that structure exactly (2 outer binds, then a nested do inside the
-- else branch that itself binds and returns a freshly-built
-- constructor), which is exactly the shape that makes the IO
-- interface-dictionary argument's own reuse-in-place offer leave one
-- of its dictionary's own unused sub-closures stranded on the unique
-- path. `myFn`'s `then` branch (no nested do) never hit this; only
-- the `else` branch's nested-do continuation worker did.
--
-- valgrind --leak-check=full ./build/exec/Test36ReuseOfferUniqueLeak
-- expect "definitely lost: 0 bytes".
myFn : HasIO io => Int -> io (Either String (Int, Int))
myFn sock = do
  ptr <- pure 42
  res <- pure (sock + 1)
  if res == (-1)
    then pure (Left "err")
    else do
      let x = sock * 2
      y <- pure (ptr + x)
      pure (Right (y, x))

-- Nested-let reuse (Reuse.idr's `tryConsume`, rc2/doc/reuse-analysis.md
-- "Nested let values"): the same-named constructor sits inside the VALUE
-- of a `let` (a `case`/`let` tree), not on the alt's own tail path. Each
-- function below checks one resolution shape; every one must stay
-- valgrind-clean and print what real RefC prints. check.sh asserts that
-- the claims in `bumpA`/`bumpB`/`bumpC`/`bumpD`/`revBump` really happen.
data T = Leaf | Node Int T

top : T -> Int
top Leaf = 0
top (Node a _) = a

sumT : T -> Int
sumT Leaf = 0
sumT (Node a r) = a + sumT r

build : Int -> T
build 0 = Leaf
build n = Node n (build (n - 1))

-- A claim in every branch of the value's case: one claim per path.
bumpA : T -> T
bumpA Leaf = Leaf
bumpA (Node x r) =
  let rest = bumpA r
      n = case x `mod` 3 of
            0 => Node (x + 1) rest
            1 => Node (x + 2) rest
            _ => Node (x + 3) rest
  in if top n > 1000000 then Leaf else n

-- A claim in only one branch: the other leaf must release the shell.
bumpB : T -> T
bumpB Leaf = Leaf
bumpB (Node x r) =
  let rest = bumpB r
      n = case x `mod` 2 of
            0 => Node (x + 1) rest
            _ => rest
  in if top n > 1000000 then Leaf else n

-- A `let` nested in the value, then a case inside that.
bumpC : T -> T
bumpC Leaf = Leaf
bumpC (Node x r) =
  let rest = bumpC r
      n = (let y = x * 2 in
           case y `mod` 3 of
             0 => Node (y + 1) rest
             _ => let z = y + 5 in Node z rest)
  in if top n > 1000000 then Leaf else n

-- A `let` ahead of a non-claiming leaf inside the value: the release
-- sits behind the let, inside the value.
bumpE : T -> T
bumpE Leaf = Leaf
bumpE (Node x r) =
  let rest = bumpE r
      n = case x `mod` 2 of
            0 => let y = x * 2 in Node y rest
            _ => let w = x + 1 in if w > 1000000 then Leaf else rest
  in if top n > 1000000 then Leaf else n

-- A non-tail call inside the value (shell held across it).
bumpD : T -> T
bumpD Leaf = Leaf
bumpD (Node x r) =
  let n = case x `mod` 2 of
            0 => let q = bumpD r in Node (x + 1) q
            _ => Node (x + 2) r
  in if top n > 1000000 then Leaf else n

-- A loop whose accumulator is built inside a let-bound case.
revBump : T -> T -> T
revBump acc Leaf = acc
revBump acc (Node x r) =
  let acc' = case x `mod` 2 of
               0 => Node (x + 1) acc
               _ => Node (x + 3) acc
  in revBump acc' r

-- The constructor is inside a lazy value: it must never claim the shell.
bumpLazy : T -> T
bumpLazy Leaf = Leaf
bumpLazy (Node x r) =
  let n : Lazy T
      n = Delay (case x `mod` 2 of
                   0 => Node (x + 1) r
                   _ => Node (x + 2) r)
  in force n

-- The offered cell is still shared at run time (`t` is used again), so
-- the offer fails and the dupOnShared path runs.
shared : Int -> Int
shared k =
  let t = build k
      a = bumpA t
      b = bumpB t
  in sumT a * 1000 + sumT b + sumT t

-- Re-check after DualABI (doc/reuse-analysis.md, "Re-checking dead
-- offers after DualABI"). `stepE` returns its Either as a struct, so the
-- inner `case stepE a of` offers a `Ret` struct that DualABI turns back
-- into a plain `drop`; the inner offer had claimed the `Right`, so
-- Reuse resolved `chainE`'s own offer on its parameter with an up-front
-- release. The rebuilt `Right` is only claimed by the re-check.
-- `stepE` is called from two places and is not small, so it stays a call.
stepE : Int -> Either String Int
stepE x =
  if x < 0
     then Left ("bad" ++ show x ++ replicate (cast (x `mod` 5)) '!')
     else Right (x * 3 + 1)

chainE : Either String Int -> Either String Int
chainE (Left e) = Left e
chainE (Right a) =
  case stepE a of
    Left e => Left e
    Right b => Right (a + b `mod` 7)

runE : Int -> Either String Int -> Either String Int
runE 0 acc = acc
runE n acc = runE (n - 1) (chainE (chainE acc))

showE : Either String Int -> String
showE (Left e) = "L " ++ e
showE (Right v) = "R " ++ show v

-- The shell is shared at run time (`r` is used again): the offer fails,
-- the dupOnShared path runs, and the claimed `Right` allocates fresh.
sharedE : Int -> String
sharedE k =
  let r = Right (k + 7)
  in showE (chainE r) ++ " " ++ showE r ++ " " ++ showE (chainE (chainE r))

-- `k` is only known at run time so nothing folds away.
workload : Int -> IO ()
workload k = do
  let t = build (50 + k)
  putStrLn (show (sumT (bumpA t)) ++ " " ++ show (sumT (bumpB t)) ++ " "
            ++ show (sumT (bumpC t)) ++ " " ++ show (sumT (bumpD t)))
  putStrLn (show (sumT (bumpE t)))
  putStrLn (show (sumT (revBump Leaf t)) ++ " " ++ show (sumT (bumpLazy t)))
  putStrLn (show (shared (30 + k)))
  putStrLn (show (sumT (bumpA (bumpC (bumpD (build (20 + k))))) + sumT (bumpB (build (20 + k)))))
  putStrLn (showE (runE (1000 + k) (Right k)))
  putStrLn (sharedE k ++ " " ++ showE (stepE (k - 1)))
  putStrLn (showE (chainE (Right (k - 3))) ++ " " ++ showE (chainE (Left "x")))

main : IO ()
main = do
  r <- myFn 10
  case r of
    Left err => putStrLn ("err: " ++ err)
    Right (y, x) => putStrLn (show y ++ " " ++ show x)
  args <- getArgs
  let k = cast (length args) - 1
  workload k
  -- Again once reference counting is atomic (a thread was forked).
  lock <- makeMutex
  cond <- makeCondition
  done <- newIORef False
  _ <- fork $ do
    workload k
    mutexAcquire lock
    writeIORef done True
    conditionSignal cond
    mutexRelease lock
  mutexAcquire lock
  waitDone lock cond done
  mutexRelease lock
  where
    waitDone : Mutex -> Condition -> IORef Bool -> IO ()
    waitDone lock cond done = do
      d <- readIORef done
      if d then pure () else conditionWait cond lock >> waitDone lock cond done
