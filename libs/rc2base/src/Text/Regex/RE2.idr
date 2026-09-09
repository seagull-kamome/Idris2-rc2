||| Bindings to Google's RE2 regular expression engine
||| (`support/c/re2_util.cpp`, an `extern "C"` shim over its C++ API,
||| built into its own shared object, see `doc/regex.md` for why this
||| needs one, unlike this package's other `%foreign` bindings).
||| `compile` once, match/capture/replace as many times as needed;
||| `matches`/`findFirst` are throwaway shorthands for one-off use.
module Text.Regex.RE2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.List
import System.FFI

-------------------------------------------------------------------------------
-- Raw FFI
-------------------------------------------------------------------------------

data RawRegex : Type where [external]

%foreign "C:idris2rc2_regex_compile, libidris2rc2re2, re2_util.h"
prim__regexCompile : String -> PrimIO AnyPtr

%foreign "C:idris2_isNull, libidris2_support, idris_support.h"
prim__isNull : AnyPtr -> PrimIO Int

%foreign "C:idris2rc2_regex_free, libidris2rc2re2, re2_util.h"
prim__regexFree : Ptr RawRegex -> PrimIO ()

%foreign "C:idris2rc2_regex_num_groups, libidris2rc2re2, re2_util.h"
prim__regexNumGroups : GCPtr RawRegex -> PrimIO Int

%foreign "C:idris2rc2_regex_full_match, libidris2rc2re2, re2_util.h"
prim__regexFullMatch : GCPtr RawRegex -> String -> PrimIO Int

%foreign "C:idris2rc2_regex_partial_match, libidris2rc2re2, re2_util.h"
prim__regexPartialMatch : GCPtr RawRegex -> String -> PrimIO Int

%foreign "C:idris2rc2_regex_find, libidris2rc2re2, re2_util.h"
prim__regexFind : GCPtr RawRegex -> String -> PrimIO Int

%foreign "C:idris2rc2_regex_group_count, libidris2rc2re2, re2_util.h"
prim__regexGroupCount : GCPtr RawRegex -> PrimIO Int

%foreign "C:idris2rc2_regex_group_present, libidris2rc2re2, re2_util.h"
prim__regexGroupPresent : GCPtr RawRegex -> Int -> PrimIO Int

%foreign "C:idris2rc2_regex_group, libidris2rc2re2, re2_util.h"
prim__regexGroup : GCPtr RawRegex -> Int -> PrimIO String

%foreign "C:idris2rc2_regex_replace, libidris2rc2re2, re2_util.h"
prim__regexReplace : GCPtr RawRegex -> String -> String -> PrimIO String

%foreign "C:idris2rc2_regex_global_replace, libidris2rc2re2, re2_util.h"
prim__regexGlobalReplace : GCPtr RawRegex -> String -> String -> PrimIO String

-------------------------------------------------------------------------------
-- Regex
-------------------------------------------------------------------------------

||| A compiled RE2 pattern. Freed automatically once unreachable (a
||| `GCPtr`, same lifecycle as `System.FFI.C.Array`'s own).
export
record Regex where
  constructor MkRegex
  ptr : GCPtr RawRegex

||| Compiles `pattern`. `Nothing` if RE2 rejects it (invalid syntax);
||| no further detail than that -- RE2's own error message isn't
||| surfaced.
export
compile : String -> IO (Maybe Regex)
compile pattern = do
  raw <- primIO (prim__regexCompile pattern)
  isN <- primIO (prim__isNull raw)
  case isN of
    0 => do
      gcPtr <- onCollect (prim__castPtr {t = RawRegex} raw) (\p => primIO (prim__regexFree p))
      pure (Just (MkRegex gcPtr))
    _ => pure Nothing

||| The number of capturing groups in the pattern (not counting the
||| whole-match group 0).
export
numGroups : Regex -> Int
numGroups re = unsafePerformIO (primIO (prim__regexNumGroups re.ptr))

||| Whether the whole of `text` matches the pattern.
export
fullMatch : Regex -> String -> Bool
fullMatch re text = unsafePerformIO (primIO (prim__regexFullMatch re.ptr text)) /= 0

||| Whether the pattern matches anywhere in `text`.
export
partialMatch : Regex -> String -> Bool
partialMatch re text = unsafePerformIO (primIO (prim__regexPartialMatch re.ptr text)) /= 0

readGroup : GCPtr RawRegex -> Int -> IO (Maybe String)
readGroup ptr i = do
  present <- primIO (prim__regexGroupPresent ptr i)
  case present of
    0 => pure Nothing
    _ => Just <$> primIO (prim__regexGroup ptr i)

||| Finds the leftmost match, returning the whole match (index 0)
||| followed by every capturing group left to right. A `Nothing` in
||| the list means that group exists in the pattern but didn't
||| participate in this particular match (e.g. the losing side of a
||| `|` alternation), distinct from a group that matched an empty
||| string (`Just ""`). An overall `Nothing` means no match at all.
export
find : Regex -> String -> Maybe (List (Maybe String))
find re text = unsafePerformIO $ do
  ok <- primIO (prim__regexFind re.ptr text)
  n  <- primIO (prim__regexGroupCount re.ptr)
  groups <- traverse (readGroup re.ptr) [0 .. n - 1]
  pure (if ok == 0 then Nothing else Just groups)

||| Replaces the first match with `replacement` (RE2's own rewrite
||| syntax: a backslash followed by a digit refers to that capturing
||| group, a doubled backslash is a literal one). Returns `text`
||| unchanged if nothing matched.
|||
||| Named `replaceFirst`, not `replace`: `replace` is
||| `Prelude.Builtin`'s own equality-substitution function, already in
||| scope via every module's implicit Prelude import (an overload of
||| that name is not what this needs). The parameter itself couldn't
||| be called `rewrite` for a related reason -- that's a reserved
||| keyword (Idris2's own `rewrite ... in ...` equality-rewriting
||| expression form), not just a name already in scope elsewhere; using
||| it as an ordinary parameter name breaks parsing of every
||| declaration that follows it in the same module, with no error
||| pointing at the actual cause (confirmed by bisecting this exact
||| file down to a two-line reproduction).
export
replaceFirst : Regex -> String -> String -> String
replaceFirst re replacement text = unsafePerformIO (primIO (prim__regexReplace re.ptr text replacement))

||| Like `replaceFirst`, but every non-overlapping match.
export
globalReplace : Regex -> String -> String -> String
globalReplace re replacement text = unsafePerformIO (primIO (prim__regexGlobalReplace re.ptr text replacement))

-------------------------------------------------------------------------------
-- Throwaway shorthands
-------------------------------------------------------------------------------

||| Compiles `pattern` and checks `fullMatch` in one call. `False` if
||| `pattern` itself is invalid. Recompiles the pattern every call --
||| prefer `compile` once plus `fullMatch` for repeated use of the same
||| pattern.
export
matches : (pattern : String) -> String -> Bool
matches pattern text = unsafePerformIO $ do
  Just re <- compile pattern
    | Nothing => pure False
  pure (fullMatch re text)

||| Compiles `pattern` and runs `find` in one call. `Nothing` if
||| `pattern` itself is invalid (indistinguishable here from a valid
||| pattern that simply didn't match). Recompiles the pattern every
||| call -- prefer `compile` once plus `find` for repeated use of the
||| same pattern.
export
findFirst : (pattern : String) -> String -> Maybe (List (Maybe String))
findFirst pattern text = unsafePerformIO $ do
  Just re <- compile pattern
    | Nothing => pure Nothing
  pure (find re text)
