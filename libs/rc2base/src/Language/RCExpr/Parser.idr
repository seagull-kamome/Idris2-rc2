module Language.RCExpr.Parser

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Parser for `Compiler.RC2.Pretty`'s own dump format (`--directive
-- dumprcexpr`) -- see `Language.RCExpr.AST`'s own module note for
-- the grammar source and the opaque-field scope decision.
--
-- Two layers, matching the grammar's own two levels of structure:
-- indentation (`Pretty.idr`'s `indent n` is always exactly `2*n`
-- spaces) decides the *tree shape* (which line is whose child), so
-- that part is driven directly off `String`/`List String` -- an
-- indentation-sensitive grammar doesn't fit a token-stream parser
-- combinator well, and doesn't need one, since dispatch is just "is
-- this line indented `2*depth` spaces". Everything *within* one
-- already-indent-stripped line (an operator name, a `[a, b, c]`
-- argument list, a `key=[...]` field) is genuinely a small
-- expression grammar, and *does* benefit from a real parser --
-- tokenized via `Language.RCExpr.Lexer` and parsed with upstream's
-- own `Text.Parser` combinators (the same library
-- `Language.JSON.Parser` is built on).
--
-- Known scope limitation: a constant-folded constructor operand with
-- more than one field (`RCConstCon` -- `Compiler.RC2.RCExp`'s own
-- `Show RCLocal`, `"#name@tag(a, b)"`) has its own internal comma,
-- which this line's *outer* list-splitting can't tell apart from the
-- enclosing list's own separator (a lexer-level ambiguity, not just
-- a parser one). Harmless for `Language.RCExpr.Lint`'s own purposes:
-- a `RCConstCon`-shaped local is never refcount-tracked either way,
-- so a garbled capture of one only ever affects a diagnostic
-- message's own text, never an anomaly verdict.

import Language.RCExpr.AST
import Language.RCExpr.Lexer

import Data.List
import Data.String
import Text.Parser

%default covering

public export
record ParseError where
  constructor MkParseError
  lineNo  : Nat
  message : String

public export
Show ParseError where
  show e = "line " ++ show e.lineNo ++ ": " ++ e.message

------------------------------------------------------------------------
-- Line/indentation structure (plain String, not tokenized -- see this
-- module's own top-of-file note).

record LState where
  constructor MkLState
  remaining : List String
  lineNo    : Nat

LParser : Type -> Type
LParser a = LState -> Either ParseError (a, LState)

lfail : Nat -> String -> Either ParseError a
lfail n msg = Left (MkParseError n msg)

countLeadingSpaces : String -> Nat
countLeadingSpaces s = length (takeWhile (== ' ') (unpack s))

dropChars : Nat -> String -> String
dropChars n s = pack (drop n (unpack s))

advanceLine : LParser ()
advanceLine st = case st.remaining of
    [] => lfail st.lineNo "unexpected end of input"
    (_ :: rest) => Right ((), MkLState rest (S st.lineNo))

||| The current line's own text stripped of exactly `2*depth` leading
||| spaces -- fails if it isn't indented at exactly that depth.
atDepth : Nat -> LParser String
atDepth depth st = case st.remaining of
    [] => lfail st.lineNo "unexpected end of input"
    (l :: _) =>
        if countLeadingSpaces l == 2 * depth
           then Right (dropChars (2 * depth) l, st)
           else lfail st.lineNo ("expected indent " ++ show (2 * depth) ++ ", got " ++ show (countLeadingSpaces l) ++ " (" ++ l ++ ")")

hasLineAtDepth : Nat -> LState -> Bool
hasLineAtDepth depth st = case st.remaining of
    [] => False
    (l :: _) => countLeadingSpaces l == 2 * depth

expectLine : Nat -> String -> LParser ()
expectLine depth text st = do
    (l, st1) <- atDepth depth st
    if l == text
       then advanceLine st1
       else lfail st1.lineNo ("expected \"" ++ text ++ "\", got \"" ++ l ++ "\"")

------------------------------------------------------------------------
-- One line's own content, via Text.Parser over Language.RCExpr.Lexer.

toks : Nat -> String -> Either ParseError (List (WithBounds RcToken))
toks ln s = maybe (lfail ln ("could not tokenize: " ++ s)) Right (lexLine s)

errMsg : ParsingError RcToken -> String
errMsg (Error msg b) = msg ++ maybe "" (\bs => " at " ++ show bs) b

runG : {c : Bool} -> Nat -> Grammar () RcToken c a -> String -> Either ParseError a
runG ln g s = do
    ts <- toks ln s
    case parse g ts of
         Left errs => lfail ln ("parse error: " ++ concat (intersperse "; " (Prelude.toList (map errMsg errs))))
         Right (v, []) => Right v
         Right (v, _ :: _) => Right v -- trailing tokens on a line are ignorable (this grammar is line-terminated, never continues past what it needs)

isDigitsOnly : String -> Bool
isDigitsOnly s = s /= "" && all isDigit (unpack s)

mutual
  ||| One name token, or a `{...}` brace group (`braceGroupG`) read as
  ||| one unit -- `Core.Name`'s own `MN` (a machine name) can start
  ||| straight with `{` (`{{__mainExpression:0}:0}`) rather than
  ||| gluing onto some earlier plain name text.
  nameAtomG : Grammar () RcToken True String
  nameAtomG = (match RcName) <|> braceGroupG

  ||| A `nameAtomG`, plus -- when immediately followed by `{` (another
  ||| brace group) or by `(` *and* that isn't a `RCConstCon`'s own
  ||| `(args)` -- the tail glued back on. `Core.Name`'s own `Show`
  ||| wraps an operator's own display in `(...)` when name-spaced
  ||| (`NS ns (UN (Basic n))`, `n` an operator symbol), e.g.
  ||| `Prelude.Types.SnocList.` + `(<>>)` ->
  ||| `"Prelude.Types.SnocList.(<>>)"` -- indistinguishable at the
  ||| lexer level from a `RCConstCon`'s own recursive
  ||| `#Name@tag(args)` (`Language.RCExpr.Lexer`'s own note), but easy
  ||| to tell apart here: a `RCConstCon`'s own args list always starts
  ||| with `[` right after the `(`, an operator's own symbols never do
  ||| (`opTailG` simply fails to read even its first token there,
  ||| since `[` isn't a `RcName`, and `<|>` falls back to no tail at
  ||| all).
  anyName : Grammar () RcToken True String
  anyName = do
      n <- nameAtomG
      -- Only glue a following `{`/`(` onto `n` when `n` itself ends
      -- in `.` -- `Core.Name`'s own `Show` only ever puts `{...}`
      -- (an `MN`/`PV`) or `(...)` (an operator's own display) right
      -- after a namespace's own trailing `.` (`show (NS ns n) =
      -- "\{show ns}.\{show n}"`), never glued straight onto some
      -- *other* token with no dot at all -- without this guard, a
      -- keyword this grammar reads with `anyName` (`call`, `op`, ...)
      -- would wrongly swallow an unrelated, merely-adjacent `{...}`/
      -- `(...)` that starts the *next* field instead (e.g. `call
      -- {rc2_specClosure_...}`, a real idris2-lsp dump line: `call`
      -- doesn't end in `.`, so this guard correctly leaves the `{...}`
      -- for a separate `anyName` read right after).
      tail <- if isSuffixOf "." n then option "" (braceGroupG <|> opTailG) else pure ""
      pure (n ++ tail)
    where
      opTailG : Grammar () RcToken True String
      opTailG = do
          match (RcPunct '(')
          first <- match RcName
          rest <- many (match RcName)
          match (RcPunct ')')
          pure ("(" ++ concat (intersperse " " (first :: rest)) ++ ")")

  ||| `{...}` (`Core.Name`'s own `MN`/`PV` display, `"{" ++ x ++ ":" ++
  ||| show y ++ "}"`), read structurally token-by-token rather than
  ||| lexed as one flat run -- `x` is an arbitrary compiler-generated
  ||| hint string that can itself embed `(`/`)` (a type's own `Show`
  ||| output, e.g. `{fromJSON_FromJSON_((SortedMap String) $v):1}`
  ||| seen in real idris2-lsp output) or a nested `{...}`
  ||| (`{{__mainExpression:0}:0}`), neither of which the lexer's own
  ||| flat character-class rule (`Language.RCExpr.Lexer`'s own note)
  ||| can track the true end of by itself. Reconstructed back into
  ||| roughly the same text (opaque, per this module's own
  ||| top-of-file note), not structurally interpreted.
  braceGroupG : Grammar () RcToken True String
  braceGroupG = do
      match (RcPunct '{')
      inner <- groupBodyG
      pure ("{" ++ inner)

  ||| Everything up to and including the `}` that closes the brace
  ||| group `braceGroupG` is currently inside -- a nested `{` recurses
  ||| back into `braceGroupG` itself (so nesting depth is tracked by
  ||| the call stack, not a counter), everything else is read as
  ||| plain text and glued straight on (no extra spaces -- the aim is
  ||| readability, not exact byte-for-byte reconstruction, and this
  ||| grammar's own tokens never need internal spaces to stay
  ||| unambiguous when just concatenated back together).
  groupBodyG : Grammar () RcToken True String
  groupBodyG = closeG <|> continueG
    where
      closeG : Grammar () RcToken True String
      closeG = match (RcPunct '}') *> pure "}"
      continueG : Grammar () RcToken True String
      continueG = do
          t <- oneGroupTokenG
          rest <- groupBodyG
          pure (t ++ rest)

  ||| One token's own text, for use only inside `groupBodyG` -- unlike
  ||| `anyName`, this never tries to glue a following `(...)`/`{...}`
  ||| onto a name token (`groupBodyG`'s own recursion already reads
  ||| every following token on its own, so doing it here too would
  ||| double up).
  oneGroupTokenG : Grammar () RcToken True String
  oneGroupTokenG = braceGroupG <|> (match RcName) <|> quotedG <|> punctG
    where
      quotedG : Grammar () RcToken True String
      quotedG = map show (match RcQuotedString)
      punctG : Grammar () RcToken True String
      punctG = matchP '[' <|> matchP ']' <|> matchP ',' <|> matchP '(' <|> matchP ')' <|> matchP '#'
        where
          matchP : Char -> Grammar () RcToken True String
          matchP c = match (RcPunct c) *> pure (pack [c])

||| Reads name-shaped tokens greedily until the next one looks like a
||| structural boundary (anything that isn't a bare `RcName`, or a
||| `key=`-shaped one, or a lone `:`/`->`) -- for the handful of
||| upstream `Show` fields that can pad themselves with an
||| unpredictable number of extra space-separated words: `Core.Name`'s
||| own `Show` sometimes suffixes a constructor's display name with
||| `at <FC>` (a `con`/case-alt header's own `name`, or a
||| `RCConstCon`'s own nested `name`); a `WithBlock`/`CaseBlock`'s own
||| display (`"with/case block in " ++ outer`, a `call`/`partial`'s
||| own `name` -- `outer` can itself contain a bare `,` when it names
||| more than one mutually-defined `with`-clause function, e.g. `case
||| block in words,helper`; that bare `,` is already part of the
||| `RcName` token itself, `Language.RCExpr.Lexer`'s own `listCommaLit`
||| note has the full reasoning, so nothing extra is needed here to
||| read it back correctly); `CFType`'s own `CFIORes`/`CFUser`/`CFFun`
||| (a `callRep`/`callFFIInline`'s own `ret`). Captured as opaque
||| text, same convention as everywhere else in this parser -- not
||| structurally interpreted, just kept readable.
export
greedyWordsG : Grammar () RcToken True String
greedyWordsG = do
    n <- anyName
    rest <- many nonBoundaryName
    pure (n ++ concatMap (" " ++) rest)
  where
    nonBoundaryName : Grammar () RcToken True String
    nonBoundaryName = do
        v <- anyName
        the (Grammar () RcToken False ()) (if isSuffixOf "=" v || v == ":" || v == "->" then fail "field boundary" else pure ())
        pure v

||| Only the two shapes that are ever a single bare token: `vN` and
||| `_`. Every `#`-prefixed shape is `hashG`'s own job (it needs
||| `localListG`, so it can't live here without a `mutual` block --
||| see that pair's own note).
classifyLocal : String -> Either String RCLocal
classifyLocal n =
    if n == "_" then Right RUnderscore
    else case strM n of
              StrCons 'v' rest => if isDigitsOnly rest then Right (RVar (cast rest)) else Left ("not an RCLocal: " ++ n)
              _ => Left ("not an RCLocal: " ++ n)

mutual
  export
  rcLocalG : Grammar () RcToken True RCLocal
  rcLocalG = nullG <|> hashG <|> plainVarG
    where
      nullG : Grammar () RcToken True RCLocal
      nullG = do
          match (RcPunct '[')
          n <- match RcName
          match (RcPunct ']')
          if n == "__" then pure RNull else fail "expected [__]"
      plainVarG : Grammar () RcToken True RCLocal
      plainVarG = do
          n <- match RcName
          the (Grammar () RcToken False RCLocal) $ case classifyLocal n of
               Right loc => pure loc
               Left err => fail err

  ||| Every `#`-prefixed `RCLocal` shape (`Compiler.RC2.RCExp.RCLocal`'s
  ||| own `Show`), dispatching on whatever comes right after the now
  ||| always-separate `#` token (`Language.RCExpr.Lexer`'s own note on
  ||| why `#` has to be its own token): a quoted value (`RConst`'s own
  ||| string, or a `Show Char` constant like `#'"'`) is `RcQuotedString`
  ||| whole; anything else is `#Name@tag` (`RCEmptyCon`/
  ||| `RCConstClosure`) or `#Name@tag(args)` (`RCConstCon`, recursive
  ||| -- `args : List RCLocal` prints via the ordinary `[a, b, c]`
  ||| convention `localListG` already reads, so this just reuses it).
  ||| `tag`'s own `Just N` is two tokens, glued straight onto `Name@`
  ||| with no space (`Show (Maybe Int)`'s own `showCon`, same shape
  ||| `tagTextG` reads elsewhere) -- read here as an *extra* token
  ||| only when the name one ends in `Just`. Reconstructed back into
  ||| roughly the same text (opaque, per this module's own top-of-file
  ||| note), not structurally interpreted -- `RCEmptyCon`'s own
  ||| `ConInfo` is dropped entirely, same as everywhere else this
  ||| parser meets one.
  hashG : Grammar () RcToken True RCLocal
  hashG = do
      match (RcPunct '#')
      quotedG <|> nameBasedG
    where
      -- `match RcQuotedString` already strips the quotes/decodes
      -- escapes (`Language.RCExpr.Lexer`'s own `unescapeQuoted`) --
      -- `RConst`'s own doc comment says it keeps a quoted value
      -- *with* its quotes (`Language.RCExpr.AST`), so `show` puts
      -- them back (Idris2's own `Show String`, the same escaping
      -- `Compiler.RC2.RCExp`'s `Show Constant`/`Show Char` used to
      -- write this in the first place -- a `Char` constant, e.g.
      -- `#'"'`, gets requoted as a `String` here; harmless, since
      -- this module never re-parses `RConst`'s own opaque payload).
      quotedG : Grammar () RcToken True RCLocal
      quotedG = do
          q <- match RcQuotedString
          pure (RConst (show q))
      nameBasedG : Grammar () RcToken True RCLocal
      nameBasedG = do
          n <- greedyWordsG
          tagExtra <- option "" $ do
              the (Grammar () RcToken False ()) (if isSuffixOf "Just" n then pure () else fail "no Just suffix")
              v <- match RcName
              pure (" " ++ v)
          conArgs <- option "" $ do
              match (RcPunct '(')
              args <- localListG
              match (RcPunct ')')
              pure ("(" ++ show args ++ ")")
          pure (ROpaqueCon (n ++ tagExtra ++ conArgs))

  localListG : Grammar () RcToken True (List RCLocal)
  localListG = do
      match (RcPunct '[')
      xs <- sepBy (match (RcPunct ',')) rcLocalG
      match (RcPunct ']')
      pure xs

||| `key=[...]`, anywhere in the remaining tokens -- consumes nothing
||| and returns `[]` if `key` isn't the next name token (every
||| optional field in this grammar is omitted entirely rather than
||| printed empty, `Pretty.idr`'s own `if x == [] then "" else ...`
||| guards throughout, so "absent" and "present but empty" never need
||| to be told apart).
optionalField : String -> Grammar () RcToken False (List RCLocal)
optionalField key = option [] $ do
    n <- match RcName
    the (Grammar () RcToken True (List RCLocal)) (if n == key ++ "=" then localListG else fail "not this field")

nameEq : String -> Grammar () RcToken True ()
nameEq text = do
    n <- match RcName
    the (Grammar () RcToken False ()) (if n == text then pure () else fail ("expected \"" ++ text ++ "\", got \"" ++ n ++ "\""))

||| A `PrimFn`'s own name (`op`/`cmp`'s own operator) -- most spellings
||| are a single glued token (`+Int`, `==Double`, `op_strcons`, ...),
||| but `Core.TT.Primitive`'s own `Show (PrimFn arity)` puts a space
||| before the type name for six of them (`neg`/`shl`/`shr`/`and`/
||| `or`/`xor`) -- those need two tokens read, not one.
opNameG : Grammar () RcToken True String
opNameG = twoWordG <|> oneWordG
  where
    isTwoWord : String -> Bool
    isTwoWord n = n == "neg" || n == "shl" || n == "shr" || n == "and" || n == "or" || n == "xor"
    twoWordG : Grammar () RcToken True String
    twoWordG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if isTwoWord n then pure () else fail "not a two-word prim name")
        ty <- anyName
        pure (n ++ " " ++ ty)
    oneWordG : Grammar () RcToken True String
    oneWordG = anyName

||| `Boxed` is one token; every other `Rep` is `Native`/`InlineNative`
||| plus a `CFType` -- greedily read the same way `greedyWordsG` reads
||| any other upstream `Show` field with an unpredictable word count
||| (`CFType`'s own `CFIORes`/`CFUser`/`CFFun`, per its own note).
repG : Grammar () RcToken True RRep
repG = boxedG <|> ret1G <|> nativeG
  where
    boxedG : Grammar () RcToken True RRep
    boxedG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if n == "Boxed" then pure () else fail "not Boxed")
        pure Boxed
    -- A by-value struct (rc2's `doc/struct-return.md`) has no
    -- reference count of its own, so it reads as a non-Boxed Rep.
    ret1G : Grammar () RcToken True RRep
    ret1G = do
        n <- anyName
        the (Grammar () RcToken False ()) (if n == "Ret1" then pure () else fail "not Ret1")
        pure (NativeRep "Ret1")
    nativeG : Grammar () RcToken True RRep
    nativeG = do
        n <- anyName
        ty <- greedyWordsG
        pure (NativeRep (n ++ " " ++ ty))

||| `Core.CompileExpr`'s own `Show ConInfo` -- always a literal
||| `[keyword]`, or `[enum N]` for the one two-word case. Neither
||| `RConstruct` nor `RConAlt` (`Language.RCExpr.AST`) carries a field
||| for this -- `Language.RCExpr.Lint`'s ownership checks never need
||| to know a constructor's *kind*, only its `RCLocal` shape -- so
||| this only consumes the tokens, it doesn't return anything.
conInfoG : Grammar () RcToken True ()
conInfoG = do
    match (RcPunct '[')
    _ <- some anyName
    match (RcPunct ']')
    pure ()

||| A `RConAlt`/`RCon` tag: `Nothing`, or `Just` followed by a second
||| token for the number (`Prelude`'s derived `Show (Maybe Int)`,
||| `showCon`-style -- a negative number's own parens glue onto it as
||| one `RcName` token, per `Language.RCExpr.Lexer`'s own note, so
||| there's never a third token to read). Captured as opaque text,
||| same as every other upstream-`Show`-derived field
||| (`Language.RCExpr.AST`'s own module note).
tagTextG : Grammar () RcToken True String
tagTextG = justTagG <|> plainTagG
  where
    justTagG : Grammar () RcToken True String
    justTagG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if n == "Just" then pure () else fail "not Just")
        v <- anyName
        pure (n ++ " " ++ v)
    plainTagG : Grammar () RcToken True String
    plainTagG = anyName

||| `Grammar` has no `Applicative`/`Monad` instance of its own (only
||| its own directly-overloaded `(>>=)`/`Functor`), so `Prelude`'s
||| `traverse` doesn't apply to it -- this is the one place that
||| needs it (each `RCLocal` arg of a con-alt header must itself be a
||| plain `RVar`).
traverseG : (a -> Grammar () RcToken False b) -> List a -> Grammar () RcToken False (List b)
traverseG f [] = pure []
traverseG f (x :: xs) = do
    y <- f x
    ys <- traverseG f xs
    pure (y :: ys)

------------------------------------------------------------------------
-- Per-shape line grammars (each returns the shape's own fields; the
-- caller -- `terminal`/`parseBlock` below -- wraps them into `RCExp`).

isLazyName : String -> Bool
isLazyName n = case strM n of StrCons '~' _ => True; _ => False

||| The line's own first "real" word, skipping an optional lazy prefix
||| (`~Reason `) -- `dispatchBlock`/`terminal` use this instead of
||| `isPrefixOf "kw " line`/`isInfixOf " kw " line` to decide a line's
||| own shape, since `isInfixOf` on the raw line text is a real bug: a
||| `RConst` string's own value can legitimately contain text that
||| happens to look like a keyword (`op ++ [#"Foreign call ", v123]`,
||| seen in real idris2-lsp output, was mistaken for a `call` node by
||| `isInfixOf " call "` matching *inside* the quoted string). Only
||| ever looking at the line's own leading word(s) makes that
||| impossible -- whatever text sits inside a quote later on the same
||| line is never even examined.
firstWord : String -> String
firstWord line =
    let w1 = pack (takeWhile (/= ' ') (unpack line)) in
    if isLazyName w1
       then pack (takeWhile (/= ' ') (unpack (dropChars (length (unpack w1) + 1) line)))
       else w1

callG : Grammar () RcToken True (Bool, String, List RCLocal)
callG = do
    n <- anyName
    let lazy = isLazyName n
    name <- the (Grammar () RcToken True String) (if n == "call" then greedyWordsG else nameEq "call" *> greedyWordsG)
    args <- localListG
    pure (lazy, name, args)

partialG : Grammar () RcToken True (String, String, List RCLocal)
partialG = do
    nameEq "partial"
    name <- greedyWordsG
    nameEq "missing="
    missing <- anyName
    args <- localListG
    pure (name, missing, args)

-- Same "lazy prefix means one extra keyword token" asymmetry as
-- `Language.RCExpr.Lexer`'s own note describes for `#`-constants --
-- `<|>` between a lazy and a plain alternative, not a single `if`
-- (its two arms would need different `consumes` flags).
applyG : Grammar () RcToken True (Bool, RCLocal, List RCLocal)
applyG = lazyApplyG <|> plainApplyG
  where
    lazyApplyG : Grammar () RcToken True (Bool, RCLocal, List RCLocal)
    lazyApplyG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if isLazyName n then pure () else fail "not lazy")
        nameEq "apply"
        c <- rcLocalG
        args <- localListG
        pure (True, c, args)
    plainApplyG : Grammar () RcToken True (Bool, RCLocal, List RCLocal)
    plainApplyG = do
        nameEq "apply"
        c <- rcLocalG
        args <- localListG
        pure (False, c, args)

opG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
opG = lazyOpG <|> plainOpG
  where
    lazyOpG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
    lazyOpG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if isLazyName n then pure () else fail "not lazy")
        nameEq "op"
        opName <- opNameG
        args <- localListG
        postDrop <- optionalField "postDrop"
        pure (True, opName, args, postDrop)
    plainOpG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
    plainOpG = do
        nameEq "op"
        opName <- opNameG
        args <- localListG
        postDrop <- optionalField "postDrop"
        pure (False, opName, args, postDrop)

extprimG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
extprimG = lazyExtprimG <|> plainExtprimG
  where
    lazyExtprimG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
    lazyExtprimG = do
        n <- anyName
        the (Grammar () RcToken False ()) (if isLazyName n then pure () else fail "not lazy")
        nameEq "extprim"
        pName <- greedyWordsG
        args <- localListG
        postDrop <- optionalField "postDrop"
        pure (True, pName, args, postDrop)
    plainExtprimG : Grammar () RcToken True (Bool, String, List RCLocal, List RCLocal)
    plainExtprimG = do
        nameEq "extprim"
        pName <- greedyWordsG
        args <- localListG
        postDrop <- optionalField "postDrop"
        pure (False, pName, args, postDrop)

||| `Pretty.idr`'s `retpack <name> tag= N [field]`, the list empty for a
||| nullary constructor.
retpackG : Grammar () RcToken True (String, String, Maybe RCLocal)
retpackG = do
    nameEq "retpack"
    name <- greedyWordsG
    nameEq "tag="
    tag <- anyName
    field <- localListG
    pure (name, tag, head' field)

conG : Grammar () RcToken True (String, String, List RCLocal, Maybe RCLocal)
conG = do
    nameEq "con"
    name <- greedyWordsG
    conInfoG
    nameEq "tag="
    tag <- tagTextG
    args <- localListG
    reuseFrom <- option Nothing (nameEq "reuse=" *> map Just rcLocalG)
    pure (name, tag, args, reuseFrom)

-- `structGet`/`structSet` render `sn` inside plain parens, e.g.
-- `( String )`; `(`/`)` aren't hard lexer delimiters (see
-- Language.RCExpr.Lexer's own note), so they're matched here as
-- ordinary `RcName` tokens (`Compiler.RC2.Pretty`'s own dump puts a
-- space either side, so they're never glued onto a neighbour).
structGetG : Grammar () RcToken True (RCLocal, String, List RCLocal)
structGetG = do
    nameEq "structGet"
    sv <- rcLocalG
    nameEq "."
    field <- anyName
    match (RcPunct '(') *> anyName *> match (RcPunct ')')
    postDrop <- optionalField "postDrop"
    pure (sv, field, postDrop)

structSetG : Grammar () RcToken True (RCLocal, String, RCLocal, List RCLocal)
structSetG = do
    nameEq "structSet"
    sv <- rcLocalG
    nameEq "."
    field <- anyName
    match (RcPunct '(') *> anyName *> match (RcPunct ')')
    nameEq "="
    value <- rcLocalG
    postDrop <- optionalField "postDrop"
    pure (sv, field, value, postDrop)

cmpG : Grammar () RcToken True (String, List RCLocal, List RCLocal)
cmpG = do
    nameEq "cmp"
    op <- opNameG
    args <- localListG
    postDrop <- optionalField "postDrop"
    pure (op, args, postDrop)

caseG : Grammar () RcToken True RCLocal
caseG = do
    nameEq "case"
    sc <- rcLocalG
    nameEq "of"
    pure sc

letHeaderG : Grammar () RcToken True (Int, RRep)
letHeaderG = do
    nameEq "let"
    loc <- rcLocalG
    nameEq ":"
    rep <- repG
    nameEq "="
    the (Grammar () RcToken False (Int, RRep)) $ case loc of
         RVar i => pure (i, rep)
         _ => fail "let-bound local must be a plain variable"

||| `Pretty.idr`'s own `"dup " ++ show v` (no count suffix, `Z` extra
||| dups) or `"dup " ++ show v ++ " x" ++ show (S extra)` (`x` glued
||| straight onto the digits, one token -- `Language.RCExpr.Lexer`'s
||| own greedy `nameLit`, no space in between) -- reading this as two
||| separate tokens (`nameEq "x"` then a number) would silently never
||| match the "x2"-shaped one at all and always fall back to `option`'s
||| own default of `1`, undercounting every multi-dup by its own
||| extra amount (a real bug this parser had, caught by the false
||| positives it produced once `Language.RCExpr.Lint` started relying
||| on this count being right).
dupG : Grammar () RcToken True (RCLocal, Int)
dupG = do
    nameEq "dup"
    v <- rcLocalG
    n <- option 1 $ do
        tok <- anyName
        the (Grammar () RcToken False Int) $ case strM tok of
             StrCons 'x' rest => if isDigitsOnly rest then pure (cast rest) else fail "malformed dup count"
             _ => fail "not a dup count"
    pure (v, n)

freeG : Grammar () RcToken True RCLocal
freeG = nameEq "free" *> rcLocalG

releaseReuseG : Grammar () RcToken True RCLocal
releaseReuseG = nameEq "releaseReuse" *> rcLocalG

reuseOfferG : Grammar () RcToken True (RCLocal, List RCLocal, List RCLocal)
reuseOfferG = do
    nameEq "reuseOffer"
    sc <- rcLocalG
    dupOnShared <- (nameEq "dupOnShared=" *> localListG) <|> (match (RcPunct '[') *> pure [] <* match (RcPunct ']'))
    dropOnUnique <- optionalField "dropOnUnique"
    pure (sc, dupOnShared, dropOnUnique)

loopParamG : Grammar () RcToken True (Int, RRep)
loopParamG = do
    q <- match RcQuotedString
    (varPart, repPart) <- the (Grammar () RcToken False (String, String)) (maybe (fail "malformed loop param") pure (splitOnColon q))
    the (Grammar () RcToken False (Int, RRep)) $ case classifyLocal varPart of
         Right (RVar i) => pure (i, if repPart == "Boxed" then Boxed else NativeRep repPart)
         _ => fail "loop param must be a plain variable"
  where
    splitOnColon : String -> Maybe (String, String)
    splitOnColon s = go 0 (unpack s)
      where
        go : Nat -> List Char -> Maybe (String, String)
        go i [] = Nothing
        go i (':' :: cs) = Just (pack (take i (unpack s)), pack cs)
        go i (_ :: cs) = go (S i) cs

loopG : Grammar () RcToken True (List (Int, RRep), List RCLocal, List RCLocal)
loopG = do
    nameEq "loop"
    match (RcPunct '[')
    params <- sepBy (match (RcPunct ',')) loopParamG
    match (RcPunct ']')
    nameEq "initial="
    initial <- localListG
    prologueDrop <- optionalField "prologueDrop"
    pure (params, initial, prologueDrop)

continueLoopG : Grammar () RcToken True (List RCLocal, List RCLocal)
continueLoopG = do
    nameEq "continue"
    nameEq "loop"
    args <- localListG
    postDrop <- optionalField "postDrop"
    pure (args, postDrop)

memoizeHeaderG : Grammar () RcToken True (String, RRep)
memoizeHeaderG = do
    nameEq "memoize"
    name <- greedyWordsG
    nameEq ":"
    rep <- repG
    pure (name, rep)

||| `["a", "b"] -> RetRep` -- `Compiler.RC2.Pretty`'s own
||| `show (map prettyRep argReps) ++ " -> " ++ prettyRep retRep`.
||| Captured as opaque text (same convention as every other
||| upstream-`Show`-derived field, `Language.RCExpr.AST`'s own module
||| note) since `RCallRep`'s own `sig` field is opaque -- reconstructed
||| well enough to read back in a diagnostic, not re-parsed as a type.
sigG : Grammar () RcToken True String
sigG = do
    match (RcPunct '[')
    argReps <- sepBy (match (RcPunct ',')) (match RcQuotedString)
    match (RcPunct ']')
    nameEq "->"
    ret <- repG
    pure ("[" ++ joinCommaShown argReps ++ "] -> " ++ show ret)
  where
    joinCommaShown : List String -> String
    joinCommaShown [] = ""
    joinCommaShown [x] = show x
    joinCommaShown (x :: xs) = show x ++ ", " ++ joinCommaShown xs

||| `[a, b]`-shaped list of opaque single-token items (a `CFType`, in
||| `RAppFFIInline`'s own `fargs`/`ret`) -- same opaque-capture
||| convention as `sigG`.
nameListTextG : Grammar () RcToken True String
nameListTextG = do
    match (RcPunct '[')
    xs <- sepBy (match (RcPunct ',')) anyName
    match (RcPunct ']')
    pure ("[" ++ joinComma xs ++ "]")
  where
    joinComma : List String -> String
    joinComma [] = ""
    joinComma [x] = x
    joinComma (x :: xs) = x ++ ", " ++ joinComma xs

callRepG : Grammar () RcToken True RCExp
callRepG = do
    nameEq "callRep"
    name <- greedyWordsG
    sig <- sigG
    postDrop <- optionalField "postDrop"
    args <- localListG
    pure (RCallRep name sig postDrop args)

||| `Pretty.idr`'s own `show ccs ++ " " ++ show fargs ++ " -> " ++ show
||| ret` -- `ccs : List String` (FFI calling-convention descriptors,
||| quoted), `fargs`/`ret : CFType` (opaque single tokens).
callFFIInlineG : Grammar () RcToken True RCExp
callFFIInlineG = do
    nameEq "callFFIInline"
    ccs <- do
        match (RcPunct '[')
        xs <- sepBy (match (RcPunct ',')) (match RcQuotedString)
        match (RcPunct ']')
        pure xs
    fargs <- nameListTextG
    nameEq "->"
    ret <- greedyWordsG
    let desc = "[" ++ joinCommaShown ccs ++ "] " ++ fargs ++ " -> " ++ ret
    postDrop <- optionalField "postDrop"
    args <- localListG
    pure (RCallFFI desc postDrop args)
  where
    joinCommaShown : List String -> String
    joinCommaShown [] = ""
    joinCommaShown [x] = show x
    joinCommaShown (x :: xs) = show x ++ ", " ++ joinCommaShown xs

crashG : Grammar () RcToken True String
crashG = nameEq "crash" *> match RcQuotedString

------------------------------------------------------------------------
-- The main recursive-descent block parser (indentation drives this;
-- one line's own content is parsed via the grammars above).

mutual
  ||| Everything at exactly `depth`, up to and including the first
  ||| line that isn't one of the "prefix, continue at the same depth"
  ||| shapes (`let`/`dup`/`drop`/`free`/`releaseReuse`/`reuseOffer`/
  ||| `loop`) -- see this module's own top-of-file note.
  parseBlock : Nat -> LParser RCExp
  parseBlock depth st = do
      (line, st1) <- atDepth depth st
      dispatchBlock depth st1.lineNo line st1

  ||| `parseBlock`'s own dispatch, pulled out of its `do` block: a
  ||| multi-way `if`/`else if` chain written directly as a `do`
  ||| statement doesn't parse (each `else` lands back at the
  ||| enclosing `do` block's own statement column) -- as a plain
  ||| function body (no `do` of its own at this level) it's fine.
  dispatchBlock : Nat -> Nat -> String -> LState -> Either ParseError (RCExp, LState)
  dispatchBlock depth ln line st1 =
      if isPrefixOf "let " line then do
          (var, rep) <- runG ln letHeaderG line
          (_, st2) <- advanceLine st1
          (value, st3) <- parseBlock (S depth) st2
          (body, st4) <- parseBlock depth st3
          Right (RLetIn var rep value body, st4)
      else if isPrefixOf "dup " line then do
          (var, count) <- runG ln dupG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RDupNode var count body, st3)
      else if isPrefixOf "drop " line then do
          vars <- runG ln (nameEq "drop" *> localListG) line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RDropNode vars body, st3)
      else if isPrefixOf "free " line then do
          v <- runG ln freeG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RFreeNode v body, st3)
      else if isPrefixOf "releaseReuse " line then do
          v <- runG ln releaseReuseG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RReleaseReuseNode v body, st3)
      else if isPrefixOf "reuseOffer " line then do
          (sc, dupOnShared, dropOnUnique) <- runG ln reuseOfferG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RReuseOfferNode sc dupOnShared dropOnUnique body, st3)
      else if isPrefixOf "loop " line then do
          (params, initial, prologueDrop) <- runG ln loopG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock depth st2
          Right (RLoopNode params initial prologueDrop body, st3)
      else terminal depth ln line st1

  ||| Every shape that never continues at the same depth.
  terminal : Nat -> Nat -> String -> LParser RCExp
  terminal depth ln line st1 =
      if isPrefixOf "memoize " line then do
          (name, rep) <- runG ln memoizeHeaderG line
          (_, st2) <- advanceLine st1
          (body, st3) <- parseBlock (S depth) st2
          Right (RMemoizeNode name rep body, st3)
      else if isPrefixOf "callRep " line then do
          r <- runG ln callRepG line
          (_, st2) <- advanceLine st1
          Right (r, st2)
      else if isPrefixOf "callFFIInline " line then do
          r <- runG ln callFFIInlineG line
          (_, st2) <- advanceLine st1
          Right (r, st2)
      else if firstWord line == "call" then do
          (lazy, name, args) <- runG ln callG line
          (_, st2) <- advanceLine st1
          Right (RCall lazy name args, st2)
      else if isPrefixOf "partial " line then do
          (name, missing, args) <- runG ln partialG line
          (_, st2) <- advanceLine st1
          Right (RPartial name missing args, st2)
      else if firstWord line == "apply" then do
          (lazy, c, args) <- runG ln applyG line
          (_, st2) <- advanceLine st1
          Right (RApply lazy c args, st2)
      else if isPrefixOf "retpack " line then do
          (name, tag, field) <- runG ln retpackG line
          (_, st2) <- advanceLine st1
          Right (RRetPackNode name tag field, st2)
      else if isPrefixOf "con " line then do
          (name, tag, args, reuseFrom) <- runG ln conG line
          (_, st2) <- advanceLine st1
          Right (RConstruct name tag args reuseFrom, st2)
      else if firstWord line == "op" then do
          (lazy, opName, args, postDrop) <- runG ln opG line
          (_, st2) <- advanceLine st1
          Right (ROpNode lazy opName args postDrop, st2)
      else if firstWord line == "extprim" then do
          (lazy, pName, args, postDrop) <- runG ln extprimG line
          (_, st2) <- advanceLine st1
          Right (RExtPrimNode lazy pName args postDrop, st2)
      else if isPrefixOf "structGet " line then do
          (sv, field, postDrop) <- runG ln structGetG line
          (_, st2) <- advanceLine st1
          Right (RStructGetNode sv field postDrop, st2)
      else if isPrefixOf "structSet " line then do
          (sv, field, value, postDrop) <- runG ln structSetG line
          (_, st2) <- advanceLine st1
          Right (RStructSetNode sv field value postDrop, st2)
      else if isPrefixOf "cmp " line then do
          (op, args, postDrop) <- runG ln cmpG line
          (_, st2) <- advanceLine st1
          (_, st3) <- expectLine depth "then" st2
          (whenTrue, st4) <- parseBlock (S depth) st3
          (_, st5) <- expectLine depth "else" st4
          (whenFalse, st6) <- parseBlock (S depth) st5
          Right (RCmp op args postDrop whenTrue whenFalse, st6)
      else if isPrefixOf "case " line then do
          sc <- runG ln caseG line
          (_, st2) <- advanceLine st1
          ((altsE, mDef), st3) <- parseAlts depth st2
          Right (either (\a => RConCaseNode sc a mDef) (\a => RConstCaseNode sc a mDef) altsE, st3)
      else if line == "erased" then do
          (_, st2) <- advanceLine st1
          Right (RErasedNode, st2)
      else if isPrefixOf "crash " line then do
          msg <- runG ln crashG line
          (_, st2) <- advanceLine st1
          Right (RCrashNode msg, st2)
      else if isPrefixOf "continue loop " line then do
          (args, postDrop) <- runG ln continueLoopG line
          (_, st2) <- advanceLine st1
          Right (RLoopContinueNode args postDrop, st2)
      else case classifyLocal line of
                Right loc =>
                    do (_, st2) <- advanceLine st1
                       Right (RV loc, st2)
                Left _ =>
                    do (_, st2) <- advanceLine st1
                       Right (RPrim line, st2)

  ||| A run of alt-lines at `depth+1` (each its own body at `depth+2`)
  ||| plus an optional trailing `_ ->` default at `depth+1`, stopping
  ||| once a shallower line is seen (or input ends). Distinguishes
  ||| `RConCase` (header `Name CI tag=T args=[...] ->`) from
  ||| `RConstCase` (bare `<constant> ->`) by whether `" tag="` appears
  ||| -- the one syntactic marker `Pretty.idr`'s two
  ||| `prettyConAlt`/`prettyConstAlt` clauses don't share.
  parseAlts : Nat -> LParser (Either (List RConAlt) (List RConstAlt), Maybe RCExp)
  parseAlts depth st =
      if not (hasLineAtDepth (S depth) st)
         then Right ((Left [], Nothing), st)
         else do
             (line, st1) <- atDepth (S depth) st
             dispatchAlt depth line st1

  ||| `parseAlts`'s own dispatch, pulled out of its `do` block for the
  ||| same layout reason as `dispatchBlock`.
  dispatchAlt : Nat -> String -> LState -> Either ParseError ((Either (List RConAlt) (List RConstAlt), Maybe RCExp), LState)
  dispatchAlt depth line st1 =
      if line == "_ ->" then do
          (_, st2) <- advanceLine st1
          (defBody, st3) <- parseBlock (S (S depth)) st2
          Right ((Left [], Just defBody), st3)
      else if isInfixOf " tag=" line then do
          (alt, st2) <- parseConAltLine depth st1.lineNo line st1
          ((restE, mDef), st3) <- parseAlts depth st2
          let rest = either id (const []) restE
          Right ((Left (alt :: rest), mDef), st3)
      else do
          (alt, st2) <- parseConstAltLine depth st1.lineNo line st1
          ((restE, mDef), st3) <- parseAlts depth st2
          let rest = either (const []) id restE
          Right ((Right (alt :: rest), mDef), st3)

  conAltHeaderG : Grammar () RcToken True (String, String, List Int)
  conAltHeaderG = do
      name <- greedyWordsG
      conInfoG
      nameEq "tag="
      tag <- tagTextG
      nameEq "args="
      match (RcPunct '[')
      args <- sepBy (match (RcPunct ',')) rcLocalG
      match (RcPunct ']')
      nameEq "->"
      -- `RUnderscore` here is a `Compiler.RC2.DeadVars`-erased alt
      -- field (`Language.RCExpr.AST`'s own `RUnderscore` doc comment)
      -- -- `RCLoc 0`, same sentinel `Pretty.idr`'s own `map RCLoc
      -- args` prints as `_`.
      argVars <- traverseG (\l => case l of
                                        RVar i => pure i
                                        RUnderscore => pure 0
                                        _ => fail "alt arg must be a plain variable or _") args
      pure (name, tag, argVars)

  parseConAltLine : Nat -> Nat -> String -> LParser RConAlt
  parseConAltLine depth ln line st1 = do
      (name, tag, args) <- runG ln conAltHeaderG line
      (_, st2) <- advanceLine st1
      (body, st3) <- parseBlock (S (S depth)) st2
      Right (MkRConAlt name tag args body, st3)

  ||| A `RConstAlt`'s own scrutinee: `Show Constant`'s value -- either
  ||| a bare token (a number, or a `Char` literal like `'x'`, both
  ||| already one `RcName` token whole) or a quoted string (its own
  ||| `RcQuotedString` token, requoted the same way `quotedConstG`
  ||| does for a `RConst` local).
  constTextG : Grammar () RcToken True String
  constTextG = quotedG <|> plainG
    where
      quotedG : Grammar () RcToken True String
      quotedG = map show (match RcQuotedString)
      plainG : Grammar () RcToken True String
      plainG = anyName

  parseConstAltLine : Nat -> Nat -> String -> LParser RConstAlt
  parseConstAltLine depth ln line st1 = do
      constPart <- runG ln (constTextG <* nameEq "->") line
      (_, st2) <- advanceLine st1
      (body, st3) <- parseBlock (S (S depth)) st2
      Right (MkRConstAlt constPart body, st3)

------------------------------------------------------------------------
-- Top level: one `def` block per top-level definition.

funArgG : Grammar () RcToken True (Int, RRep)
funArgG = do
    q <- match RcQuotedString
    let noQuotes = q
    (varPart, repPart) <- the (Grammar () RcToken False (String, String)) (maybe (fail "malformed fun arg") pure (splitOnColon noQuotes))
    the (Grammar () RcToken False (Int, RRep)) $ case classifyLocal varPart of
         Right (RVar i) => pure (i, if repPart == "Boxed" then Boxed else NativeRep repPart)
         _ => fail "fun arg must be a plain variable"
  where
    splitOnColon : String -> Maybe (String, String)
    splitOnColon s = go 0 (unpack s)
      where
        go : Nat -> List Char -> Maybe (String, String)
        go i [] = Nothing
        go i (':' :: cs) = Just (pack (take i (unpack s)), pack cs)
        go i (_ :: cs) = go (S i) cs

defHeaderFunG : Grammar () RcToken True (List (Int, RRep), RRep, Bool)
defHeaderFunG = do
    nameEq "fun"
    nameEq "args="
    match (RcPunct '[')
    args <- sepBy (match (RcPunct ',')) funArgG
    match (RcPunct ']')
    nameEq "ret="
    retRep <- repG
    isWorker <- option False (nameEq "worker=True" *> pure True)
    pure (args, retRep, isWorker)

||| `Compiler.RC2.Pretty.prettyDef`'s own `MkRCCon` clause -- `tag :
||| Maybe Int` and `nt : Maybe Nat` both print via the same `Just N`/
||| `Nothing` shape `tagTextG` already reads for a con-alt's own tag.
conDefG : Grammar () RcToken True (String, String, String)
conDefG = do
    nameEq "con"
    nameEq "tag="
    tag <- tagTextG
    nameEq "arity="
    arity <- anyName
    nameEq "newtype="
    nt <- tagTextG
    pure (tag, arity, nt)

parseOneDef : LParser (String, RCDef)
parseOneDef st = do
    (line, st1) <- atDepth 0 st
    (name, rest) <- maybe (lfail st1.lineNo ("malformed def: " ++ line)) Right (splitOn2Spaces (dropChars 4 line))
    (_, st2) <- advanceLine st1
    dispatchDef st1.lineNo name (dropParenPrefix rest) st2
  where
    -- `where`-block items can't forward-reference each other in
    -- Idris2 (unlike a top-level `mutual` block) -- everything
    -- `dispatchDef` calls has to come before it here.
    skipBlank : LParser ()
    skipBlank st = case st.remaining of
        (l :: rest) => if trim l == "" then Right ((), MkLState rest (S st.lineNo)) else Right ((), st)
        [] => Right ((), st)

    ||| `parseOneDef`'s own dispatch, pulled out of its `do` block for
    ||| the same layout reason as `dispatchBlock`.
    dispatchDef : Nat -> String -> String -> LState -> Either ParseError ((String, RCDef), LState)
    dispatchDef ln name kindText st2 =
        if isPrefixOf "fun args=" kindText then do
            (args, retRep, isWorker) <- runG ln defHeaderFunG kindText
            (body, st3) <- parseBlock 1 st2
            (_, st4) <- skipBlank st3
            Right ((name, RCFun args retRep isWorker body), st4)
        else if isPrefixOf "con tag=" kindText then do
            (tag, arity, nt) <- runG ln conDefG kindText
            Right ((name, RCCon tag arity nt), st2)
        else if isPrefixOf "foreign " kindText then
            Right ((name, RCForeign kindText), st2)
        else if isPrefixOf "error" kindText then do
            (body, st3) <- parseBlock 1 st2
            (_, st4) <- skipBlank st3
            Right ((name, RCErrorDef body), st4)
        else lfail ln ("unrecognised def kind: " ++ kindText)

    splitOn2Spaces : String -> Maybe (String, String)
    splitOn2Spaces s = go 0 (unpack s)
      where
        go : Nat -> List Char -> Maybe (String, String)
        go i (' ' :: ' ' :: cs) = Just (pack (take i (unpack s)), pack cs)
        go i (_ :: cs) = go (S i) cs
        go i [] = Nothing

    dropParenPrefix : String -> String
    dropParenPrefix s = case unpack s of ('(' :: cs) => pack (reverse (drop 1 (reverse cs))); _ => s

||| Parses a whole `--directive dumprcexpr` dump into one `(name, def)`
||| pair per `def` block, in file order. A blank line, or a line
||| starting with `-- ` (`Compiler.RC2.Util`'s own `directiveComment`
||| writes exactly one of these at the very top of the dump, recording
||| which `--directive`/`%cg rc2` flags produced it), is skipped
||| wherever it appears at this top level -- no other line of a real
||| `def` block ever starts this way (`Compiler.RC2.Pretty`'s own
||| format has no comment syntax of its own inside a block), so this
||| can't be mistaken for anything else.
export
parseProgram : String -> Either ParseError RCProgram
parseProgram src = go (MkLState (lines src) 1)
  where
    go : LState -> Either ParseError RCProgram
    go st = case st.remaining of
        [] => Right []
        (l :: rest) =>
            if trim l == "" || isPrefixOf "-- " l
               then go (MkLState rest (S st.lineNo))
               else do
                   (one, st1) <- parseOneDef st
                   defs <- go st1
                   Right (one :: defs)
