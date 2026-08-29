module Data.TextBuffer

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import Data.Fin
import Data.So
import Data.Vect

-- ---------------------------------------------------------------------------

||| The Text type, representing a Unicode codepoint sequence. `length`
||| (an FFI re-read of the underlying C buffer's own `len` field) is
||| this module's only source of truth for how long a given `TextBuffer`
||| is -- nothing here tracks it separately in the type. A function
||| that genuinely needs to relate a `Nat` to a specific buffer's
||| length (a `Fin` bound, a range precondition, a `Vect`'s own length)
||| takes an explicit, erased `(0 _ : n = length buf)` witness for
||| exactly that purpose instead of indexing the whole type by it --
||| see `index`/`substr`/`fastMap'` below.
export
data TextBuffer : Type where
  MkTextBuffer : GCAnyPtr -> TextBuffer

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
-- Every buffer-producing function below goes through one of these:
-- `wrapBuffer` attaches the GC finalizer to an already-obtained raw
-- pointer (from `mkEmpty` or a primitive that builds one directly, e.g.
-- `String_to_TextBuffer`/`append`); `allocBuffer` is `wrapBuffer` of a
-- fresh `mkEmpty`; `build` additionally runs a caller-given action to
-- populate that fresh buffer before handing it back.

freeTextBuffer : AnyPtr -> IO ()
freeTextBuffer ptr = primIO $ prim__TextBuffer_free ptr

wrapBuffer : AnyPtr -> IO GCAnyPtr
wrapBuffer ptr = onCollectAny ptr freeTextBuffer

allocBuffer : (len : Nat) -> IO GCAnyPtr
allocBuffer len = wrapBuffer =<< primIO (prim__TextBuffer_mkEmpty (cast len))

build : (len : Nat) -> (GCAnyPtr -> IO ()) -> TextBuffer
build len action = unsafePerformIO $ do
  gcptr <- allocBuffer len
  action gcptr
  pure (MkTextBuffer gcptr)

||| Convert a String to Text.
export
fromString : String -> TextBuffer
fromString s = unsafePerformIO $ MkTextBuffer <$> (wrapBuffer =<< primIO (prim__String_to_TextBuffer s))

-- Same C symbol as prim__String_to_TextBuffer above, just typed
-- against an already-raw AnyPtr instead of a boxed Idris String --
-- idris2rc2_String_to_TextBuffer only ever sees a plain, NUL-
-- terminated `const char *` at the C ABI level regardless (an Idris
-- `String` %foreign argument is itself passed to C as a raw `char *`,
-- no separate marshalling step), so this reuses the identical decode
-- loop with no new C code, for a caller that already has a raw
-- pointer and doesn't want to force it through a boxed String first.
%foreign "C:idris2rc2_String_to_TextBuffer,libidris2rc2base,text_util.h"
prim__RawUtf8_to_TextBuffer : AnyPtr -> PrimIO AnyPtr

||| Erased (`0`-multiplicity, zero runtime cost), `Data.So`-based proof
||| that a raw `AnyPtr` is non-NULL. `idris2rc2_String_to_TextBuffer`
||| (`prim__RawUtf8_to_TextBuffer` below) unconditionally dereferences
||| its own argument with no NULL check of its own (same contract as
||| `strlen`) -- rather than leave that precondition as a doc comment a
||| caller could forget, `fromRawUtf8` demands one of these, obtained
||| via `Data.So.choose (prim__nullAnyPtr ptr == 0)` at the call site.
public export
NonNullPtr : AnyPtr -> Type
NonNullPtr ptr = So (prim__nullAnyPtr ptr == 0)

||| Convert a raw, NUL-terminated UTF-8 byte buffer directly to Text --
||| one decode copy (raw bytes -> codepoint array), the same work
||| `fromString` above does, without a boxed Idris `String` in between.
||| `ok` -- see `NonNullPtr`'s own doc comment; a caller can only reach
||| this function after actually performing that check, not merely
||| documenting it. Deliberately sequenced (`IO`), not pure like
||| `fromString` above: `ptr` is expected to come from external,
||| C-managed memory with its own lifetime window (e.g. a libcurl
||| response buffer, valid only between some "capture finished" point
||| and its own release) -- unlike an immutable Idris `String`,
||| `unsafePerformIO` here could let the optimizer reorder this read
||| relative to that window.
export
fromRawUtf8 : (ptr : AnyPtr) -> (0 ok : NonNullPtr ptr) -> IO TextBuffer
fromRawUtf8 ptr _ = MkTextBuffer <$> (wrapBuffer =<< primIO (prim__RawUtf8_to_TextBuffer ptr))

||| Convert a Text back to a String.
export
toString : TextBuffer -> String
toString (MkTextBuffer ptr) = believe_me $ unsafePerformIO $ primIO $ prim__TextBuffer_toString ptr

||| Get the length of the Text.
export
length : TextBuffer -> Nat
length (MkTextBuffer ptr) =
  fromInteger $ cast $ unsafePerformIO $ primIO $ prim__textLength ptr

||| Get the character at the given index.
export
index : (buf : TextBuffer) -> {0 n : Nat} -> {auto 0 prf : n = length buf} -> Fin n -> Char
index (MkTextBuffer ptr) idx = cast $ unsafePerformIO $ primIO $ prim__textIndex ptr (cast (finToNat idx))

||| Append two Texts.
export
(++) : TextBuffer -> TextBuffer -> TextBuffer
(++) (MkTextBuffer p1) (MkTextBuffer p2) =
  unsafePerformIO $ MkTextBuffer <$> (wrapBuffer =<< primIO (prim__TextBuffer_append p1 p2))

-- ---------------------------------------------------------------------------
-- Shared construction/deconstruction primitives. Everything below this
-- point is built purely in terms of these plus the C primitives above
-- -- no new %foreign declarations are introduced past this point.

||| Read the character at a raw Nat offset, without a `Fin n` bounds
||| proof. Only meant for internal use by loops here that already
||| guarantee the offset is in range by construction (e.g. counting up
||| to a buffer's own `length`).
unsafeIndex : TextBuffer -> Nat -> Char
unsafeIndex (MkTextBuffer ptr) i = cast $ unsafePerformIO $ primIO $ prim__textIndex ptr (cast i)

||| Build a Text of the given length by evaluating `f` at each index.
||| The `fuel` parameter is `n` itself, counted down, so this
||| structurally terminates under this package's `--total`.
export
tabulate : (n : Nat) -> (Nat -> Char) -> TextBuffer
tabulate n f = build n (\p => writeLoop p n 0)
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
toList : TextBuffer -> List Char
toList buf = go (length buf) 0
  where
    go : (fuel : Nat) -> Nat -> List Char
    go Z _ = []
    go (S fuel) i = unsafeIndex buf i :: go fuel (S i)

||| The inverse of `toList`.
export
fromCharList : List Char -> TextBuffer
fromCharList cs = build (length cs) (\p => writeLoop p 0 cs)
  where
    writeLoop : GCAnyPtr -> Nat -> List Char -> IO ()
    writeLoop p i [] = pure ()
    writeLoop p i (c :: rest) = do
      primIO $ prim__TextBuffer_unsafe_write_char p (cast i) (cast c)
      writeLoop p (S i) rest

||| `map f . toList` fused into a single index-based pass -- no
||| intermediate `List Char` gets read out of the buffer just to
||| immediately map over it.
export
fastMap : (Char -> a) -> TextBuffer -> List a
fastMap f buf = go (length buf) 0
  where
    go : (fuel : Nat) -> Nat -> List a
    go Z _ = []
    go (S fuel) i = f (unsafeIndex buf i) :: go fuel (S i)

||| Like `fastMap`, but into a `Vect` of the buffer's own exact length
||| instead of a `List` -- useful when the caller wants that length
||| carried in the type rather than re-deriving it.
export
fastMap' : (f : Char -> a) -> (buf : TextBuffer) -> {0 n : Nat} -> {auto 0 prf : n = length buf} -> Vect n a
fastMap' f buf {prf = Refl} = go (length buf) 0
  where
    go : (fuel : Nat) -> Nat -> Vect fuel a
    go Z i = []
    go (S fuel) i = f (unsafeIndex buf i) :: go fuel (S i)

-- ---------------------------------------------------------------------------
-- Construction helpers.

||| A Text of a single character.
export
singleton : Char -> TextBuffer
singleton c = tabulate 1 (const c)

||| A Text of `n` copies of a character.
export
replicate : (n : Nat) -> Char -> TextBuffer
replicate n c = tabulate n (const c)

||| Uppercase every character.
export
toUpper : TextBuffer -> TextBuffer
toUpper buf = tabulate (length buf) (\i => toUpper (unsafeIndex buf i))

||| Lowercase every character.
export
toLower : TextBuffer -> TextBuffer
toLower buf = tabulate (length buf) (\i => toLower (unsafeIndex buf i))

-- ---------------------------------------------------------------------------
-- Dynamic-length operations.
--
-- Every one of these builds its result by pre-computing the exact
-- output length and then writing straight into a single freshly
-- `mkEmpty`'d buffer via `unsafe_write_char` (through `build`/
-- `copyInto`/`copyAll`/`fillChar`), all inside one `unsafePerformIO`
-- -- no `List Char` round trip through `toList`/`fromCharList`. Same
-- idea as `tabulate` above, just reading from an existing buffer's
-- own `unsafeIndex` instead of an arbitrary `f`.

||| Copy `fuel` characters of `src` (starting at `srcOffset`) into
||| `dest` starting at `destOffset`.
copyInto : (dest : GCAnyPtr) -> (destOffset : Nat) -> (src : TextBuffer) -> (fuel : Nat) -> (srcOffset : Nat) -> IO ()
copyInto dest destOffset src Z srcOffset = pure ()
copyInto dest destOffset src (S fuel) srcOffset = do
  primIO $ prim__TextBuffer_unsafe_write_char dest (cast destOffset) (cast (unsafeIndex src srcOffset))
  copyInto dest (S destOffset) src fuel (S srcOffset)

||| `copyInto`, copying all of `src`.
copyAll : (dest : GCAnyPtr) -> (destOffset : Nat) -> (src : TextBuffer) -> IO ()
copyAll dest destOffset src = copyInto dest destOffset src (length src) 0

||| Write `fuel` copies of `c` into `dest` starting at `destOffset`.
fillChar : (dest : GCAnyPtr) -> (destOffset : Nat) -> Char -> (fuel : Nat) -> IO ()
fillChar dest destOffset c Z = pure ()
fillChar dest destOffset c (S fuel) = do
  primIO $ prim__TextBuffer_unsafe_write_char dest (cast destOffset) (cast c)
  fillChar dest (S destOffset) c fuel

||| The first index `>= start` (bounded by `start + fuel`) at which
||| `p` no longer holds -- the split point `span`/`ltrim` scan for.
scanWhile : (Char -> Bool) -> TextBuffer -> (fuel : Nat) -> Nat -> Nat
scanWhile p buf Z i = i
scanWhile p buf (S fuel) i = if p (unsafeIndex buf i) then scanWhile p buf fuel (S i) else i

||| The length `<= len` (bounded by `fuel` steps down from `len`) such
||| that the character just before it no longer satisfies `p` -- the
||| "keep length" `rtrim` scans for, from the right.
scanWhileBack : (Char -> Bool) -> TextBuffer -> (fuel : Nat) -> (len : Nat) -> Nat
scanWhileBack p buf Z len = len
scanWhileBack p buf (S fuel) Z = Z
scanWhileBack p buf (S fuel) (S len) = if p (unsafeIndex buf len) then scanWhileBack p buf fuel len else S len

||| `substr`, clamped to the source Text's actual bounds instead of
||| requiring a proof -- used internally by scans (`ltrim`/`span`/...)
||| whose bounds are only known at runtime, never statically provable
||| the way `substr`'s own `LTE` precondition demands.
substrClamped : (start, len : Nat) -> TextBuffer -> TextBuffer
substrClamped start len buf =
  let copyLen = min len (length buf `minus` start)
  in build copyLen (\p => copyInto p 0 buf copyLen start)

||| Extract a substring of exactly `len` characters starting at
||| `start`. Requires a proof that `start + len` doesn't exceed the
||| buffer's own length -- unlike most of this module's other
||| operations, this one doesn't silently clamp.
export
substr : (start, len : Nat) -> (buf : TextBuffer) -> {0 n : Nat} -> {auto 0 prf : n = length buf} -> {auto ok : LTE (start + len) n} -> TextBuffer
substr start len buf = build len (\p => copyInto p 0 buf len start)

||| Splits `buf` wherever `p` holds, one character at a time (`fuel`
||| decreasing by exactly 1 per character scanned, so this is
||| structurally total without needing a variable-length fuel jump).
||| `pieceStart` marks where the current (not-yet-emitted) piece
||| began; hitting a separator emits `[pieceStart, pos)` and starts a
||| fresh piece right after it, matching `Data.List.split`'s own
||| one-separator-at-a-time semantics (consecutive separators produce
||| empty pieces in between).
scanSplit : (Char -> Bool) -> TextBuffer -> (fuel : Nat) -> (pos : Nat) -> (pieceStart : Nat) -> List TextBuffer
scanSplit p buf Z pos pieceStart = [substrClamped pieceStart (pos `minus` pieceStart) buf]
scanSplit p buf (S fuel) pos pieceStart =
  if p (unsafeIndex buf pos)
    then substrClamped pieceStart (pos `minus` pieceStart) buf :: scanSplit p buf fuel (S pos) (S pos)
    else scanSplit p buf fuel (S pos) pieceStart

||| The combined length of a list of Texts.
export
totalLength : List TextBuffer -> Nat
totalLength = foldr (\b, acc => length b + acc) 0

||| Concatenate a list of Texts into one.
export
concat : List TextBuffer -> TextBuffer
concat xs = build (totalLength xs) (\p => writeAll p 0 xs)
  where
    writeAll : GCAnyPtr -> Nat -> List TextBuffer -> IO ()
    writeAll p destOffset [] = pure ()
    writeAll p destOffset (b :: rest) = do
      copyAll p destOffset b
      writeAll p (destOffset + length b) rest

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : TextBuffer -> List TextBuffer -> TextBuffer
joinBy sep xs = build (totalLength xs + (List.length xs `minus` 1) * length sep) (\p => writeAll p 0 xs)
  where
    writeAll : GCAnyPtr -> Nat -> List TextBuffer -> IO ()
    writeAll p destOffset [] = pure ()
    writeAll p destOffset (b :: []) = copyAll p destOffset b
    writeAll p destOffset (b :: rest@(_ :: _)) = do
      copyAll p destOffset b
      copyAll p (destOffset + length b) sep
      writeAll p (destOffset + length b + length sep) rest

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long).
export
padLeft : (width : Nat) -> Char -> TextBuffer -> TextBuffer
padLeft width c buf =
  let padLen = width `minus` length buf
  in build (padLen + length buf) (\p => fillChar p 0 c padLen >> copyAll p padLen buf)

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long).
export
padRight : (width : Nat) -> Char -> TextBuffer -> TextBuffer
padRight width c buf =
  let padLen = width `minus` length buf
  in build (length buf + padLen) (\p => copyAll p 0 buf >> fillChar p (length buf) c padLen)

||| Strip whitespace from the left.
export
ltrim : TextBuffer -> TextBuffer
ltrim buf =
  let start = scanWhile isSpace buf (length buf) 0
  in substrClamped start (length buf `minus` start) buf

||| Strip whitespace from the right.
export
rtrim : TextBuffer -> TextBuffer
rtrim buf = substrClamped 0 (scanWhileBack isSpace buf (length buf) (length buf)) buf

||| Strip whitespace from both ends.
export
trim : TextBuffer -> TextBuffer
trim buf =
  let bufLen = length buf
      start = scanWhile isSpace buf bufLen 0
      keepLen = scanWhileBack isSpace buf bufLen bufLen
  in substrClamped start (keepLen `minus` start) buf

||| Split on runs of whitespace, dropping empty pieces.
export
words : TextBuffer -> List TextBuffer
words buf = filter (\w => length w > 0) (scanSplit isSpace buf (length buf) 0 0)

||| Join with single spaces.
export
unwords : List TextBuffer -> TextBuffer
unwords xs = joinBy (singleton ' ') xs

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece, matching `Data.String.lines`.
export
lines : TextBuffer -> List TextBuffer
lines buf = scanLines (length buf) 0 0
  where
    -- One character at a time (`fuel` decreasing by exactly 1 per
    -- character scanned, so this is structurally total without
    -- needing a variable-length fuel jump). Unlike `scanSplit`, a
    -- trailing newline doesn't produce a trailing empty piece:
    -- reaching the end exactly at a piece boundary (`pos ==
    -- pieceStart`, i.e. the last thing scanned was itself a newline,
    -- or the buffer was empty) emits nothing further, matching
    -- `Data.String.lines`.
    scanLines : (fuel : Nat) -> (pos : Nat) -> (pieceStart : Nat) -> List TextBuffer
    scanLines Z pos pieceStart =
      if pos == pieceStart then [] else [substrClamped pieceStart (pos `minus` pieceStart) buf]
    scanLines (S fuel) pos pieceStart =
      case unsafeIndex buf pos of
        '\n' => substrClamped pieceStart (pos `minus` pieceStart) buf :: scanLines fuel (S pos) (S pos)
        '\r' => case fuel of
                  Z => [substrClamped pieceStart (pos `minus` pieceStart) buf]
                  S fuel' =>
                    if unsafeIndex buf (S pos) == '\n'
                      then substrClamped pieceStart (pos `minus` pieceStart) buf :: scanLines fuel' (S (S pos)) (S (S pos))
                      else substrClamped pieceStart (pos `minus` pieceStart) buf :: scanLines fuel (S pos) (S pos)
        _ => scanLines fuel (S pos) pieceStart

||| Join, appending a newline after each piece (including the last).
export
unlines : List TextBuffer -> TextBuffer
unlines xs = build (totalLength xs + List.length xs) (\p => writeAll p 0 xs)
  where
    writeAll : GCAnyPtr -> Nat -> List TextBuffer -> IO ()
    writeAll p destOffset [] = pure ()
    writeAll p destOffset (b :: rest) = do
      copyAll p destOffset b
      primIO $ prim__TextBuffer_unsafe_write_char p (cast (destOffset + length b)) (cast '\n')
      writeAll p (destOffset + length b + 1) rest

||| Split into the longest prefix satisfying the predicate, and the
||| rest.
export
span : (Char -> Bool) -> TextBuffer -> (TextBuffer, TextBuffer)
span pred buf =
  let splitAt = scanWhile pred buf (length buf) 0
  in (substrClamped 0 splitAt buf, substrClamped splitAt (length buf `minus` splitAt) buf)

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> TextBuffer -> (TextBuffer, TextBuffer)
break p buf = span (not . p) buf

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> TextBuffer -> List TextBuffer
split p buf = scanSplit p buf (length buf) 0 0
