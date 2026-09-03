module Main

-- Regression test for Compiler.RC2.RC's `annotate` never annotating
-- RExtPrim nodes at all (no splitBorrows/wrapDups/postDrop, unlike
-- every other operand-consuming RCExp node -- ROp/RCon/etc.) -- this
-- leaked the IORef cell itself (never dropped after its last read) and
-- any Boxed ext-prim argument whose last use is the call itself (e.g.
-- modifyIORef's freshly computed Int fed into writeIORef). See
-- doc/c-struct-support.md's own addendum for the full root-cause
-- writeup.
--
-- valgrind --leak-check=full ./build/exec/Test44IORefExtPrimLeak
-- expect "definitely lost: 0 bytes".
--
-- Also covers the same gap's array-prim blast radius (formerly a
-- separate Test45ArrayExtPrimLeak.idr, merged in below):
-- Data.IOArray's newArray/writeArray/readArray reach the byte-for-byte
-- identical RExtPrim path (prim__newArray/prim__arraySet/
-- prim__arrayGet) and the same rc2/support/rc2/ioprims.c dup-on-store
-- convention as IORef -- affected equally, verified here rather than
-- assumed.

import Data.IORef
import Data.IOArray

main : IO ()
main = do
  ref <- newIORef 0
  modifyIORef ref (+1)
  modifyIORef ref (+41)
  v <- readIORef ref
  printLn v
  arr <- newArray 3
  _ <- writeArray arr 0 "a"
  _ <- writeArray arr 1 "b"
  _ <- writeArray arr 2 "c"
  v2 <- readArray arr 1
  printLn v2
