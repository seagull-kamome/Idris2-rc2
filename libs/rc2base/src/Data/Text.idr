module Data.Text

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A rope over Data.TextBuffer chunks, backed by contrib's own 2-3
-- finger tree (Hinze/Paterson): `Data.Seq.Unsized.Seq`. TextBuffer's
-- own (++) is O(n) (it memcpys both sides into a fresh buffer every
-- time), which makes repeated small concatenations O(n^2) overall;
-- wrapping chunks in a finger tree instead makes (++) O(log(min(n,m))).
--
-- This module used to carry its own hand-rolled copy of that same
-- finger tree engine (Digit/Node/FingerTree, consTree/snocTree/
-- addTree0 -- itself a port of Data.Seq.Internal's algorithm, adapted
-- from the `containers` package's Data.Sequence). Once this module's
-- own Sized cache was dropped (nothing here ever branched on a size
-- value, only on which Digit constructor was in hand), the two
-- implementations had nothing left distinguishing them, so the
-- hand-rolled copy was replaced with `Seq` directly: one less engine
-- to maintain, and contrib's version is `%default total` with no
-- partial functions.
--
-- `Seq`'s own element wrapper (`Elem`) fixes its internal size
-- annotation at a constant 1 per element regardless of what's stored,
-- so `Seq`'s own `index`/`splitAt` count chunks, not characters -- of
-- no consequence here since this module never uses tree-level indexed
-- access anyway (every non-concatenation operation flattens to a
-- single TextBuffer first, see below). `Text` itself is plain `Type`,
-- exactly like `Data.TextBuffer.TextBuffer`; `length` walks the tree
-- structurally (via `Seq`'s own `Foldable`, O(chunk count), no data
-- copied) and is the one source of truth for how long a given `Text`
-- is. A function that genuinely needs to relate a `Nat` to a specific
-- `Text`'s length (just `index`'s `Fin` bound, here) takes an
-- explicit, erased `(0 _ : n = length t)` witness for exactly that
-- purpose instead of indexing the whole type by it.
--
-- Every operation that needs to look at, or rebuild, every chunk
-- but can't avoid touching every character anyway (substr, words,
-- trim, ...) is implemented by flattening to a single TextBuffer and
-- delegating to Data.TextBuffer's own (already-correct) implementation
-- -- same asymptotic cost as TextBuffer itself, no better, no worse.
-- (++) and the handful of operations built from it (concat, joinBy,
-- unwords, unlines, singleton, replicate) get the tree's O(log n)
-- concatenation win; `index` skips whole chunks instead of copying
-- them, and toUpper/toLower map each chunk in place -- neither needs
-- `flatten` at all.

import Data.TextBuffer
import Data.Seq.Unsized as Seq
import Data.Fin
import Data.List

-- ---------------------------------------------------------------------------
-- The public API. `TextBuffer` itself is already a plain `Type` (see
-- Data.TextBuffer's own header), so it sits directly as `Seq`'s
-- element type with no existential wrapping and no separate `Chunk`
-- alias needed.

export
data Text : Type where
  MkText : Seq TextBuffer -> Text

||| O(chunk count). The length of a Text, summed by walking the tree
||| structurally (via `Seq`'s own `Foldable`) -- no data is copied,
||| contrast with `flatten` below, which builds a single buffer.
export
length : Text -> Nat
length (MkText t) = foldr (\c, acc => TextBuffer.length c + acc) 0 t

||| O(1). Wrap an existing TextBuffer as a single-chunk Text.
export
fromTextBuffer : TextBuffer -> Text
fromTextBuffer tb = MkText (Seq.singleton tb)

||| Convert a String to Text.
export
fromString : String -> Text
fromString s = fromTextBuffer (TextBuffer.fromString s)

-- Collapses a Text's chunks back into a single TextBuffer -- the
-- boundary every operation below that isn't fundamentally about
-- concatenation crosses to reuse Data.TextBuffer's own algorithms.
-- Folds with TextBuffer's own native (++) rather than calling
-- TextBuffer.concat on the chunk list: the overwhelmingly common case
-- is a single-chunk Text (nothing appended to it yet), where this
-- fold is free (foldl returns the one chunk unchanged) but
-- TextBuffer.concat would still allocate and copy into a fresh
-- buffer.
flatten : Text -> TextBuffer
flatten (MkText t) = case toList t of
  [] => TextBuffer.fromString ""
  (x :: xs) => foldl (TextBuffer.(++)) x xs

||| Convert a Text back to a String.
export
toString : Text -> String
toString t = TextBuffer.toString (flatten t)

||| O(log(min(n,m))). Concatenate two Texts.
export
(++) : Text -> Text -> Text
(++) (MkText t1) (MkText t2) = MkText (Seq.(++) t1 t2)

||| A Text of a single character.
export
singleton : Char -> Text
singleton c = fromTextBuffer (TextBuffer.singleton c)

||| A Text of `n` copies of a character.
export
replicate : (n : Nat) -> Char -> Text
replicate n c = fromTextBuffer (TextBuffer.replicate n c)

||| Concatenate a list of Texts into one, O(log) chunk at a time.
export
concat : List Text -> Text
concat = foldl (Data.Text.(++)) (MkText Seq.empty)

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : Text -> List Text -> Text
joinBy sep xs = Data.Text.concat (intersperse sep xs)

||| Join with single spaces.
export
unwords : List Text -> Text
unwords xs = joinBy (Data.Text.fromString " ") xs

||| Join, appending a newline after each piece (including the last).
export
unlines : List Text -> Text
unlines xs = Data.Text.concat (concatMap (\t => [t, Data.Text.fromString "\n"]) xs)

||| Get the character at the given index. Walks the chunk list
||| summing lengths to find the chunk containing the target offset,
||| then delegates to it locally -- no `flatten`, no data copied.
export
index : (t : Text) -> {0 n : Nat} -> {auto 0 prf : n = length t} -> Fin n -> Char
index (MkText t) i = go (toList t) (finToNat i)
  where
    go : List TextBuffer -> Nat -> Char
    go [] _ = believe_me ()
    go (c :: cs) idx =
      if idx < TextBuffer.length c
        then case natToFin idx (TextBuffer.length c) of
               Just fin => TextBuffer.index c {n = TextBuffer.length c} {prf = Refl} fin
               Nothing => believe_me ()
        else go cs (idx `minus` TextBuffer.length c)

||| Uppercase every character. Length-preserving. Maps each chunk in
||| place -- no `flatten`, no merging into a single buffer.
export
toUpper : Text -> Text
toUpper (MkText t) = MkText (map TextBuffer.toUpper t)

||| Lowercase every character. Length-preserving. Maps each chunk in
||| place -- no `flatten`, no merging into a single buffer.
export
toLower : Text -> Text
toLower (MkText t) = MkText (map TextBuffer.toLower t)

-- ---------------------------------------------------------------------------
-- Range extraction: skip whole chunks outside the target range without
-- touching them, copy only the chunk(s) the range actually overlaps,
-- and stitch the (usually one, occasionally a handful of) resulting
-- pieces into a single fresh TextBuffer. `words`/`lines`/`split` are
-- the exception -- they must inspect every character regardless of
-- chunking to find every delimiter, so no range can be skipped, and
-- they stay on the simpler `flatten`-then-delegate path below.

-- Copies exactly `len` characters starting at global offset `start`
-- out of `chunks`, touching only the chunk(s) that range overlaps.
-- Chunks entirely before `start` are skipped by their length alone,
-- no copy. Structurally recurses on the chunk list, so no fuel is
-- needed.
extractRange : (start, len : Nat) -> List TextBuffer -> TextBuffer
extractRange start len chunks = case collect start len chunks of
    []  => TextBuffer.fromString ""
    [x] => x
    xs  => TextBuffer.concat xs
  where
    collect : Nat -> Nat -> List TextBuffer -> List TextBuffer
    collect _ Z _ = []
    collect _ _ [] = []
    collect skip remaining (c :: cs) =
      let clen = TextBuffer.length c
      in if skip >= clen
           then collect (skip `minus` clen) remaining cs
           else
             let avail = clen `minus` skip
                 takeLen = min remaining avail
                 piece = TextBuffer.substr skip takeLen c {n = clen} {prf = believe_me ()} {ok = believe_me ()}
             in piece :: collect 0 (remaining `minus` takeLen) cs

-- The global offset at which `p` first stops holding, found by
-- delegating to `TextBuffer.span` one chunk at a time and stopping as
-- soon as a chunk's own remainder is non-empty -- chunks after that
-- point are never even looked at.
findBoundary : (Char -> Bool) -> List TextBuffer -> Nat
findBoundary p [] = 0
findBoundary p (c :: cs) =
  let (matched, rest) = TextBuffer.span p c
  in if TextBuffer.length rest == 0
       then TextBuffer.length c + findBoundary p cs
       else TextBuffer.length matched

-- The number of trailing characters `TextBuffer.rtrim` would remove,
-- found by walking chunks from the end (caller passes `reverse
-- chunks`) and stopping as soon as a chunk turns out not to be pure
-- trailing whitespace -- chunks before that point are never looked at.
trimmedSuffixLen : List TextBuffer -> Nat
trimmedSuffixLen [] = 0
trimmedSuffixLen (c :: cs) =
  let trimmed = TextBuffer.rtrim c
      removedHere = TextBuffer.length c `minus` TextBuffer.length trimmed
  in if TextBuffer.length trimmed == 0
       then removedHere + trimmedSuffixLen cs
       else removedHere

||| Extract a substring of the given length, starting at the given
||| offset. Clamped to the source Text's actual bounds. Chunks outside
||| the range are skipped, not copied.
export
substr : (start, len : Nat) -> Text -> Text
substr start len t@(MkText s) =
  let n = Data.Text.length t
      copyLen = min len (n `minus` start)
  in fromTextBuffer (extractRange start copyLen (toList s))

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long). When padding is needed, only the new padding
||| chunk is allocated -- the existing chunks are shared, not copied.
export
padLeft : (width : Nat) -> Char -> Text -> Text
padLeft width c t@(MkText s) =
  let n = Data.Text.length t
  in if n >= width then t else MkText (Seq.cons (TextBuffer.replicate (width `minus` n) c) s)

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long). When padding is needed, only the new padding
||| chunk is allocated -- the existing chunks are shared, not copied.
export
padRight : (width : Nat) -> Char -> Text -> Text
padRight width c t@(MkText s) =
  let n = Data.Text.length t
  in if n >= width then t else MkText (Seq.snoc s (TextBuffer.replicate (width `minus` n) c))

||| Strip whitespace from the left. Chunks past the first non-space
||| character are skipped, not copied.
export
ltrim : Text -> Text
ltrim t@(MkText s) =
  let chunks = toList s
      n = Data.Text.length t
      start = findBoundary isSpace chunks
  in fromTextBuffer (extractRange start (n `minus` start) chunks)

||| Strip whitespace from the right. Chunks before the last non-space
||| character are skipped, not copied.
export
rtrim : Text -> Text
rtrim t@(MkText s) =
  let chunks = toList s
      n = Data.Text.length t
      removed = trimmedSuffixLen (reverse chunks)
  in fromTextBuffer (extractRange 0 (n `minus` removed) chunks)

||| Strip whitespace from both ends. Chunks entirely outside the kept
||| range are skipped, not copied.
export
trim : Text -> Text
trim t@(MkText s) =
  let chunks = toList s
      n = Data.Text.length t
      start = findBoundary isSpace chunks
      removed = trimmedSuffixLen (reverse chunks)
  in fromTextBuffer (extractRange start ((n `minus` removed) `minus` start) chunks)

-- ---------------------------------------------------------------------------
-- Everything below flattens to a single TextBuffer and delegates to
-- Data.TextBuffer's own implementation -- same asymptotic cost as
-- TextBuffer itself (no tree-shape reuse). Unlike substr/ltrim/rtrim/
-- trim above, these must examine every character no matter how the
-- text is chunked (to find every delimiter), so there is no range to
-- skip and flattening first costs nothing extra.

||| Split on runs of whitespace, dropping empty pieces.
export
words : Text -> List Text
words t = map fromTextBuffer (TextBuffer.words (flatten t))

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece.
export
lines : Text -> List Text
lines t = map fromTextBuffer (TextBuffer.lines (flatten t))

||| Split into the longest prefix satisfying the predicate, and the
||| rest. Scans chunk by chunk, stopping as soon as the predicate
||| first fails -- chunks past that point are reused inside the
||| extracted ranges, never scanned.
export
span : (Char -> Bool) -> Text -> (Text, Text)
span p t@(MkText s) =
  let chunks = toList s
      n = Data.Text.length t
      boundary = findBoundary p chunks
  in (fromTextBuffer (extractRange 0 boundary chunks), fromTextBuffer (extractRange boundary (n `minus` boundary) chunks))

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> Text -> (Text, Text)
break p t =
  let (a, b) = TextBuffer.break p (flatten t)
  in (fromTextBuffer a, fromTextBuffer b)

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> Text -> List Text
split p t = map fromTextBuffer (TextBuffer.split p (flatten t))
