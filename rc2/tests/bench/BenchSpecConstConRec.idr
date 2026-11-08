module Main

-- The *self-passthrough* half of constant-constructor specialization
-- (`doc/constant-constructor-specialization.md`): a dictionary that is
-- scrutinised **and** handed straight back to the same argument
-- position of its own recursive call. That is the shape a real
-- interface dictionary almost always has -- a recursive `go` carries
-- it along on every step -- and `paramIsScrutineeOnly` rejected it
-- outright until it learned to discount the passthrough, the same way
-- `paramLooksSpecializable` already did for the closure case.
--
-- The sibling `BenchSpecConstCon.idr` measures the simpler shape,
-- where the dictionary reaches a non-recursive callee. Here the
-- dictionary parameter is live across two million iterations, so what
-- is being measured is not just the removed dispatch but also the
-- parameter no longer being passed and refcounted at all: the accepted
-- clone drops it from its own signature, and the whole-program
-- redirect sweep then points the recursive call at the clone itself,
-- so the recursion runs specialized all the way down.
--
-- Same arithmetic as `BenchSpecConstCon.idr`, so both print 937501.
--
-- A/B it with `--directive nospecconstcon`.

record Ops where
  constructor MkOps
  f : Int -> Int
  g : Int -> Int

%noinline
addOne : Int -> Int
addOne x = x + 1

%noinline
mulTwo : Int -> Int
mulTwo x = x * 2

ops : Ops
ops = MkOps addOne mulTwo

%noinline
sweep : Ops -> Int -> Int -> Int
sweep d acc 0 = acc
sweep d acc n = sweep d ((d.g (d.f acc)) `mod` 1000003) (n - 1)

main : IO ()
main = printLn (sweep ops 1 2000000)
