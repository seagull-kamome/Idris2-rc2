module Main

import Data.String
import Data.List1

-- Simple direct FFI, plus string-heavy operations that route through the
-- "RefC"-tagged fastPack/fastConcat/fastUnpack primitives our own runtime
-- provides (see Compiler/RC2/Emit.idr's ffiTags and
-- support/rc2/idris2rc2_strings.c).

%foreign "C:strlen,libc 6"
prim__strlen : String -> Int

cStrlen : String -> Int
cStrlen = prim__strlen

main : IO ()
main = do
  printLn (cStrlen "hello, world")

  let chars = unpack "Hello, rc2!"
  printLn chars
  putStrLn (pack chars)

  let strs = ["foo", "bar", "baz", "quux"]
  putStrLn (concat strs)
  putStrLn (fastConcat strs)

  let big = pack (replicate 1000 'x')
  printLn (length big)

  putStrLn (toUpper "shout this")
  putStrLn (toLower "WHISPER THIS")
  printLn (words "the quick brown fox")
  printLn (forget (split (== ',') "a,b,c,d"))
