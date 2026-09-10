||| Bindings to POSIX `<regex.h>` (`regcomp`/`regexec`/`regfree`/
||| `regerror`). `compile` once with `ere` (Extended REs, the default)
||| or `bre` (Basic REs), then `match`/`matchAll`/`matches`/`replace*`.
||| libc only -- no external dependency, unlike `text-re2`'s RE2 engine.
|||
||| Caveats, all inherent to POSIX `regexec`:
||| * it takes a NUL-terminated string, so a `\0` in the input ends the
|||   search there (glibc's `REG_STARTEND` would fix this -- not wired up);
||| * leftmost-longest ("POSIX") match semantics, not leftmost-first;
||| * no named groups; global search is `regexec` iterated (`matchAll`).
|||
||| `regexec` reports *byte* offsets while rc2's `String` primitives are
||| codepoint-wise, so every span here is cut out with
||| `Data.String.RC2.unsafeStringByteSlice` (a genuine byte slice) and
||| loop bounds use byte length, not `strLength` -- `match`/`matchAll`/
||| `replace*` are UTF-8-correct, not ASCII-only.
module Text.Regex.POSIX

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Bits
import Data.List
import Data.String
import Data.String.RC2
import System.FFI
import Text.Encoding.UTF8 as UTF8

-- matchAll/replace loop on a byte index, not structurally -- relax
-- rc2base.ipkg's package-wide `--total` to `covering`.
%default covering

-------------------------------------------------------------------------------
-- Compile flags
-------------------------------------------------------------------------------

||| `regcomp` flags. `extended` selects POSIX Extended Regular
||| Expressions (ERE) over Basic (BRE).
public export
record Flags where
  constructor MkFlags
  extended   : Bool
  ignoreCase : Bool
  newline    : Bool   -- REG_NEWLINE: `.`/negated sets don't cross '\n', `^`/`$` match at them

||| ERE, case-sensitive -- `compile`'s default. Case-insensitive:
||| `compile {flags = { ignoreCase := True } ere} pat`.
public export
ere : Flags
ere = MkFlags True False False

||| BRE (no `REG_EXTENDED`), case-sensitive.
public export
bre : Flags
bre = MkFlags False False False

-------------------------------------------------------------------------------
-- Raw FFI (support/c/posix_regex.c)
-------------------------------------------------------------------------------

data RawRegex : Type where [external]

%foreign "C:idris2rc2_regex_compile, libidris2rc2base, posix_regex.h"
prim__compile : String -> Int -> PrimIO AnyPtr

%foreign "C:idris2rc2_regex_compile_errmsg, libidris2rc2base, posix_regex.h"
prim__compileErrmsg : PrimIO String

%foreign "C:idris2_isNull, libidris2_support, idris_support.h"
prim__isNull : AnyPtr -> PrimIO Int

%foreign "C:idris2rc2_regex_free, libidris2rc2base, posix_regex.h"
prim__free : Ptr RawRegex -> PrimIO ()

%foreign "C:idris2rc2_regex_nsub, libidris2rc2base, posix_regex.h"
prim__nsub : GCPtr RawRegex -> PrimIO Int

%foreign "C:idris2rc2_regex_exec, libidris2rc2base, posix_regex.h"
prim__exec : GCPtr RawRegex -> String -> Int -> PrimIO Int

%foreign "C:idris2rc2_regex_group_so, libidris2rc2base, posix_regex.h"
prim__groupSo : Int -> PrimIO Int

%foreign "C:idris2rc2_regex_group_eo, libidris2rc2base, posix_regex.h"
prim__groupEo : Int -> PrimIO Int

%foreign "C:idris2rc2_regex_extended, libidris2rc2base, posix_regex.h"
prim__cExtended : PrimIO Int

%foreign "C:idris2rc2_regex_icase, libidris2rc2base, posix_regex.h"
prim__cIcase : PrimIO Int

%foreign "C:idris2rc2_regex_newline, libidris2rc2base, posix_regex.h"
prim__cNewline : PrimIO Int

-- Platform REG_* values. Cached via unsafePerformIO, same pattern as
-- System.Net.Epoll's own flag constants -- OS-fixed, not per-call.
cExtended, cIcase, cNewline : Int
cExtended = unsafePerformIO (primIO prim__cExtended)
cIcase    = unsafePerformIO (primIO prim__cIcase)
cNewline  = unsafePerformIO (primIO prim__cNewline)

cflagsOf : Flags -> Int
cflagsOf f = bit f.extended cExtended .|. bit f.ignoreCase cIcase .|. bit f.newline cNewline
  where
    bit : Bool -> Int -> Int
    bit b v = if b then v else 0

-------------------------------------------------------------------------------
-- Regex
-------------------------------------------------------------------------------

||| A compiled POSIX pattern. `regfree`d (and freed) automatically once
||| unreachable -- a `GCPtr`, same lifecycle as `System.FFI.C.Array`'s.
export
record Regex where
  constructor MkRegex
  ptr : GCPtr RawRegex

||| Compile `pattern` with `flags` (default `ere`). `Left` carries the
||| `regerror` text for a syntactically invalid pattern.
export
compile : {default ere flags : Flags} -> String -> IO (Either String Regex)
compile {flags} pattern = do
  raw <- primIO (prim__compile pattern (cflagsOf flags))
  0 <- primIO (prim__isNull raw)
    | _ => Left <$> primIO prim__compileErrmsg
  p <- onCollect (prim__castPtr {t = RawRegex} raw) (\q => primIO (prim__free q))
  pure (Right (MkRegex p))

||| Number of capturing groups (not counting the whole match, group 0).
export
groupCount : Regex -> Int
groupCount re = unsafePerformIO (primIO (prim__nsub re.ptr))

-------------------------------------------------------------------------------
-- Matching
-------------------------------------------------------------------------------

-- (start, end) of group `i` from the last `prim__exec` on this thread,
-- or Nothing if it didn't participate.
groupSpan : Int -> IO (Maybe (Int, Int))
groupSpan i = do
  so <- primIO (prim__groupSo i)
  if so < 0
    then pure Nothing
    else do eo <- primIO (prim__groupEo i)
            pure (Just (so, eo))

-- Spans for [group 0 .. group nsub] after the last `prim__exec`.
allSpans : Regex -> IO (List (Maybe (Int, Int)))
allSpans re = do
  n <- primIO (prim__nsub re.ptr)
  traverse groupSpan [0 .. n]

-- `regexec` offsets are byte offsets; `strSubstr` would read them as
-- codepoint indices. Cut the real bytes instead.
sub : String -> (Int, Int) -> String
sub s (a, b) = unsafeStringByteSlice s a (b - a)

-- The codepoint starting at byte offset `i` of `input` (a real match
-- boundary on valid UTF-8 always is one) plus the byte offset just
-- past it. `(Nothing, i + 1)` at or beyond the end, so an empty-match
-- loop still makes progress.
charFromByte : String -> Int -> (Maybe Char, Int)
charFromByte input i =
  case unpack (unsafeStringByteSlice input i (byteLength input - i)) of
    []       => (Nothing, i + 1)
    (c :: _) => (Just c, i + cast (length (UTF8.encodeChar c)))

||| Leftmost-longest match anywhere in `input`, as byte-offset spans:
||| index 0 the whole match, then each capturing group. A `Nothing`
||| element is a group that didn't participate (e.g. the losing side of
||| a `|`); overall `Nothing` is no match at all.
export
matchSpans : Regex -> String -> Maybe (List (Maybe (Int, Int)))
matchSpans re input = unsafePerformIO $ do
  1 <- primIO (prim__exec re.ptr input 0)
    | _ => pure Nothing
  Just <$> allSpans re

||| `matchSpans` with each span resolved to its substring. `Just ""`
||| (an empty match) stays distinct from `Nothing` (absent group).
export
match : Regex -> String -> Maybe (List (Maybe String))
match re input = (map . map . map) (sub input) (matchSpans re input)

||| Does the pattern match anywhere in `input`?
export
matches : Regex -> String -> Bool
matches re input = unsafePerformIO ((== 1) <$> primIO (prim__exec re.ptr input 0))

||| Every non-overlapping match, left to right -- each element is what
||| `match` would return for that match. An empty match advances one
||| byte so the scan terminates.
export
matchAll : Regex -> String -> List (List (Maybe String))
matchAll re input = unsafePerformIO (go 0)
  where
    go : Int -> IO (List (List (Maybe String)))
    go start =
      if start > byteLength input
        then pure []
        else do
          1 <- primIO (prim__exec re.ptr input start)
            | _ => pure []
          spans <- allSpans re
          let here = (map . map) (sub input) spans
          case join (head' spans) of
            Nothing        => pure [here]  -- group 0 is always present on a match
            Just (ms, me)  => (here ::) <$> go (if me > ms then me else snd (charFromByte input me))

-------------------------------------------------------------------------------
-- Replace (POSIX has no rewrite syntax; \0..\9 = group, \\ = literal \,
-- \x (any other) = x)
-------------------------------------------------------------------------------

nth : Nat -> List a -> Maybe a
nth _     []        = Nothing
nth Z     (x :: _)  = Just x
nth (S k) (_ :: xs) = nth k xs

expandRepl : (spans : List (Maybe (Int, Int))) -> (repl : String) -> (input : String) -> String
expandRepl spans repl input = pack (go (unpack repl))
  where
    grp : Nat -> List Char
    grp d = case nth d spans of
              Just (Just span) => unpack (sub input span)
              _                => []
    go : List Char -> List Char
    go []                = []
    go ('\\' :: d :: cs) = if isDigit d
                             then grp (integerToNat (cast (ord d - ord '0'))) ++ go cs
                             else d :: go cs
    go ('\\' :: [])      = ['\\']
    go (c :: cs)         = c :: go cs

replaceWith : Regex -> (repl : String) -> (input : String) -> (global : Bool) -> String
replaceWith re repl input global = unsafePerformIO (go 0 [<])
  where
    tailFrom : Int -> SnocList Char -> String
    tailFrom i acc = pack (acc <>> unpack (unsafeStringByteSlice input i (byteLength input - i)))

    go : Int -> SnocList Char -> IO String
    go start acc = do
      1 <- primIO (prim__exec re.ptr input start)
        | _ => pure (tailFrom start acc)
      spans <- allSpans re
      case join (head' spans) of
        Nothing => pure (tailFrom start acc)
        Just (ms, me) => do
          let acc' = (acc <>< unpack (sub input (start, ms)))
                         <>< unpack (expandRepl spans repl input)
          if not global
            then pure (tailFrom me acc')
            else if me > ms
              then go me acc'
              else case charFromByte input me of  -- empty match: copy the skipped char, step past it
                     (Just c,  nxt) => go nxt (acc' :< c)
                     (Nothing, _)   => pure (pack (acc' <>> []))

||| Replace the first match. `\0`..`\9` in `replacement` name groups,
||| `\\` is a literal backslash; any other `\x` becomes `x`.
export
replaceFirst : Regex -> (replacement : String) -> String -> String
replaceFirst re repl input = replaceWith re repl input False

||| Replace every non-overlapping match. See `replaceFirst` for the
||| `replacement` syntax.
export
replaceAll : Regex -> (replacement : String) -> String -> String
replaceAll re repl input = replaceWith re repl input True
