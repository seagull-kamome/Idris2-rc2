module Data.TextBuffer

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import Data.Fin
import Data.List
import Data.List1

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

||| Extract a substring of the given length, starting at the given
||| offset. Clamped to the source Text's actual bounds.
export
substr : (start, len : Nat) -> TextBuffer n -> (m ** TextBuffer m)
substr start len buf = fromCharList (take len (drop start (toList buf)))

||| Concatenate a list of Texts into one.
export
concat : List (n ** TextBuffer n) -> (m ** TextBuffer m)
concat xs = fromCharList (concatMap (\(_ ** b) => toList b) xs)

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : TextBuffer k -> List (n ** TextBuffer n) -> (m ** TextBuffer m)
joinBy sep xs = fromCharList (concatMap id (intersperse (toList sep) (map (\(_ ** b) => toList b) xs)))

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long).
export
padLeft : (width : Nat) -> Char -> TextBuffer n -> (m ** TextBuffer m)
padLeft width c buf =
  let cs = toList buf
  in fromCharList (replicate (width `minus` length cs) c ++ cs)

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long).
export
padRight : (width : Nat) -> Char -> TextBuffer n -> (m ** TextBuffer m)
padRight width c buf =
  let cs = toList buf
  in fromCharList (cs ++ replicate (width `minus` length cs) c)

||| Strip whitespace from the left.
export
ltrim : TextBuffer n -> (m ** TextBuffer m)
ltrim buf = fromCharList (dropWhile isSpace (toList buf))

||| Strip whitespace from the right.
export
rtrim : TextBuffer n -> (m ** TextBuffer m)
rtrim buf = fromCharList (reverse (dropWhile isSpace (reverse (toList buf))))

||| Strip whitespace from both ends.
export
trim : TextBuffer n -> (m ** TextBuffer m)
trim buf = let (_ ** t) = ltrim buf in rtrim t

||| Split on runs of whitespace, dropping empty pieces.
export
words : TextBuffer n -> List (m ** TextBuffer m)
words buf = map fromCharList (filter (not . null) (forget (split isSpace (toList buf))))

||| Join with single spaces.
export
unwords : List (n ** TextBuffer n) -> (m ** TextBuffer m)
unwords xs = joinBy (singleton ' ') xs

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece, matching `Data.String.lines`.
export
lines : TextBuffer n -> List (m ** TextBuffer m)
lines buf = map fromCharList (go [] (toList buf))
  where
    go : List Char -> List Char -> List (List Char)
    go [] [] = []
    go acc [] = [reverse acc]
    go acc ('\n' :: xs) = reverse acc :: go [] xs
    go acc ('\r' :: '\n' :: xs) = reverse acc :: go [] xs
    go acc ('\r' :: xs) = reverse acc :: go [] xs
    go acc (c :: xs) = go (c :: acc) xs

||| Join, appending a newline after each piece (including the last).
export
unlines : List (n ** TextBuffer n) -> (m ** TextBuffer m)
unlines xs = fromCharList (concatMap (\(_ ** b) => toList b ++ ['\n']) xs)

||| Split into the longest prefix satisfying the predicate, and the
||| rest.
export
span : (Char -> Bool) -> TextBuffer n -> ((p ** TextBuffer p), (q ** TextBuffer q))
span p buf = let (a, b) = span p (toList buf) in (fromCharList a, fromCharList b)

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> TextBuffer n -> ((p ** TextBuffer p), (q ** TextBuffer q))
break p buf = span (not . p) buf

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> TextBuffer n -> List (m ** TextBuffer m)
split p buf = map fromCharList (forget (split p (toList buf)))
