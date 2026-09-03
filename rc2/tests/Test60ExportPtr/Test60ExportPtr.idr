module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%export`'s CFPtr support (rc2/doc/export-
-- support.md): `identityPtr` is exported and called directly from
-- plain C (companion Test60ExportPtr.c) with a raw, non-Idris-owned
-- pointer, proving the wrapper's own packCFType/extractValue CFPtr
-- round trip is genuine native-C-ABI marshalling, not merely a
-- compiling no-op -- the companion C checks both that the exact same
-- address comes back out and that the memory behind it is still
-- readable (i.e. still live, not something the wrapper's own
-- drop-after-return step freed).

%export "C:idris2rc2_test60_identity"
identityPtr : AnyPtr -> AnyPtr
identityPtr p = p

%foreign "C:idris2rc2_test60_run_check,libc,Test60ExportPtr.h"
prim__runCheck : PrimIO Int

main : IO ()
main = do
  r <- primIO prim__runCheck
  printLn r
