module Data.TextBuffer

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import Data.Fin

-- ---------------------------------------------------------------------------

||| The Text type, representing a Unicode codepoint sequence of length n.
export
data TextBuffer : Nat -> Type where
  MkTextBuffer : GCAnyPtr -> TextBuffer n

-- ---------------------------------------------------------------------------

||| Opaque marker type, never constructed on the Idris side. Used only
||| to keep rc2's %foreign marshaller from touching this primitive's
||| return value: text_util.c's idris2rc2_TextBuffer_to_string already
||| builds a fully-formed, correctly refcounted/tagged
||| IDRIS2RC2_String directly (via idris2rc2_mkEmptyString), so
||| declaring the return type as `String` here would make rc2 wrap it
||| a SECOND time via idris2rc2_mkString (packCFType CFString) --
||| `AnyPtr` would also be wrong, since that maps to CFPtr and gets
||| boxed via idris2rc2_mkPointer. An unrecognized type constructor
||| like this one maps to CFUser instead, whose packCFType/extractValue
||| (Compiler.RC2.Emit) are both the identity -- the Boxed Value* flows
||| through untouched.
data RawStringValue : Type

%foreign "C:idris2rc2_TextBuffer_mkEmpty,libidris2rc2base,text_util.h"
prim__TextBuffer_mkEmpty : Int -> PrimIO AnyPtr

%foreign "C:idris2rc2_String_to_TextBuffer,libidris2rc2base,text_util.h"
prim__String_to_TextBuffer : String -> PrimIO AnyPtr

%foreign "C:idris2rc2_TextBuffer_to_string,libidris2rc2base,text_util.h"
prim__TextBuffer_toString : GCAnyPtr -> PrimIO RawStringValue

%foreign "C:idris2rc2_TextBuffer_free,libidris2rc2base,text_util.h"
prim__TextBuffer_free : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_TextBuffer_unsafe_write_char,libidris2rc2base,text_util.h"
prim__TextBuffer_unsafe_write_char : GCAnyPtr -> Int -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_text_length,libidris2rc2base,text_util.h"
prim__textLength : GCAnyPtr -> PrimIO Int

%foreign "C:idris2rc2_text_index,libidris2rc2base,text_util.h"
prim__textIndex : GCAnyPtr -> Int -> PrimIO Bits32

%foreign "C:idris2rc2_TextBuffer_append,libidris2rc2base,text_util.h"
prim__TextBuffer_append : GCAnyPtr -> GCAnyPtr -> PrimIO AnyPtr

-- ---------------------------------------------------------------------------

freeTextBuffer : AnyPtr -> IO ()
freeTextBuffer ptr = primIO $ prim__TextBuffer_free ptr

||| Convert a String to Text.
export
fromString : (s : String) -> (n : Nat ** TextBuffer n)
fromString s = unsafePerformIO $ do
  ptr <- primIO $ prim__String_to_TextBuffer s
  gcptr <- onCollectAny ptr freeTextBuffer
  len <- primIO $ prim__textLength gcptr
  pure (fromInteger (cast len) ** MkTextBuffer gcptr)

||| Convert a Text back to a String.
export
toString : TextBuffer n -> String
toString (MkTextBuffer ptr) = believe_me $ unsafePerformIO $ primIO $ prim__TextBuffer_toString ptr

||| Get the length of the Text.
export
length : TextBuffer n -> Nat
length (MkTextBuffer ptr) =
  fromInteger $ cast $ unsafePerformIO $ primIO $ prim__textLength ptr

||| `length` always agrees with a `Text`'s own index `n` -- true by
||| construction (every `Text` value is reached only through this
||| module's own smart constructors, each of which sets the C buffer's
||| `len` field to exactly `n`, and no operation here ever mutates a
||| buffer's `len` afterward), but not mechanically provable from this
||| side: `length` re-reads `n` through an opaque C FFI call every
||| time, which the proof checker can't see through.
export
0 lengthCorrect : {n:Nat} -> (xs:TextBuffer n) -> length xs = n
lengthCorrect xs = the (length xs = n) $ believe_me xs

||| Get the character at the given index.
export
index : {n : Nat} -> TextBuffer n -> Fin n -> Char
index (MkTextBuffer ptr) idx = cast $ unsafePerformIO $ primIO $ prim__textIndex ptr (cast (finToNat idx))

||| Append two Texts.
export
(++) : TextBuffer n -> TextBuffer m -> TextBuffer (n + m)
(++) (MkTextBuffer ptr1) (MkTextBuffer ptr2) = unsafePerformIO $ do
  newPtr <- primIO $ prim__TextBuffer_append ptr1 ptr2
  gcptr <- onCollectAny newPtr freeTextBuffer
  pure (MkTextBuffer gcptr)

-- ---------------------------------------------------------------------------
-- Shared construction/deconstruction primitives. Everything below this
-- point is built purely in terms of these plus the C primitives above
-- -- no new %foreign declarations are introduced past this point.

||| Read the character at a raw Nat offset, without a `Fin n` bounds
||| proof. Only meant for internal use by loops here that already
||| guarantee the offset is in range by construction (e.g. counting up
||| to a buffer's own `length`).
unsafeIndex : TextBuffer n -> Nat -> Char
unsafeIndex (MkTextBuffer ptr) i = cast $ unsafePerformIO $ primIO $ prim__textIndex ptr (cast i)

||| Build a Text of the given length by evaluating `f` at each index.
||| The `fuel` parameter is `n` itself, counted down, so this
||| structurally terminates under this package's `--total`.
export
tabulate : (n : Nat) -> (Nat -> Char) -> TextBuffer n
tabulate n f = unsafePerformIO $ do
  ptr <- primIO $ prim__TextBuffer_mkEmpty (cast n)
  gcptr <- onCollectAny ptr freeTextBuffer
  writeLoop gcptr n 0
  pure (MkTextBuffer gcptr)
  where
    writeLoop : GCAnyPtr -> (fuel : Nat) -> Nat -> IO ()
    writeLoop p Z _ = pure ()
    writeLoop p (S fuel) i = do
      primIO $ prim__TextBuffer_unsafe_write_char p (cast i) (cast (f i))
      writeLoop p fuel (S i)

||| Read a Text out into a plain `List Char`, the boundary used by
||| every dynamic-length operation below to reuse `Data.List`'s
||| already-total string-shaped algorithms instead of reimplementing
||| them against the raw C buffer.
export
toList : TextBuffer n -> List Char
toList buf = go (length buf) 0
  where
    go : (fuel : Nat) -> Nat -> List Char
    go Z _ = []
    go (S fuel) i = unsafeIndex buf i :: go fuel (S i)

||| The inverse of `toList`: build a Text whose length isn't known
||| statically, existentially quantified like `fromString`.
export
fromCharList : List Char -> (n ** TextBuffer n)
fromCharList cs = unsafePerformIO $ do
  ptr <- primIO $ prim__TextBuffer_mkEmpty (cast (length cs))
  gcptr <- onCollectAny ptr freeTextBuffer
  writeLoop gcptr 0 cs
  pure (length cs ** MkTextBuffer gcptr)
  where
    writeLoop : GCAnyPtr -> Nat -> List Char -> IO ()
    writeLoop p i [] = pure ()
    writeLoop p i (c :: rest) = do
      primIO $ prim__TextBuffer_unsafe_write_char p (cast i) (cast c)
      writeLoop p (S i) rest

-- ---------------------------------------------------------------------------
-- Construction helpers with a statically known result length.

||| A Text of a single character.
export
singleton : Char -> TextBuffer 1
singleton c = tabulate 1 (const c)

||| A Text of `n` copies of a character.
export
replicate : (n : Nat) -> Char -> TextBuffer n
replicate n c = tabulate n (const c)

||| Uppercase every character. Length-preserving, so no existential
||| needed.
export
toUpper : TextBuffer n -> TextBuffer n
toUpper buf = rewrite sym (lengthCorrect buf) in tabulate (length buf) (\i => toUpper (unsafeIndex buf i))

||| Lowercase every character. Length-preserving, so no existential
||| needed.
export
toLower : TextBuffer n -> TextBuffer n
toLower buf = rewrite sym (lengthCorrect buf) in tabulate (length buf) (\i => toLower (unsafeIndex buf i))

-- ---------------------------------------------------------------------------
-- Dynamic-length operations, all returning an existential
-- `(m ** TextBuffer m)` (or a list thereof) like `fromString`.

-- Every operation below builds its result by pre-computing the exact
-- output length and then writing straight into a single freshly
-- `mkEmpty`'d buffer via `unsafe_write_char`, all inside one
-- `unsafePerformIO` -- no `List Char` round trip through `toList`/
-- `fromCharList`. Same idea as `tabulate` above, just reading from an
-- existing buffer's own `unsafeIndex` instead of an arbitrary `f`.

totalLength : List (n ** TextBuffer n) -> Nat
totalLength [] = 0
totalLength ((_ ** b) :: rest) = length b + totalLength rest

||| Copy `fuel` characters of `src` (starting at `srcOffset`) into
||| `dest` starting at `destOffset`.
copyInto : (dest : GCAnyPtr) -> (destOffset : Nat) -> (src : TextBuffer bn) -> (fuel : Nat) -> (srcOffset : Nat) -> IO ()
copyInto dest destOffset src Z srcOffset = pure ()
copyInto dest destOffset src (S fuel) srcOffset = do
  primIO $ prim__TextBuffer_unsafe_write_char dest (cast destOffset) (cast (unsafeIndex src srcOffset))
  copyInto dest (S destOffset) src fuel (S srcOffset)

||| Write `fuel` copies of `c` into `dest` starting at `destOffset`.
fillChar : (dest : GCAnyPtr) -> (destOffset : Nat) -> Char -> (fuel : Nat) -> IO ()
fillChar dest destOffset c Z = pure ()
fillChar dest destOffset c (S fuel) = do
  primIO $ prim__TextBuffer_unsafe_write_char dest (cast destOffset) (cast c)
  fillChar dest (S destOffset) c fuel

||| The first index `>= start` (bounded by `start + fuel`) at which
||| `p` no longer holds -- the split point `span`/`ltrim` scan for.
scanWhile : (Char -> Bool) -> TextBuffer n -> (fuel : Nat) -> Nat -> Nat
scanWhile p buf Z i = i
scanWhile p buf (S fuel) i = if p (unsafeIndex buf i) then scanWhile p buf fuel (S i) else i

||| The length `<= len` (bounded by `fuel` steps down from `len`) such
||| that the character just before it no longer satisfies `p` -- the
||| "keep length" `rtrim` scans for, from the right.
scanWhileBack : (Char -> Bool) -> TextBuffer n -> (fuel : Nat) -> (len : Nat) -> Nat
scanWhileBack p buf Z len = len
scanWhileBack p buf (S fuel) Z = Z
scanWhileBack p buf (S fuel) (S len) = if p (unsafeIndex buf len) then scanWhileBack p buf fuel len else S len

||| Extract a substring of the given length, starting at the given
||| offset. Clamped to the source Text's actual bounds.
export
substr : (start, len : Nat) -> TextBuffer n -> (m ** TextBuffer m)
substr start len buf =
  let bufLen = length buf
      copyLen = min len (bufLen `minus` start)
  in unsafePerformIO $ do
    ptr <- primIO $ prim__TextBuffer_mkEmpty (cast copyLen)
    gcptr <- onCollectAny ptr freeTextBuffer
    copyInto gcptr 0 buf copyLen start
    pure (copyLen ** MkTextBuffer gcptr)

||| Splits `buf` wherever `p` holds, one character at a time (`fuel`
||| decreasing by exactly 1 per character scanned, so this is
||| structurally total without needing a variable-length fuel jump).
||| `pieceStart` marks where the current (not-yet-emitted) piece
||| began; hitting a separator emits `[pieceStart, pos)` and starts a
||| fresh piece right after it, matching `Data.List.split`'s own
||| one-separator-at-a-time semantics (consecutive separators produce
||| empty pieces in between).
scanSplit : (Char -> Bool) -> TextBuffer n -> (fuel : Nat) -> (pos : Nat) -> (pieceStart : Nat) -> List (m ** TextBuffer m)
scanSplit p buf Z pos pieceStart = [substr pieceStart (pos `minus` pieceStart) buf]
scanSplit p buf (S fuel) pos pieceStart =
  if p (unsafeIndex buf pos)
    then substr pieceStart (pos `minus` pieceStart) buf :: scanSplit p buf fuel (S pos) (S pos)
    else scanSplit p buf fuel (S pos) pieceStart

||| Splits `buf` on `\n`, `\r`, or `\r\n`, one character at a time
||| like `scanSplit`. Unlike `scanSplit`, a trailing newline doesn't
||| produce a trailing empty piece: reaching the end exactly at a
||| piece boundary (`pos == pieceStart`, i.e. the last thing scanned
||| was itself a newline, or the buffer was empty) emits nothing
||| further, matching `Data.String.lines`.
scanLines : TextBuffer n -> (fuel : Nat) -> (pos : Nat) -> (pieceStart : Nat) -> List (m ** TextBuffer m)
scanLines buf Z pos pieceStart =
  if pos == pieceStart then [] else [substr pieceStart (pos `minus` pieceStart) buf]
scanLines buf (S fuel) pos pieceStart =
  case unsafeIndex buf pos of
    '\n' => substr pieceStart (pos `minus` pieceStart) buf :: scanLines buf fuel (S pos) (S pos)
    '\r' => case fuel of
              Z => [substr pieceStart (pos `minus` pieceStart) buf]
              S fuel' =>
                if unsafeIndex buf (S pos) == '\n'
                  then substr pieceStart (pos `minus` pieceStart) buf :: scanLines buf fuel' (S (S pos)) (S (S pos))
                  else substr pieceStart (pos `minus` pieceStart) buf :: scanLines buf fuel (S pos) (S pos)
    _ => scanLines buf fuel (S pos) pieceStart

concatWriteAll : GCAnyPtr -> Nat -> List (n ** TextBuffer n) -> IO ()
concatWriteAll p destOffset [] = pure ()
concatWriteAll p destOffset ((_ ** b) :: rest) = do
  copyInto p destOffset b (length b) 0
  concatWriteAll p (destOffset + length b) rest

||| Concatenate a list of Texts into one.
export
concat : List (n ** TextBuffer n) -> (m ** TextBuffer m)
concat xs = unsafePerformIO $ do
  let totalLen = totalLength xs
  ptr <- primIO $ prim__TextBuffer_mkEmpty (cast totalLen)
  gcptr <- onCollectAny ptr freeTextBuffer
  concatWriteAll gcptr 0 xs
  pure (totalLen ** MkTextBuffer gcptr)

joinTotalLength : Nat -> List (n ** TextBuffer n) -> Nat
joinTotalLength sepLen [] = 0
joinTotalLength sepLen ((_ ** b) :: []) = length b
joinTotalLength sepLen ((_ ** b) :: rest@(_ :: _)) = length b + sepLen + joinTotalLength sepLen rest

joinWriteAll : GCAnyPtr -> Nat -> TextBuffer k -> List (n ** TextBuffer n) -> IO ()
joinWriteAll p destOffset sep [] = pure ()
joinWriteAll p destOffset sep ((_ ** b) :: []) = copyInto p destOffset b (length b) 0
joinWriteAll p destOffset sep ((_ ** b) :: rest@(_ :: _)) = do
  copyInto p destOffset b (length b) 0
  copyInto p (destOffset + length b) sep (length sep) 0
  joinWriteAll p (destOffset + length b + length sep) sep rest

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : TextBuffer k -> List (n ** TextBuffer n) -> (m ** TextBuffer m)
joinBy sep xs = unsafePerformIO $ do
  let totalLen = joinTotalLength (length sep) xs
  ptr <- primIO $ prim__TextBuffer_mkEmpty (cast totalLen)
  gcptr <- onCollectAny ptr freeTextBuffer
  joinWriteAll gcptr 0 sep xs
  pure (totalLen ** MkTextBuffer gcptr)

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long).
export
padLeft : (width : Nat) -> Char -> TextBuffer n -> (m ** TextBuffer m)
padLeft width c buf =
  let bufLen = length buf
      padLen = width `minus` bufLen
      resultLen = padLen + bufLen
  in unsafePerformIO $ do
    ptr <- primIO $ prim__TextBuffer_mkEmpty (cast resultLen)
    gcptr <- onCollectAny ptr freeTextBuffer
    fillChar gcptr 0 c padLen
    copyInto gcptr padLen buf bufLen 0
    pure (resultLen ** MkTextBuffer gcptr)

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long).
export
padRight : (width : Nat) -> Char -> TextBuffer n -> (m ** TextBuffer m)
padRight width c buf =
  let bufLen = length buf
      padLen = width `minus` bufLen
      resultLen = bufLen + padLen
  in unsafePerformIO $ do
    ptr <- primIO $ prim__TextBuffer_mkEmpty (cast resultLen)
    gcptr <- onCollectAny ptr freeTextBuffer
    copyInto gcptr 0 buf bufLen 0
    fillChar gcptr bufLen c padLen
    pure (resultLen ** MkTextBuffer gcptr)

||| Strip whitespace from the left.
export
ltrim : TextBuffer n -> (m ** TextBuffer m)
ltrim buf =
  let bufLen = length buf
      start = scanWhile isSpace buf bufLen 0
  in substr start (bufLen `minus` start) buf

||| Strip whitespace from the right.
export
rtrim : TextBuffer n -> (m ** TextBuffer m)
rtrim buf =
  let bufLen = length buf
      keepLen = scanWhileBack isSpace buf bufLen bufLen
  in substr 0 keepLen buf

||| Strip whitespace from both ends.
export
trim : TextBuffer n -> (m ** TextBuffer m)
trim buf =
  let bufLen = length buf
      start = scanWhile isSpace buf bufLen 0
      keepLen = scanWhileBack isSpace buf bufLen bufLen
  in substr start (keepLen `minus` start) buf

||| Split on runs of whitespace, dropping empty pieces.
export
words : TextBuffer n -> List (m ** TextBuffer m)
words buf = filter (\(_ ** w) => length w > 0) (scanSplit isSpace buf (length buf) 0 0)

||| Join with single spaces.
export
unwords : List (n ** TextBuffer n) -> (m ** TextBuffer m)
unwords xs = joinBy (singleton ' ') xs

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece, matching `Data.String.lines`.
export
lines : TextBuffer n -> List (m ** TextBuffer m)
lines buf = scanLines buf (length buf) 0 0

unlinesTotalLength : List (n ** TextBuffer n) -> Nat
unlinesTotalLength [] = 0
unlinesTotalLength ((_ ** b) :: rest) = length b + 1 + unlinesTotalLength rest

unlinesWriteAll : GCAnyPtr -> Nat -> List (n ** TextBuffer n) -> IO ()
unlinesWriteAll p destOffset [] = pure ()
unlinesWriteAll p destOffset ((_ ** b) :: rest) = do
  copyInto p destOffset b (length b) 0
  primIO $ prim__TextBuffer_unsafe_write_char p (cast (destOffset + length b)) (cast '\n')
  unlinesWriteAll p (destOffset + length b + 1) rest

||| Join, appending a newline after each piece (including the last).
export
unlines : List (n ** TextBuffer n) -> (m ** TextBuffer m)
unlines xs = unsafePerformIO $ do
  let totalLen = unlinesTotalLength xs
  ptr <- primIO $ prim__TextBuffer_mkEmpty (cast totalLen)
  gcptr <- onCollectAny ptr freeTextBuffer
  unlinesWriteAll gcptr 0 xs
  pure (totalLen ** MkTextBuffer gcptr)

||| Split into the longest prefix satisfying the predicate, and the
||| rest.
export
span : (Char -> Bool) -> TextBuffer n -> ((p ** TextBuffer p), (q ** TextBuffer q))
span pred buf =
  let bufLen = length buf
      splitAt = scanWhile pred buf bufLen 0
  in (substr 0 splitAt buf, substr splitAt (bufLen `minus` splitAt) buf)

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> TextBuffer n -> ((p ** TextBuffer p), (q ** TextBuffer q))
break p buf = span (not . p) buf

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> TextBuffer n -> List (m ** TextBuffer m)
split p buf = scanSplit p buf (length buf) 0 0
