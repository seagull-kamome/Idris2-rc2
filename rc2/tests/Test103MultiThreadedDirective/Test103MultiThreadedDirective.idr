module Main

-- `%cg rc2 multithreaded` switches reference counting to atomic in
-- `main()`, before any Idris code runs (rc2/doc/hybrid-refcount.md).

import System.GC.RC2

%cg rc2 multithreaded

main : IO ()
main = do
  on <- isMultiThreaded
  putStrLn "at start: \{show on}"
