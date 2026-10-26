||| A small Markdown reader for the terminal: text in, blocks out. It reads what
||| a chat or a help text uses (headings, paragraphs, lists, quotes, fenced code,
||| rules, emphasis, code, links) and nothing more: no tables, no HTML, no
||| setext headings, no indented code, no reference links. Text that is cut
||| short, as in a reply that is still arriving, is read as far as it goes: a
||| fence that is not closed holds the rest of the text, an emphasis that is not
||| closed is plain text. The last line of a text may be one that more text will
||| turn into something else (`#`, `---`), which can change the block before
||| it too; the blocks before the last two stay as they are when more text comes. See
||| libs/termui/doc/design.md ("Markdown").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Markdown

import Data.List
import Data.Maybe

%default covering

||| Text within a line.
public export
data Inline
  = IText String
  | IEmph (List Inline)
  | IStrong (List Inline)
  | IStrike (List Inline)
  | ICode String
  | ILink (List Inline) String
  | IBreak

||| A block. A list item is a list of blocks.
public export
data Block
  = Heading Nat (List Inline)
  | Paragraph (List Inline)
  | CodeBlock String (List String)     -- the info string (the language) and the lines
  | Quote (List Block)
  | Bullets (List (List Block))
  | Numbered Nat (List (List Block))   -- the number of the first item
  | Rule

-------------------------------------------------------------------------------
-- Characters and lines

isSp : Char -> Bool
isSp c = c == ' ' || c == '\t' || c == '\r'

blank : List Char -> Bool
blank = all isSp

trimL, trimR, trimBoth : List Char -> List Char
trimL = dropWhile isSp
trimR = reverse . dropWhile isSp . reverse
trimBoth = trimL . trimR

isDig : Char -> Bool
isDig c = c >= '0' && c <= '9'

isWordChar : Char -> Bool
isWordChar c = isAlphaNum c || ord c > 127

isPunct : Char -> Bool
isPunct c = ord c > 32 && ord c < 127 && not (isAlphaNum c)

-- Leading tabs are four spaces.
detab : List Char -> List Char
detab ('\t' :: r) = ' ' :: ' ' :: ' ' :: ' ' :: detab r
detab (' ' :: r) = ' ' :: detab r
detab r = r

spaces : List Char -> Nat
spaces l = length (takeWhile (== ' ') l)

splitLines : String -> List (List Char)
splitLines s = go [] (unpack s)
  where
    dropCR : List Char -> List Char
    dropCR ('\r' :: r) = r
    dropCR r = r

    go : List Char -> List Char -> List (List Char)
    go acc [] = [detab (reverse acc)]
    go acc ('\n' :: rest) = detab (reverse (dropCR acc)) :: go [] rest
    go acc (c :: rest) = go (c :: acc) rest

-------------------------------------------------------------------------------
-- Inline

-- The length of the run of `c` at the start, and what follows it.
skipRun : Char -> List Char -> (Nat, List Char)
skipRun c cs = let run = takeWhile (== c) cs in (length run, drop (length run) cs)

-- The text up to the run of exactly `n` backticks that closes a code span, and
-- what follows it.
closeTicks : Nat -> List Char -> List Char -> Maybe (List Char, List Char)
closeTicks _ _ [] = Nothing
closeTicks n acc xs@('`' :: _) =
  let (k, after) = skipRun '`' xs
  in if k == n then Just (reverse acc, after) else closeTicks n (replicate k '`' ++ acc) after
closeTicks n acc (x :: xs) = closeTicks n (x :: acc) xs

-- Inside `[ ... ]`: up to the matching `]`.
closeBracket : Nat -> List Char -> List Char -> Maybe (List Char, List Char)
closeBracket _ _ [] = Nothing
closeBracket depth acc ('\\' :: c :: rest) = closeBracket depth (c :: '\\' :: acc) rest
closeBracket depth acc ('[' :: rest) = closeBracket (S depth) ('[' :: acc) rest
closeBracket Z acc (']' :: rest) = Just (reverse acc, rest)
closeBracket (S d) acc (']' :: rest) = closeBracket d (']' :: acc) rest
closeBracket depth acc ('`' :: rest) =
  let (n, after) = skipRun '`' ('`' :: rest)
  in case closeTicks n [] after of
       Just (inner, after') => closeBracket depth (reverse (replicate n '`' ++ inner ++ replicate n '`') ++ acc) after'
       Nothing => closeBracket depth (replicate n '`' ++ acc) after
closeBracket depth acc (c :: rest) = closeBracket depth (c :: acc) rest

-- The address of a link: up to a space or the `)` that closes the link, the
-- parentheses within it paired.
takeAddress : Nat -> List Char -> (List Char, List Char)
takeAddress depth [] = ([], [])
takeAddress depth (c :: rest) =
  if isSp c || (c == ')' && depth == 0) then ([], c :: rest)
  else let (a, b) = takeAddress (if c == '(' then S depth else if c == ')' then depth `minus` 1 else depth) rest
       in (c :: a, b)

-- The text of `( ... )` after a link text: the address and what follows the
-- `)`. A title in quotes after the address is dropped.
linkTarget : List Char -> Maybe (String, List Char)
linkTarget ('(' :: rest) =
  let (url, after) = takeAddress 0 (trimL rest)
  in if null url then Nothing
     else case trimL after of
            (')' :: tail) => Just (pack url, tail)
            (q :: more) =>
              if q == '"' || q == '\''
                 then (case dropWhile (/= q) more of
                         (_ :: more') => (case trimL more' of
                                            (')' :: tail) => Just (pack url, tail)
                                            _ => Nothing)
                         [] => Nothing)
                 else Nothing
            [] => Nothing
linkTarget _ = Nothing

-- Where an emphasis opened by a run of `n` `c`s ends: the text before the
-- closing run (which is the same length, not after a space) and what follows.
findClose : Char -> Nat -> List Char -> Maybe (List Char, List Char)
findClose c n cs = go [] cs
  where
    go : List Char -> List Char -> Maybe (List Char, List Char)
    go _ [] = Nothing
    go acc ('\\' :: x :: xs) = go (x :: '\\' :: acc) xs
    go acc xs@('`' :: _) =
      let (k, after) = skipRun '`' xs
          ticks = replicate k '`'
      in case closeTicks k [] after of
           Just (inner, after') => go (reverse (ticks ++ inner ++ ticks) ++ acc) after'
           Nothing => go (ticks ++ acc) after
    go acc xs@(x :: rest) =
      if x == c
         then let (k, after) = skipRun c xs
              in if (k == n || (n == 2 && k == 3)) && not (null acc) && not (maybe True isSp (head' acc))
                    && (c /= '_' || not (maybe False isWordChar (head' after)))
                    then Just (reverse (replicate (k `minus` n) c ++ acc), after)
                    else go (replicate k c ++ acc) after
         else go (x :: acc) rest

-- The end of a bare address: not the stops and brackets that end a sentence.
addressEnd : List Char -> (List Char, List Char)
addressEnd cs =
  let url = takeWhile (\c => not (isSp c) && c /= '<' && c /= '>' && c /= '"') cs
      trimmed = reverse (dropWhile (\c => elem c (unpack ".,;:!?)]}'")) (reverse url))
  in (trimmed, drop (length trimmed) cs)

mutual
  ||| The inlines of a text; a `\n` in it is a hard line break.
  export
  inlines : List Char -> List Inline
  inlines cs = go [] Nothing cs

  -- `acc` is the plain text so far, reversed; `prev` the character before.
  flush : List Char -> List Inline -> List Inline
  flush [] rest = rest
  flush acc rest = IText (pack (reverse acc)) :: rest

  go : (acc : List Char) -> (prev : Maybe Char) -> List Char -> List Inline
  go acc _ [] = flush acc []
  go acc _ ('\\' :: '\n' :: rest) = flush acc (IBreak :: go [] Nothing rest)
  go acc _ ('\n' :: rest) = flush acc (IBreak :: go [] Nothing rest)
  go acc _ ('\\' :: c :: rest) =
    if isPunct c then go (c :: acc) (Just c) rest else go (c :: '\\' :: acc) (Just c) rest
  go acc prev xs@('`' :: _) =
    let (n, after) = skipRun '`' xs
        ticks = replicate n '`'
    in case closeTicks n [] after of
         Just (inner, after') =>
           let inner' = if length inner >= 2 && head' inner == Just ' ' && last' inner == Just ' ' && not (blank inner)
                           then take (length inner `minus` 2) (drop 1 inner) else inner
           in flush acc (ICode (pack inner') :: go [] (Just '`') after')
         Nothing => go (ticks ++ acc) (Just '`') after
  go acc prev xs@(c :: rest) =
    if c == '*' || c == '_' || c == '~'
       then emphasis acc prev c xs
    else if c == '['
       then link acc prev xs
    else if c == '<'
       then autolink acc prev xs
    else if (c == 'h') && not (maybe False isWordChar prev) && (isPrefixOf (unpack "http://") xs || isPrefixOf (unpack "https://") xs)
       then let (url, after) = addressEnd xs
            in flush acc (ILink [IText (pack url)] (pack url) :: go [] (last' url) after)
    else go (c :: acc) (Just c) rest

  emphasis : (acc : List Char) -> (prev : Maybe Char) -> Char -> List Char -> List Inline
  emphasis acc prev c xs =
    let (run, after) = skipRun c xs
        literal : Unit -> List Inline
        literal () = go (replicate run c ++ acc) (Just c) after
        opens = not (maybe True isSp (head' after)) && not (null after)
                && (c /= '_' || not (maybe False isWordChar prev))
        size = if c == '~' then (if run >= 2 then 2 else 0) else min run 3
        extra = run `minus` size
    in if not opens || size == 0 then literal ()
       else case findClose c size after of
              Nothing => literal ()
              Just (inner, rest) =>
                let kids = inlines inner
                    node = case (c, size) of
                             ('~', _) => IStrike kids
                             (_, 1) => IEmph kids
                             (_, 2) => IStrong kids
                             _ => IStrong [IEmph kids]
                in flush (replicate extra c ++ acc) (node :: go [] (Just c) rest)

  link : (acc : List Char) -> (prev : Maybe Char) -> List Char -> List Inline
  link acc prev xs =
    case xs of
      ('[' :: rest) =>
        case closeBracket 0 [] rest of
          Just (text, after) =>
            case linkTarget after of
              Just (url, tail) => flush acc (ILink (inlines text) url :: go [] (Just ')') tail)
              Nothing => go ('[' :: acc) (Just '[') rest
          Nothing => go ('[' :: acc) (Just '[') rest
      _ => go acc prev xs

  autolink : (acc : List Char) -> (prev : Maybe Char) -> List Char -> List Inline
  autolink acc prev xs =
    case xs of
      ('<' :: rest) =>
        let url = takeWhile (\c => c /= '>' && not (isSp c) && c /= '<') rest
        in case drop (length url) rest of
             ('>' :: tail) =>
               if isInfixOf (unpack "://") url
                  then flush acc (ILink [IText (pack url)] (pack url) :: go [] (Just '>') tail)
                  else go ('<' :: acc) (Just '<') rest
             _ => go ('<' :: acc) (Just '<') rest
      _ => go acc prev xs

-------------------------------------------------------------------------------
-- Blocks

-- A code fence: its character, the length of the run and the info string.
fenceOf : List Char -> Maybe (Char, Nat, String)
fenceOf l =
  if spaces l > 3 then Nothing
  else case drop (spaces l) l of
         xs@(c :: _) =>
           if c == '`' || c == '~'
              then let (n, after) = skipRun c xs
                   in if n >= 3 && not (c == '`' && elem '`' after)
                         then Just (c, n, pack (trimBoth after))
                         else Nothing
              else Nothing
         _ => Nothing

closesFence : Char -> Nat -> List Char -> Bool
closesFence c n l =
  spaces l <= 3 &&
  (let (k, after) = skipRun c (drop (spaces l) l) in k >= n && blank after)

-- ATX heading: the level and the text.
headingOf : List Char -> Maybe (Nat, List Char)
headingOf l =
  if spaces l > 3 then Nothing
  else let (n, after) = skipRun '#' (drop (spaces l) l)
       in if n < 1 || n > 6 then Nothing
          else case after of
                 [] => Just (n, [])
                 (c :: _) => if isSp c then Just (n, closing (trimBoth after)) else Nothing
  where
    -- A closing run of `#`s, after a space, is not text.
    closing : List Char -> List Char
    closing t =
      let body = reverse (dropWhile (== '#') (reverse t))
      in if null body then [] else if maybe False isSp (last' body) then trimR body else t

isRule : List Char -> Bool
isRule l =
  spaces l <= 3 &&
  (case trimBoth l of
     xs@(c :: _) => (c == '-' || c == '*' || c == '_')
                    && all (\x => x == c || isSp x) xs && length (filter (== c) xs) >= 3
     _ => False)

-- A line of a quote, without its marker.
quoteOf : List Char -> Maybe (List Char)
quoteOf l =
  if spaces l > 3 then Nothing
  else case drop (spaces l) l of
         ('>' :: ' ' :: rest) => Just rest
         ('>' :: rest) => Just rest
         _ => Nothing

data Marker = Bul Char | Ord Char

Eq Marker where
  Bul a == Bul b = a == b
  Ord a == Ord b = a == b
  _ == _ = False

-- A list item line: its kind, the number, the column its text starts in and
-- the text.
markerOf : List Char -> Maybe (Marker, Nat, Nat, List Char)
markerOf l =
  let ind = spaces l
      body = drop ind l
  in if ind > 3 then Nothing
     else case body of
            (c :: rest) =>
              if c == '-' || c == '*' || c == '+'
                 then map (\(w, t) => (Bul c, 0, w, t)) (afterMarker (ind + 1) rest)
              else if isDig c
                 then let ds = takeWhile isDig body
                          after = drop (length ds) body
                      in if length ds > 9 then Nothing
                         else case after of
                                (d :: rest') =>
                                  if d == '.' || d == ')'
                                     then map (\(w, t) => (Ord d, number ds, w, t)) (afterMarker (ind + length ds + 1) rest')
                                     else Nothing
                                _ => Nothing
              else Nothing
            _ => Nothing
  where
    number : List Char -> Nat
    number = foldl (\a, d => a * 10 + cast (ord d - ord '0')) 0

    afterMarker : (column : Nat) -> List Char -> Maybe (Nat, List Char)
    afterMarker col [] = Just (col + 1, [])
    afterMarker col xs@(' ' :: _) =
      if blank xs then Just (col + 1, [])
      else let sp = spaces xs
           in if sp > 4 then Just (col + 2, drop 1 xs) else Just (col + sp, drop sp xs)
    afterMarker _ _ = Nothing

-- Text that starts a block cuts a paragraph short.
interrupts : List Char -> Bool
interrupts l =
  isJust (fenceOf l) || isJust (headingOf l) || isRule l || isJust (quoteOf l)
  || (case markerOf l of
        Just (Bul _, _, _, t) => not (blank t)
        Just (Ord _, n, _, t) => n == 1 && not (blank t)
        Nothing => False)

-- The lines of the fenced code and what follows its closing fence.
fenceBody : Char -> Nat -> List (List Char) -> (List (List Char), List (List Char))
fenceBody c n ls =
  let (body, rest) = break (closesFence c n) ls
  in (body, drop 1 rest)

hardBreak : List Char -> Bool
hardBreak l = spaces (reverse l) >= 2 || last' l == Just '\\'

-- A paragraph: the lines up to a blank one or one that starts a block; the
-- line ends become spaces, hard breaks and the rows of a table-like text
-- stay line ends.
paragraphOf : List Char -> List (List Char) -> (Block, List (List Char))
paragraphOf first more =
  let (body, rest) = span (\l => not (blank l) && not (interrupts l)) more
      all' = first :: body
      joined = joinAll all'
  in (Paragraph (inlines joined), rest)
  where
    stripEnd : List Char -> List Char
    stripEnd l = if last' l == Just '\\' && not (isSuffixOf (unpack "\\\\") l) then fromMaybe l (init' l) else trimR l

    sepFor : List Char -> List Char -> Char
    sepFor prev next = if hardBreak prev || head' (trimL next) == Just '|' || head' (trimL prev) == Just '|' then '\n' else ' '

    joinAll : List (List Char) -> List Char
    joinAll [] = []
    joinAll [l] = trimBoth l
    joinAll (l :: next :: ls) = stripEnd (trimL l) ++ (sepFor l next :: joinAll (next :: ls))

-- The lines that belong to a list item whose text starts in column `ci`
-- (unindented), and the lines that follow. A blank line stays inside if a
-- line indented enough follows it; a line not indented enough that follows
-- text directly goes on with it, unless it starts a block.
itemLines : (ci : Nat) -> (startsText : Bool) -> List (List Char) -> (List (List Char), List (List Char))
itemLines ci startsText ls = go startsText [] ls
  where
    strip : List Char -> List Char
    strip l = drop (min ci (spaces l)) l

    indented : List Char -> Bool
    indented l = not (blank l) && spaces l >= ci

    -- `afterText`: the last line taken was text, with no blank line since.
    go : (afterText : Bool) -> List (List Char) -> List (List Char) -> (List (List Char), List (List Char))
    go _ acc [] = (reverse acc, [])
    go afterText acc all'@(l :: rest) =
      if blank l
         then (case dropWhile blank rest of
                 next@(n :: _) =>
                   if indented n then go False (reverse (map (const []) (takeWhile blank all')) ++ acc) next
                   else (reverse acc, all')
                 [] => (reverse acc, all'))
      else if indented l then go True (strip l :: acc) rest
      else if afterText && not (interrupts l) && isNothing (markerOf l) then go True (trimL l :: acc) rest
      else (reverse acc, all')

-- The lines that are quote lines, without their markers, and the rest.
quoteLines : List (List Char) -> (List (List Char), List (List Char))
quoteLines [] = ([], [])
quoteLines (l :: ls) =
  case quoteOf l of
    Just q => let (more, rest) = quoteLines ls in (q :: more, rest)
    Nothing => ([], l :: ls)

mutual
  ||| The blocks of the lines of a text.
  export
  blocks : List (List Char) -> List Block
  blocks [] = []
  blocks (l :: ls) =
    if blank l then blocks ls
    else case firstBlock l ls of
           Just (b, rest) => b :: blocks rest
           Nothing => let (b, rest) = paragraphOf l ls in b :: blocks rest

  firstBlock : List Char -> List (List Char) -> Maybe (Block, List (List Char))
  firstBlock l ls =
    case fenceOf l of
      Just (c, n, info) =>
        let (body, rest) = fenceBody c n ls in Just (CodeBlock info (map pack body), rest)
      Nothing =>
        case headingOf l of
          Just (n, t) => Just (Heading n (inlines t), ls)
          Nothing =>
            if isRule l then Just (Rule, ls)
            else case quoteOf l of
                   Just q => let (more, rest) = quoteLines ls in Just (Quote (blocks (q :: more)), rest)
                   Nothing => listBlock l ls

  listBlock : List Char -> List (List Char) -> Maybe (Block, List (List Char))
  listBlock l ls =
    case markerOf l of
      Nothing => Nothing
      Just (mk, n, ci, text) =>
        let (items, rest) = listItems mk ci text ls
        in Just (case mk of
                   Bul _ => Bullets items
                   Ord _ => Numbered n items, rest)

  -- The items of a list: this one, then those after it with a marker of the same kind.
  listItems : Marker -> (ci : Nat) -> (text : List Char) -> List (List Char) -> (List (List Block), List (List Char))
  listItems mk ci text ls =
    let (cont, rest) = itemLines ci (not (blank text)) ls
        item = blocks (text :: cont)
    in case dropWhile blank rest of
         (l2 :: ls2) =>
           (case markerOf l2 of
              Just (mk2, _, ci2, text2) =>
                if mk2 == mk && not (isRule l2)
                   then let (more, rest') = listItems mk ci2 text2 ls2 in (item :: more, rest')
                   else ([item], rest)
              Nothing => ([item], rest))
         [] => ([item], rest)

||| The blocks of a text.
export
parse : String -> List Block
parse = blocks . splitLines
