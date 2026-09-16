||| Automated smoke test: build+link+run only. Deliberately doesn't
||| call `init` -- notcurses needs a real terminal for that, which an
||| automated/sandboxed environment generally doesn't have. See
||| ../examples/ for interactive coverage of everything else.
module Main

import System.Notcurses
import Data.String

main : IO ()
main = do
  v <- version
  -- Loosely shaped check ("N.N.N...", not an exact match) rather than
  -- a fixed expected string -- a notcurses point-release bump on the
  -- machine running this shouldn't fail this test.
  let looksLikeVersion = all (\c => isDigit c || c == '.') (unpack v) && length v > 0
  putStrLn $ if looksLikeVersion
                then "PASS: notcurses_version() = " ++ v
                else "FAIL: notcurses_version() returned unexpected value: " ++ show v
