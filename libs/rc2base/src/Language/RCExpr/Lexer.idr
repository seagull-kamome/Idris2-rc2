module Language.RCExpr.Lexer

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Tokenizes a single already-indentation-stripped line of
-- `Compiler.RC2.Pretty`'s dump format (`Language.RCExpr.Parser`
-- handles the line/indentation structure itself; this only ever runs
-- on one line's own content at a time). Built on upstream's own
-- `Text.Lexer`/`Text.Token`, the same library `Language.JSON.Lexer`
-- itself is built on (`idris2-src/libs/contrib/Language/JSON/`) --
-- `rc2base` already depends on `contrib`.
--
-- Deliberately few token kinds: `[`/`]`/`,` are the only real
-- structural delimiters this grammar has (every list is
-- `[a, b, c]`-shaped, `Show (List _)`'s own convention); a quoted
-- string needs its own rule so its interior (which can contain
-- spaces/commas/brackets, e.g. a `crash` message or a `RCConst`
-- string's own value) is never mistaken for structure; everything
-- else -- keywords, `vN`/`_`/`[__]`-shaped locals, dotted/braced
-- names (including a machine name's own nested `{...}`, e.g.
-- `{{__mainExpression:0}:0}`), field labels (`postDrop=`), single
-- punctuation characters that only ever appear surrounded by
-- whitespace in this grammar (`:`, `=`, `->`, a lone `#`) -- is one
-- greedy `RcName` run, since whitespace already separates every one
-- of those from its neighbours and `Language.RCExpr.Parser`'s own
-- grammar checks a name token's exact text where it needs to
-- distinguish them. See `Language.RCExpr.AST`'s own module note for
-- why none of this needs to be parsed any more precisely than that.

import Text.Lexer
import Text.Token

%default total

public export
data RcTokenKind = RcName | RcQuotedString | RcPunct Char | RcIgnore

public export
Eq RcTokenKind where
  RcName == RcName = True
  RcQuotedString == RcQuotedString = True
  RcPunct a == RcPunct b = a == b
  RcIgnore == RcIgnore = True
  _ == _ = False

public export
RcToken : Type
RcToken = Token RcTokenKind

||| Strips the enclosing quotes (`"..."` or `'...'` -- a `Show Char`
||| value, e.g. `'"'` for the character `"` itself, is tokenized the
||| same way as a quoted string, see `rcCharLit`'s own note) and decodes
||| the common backslash escapes `Prelude.Show.showLitString`/
||| `showLitChar` (`Compiler.RC2.RCExp`'s own `Show String`/`Show
||| Constant`, what produced this text in the first place) actually
||| emit for this grammar's own alphabet -- `\n`/`\t`/`\r`/`\\`/`\"`/
||| `\'`. Not a full inverse (control-character names like `\NUL`,
||| `\DEL` are left as literal backslash-letter text) -- unneeded
||| here, since `Language.RCExpr.Lint`'s own ownership checks never
||| read a constant's *value*, only that a `RCLocal` position holds
||| one; good enough for a diagnostic to echo back is enough.
unescapeQuoted : String -> String
unescapeQuoted s = case unpack s of
    (q :: rest) => if q == '"' || q == '\'' then pack (go (dropLastQuote q rest)) else s
    _ => s
  where
    dropLastQuote : Char -> List Char -> List Char
    dropLastQuote q cs = case reverse cs of
                             (c :: rs) => if c == q then reverse rs else cs
                             [] => cs
    go : List Char -> List Char
    go [] = []
    go ('\\' :: 'n' :: cs) = '\n' :: go cs
    go ('\\' :: 't' :: cs) = '\t' :: go cs
    go ('\\' :: 'r' :: cs) = '\r' :: go cs
    go ('\\' :: '"' :: cs) = '"' :: go cs
    go ('\\' :: '\'' :: cs) = '\'' :: go cs
    go ('\\' :: '\\' :: cs) = '\\' :: go cs
    go (c :: cs) = c :: go cs

public export
TokenKind RcTokenKind where
  TokType RcName = String
  TokType RcQuotedString = String
  TokType (RcPunct _) = ()
  TokType RcIgnore = ()

  tokValue RcName text = text
  tokValue RcQuotedString text = unescapeQuoted text
  tokValue (RcPunct _) _ = ()
  tokValue RcIgnore _ = ()

export
ignored : WithBounds RcToken -> Bool
ignored (MkBounded (Tok RcIgnore _) _ _) = True
ignored _ = False

------------------------------------------------------------------------

||| The list separator `Show (List a)` actually writes is `", "`
||| (comma *and* a following space), never a bare `,` -- but a bare
||| `,` with no following space shows up glued directly into some
||| `Core.Name` displays too (a `with`/`case` block naming more than
||| one mutually-defined clause, e.g. `case block in words,helper`,
||| seen in real idris2-lsp output). So only a `,` immediately
||| followed by a space is the real separator here; matched via
||| `expect` (checks, doesn't consume) so the space itself is left for
||| `spaces`/`RcIgnore` to eat as usual. `nameLit` (below) stops
||| *before* one of these via `someUntil`, so this rule actually gets
||| a turn at the `,` instead of it always being swallowed as just
||| another name character first -- a bare `,` with no trailing space
||| is still an ordinary name character there, gluing onto whatever
||| name surrounds it, same as the source.
listCommaLit : Lexer
listCommaLit = is ',' <+> expect (pred isSpace)

||| Everything except whitespace and the hard delimiters `[`, `]`,
||| `(`, `)`, `{`, `}`, `"`, `#` (see this module's own top-of-file
||| note for why a single greedy class is otherwise the right call
||| here) -- and, per `someUntil`, stopping one character early
||| whenever what's left starts with `listCommaLit`'s own `, `, so
||| that rule gets a chance to claim the comma as a real list
||| separator instead of it always being read as just another name
||| character first. `'` is *not* excluded -- a bare identifier with a
||| trailing prime (`bufferData'`) or an operator's own namespaced
||| display (`Prelude.Types.SnocList.(<>>)`, which also needs the
||| `'`-adjacent `(`/`)` back) both rely on it staying a name
||| character -- this is safe because `rcTokenMap` tries `rcCharLit`
||| (below) *before* this rule, and `Text.Lexer.Core.getFirstToken`
||| picks the first rule that matches at all, not the longest one, so
||| a token actually starting with `'` (a `Show Char` value) is always
||| claimed by `rcCharLit` first regardless of what `nameLit` alone
||| could also match. `(`/`)` stay excluded so a `RCConstCon`'s own
||| recursive `#Name@tag(args)` (`Compiler.RC2.RCExp.RCLocal`'s
||| `Show`) can be told apart from its own leading `#Name@tag` --
||| `Language.RCExpr.Parser`'s own `hashLocalG`/`anyName` need `(`/`)`
||| as their own tokens, not glued onto the name before or after them,
||| and tell a `RCConstCon`'s own args list apart from an operator's
||| own namespaced display by what immediately follows the `(` (`[`
||| only for the former). `#` is its own token too (`Language.RCExpr.
||| Parser`'s own `rcLocalG` always matches it separately, then
||| dispatches on whatever comes right after) -- needed because a
||| `#`-prefixed `Show Char` constant, e.g. `#'"'` for the character
||| `"` itself, would otherwise glue the `'` straight onto the `#` as
||| one name run before `rcCharLit` ever gets a chance to claim it (a
||| token's *first* character decides which rule can match it at all,
||| and `#` on its own matches neither `quotedStringLit` nor
||| `rcCharLit`). `{`/`}` stay excluded so `Language.RCExpr.Parser`'s
||| own `braceGroupG` can read a `Core.Name` `MN`'s own machine name
||| (`"{" ++ x ++ ":" ++ show y ++ "}"`) structurally, token by token,
||| tracking nesting depth as it goes -- `x` is an arbitrary compiler-
||| generated hint string that can itself embed `(`/`)` (a type's own
||| `Show` output, e.g. `{fromJSON_FromJSON_((SortedMap String)
||| $v):1}` seen in real idris2-lsp output) or even a nested `{...}`,
||| neither of which a single flat lexer rule (unlike the simpler,
||| already-balanced `{{__mainExpression:0}:0}` case this grammar
||| handled before that discovery) can track the true end of.
nameLit : Lexer
nameLit = someUntil listCommaLit (pred isNameChar)
  where
    isNameChar : Char -> Bool
    isNameChar c = not (isSpace c) && c /= '[' && c /= ']' && c /= '"' && c /= '(' && c /= ')' && c /= '#' && c /= '{' && c /= '}'

quotedStringLit : Lexer
quotedStringLit = is '"' <+> manyUntil (is '"') (escape (is '\\') any <|> any) <+> is '"'

||| A `Show Char` value, e.g. `'x'`, `'\n'`, or (the case that broke
||| this grammar's original design, which had no rule for this at
||| all) `'"'` for the character `"` itself -- `Prelude.Show`'s own
||| `showLitChar` never escapes a bare `"` inside a `Char`, only
||| inside a `String`, so that character shows up completely
||| unescaped here. Tokenized the same `RcQuotedString` kind as a
||| quoted string (`unescapeQuoted` handles both quote characters) --
||| this grammar never needs to tell a `Char` constant apart from a
||| `String` one, both are opaque `RConst` payloads either way (see
||| `Language.RCExpr.AST`'s own module note).
rcCharLit : Lexer
rcCharLit = is '\'' <+> manyUntil (is '\'') (escape (is '\\') any <|> any) <+> is '\''

rcTokenMap : TokenMap RcToken
rcTokenMap = toTokenMap $
    [ (spaces, RcIgnore)
    , (is '[', RcPunct '[')
    , (is ']', RcPunct ']')
    , (listCommaLit, RcPunct ',')
    , (is '(', RcPunct '(')
    , (is ')', RcPunct ')')
    , (is '{', RcPunct '{')
    , (is '}', RcPunct '}')
    , (is '#', RcPunct '#')
    , (quotedStringLit, RcQuotedString)
    , (rcCharLit, RcQuotedString)
    , (nameLit, RcName)
    ]

||| Tokenizes one line's own already-indent-stripped text. `Nothing`
||| only if the lexer gets stuck (never consumes any input at some
||| position) -- a malformed-input signal `Language.RCExpr.Parser`
||| turns into a `ParseError`.
export
lexLine : String -> Maybe (List (WithBounds RcToken))
lexLine str = case lex rcTokenMap str of
    (toks, _, _, "") => Just (filter (not . ignored) toks)
    _ => Nothing
