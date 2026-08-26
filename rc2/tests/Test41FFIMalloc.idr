module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System.FFI's malloc/free (idris_memory.c's
-- idris2_malloc/idris2_free, a libidris2_support.a fallback rc2 has
-- no native port of -- unrelated to rc2's own GC'd heap). base's
-- System.FFI exposes no generic peek/poke on a raw AnyPtr, so a small
-- companion C file (Test41FFIMalloc.c/.h) writes/reads a single byte
-- through the pointer to prove it's a real, writable allocation, not
-- just an opaque handle.
--
-- valgrind --leak-check=full ./build/exec/<this test's own output>
-- expect "definitely lost: 0 bytes in 0 blocks".

import System.FFI

%foreign "C:idris2rc2_test41_poke_byte,libc,Test41FFIMalloc.h"
prim__pokeByte : AnyPtr -> Int -> PrimIO ()

%foreign "C:idris2rc2_test41_peek_byte,libc,Test41FFIMalloc.h"
prim__peekByte : AnyPtr -> PrimIO Int

main : IO ()
main = do
  ptr <- malloc 16
  primIO (prim__pokeByte ptr 42)
  v <- primIO (prim__peekByte ptr)
  putStrLn ("peeked byte: " ++ show v)
  free ptr
  putStrLn "done"
