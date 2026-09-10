||| UTF-8 <-> Unicode scalar values, as pure `List` transforms.
|||
||| rc2's own `String` is a UTF-8 byte sequence on the wire, but every
||| `String` primitive (`pack`/`unpack`/`strLength`/`strIndex`/
||| `strSubstr`/...) is *codepoint*-wise -- `unpack` decodes UTF-8, `pack`
||| re-encodes it (see `rc2/support/rc2/idris2rc2_strings.c`, whose
||| header says as much: "matching Idris2's own Chez backend"). So the
||| one thing missing when you hold a run of raw UTF-8 *bytes* (from a
||| socket, a `%XX` sequence, a `Buffer`) is turning that byte list into
||| the codepoint list `pack` expects -- and the reverse. That is all
||| this module is.
|||
||| Decoding is strict: an overlong form, a surrogate (U+D800..U+DFFF),
||| a value above U+10FFFF, a truncated or malformed sequence -- each
||| becomes one `replacementChar` (U+FFFD). (rc2's in-runtime C decoder
||| is more lenient; being stricter here is deliberate, overlong forms
||| especially are a classic injection vector.)
module Text.Encoding.UTF8

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

%default total

||| U+FFFD REPLACEMENT CHARACTER. Every malformed input byte/sequence
||| decodes to exactly one of these.
public export
replacementChar : Char
replacementChar = chr 0xFFFD

-- Powers of 64 (2^6), used to peel 6-bit groups off a code point with
-- plain `div`/`mod` rather than pulling in `Data.Bits` for shifts.
p6 : Int
p6 = 64

p12 : Int
p12 = 4096

p18 : Int
p18 = 262144

isScalar : Int -> Bool
isScalar cp = cp >= 0 && cp <= 0x10FFFF && not (cp >= 0xD800 && cp <= 0xDFFF)

||| Encode one Unicode scalar value as its 1-4 UTF-8 bytes. A `Char`
||| outside the scalar range (negative, a surrogate, or > U+10FFFF) is
||| emitted as the encoding of `replacementChar`.
export
encodeChar : Char -> List Bits8
encodeChar c =
  let raw = ord c
      cp  = if isScalar raw then raw else 0xFFFD
      b : Int -> Bits8
      b = cast
  in if cp < 0x80
       then [b cp]
     else if cp < 0x800
       then [ b (0xC0 + (cp `div` p6))
            , b (0x80 + (cp `mod` p6)) ]
     else if cp < 0x10000
       then [ b (0xE0 + (cp `div` p12))
            , b (0x80 + ((cp `div` p6) `mod` p6))
            , b (0x80 + (cp `mod` p6)) ]
       else [ b (0xF0 + (cp `div` p18))
            , b (0x80 + ((cp `div` p12) `mod` p6))
            , b (0x80 + ((cp `div` p6) `mod` p6))
            , b (0x80 + (cp `mod` p6)) ]

||| Encode a codepoint list to its UTF-8 bytes.
export
encode : List Char -> List Bits8
encode = concatMap encodeChar

-- Decoder state: `Ground` between characters, or `Pending k acc lo`
-- partway through a multi-byte sequence needing `k` more continuation
-- bytes, `acc` the bits gathered so far, `lo` the smallest value this
-- sequence length may legitimately encode (anything below `lo` is an
-- overlong form -> U+FFFD).
data DecSt = Ground | Pending Nat Int Int

-- Start a fresh sequence from a lead byte (also the recovery path when
-- a continuation byte was expected but a lead/ASCII byte turned up).
fromGround : Int -> (DecSt, List Char)
fromGround x =
  if x < 0x80        then (Ground, [chr x])
  else if x < 0xC0   then (Ground, [replacementChar])          -- stray continuation
  else if x < 0xE0   then (Pending 1 (x - 0xC0) 0x80, [])
  else if x < 0xF0   then (Pending 2 (x - 0xE0) 0x800, [])
  else if x < 0xF8   then (Pending 3 (x - 0xF0) 0x10000, [])
  else                    (Ground, [replacementChar])          -- 0xF8..0xFF: never valid UTF-8

finish : (val, lo : Int) -> Char
finish val lo = if val >= lo && isScalar val then chr val else replacementChar

-- Feed one byte; return the next state and any characters completed by
-- consuming it.
step : DecSt -> Int -> (DecSt, List Char)
step Ground x = fromGround x
step (Pending k acc lo) x =
  if x < 0x80 || x >= 0xC0
    then let (st, cs) = fromGround x in (st, replacementChar :: cs)  -- incomplete seq, then reprocess x
    else let acc' = acc * p6 + (x - 0x80) in
         case k of
           S Z    => (Ground, [finish acc' lo])
           S j    => (Pending j acc' lo, [])
           Z      => (Ground, [chr acc'])   -- unreachable: Pending always carries k >= 1

decodeAcc : DecSt -> List Int -> List Char
decodeAcc Ground         []        = []
decodeAcc (Pending _ _ _) []       = [replacementChar]   -- input ended mid-sequence
decodeAcc st (x :: xs) = let (st', cs) = step st x in cs ++ decodeAcc st' xs

||| Decode a run of raw UTF-8 bytes to Unicode scalar values. Never
||| fails: every malformed byte or sequence yields one `replacementChar`.
export
decode : List Bits8 -> List Char
decode = decodeAcc Ground . map (cast {to = Int})
