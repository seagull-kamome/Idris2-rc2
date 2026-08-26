module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression/smoke test for aligning String primitives
-- (Compiler.RC2.Emit's Str* dispatch -> rc2/support/rc2/
-- idris2rc2_strings.c) to UTF-8 codepoint-, not byte-, indexed
-- semantics -- matching Idris2's own Chez backend (Scheme strings are
-- Unicode-scalar sequences by spec) rather than upstream RefC's own
-- byte-wise treatment (see README.md's "Deliberate differences from
-- upstream RefC"). `s` mixes a 1/2/3/4-byte-UTF-8 character each
-- (11 bytes, 5 characters), so every primitive below is exercised
-- against a case where "byte count" and "character count" genuinely
-- disagree -- the exact confusion this whole fix exists to rule out
-- of every allocation site (idris2rc2_strings.c's own per-primitive
-- comments spell out which byte count each one allocates against).
-- Also covers a companion-C-sourced malformed byte sequence (a lone
-- UTF-8 continuation byte), verifying it decodes to U+FFFD (the
-- replacement character) rather than crashing or misreading --
-- rc2/support/rc2/utf8.c's own chosen fallback policy for lossy
-- decoding, matching Unicode's own standard convention.

import Data.String
import Prelude.Fix.RC2

%foreign "C:idris2rc2_test28_malformed,libc,Test28Utf8Strings.h"
prim__malformed : PrimIO String

-- Every index below is known in range by construction; strIndex is
-- only `partial` because it can't express that statically.
idx : String -> Int -> Char
idx = assert_total strIndex

s : String
s = "aéあ😀z"

main : IO ()
main = do
    printLn (length s)
    printLn (idx s 0         == 'a')
    printLn (idx s 1         == 'é')
    printLn (idx s 2         == 'あ')
    printLn (idx s 3         == '😀')
    printLn (idx s 4         == 'z')
    printLn (strUncons s     == Just ('a', "éあ😀z"))
    printLn (strCons '★' s   == "★aéあ😀z")
    printLn (reverse s       == "z😀あéa")
    printLn (strSubstr 1 3 s == "éあ😀")
    let chars = unpack s
    printLn chars
    printLn (pack chars == s)
    malformed <- primIO prim__malformed
    printLn (length malformed)
    printLn (unpack malformed == ['a', 'b', chr 0xFFFD, 'c', 'd'])
    -- Not malformed == pack (unpack malformed): the lone 0x80 became a
    -- real (3-byte-encoded) U+FFFD, so re-packing is legitimately a
    -- different, longer, well-formed byte sequence, not a round trip.
    printLn (pack (unpack malformed) == pack ['a', 'b', chr 0xFFFD, 'c', 'd'])
    putStrLn "done"
