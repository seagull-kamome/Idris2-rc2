module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.Emit's own C-emission-time
-- interception of Prelude.Types.fastPack/fastConcat (see
-- fastPackFixedReplacement's own doc comment in Emit.idr, KNOWN-BUGS.md,
-- and rc2/doc/fastpack-fix.md for the full writeup): both leak their own
-- raw malloc'd char* return through the generic CFString-return FFI
-- wrapper codegen, which copies it into a fresh IDRIS2RC2_String and
-- never frees the original. Fixed by redirecting the wrapper's own
-- internal implementation to rc2's own leak-free idris2rc2_fastPackFixed/
-- idris2rc2_fastConcatFixed at codegen time -- unconditionally, for every call
-- site project-wide, with no opt-in import needed (unlike the retired
-- Prelude.Fix.RC2 module, which only ever reached a call site within
-- its own importer's elaboration scope). `pack`/`concat` below reach
-- fastPack/fastConcat via upstream's own unconditional %transform
-- (Prelude.Types, no import needed for that part either) -- this test's
-- own point is that the underlying C implementation no longer leaks,
-- with nothing special imported or opted into.
--
-- valgrind --leak-check=full ./build/exec/Test46FastPackUnconditional
-- expect "definitely lost: 0 bytes".

main : IO ()
main = do
  putStrLn (pack ['h', 'e', 'l', 'l', 'o'])
  putStrLn (concat ["foo", "bar", "baz"])
