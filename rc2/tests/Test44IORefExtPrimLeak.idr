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

import Data.IORef

main : IO ()
main = do
  ref <- newIORef 0
  modifyIORef ref (+1)
  modifyIORef ref (+41)
  v <- readIORef ref
  printLn v
