||| What the single-line text field and the multi-line editor share: which
||| characters are kept, the horizontal scrolling and the mapping from a cell
||| to a character.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Widget.LineEdit

import Data.List
import TermUI.Len
import TermUI.Width

%default total

||| A tab becomes a space and other control characters are dropped.
export
clean : Char -> List Char
clean c =
  if c == '\t' then [' ']
  else if charWidth c == 0 && ord c < 0xA0 then []
  else [c]

||| The cursor cell is as wide as the character under it, and at least one.
export
cursorWidth : (after : List Char) -> Len
cursorWidth (c :: _) = max 1 (charWidth c)
cursorWidth [] = 1

||| The number of characters scrolled out on the left, so that the cursor cell
||| fits in `room` cells: the current `left` if it already does, otherwise as
||| little more as needed. `before` is the text before the cursor, reversed.
export
leftFor : (room : Len) -> (cursorW : Len) -> (left : Nat) -> (before : List Char) -> Nat
leftFor room cursorW left before =
  let pos = length before
  in max (min left pos) (pos `minus` fitting before (room `monus` cursorW) 0)
  where
    -- how many characters, from the cursor back, fit in the budget
    fitting : List Char -> Len -> Nat -> Nat
    fitting [] _ acc = acc
    fitting (c :: cs) budget acc =
      if charWidth c <= budget then fitting cs (budget `monus` charWidth c) (S acc) else acc

||| The index of the character under cell `col`, counting from index `from`
||| over the characters `chars` (which start there).
export
reach : (col : Len) -> (chars : List Char) -> (from : Nat) -> Nat
reach _ [] i = i
reach col (x :: xs) i = if charWidth x > col then i else reach (col `monus` charWidth x) xs (S i)

||| The characters that fit in `room` cells.
export
cutTo : (room : Len) -> List Char -> List Char
cutTo _ [] = []
cutTo room (c :: cs) = if charWidth c <= room then c :: cutTo (room `monus` charWidth c) cs else []

-- Spaces, the characters of words (letters, digits, `_` and everything
-- beyond ASCII) and the rest each make a kind of run.
kindOf : Char -> Nat
kindOf c = if c == ' ' then 0 else if isAlphaNum c || c == '_' || ord c >= 128 then 1 else 2

||| The range of character indexes `[lo, hi)` of the run of one kind (word,
||| spaces, punctuation) that the character `idx` is in; at the end of the
||| text, the last run.
export
wordRange : (chars : List Char) -> (idx : Nat) -> (Nat, Nat)
wordRange [] _ = (0, 0)
wordRange chars idx =
  let i = min idx (length chars `minus` 1)
      k = maybe 0 kindOf (head' (drop i chars))
      same = \c => kindOf c == k
  in (i `minus` length (takeWhile same (reverse (take i chars))), i + length (takeWhile same (drop i chars)))
