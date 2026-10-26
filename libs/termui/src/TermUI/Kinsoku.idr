||| Line breaking rules for Japanese text (kinsoku): some characters must not
||| begin a line, others must not end one. A break that would put a character
||| where it must not be moves back, so that the character before goes down
||| with it.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Kinsoku

import Data.List

%default total

-- Not at the start of a line: closing brackets, stops, small kana, the long
-- vowel mark, and the like.
noStart : List Char
noStart = unpack "、。，．・：；？！゛゜ヽヾゝゞ々ー〜）〕］｝〉》」』】〙〗｠»’”‥…‐ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ"

-- Not at the end of a line: opening brackets.
noEnd : List Char
noEnd = unpack "（〔［｛〈《「『【〘〖｟«‘“"

-- How many characters of a break may be pushed down to the next line.
maxPush : Nat
maxPush = 3

||| The length of the line that starts `rest` and was to break after `n`
||| characters, once the rules are kept: shorter by up to three characters. If
||| no break that far back keeps the rules, or the line would be left with
||| nothing, the break stays at `n` and the rule is broken. Only the first
||| `n + 1` characters of `rest` are looked at. Breaks at a space are not
||| moved: the callers use this for a break inside a run of characters.
export
holdBack : (n : Nat) -> (rest : List Char) -> Nat
holdBack n rest = go n (reverse (take (S n) rest)) 0
  where
    go : (k : Nat) -> List Char -> (pushed : Nat) -> Nat
    go k (next :: prev :: more) pushed =
      if not (elem next noStart) && not (elem prev noEnd)
         then k
         else if pushed >= maxPush || k <= 1 then n
         else go (k `minus` 1) (prev :: more) (S pushed)
    go _ _ _ = n
