module Main

-- Regression test for the same Compiler.RC2.RC `annotate`/RExtPrim gap
-- Test44IORefExtPrimLeak covers, but for the array-prim blast radius:
-- Data.IOArray's newArray/writeArray/readArray reach the byte-for-byte
-- identical RExtPrim path (prim__newArray/prim__arraySet/
-- prim__arrayGet) and the same rc2/support/rc2/ioprims.c dup-on-store
-- convention as IORef -- affected equally, verified here rather than
-- assumed.
--
-- valgrind --leak-check=full ./build/exec/Test45ArrayExtPrimLeak
-- expect "definitely lost: 0 bytes".

import Data.IOArray

main : IO ()
main = do
  arr <- newArray 3
  _ <- writeArray arr 0 "a"
  _ <- writeArray arr 1 "b"
  _ <- writeArray arr 2 "c"
  v <- readArray arr 1
  printLn v
