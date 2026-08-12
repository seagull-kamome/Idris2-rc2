module Test7CastMatrix

-- Fills the gap rc2/tests/refc-suite/integers/TestIntegers.idr (ported
-- from upstream RefC) leaves in Idris2's full `Cast` primitive matrix:
-- that test thoroughly exercises Bits8/16/32/64 <-> Int8/16/32/64 <->
-- Int <-> Integer <-> String, but never touches Double or Char as
-- either source or destination, and never uses String as a *source*.
-- Per libs/prelude/Prelude/Cast.idr, every (from, to) pair among
-- {Int, Integer, Char, Double, String, Int8/16/32/64, Bits8/16/32/64}
-- is a real Cast instance except Char<->Double (neither direction
-- exists in the Prelude) -- this covers exactly the rest of that
-- matrix, at values chosen to stay within each target's representable
-- range (an out-of-range Double-to-int or String-to-int cast is
-- undefined behaviour in C, not a specific contract either backend
-- defines an answer for -- note rc2's own String->Int64/Bits64
-- deliberately parse via `atoll` rather than reproducing RefC's
-- `atoi`-based -- and therefore 32-bit-limited -- version of the same
-- cast, so String source values here are also kept within `atoi`'s
-- range to stay comparable rather than showcase that divergence).
--
-- Output verified correct by hand (truncation/wraparound arithmetic,
-- UTF-8 encoding of boundary codepoints, GMP precision loss casting a
-- 30-digit Integer to Double, ...) rather than by diffing against real
-- `idris2 --cg refc`, because the nixpkgs-packaged RefC runtime this
-- environment's `idris2` resolves to cannot actually compile this
-- program: it's missing `idris2_cast_Double_to_Int8` entirely, defines
-- `idris2_cast_String_to_*` with a capital S while its own compiler
-- emits calls to lowercase `idris2_cast_string_to_*`, and defines
-- `idris2_nagate_Double` (sic) where its compiler emits
-- `idris2_negate_Double`. All three are upstream RefC-runtime bugs
-- unrelated to rc2 -- confirmed by reading idris2-src's own
-- src/Compiler/RefC/RefC.idr and support/refc/*, which don't have this
-- mismatch, so this is specific to whatever version nixpkgs currently
-- packages, not idris2-src HEAD.

import Data.List.Quantifiers

put : Show a => a -> IO ()
put = putStrLn . show

castAllTo : (to : Type)
         -> {0 types : List Type}
         -> All (flip Cast to) types => HList types -> List to
castAllTo to = forget . imapProperty (flip Cast to) (cast {to})

doubles : List Double
doubles = [0.0, 1.5, -1.5, 3.999, -3.999, 100.0, -100.0]

doublesNarrowSigned : List Double
doublesNarrowSigned = [0.0, 1.5, -1.5, 100.0, -100.0, 127.0, -128.0]

doublesNarrowUnsigned : List Double
doublesNarrowUnsigned = [0.0, 1.5, 100.0, 3.999, 255.0]

-- Non-negative only: converting a negative Double to an unsigned
-- integer type is undefined behaviour in C (not just
-- implementation-defined truncation like the signed/narrow cases
-- above), so unlike `doubles` this must never include one.
doublesUnsigned : List Double
doublesUnsigned = [0.0, 1.5, 3.999, 100.0, 4000000000.0]

chars : List Char
chars = ['A', 'z', '0', '~', cast (the Int 0), cast (the Int 255), cast (the Integer 0x10FFFF)]

main : IO ()
main = do
    -- Double as source
    putStrLn "Double -> Int:"
    put $ map (\x => the Int (cast x)) doubles
    putStrLn "Double -> Integer:"
    put $ map (\x => the Integer (cast x)) doubles
    putStrLn "Double -> Int8:"
    put $ map (\x => the Int8 (cast x)) doublesNarrowSigned
    putStrLn "Double -> Int16:"
    put $ map (\x => the Int16 (cast x)) doublesNarrowSigned
    putStrLn "Double -> Int32:"
    put $ map (\x => the Int32 (cast x)) doubles
    putStrLn "Double -> Int64:"
    put $ map (\x => the Int64 (cast x)) doubles
    putStrLn "Double -> Bits8:"
    put $ map (\x => the Bits8 (cast x)) doublesNarrowUnsigned
    putStrLn "Double -> Bits16:"
    put $ map (\x => the Bits16 (cast x)) doublesNarrowUnsigned
    putStrLn "Double -> Bits32:"
    put $ map (\x => the Bits32 (cast x)) doublesUnsigned
    putStrLn "Double -> Bits64:"
    put $ map (\x => the Bits64 (cast x)) doublesUnsigned
    putStrLn "Double -> String:"
    put $ map (\x => the String (cast x)) doubles

    -- Double as destination, from every other numeric/string type
    putStrLn "X -> Double:"
    put $ castAllTo Double (the (HList _) [
        the Int (-1234567890), the Integer 123456789012345678901234567890,
        the Bits8 200, the Bits16 50000, the Bits32 3000000000, the Bits64 10000000000000000000,
        the Int8 (-100), the Int16 (-30000), the Int32 (-2000000000), the Int64 (-9000000000000000000),
        the String "3.14159"
    ])

    -- Char as source
    putStrLn "Char -> Int:"
    put $ map (\x => the Int (cast x)) chars
    putStrLn "Char -> Integer:"
    put $ map (\x => the Integer (cast x)) chars
    putStrLn "Char -> Int8:"
    put $ map (\x => the Int8 (cast x)) chars
    putStrLn "Char -> Int16:"
    put $ map (\x => the Int16 (cast x)) chars
    putStrLn "Char -> Int32:"
    put $ map (\x => the Int32 (cast x)) chars
    putStrLn "Char -> Int64:"
    put $ map (\x => the Int64 (cast x)) chars
    putStrLn "Char -> Bits8:"
    put $ map (\x => the Bits8 (cast x)) chars
    putStrLn "Char -> Bits16:"
    put $ map (\x => the Bits16 (cast x)) chars
    putStrLn "Char -> Bits32:"
    put $ map (\x => the Bits32 (cast x)) chars
    putStrLn "Char -> Bits64:"
    put $ map (\x => the Bits64 (cast x)) chars
    putStrLn "Char -> String:"
    put $ map (\x => the String (cast x)) chars

    -- Char as destination
    putStrLn "X -> Char:"
    put $ castAllTo Char (the (HList _) [
        the Int 65, the Integer 122,
        the Bits8 48, the Bits16 126, the Bits32 0, the Bits64 255,
        the Int8 65, the Int16 122, the Int32 48, the Int64 126
    ])

    -- String as source -- kept within `atoi`'s 32-bit-safe range (see
    -- the module note) so this exercises the actual parsing path
    -- without landing on the one place rc2 and RefC deliberately
    -- disagree.
    putStrLn "String -> Int:"
    put $ the Int (cast "-1234567890")
    putStrLn "String -> Integer:"
    put $ the Integer (cast "123456789012345678901234567890")
    putStrLn "String -> Int8:"
    put $ the Int8 (cast "-128")
    putStrLn "String -> Int16:"
    put $ the Int16 (cast "-32768")
    putStrLn "String -> Int32:"
    put $ the Int32 (cast "-1234567890")
    putStrLn "String -> Int64:"
    put $ the Int64 (cast "-1234567890")
    putStrLn "String -> Bits8:"
    put $ the Bits8 (cast "255")
    putStrLn "String -> Bits16:"
    put $ the Bits16 (cast "65535")
    putStrLn "String -> Bits32:"
    put $ the Bits32 (cast "1234567890")
    putStrLn "String -> Bits64:"
    put $ the Bits64 (cast "1234567890")
    putStrLn "String -> Double:"
    put $ the Double (cast "3.14159")
