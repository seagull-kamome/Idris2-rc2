module Main

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

main : IO ()
main = do
  r <- myFn 10
  case r of
    Left err => putStrLn ("err: " ++ err)
    Right (y, x) => putStrLn (show y ++ " " ++ show x)
