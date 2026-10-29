module Main

-- `System.Info.os` under `--directive target-os` (rc2/doc/directives.md).
-- check.sh looks at what the compiler did with the primitive.

import System.Info

main : IO ()
main = do
  putStrLn os
  putStrLn (if isWindows then "windows" else "not windows")
  putStrLn (if os == "Linux" then "os is Linux" else "os is other")
