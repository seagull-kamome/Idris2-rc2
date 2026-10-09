||| Parsing of a `%foreign` declaration's calling-convention strings.
||| Replaces upstream's comma-only `parseCC`: the options after
||| `Tag:` are split at top-level commas only (nesting of `()`, `[]`,
||| `{}` and C string/character literals is respected), and the new
||| `CExpr:` tag carries a C expression template instead of a function
||| name. See `rc2/doc/ffi-cexpr.md`.
module Compiler.RC2.ForeignSpec
-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.CompileExpr

import Core.Context
import Core.Core

import Data.List
import Data.List1
import Data.String

%default total

||| One piece of a `CExpr:` template: literal C text, a 1-based
||| reference to a declaration argument (`$N`), or the `Integer`
||| out-parameter of the result (`$r`).
public export
data TemplatePart = TLit String | TArg Nat | TResult

||| What a convention string names: a C function symbol (`C:`,
||| `RefC:`, `RC2:`) or a C expression template (`CExpr:`).
public export
data ForeignTarget = FSymbol String | FExpr (List TemplatePart)

||| A parsed convention string. `libOpts` are the options after the
||| first one (library, then header file), as for `C:`.
public export
record ForeignSpec where
  constructor MkForeignSpec
  tag : String
  target : ForeignTarget
  libOpts : List String

||| The header names of a spec: the second option split at `;`, each
||| trimmed, empty pieces and repeats (exact, case-sensitive match) dropped (`"a.h; b.h;"` is `["a.h", "b.h"]`).
||| Only this field treats `;` specially. See `rc2/doc/ffi-cexpr.md`.
export
headerList : ForeignSpec -> List String
headerList spec = case spec.libOpts of
                       [_, hs] => nub $ filter (/= "") (map (trim . pack) (Data.List1.forget (Data.List.split (== ';') (unpack hs))))
                       _ => []

||| Accepted tags, in priority order. "RefC" is accepted (and treated
||| as directly callable, not stubbed) because prelude/base/contrib
||| bake a handful of load-bearing low-level primitives (fastPack,
||| fastConcat, fastUnpack, string iterators) into %foreign/%transform
||| pairs hardcoded to the "RefC" tag; our own runtime provides
||| matching C symbols for those so we can reuse the declarations
||| as-is instead of forking prelude.
export
foreignTags : List String
foreignTags = ["CExpr", "RC2", "RefC", "C"]

||| The highest-priority tag present in `ccs` as `(tag, raw string,
||| payload after the first ':')`. Same selection as upstream's
||| `parseCC`: the tag is the text before the first ':' compared
||| untrimmed, and a string without ':' has an empty payload.
selectTag : List String -> Maybe (String, String, String)
selectTag ccs = go foreignTags
  where
    findIn : String -> List String -> Maybe (String, String, String)
    findIn _ [] = Nothing
    findIn tag (s :: xs) =
        case break (== ':') s of
             (t, rest) => if t == tag
                             then Just (tag, s, if rest == "" then "" else assert_total (strTail rest))
                             else findIn tag xs

    go : List String -> Maybe (String, String, String)
    go [] = Nothing
    go (t :: ts) = findIn t ccs <|> go ts

data Mode = Plain | Quoted Char | Escaped Char

closerOf : Char -> Maybe Char
closerOf '(' = Just ')'
closerOf '[' = Just ']'
closerOf '{' = Just '}'
closerOf _ = Nothing

||| Split at top-level commas. A single trailing empty option (from a
||| trailing comma) is dropped, like upstream's `getOpts`.
splitOptions : List Char -> Either String (List String)
splitOptions = go Plain [] [] []
  where
    finish : List String -> List Char -> List String
    finish acc cur =
        let all = reverse (pack (reverse cur) :: acc)
        in map trim (case reverse all of
                          ("" :: rest) => reverse rest
                          _ => all)

    go : Mode -> List Char -> List String -> List Char -> List Char -> Either String (List String)
    go Plain [] acc cur [] = Right (finish acc cur)
    go Plain (c :: _) _ _ [] = Left "missing closing '\{Data.String.singleton c}'"
    go (Quoted q) _ _ _ [] = Left "unterminated \{if q == '"' then "string" else "character"} literal"
    go (Escaped q) _ _ _ [] = Left "unterminated \{if q == '"' then "string" else "character"} literal"
    go (Escaped q) stack acc cur (c :: cs) = go (Quoted q) stack acc (c :: cur) cs
    go (Quoted q) stack acc cur (c :: cs) =
        if c == '\\' then go (Escaped q) stack acc (c :: cur) cs
        else if c == q then go Plain stack acc (c :: cur) cs
        else go (Quoted q) stack acc (c :: cur) cs
    go Plain stack acc cur (c :: cs) =
        if c == '"' || c == '\'' then go (Quoted c) stack acc (c :: cur) cs
        else case closerOf c of
                  Just cl => go Plain (cl :: stack) acc (c :: cur) cs
                  Nothing =>
                      if c == ')' || c == ']' || c == '}'
                         then case stack of
                                   (cl :: rest) => if cl == c
                                                      then go Plain rest acc (c :: cur) cs
                                                      else Left "unbalanced '\{Data.String.singleton c}': expected '\{Data.String.singleton cl}'"
                                   [] => Left "unbalanced '\{Data.String.singleton c}': no matching opening bracket"
                         else if c == ',' && isNil stack
                                 then go Plain stack (pack (reverse cur) :: acc) [] cs
                                 else go Plain stack acc (c :: cur) cs

||| Tokenize a `CExpr:` template: `$$` is a literal '$', `$N` (any
||| number of digits) and `$r` are placeholders, any other '$' is an error.
parseTemplate : List Char -> Either String (List TemplatePart)
parseTemplate = go [] []
  where
    flush : List Char -> List TemplatePart -> List TemplatePart
    flush [] acc = acc
    flush lit acc = TLit (pack (reverse lit)) :: acc

    go : List Char -> List TemplatePart -> List Char -> Either String (List TemplatePart)
    go lit acc [] = Right (reverse (flush lit acc))
    go lit acc ('$' :: '$' :: cs) = go ('$' :: lit) acc cs
    go lit acc ('$' :: 'r' :: cs) = go [] (TResult :: flush lit acc) cs
    go lit acc ('$' :: d :: cs) =
        if isDigit d
           then let (ds, rest) = span isDigit (d :: cs)
                in assert_total (go [] (TArg (stringToNatOrZ (pack ds)) :: flush lit acc) rest)
           else Left "'$' must be followed by a digit, 'r' or '$'"
    go lit acc ['$'] = Left "'$' must be followed by a digit, 'r' or '$'"
    go lit acc (c :: cs) = go (c :: lit) acc cs

||| Parse the convention string selected from `ccs`: `Right Nothing`
||| if no usable convention is present (no known tag, or a tag with no
||| options), `Left` with a message for a malformed one. The message
||| quotes the offending string; the caller adds the declaration name.
export
parseForeign : List String -> Either String (Maybe ForeignSpec)
parseForeign ccs =
    case selectTag ccs of
         Nothing => Right Nothing
         Just (tag, raw, payload) =>
             let quoted : String -> String
                 quoted err = err ++ " in \"" ++ raw ++ "\""
             in case splitOptions (unpack payload) of
                     Left err => Left (quoted err)
                     Right [] => if tag == "CExpr" then Left (quoted "missing expression") else Right Nothing
                     Right (first :: rest) =>
                         if tag == "CExpr"
                            then case parseTemplate (unpack first) of
                                      Left err => Left (quoted err)
                                      Right [] => Left (quoted "empty expression")
                                      Right ps => Right (Just (MkForeignSpec tag (FExpr ps) rest))
                            else Right (Just (MkForeignSpec tag (FSymbol first) rest))

||| Whether `ccs` carries a convention rc2 can use. A malformed one
||| counts as usable, so it reaches `validateForeign` and its
||| user-facing error instead of being dropped silently.
export
foreignUsable : List String -> Bool
foreignUsable ccs = case parseForeign ccs of
                         Right Nothing => False
                         _ => True

||| Parse and check the convention of declaration `n` (arguments
||| `fargs`, result `ret`): a malformed string, a `$N` outside the
||| declaration's own arguments (the trailing `%World` of an IO type
||| not counted), `$r` outside an `Integer`-result declaration and an
||| `Integer`-result declaration without `$r` are compile-time errors
||| naming the declaration.
export
validateForeign : Name -> List String -> List CFType -> CFType -> Core (Maybe ForeignSpec)
validateForeign n ccs fargs ret =
    case parseForeign ccs of
         Left err => bad err
         Right Nothing => pure Nothing
         Right (Just spec) => do
             case find badHeader (headerList spec) of
                  Just h => bad "invalid header name \"\{h}\" (a header name must not contain whitespace, '<', '>' or '\"')"
                  Nothing => pure ()
             case spec.target of
                  FSymbol _ => pure ()
                  FExpr parts => do
                      let nargs = case ret of
                                       CFIORes _ => length fargs `minus` 1
                                       _ => length fargs
                      case find (\k => k == 0 || k > nargs) (placeholders parts) of
                           Just k => bad "placeholder $\{show k} is out of range (the declaration has \{show nargs} argument(s))"
                           Nothing => pure ()
                      let hasResult = any isResult parts
                      if isInteger (peel ret)
                         then unless hasResult $
                                  bad "an Integer result needs the out-parameter placeholder '$r' (e.g. \"CExpr:mpz_add($r, $1, $2)\"); a function returning a value, such as mpz_get_si, must be declared with an Int-typed result and wrapped in Idris"
                         else when hasResult $
                                  bad "'$r' is only valid in a declaration whose result type is Integer or PrimIO Integer"
             pure (Just spec)
  where
    bad : String -> Core a
    bad msg = throw $ UserError "[rc2] invalid %foreign declaration \{show n}: \{msg}"

    badHeader : String -> Bool
    badHeader h = any (\c => isSpace c || c == '<' || c == '>' || c == '"') (unpack h)

    placeholders : List TemplatePart -> List Nat
    placeholders [] = []
    placeholders (TLit _ :: ps) = placeholders ps
    placeholders (TArg k :: ps) = k :: placeholders ps
    placeholders (TResult :: ps) = placeholders ps

    isResult : TemplatePart -> Bool
    isResult TResult = True
    isResult _ = False

    isInteger : CFType -> Bool
    isInteger CFInteger = True
    isInteger _ = False

    peel : CFType -> CFType
    peel (CFIORes t) = t
    peel t = t

||| Substitute the already-marshalled argument expressions `args`
||| (1-based `$N`) into a template, each wrapped in parentheses.
||| `$r` becomes `<resultVar>->v` (the `mpz_t` of the allocated
||| `IDRIS2RC2_Integer`), deliberately unparenthesised: a postfix
||| expression cannot be affected by its context, and the array stays
||| an array for `sizeof` and decay.
export
renderTemplate : List TemplatePart -> Maybe String -> List String -> String
renderTemplate parts resultVar args = concatMap render parts
  where
    nth : Nat -> List String -> String
    nth _ [] = ""
    nth Z (x :: _) = x
    nth (S k) (_ :: xs) = nth k xs

    render : TemplatePart -> String
    render (TLit s) = s
    render (TArg k) = "(" ++ nth (k `minus` 1) args ++ ")"
    render TResult = maybe "" (++ "->v") resultVar
