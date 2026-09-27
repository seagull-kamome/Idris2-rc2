module Main

-- Values crossing threads once reference counting has gone atomic
-- (rc2/doc/hybrid-refcount.md): eight threads map over one shared list
-- and hand new lists back, dropped on the main thread. Also run under
-- ThreadSanitizer by tsan.sh.

import System.Concurrency.RC2

worker : List Int -> Int -> IO (List Int)
worker shared k = pure (map (+ k) shared ++ [k .. k + 1000])

main : IO ()
main = do
  let shared = [1 .. 2000]
  hs <- traverse (\k => forkJoin (worker shared k)) [1 .. 8]
  rs <- traverse join hs
  printLn (sum (map sum rs), sum shared)
