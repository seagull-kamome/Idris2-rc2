||| Hex formatting for the fixed-width integer types.
|||
||| `toHex` renders a value as exactly as many lowercase hex digits as
||| its type is wide -- two for `Bits8`/`Int8`, four for
||| `Bits16`/`Int16`, eight for `Bits32`/`Int32` and sixteen for
||| `Bits64`/`Int64`/`Int` -- zero-padded on the left. A signed type
||| renders its two's-complement bit pattern, so `the Int8 (-1)` is
||| `"ff"`. `digit` is the single-nibble step.
module Text.NumberFormat

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Bits

-------------------------------------------------------------------------------
-- Digit

||| The lowercase hex digit for the nibble `n`. Only `0`-`15` are
||| meaningful; a larger `n` keeps counting past `'f'`.
public export
digit : Bits8 -> Char
digit n = if n < 10
             then chr (cast n + ord '0')
             else chr (cast n + ord 'a' - 10)

-------------------------------------------------------------------------------
-- ToHex

public export
interface ToHex a where
  toHex : a -> String

-- Most-significant nibble first, zero-padded to `width` digits.
hexOf : (width : Nat) -> (value : Bits64) -> String
hexOf width value = pack (reverse (nibbles width value))
  where
    nibbles : Nat -> Bits64 -> List Char
    nibbles Z _ = []
    nibbles (S k) x = digit (cast (x .&. 0xf)) :: nibbles k (x `shiftR` 4)

public export
ToHex Bits8 where
  toHex x = hexOf 2 (cast x)

public export
ToHex Bits16 where
  toHex x = hexOf 4 (cast x)

public export
ToHex Bits32 where
  toHex x = hexOf 8 (cast x)

public export
ToHex Bits64 where
  toHex x = hexOf 16 x

public export
ToHex Int8 where
  toHex x = toHex (the Bits8 (cast x))

public export
ToHex Int16 where
  toHex x = toHex (the Bits16 (cast x))

public export
ToHex Int32 where
  toHex x = toHex (the Bits32 (cast x))

public export
ToHex Int64 where
  toHex x = toHex (the Bits64 (cast x))

public export
ToHex Int where
  toHex x = toHex (the Bits64 (cast x))
