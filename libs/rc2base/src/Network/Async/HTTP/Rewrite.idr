||| A URL rewriter for `Network.Async.HTTP.Router`: `urlRewrite` is a `Handler`
||| transformer that changes the path of a request, or answers it with a redirect,
||| by rules of regular expressions, before the handler it wraps (`static`, `cgi`,
||| `proxy`, `router`) sees it. See `doc/async-http-router.md`.
module Network.Async.HTTP.Rewrite

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.List
import Data.Maybe
import Data.String
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Text.Regex.POSIX

%default covering

||| What a rule does with a request it matches.
public export
data Action
  = ||| Give the handler a request with the new path (the client does not see it).
    Internal
  | ||| Answer with this status (301, 302, 303, 307 or 308) and the new path as
    ||| `Location`.
    Redirect Int

-- A piece of a template: some text, or what a group of the pattern matched.
data Piece = Lit String | Group Nat

||| A rewrite rule, made by `rule`.
export
record RewriteRule where
  constructor MkRule
  pattern : Regex
  pieces : List Piece
  ||| Whether the template starts with `http://` or `https://`: only then may the
  ||| result of a redirect name another host.
  absolute : Bool
  action : Action

-- The pieces of a template: `\0` to `\9` is what a group matched (`\0` all of the
-- path), `\\` a backslash. A backslash before anything else is an error.
parsePieces : String -> Either String (List Piece)
parsePieces template = go [] [] (unpack template)
  where
    flush : List Char -> List Piece -> List Piece
    flush [] ps = ps
    flush cs ps = Lit (pack (reverse cs)) :: ps

    go : (literal : List Char) -> (done : List Piece) -> List Char -> Either String (List Piece)
    go cs ps [] = Right (reverse (flush cs ps))
    go cs ps ('\\' :: '\\' :: rest) = go ('\\' :: cs) ps rest
    go cs ps ('\\' :: d :: rest) =
      if isDigit d then go [] (Group (cast {to = Nat} (ord d - ord '0')) :: flush cs ps) rest
      else Left "a backslash in a template is followed by a digit or a backslash"
    go _ _ ['\\'] = Left "a template does not end with a backslash"
    go cs ps (c :: rest) = go (c :: cs) ps rest

-- Whether a group comes before the `/` that ends the host of an `http(s)://` template
-- (`scheme` is `http://` or `https://`): `https://example.org\1` with `@evil.example/`
-- caught is `https://example.org@evil.example/`.
groupInAuthority : (scheme : String) -> List Piece -> Bool
groupInAuthority scheme pieces =
  any isGroup pieces && not (elem '/' (drop (length scheme) (unpack (leading pieces))))
  where
    isGroup : Piece -> Bool
    isGroup (Group _) = True
    isGroup (Lit _) = False

    -- the text before the first group
    leading : List Piece -> String
    leading (Lit s :: rest) = s ++ leading rest
    leading _ = ""

||| Make a rule. A request is matched when `pattern` (a POSIX extended regular
||| expression) matches all of its path, the query string left out and the path as it
||| stands in the request, percent-encoded. `template` is the new path (and query):
||| text with `\1` to `\9` for what the groups matched, `\0` for all of the path and
||| `\\` for a backslash; a query string in the template replaces the one of the
||| request, else that stays. `Left` for a pattern or template that is not valid (the
||| template must also have no control character: it ends up in a `Location`; and an
||| `http://` or `https://` template has no group before the first `/` after the
||| host, which the request could fill with `@host`), a
||| group the pattern does not have, or a `Redirect` status other than 301, 302, 303,
||| 307 and 308.
export
rule : (pattern, template : String) -> Action -> IO (Either String RewriteRule)
rule pattern template action = do
  let scheme = if isPrefixOf "http://" template then Just "http://"
               else if isPrefixOf "https://" template then Just "https://" else Nothing
  let absolute = isJust scheme
  Right re <- compile pattern
    | Left e => pure (Left ("bad pattern: " ++ e))
  pure $ do
    unless (noControl template) (Left "a template has no control character")
    pieces <- parsePieces template
    case scheme of
      Just sch => when (groupInAuthority sch pieces) $
                    Left "a group in the host part of a URL template: the request could name another host"
      Nothing => Right ()
    when (any (\p => case p of Group n => cast n > groupCount re; Lit _ => False) pieces) $
      Left "the template uses a group the pattern does not have"
    case action of
      Redirect status => unless (elem status [301, 302, 303, 307, 308]) (Left "bad redirect status")
      Internal => Right ()
    Right (MkRule re pieces absolute action)

-- The text of a template for the groups of a match.
expand : List Piece -> List (Maybe String) -> String
expand pieces groups = concatMap piece pieces
  where
    piece : Piece -> String
    piece (Lit s) = s
    piece (Group n) = case drop n groups of
                           Just g :: _ => g
                           _ => ""

-- The groups of the first rule that matches all of `path`, with the rule.
firstMatch : String -> List RewriteRule -> Maybe (RewriteRule, List (Maybe String))
firstMatch path [] = Nothing
firstMatch path (r :: rs) = case match r.pattern path of
  Just groups@(Just whole :: _) => if whole == path then Just (r, groups) else firstMatch path rs
  _ => firstMatch path rs

-- A path the handler behind the rewriter can be given: it starts with one `/`, is
-- not cut or split by a control character, a space or a backslash, and has no
-- `.` or `..` segment.
validPath : String -> Bool
validPath p =
  isPrefixOf "/" p && noControl p && not (any (\c => c == ' ' || c == '\\') (unpack p))
  && not (hasDotSegment p)

-- Where a redirect may go: a path on this server (not `//host`, which a browser takes
-- for another host), or, for a template that says so, an `http` or `https` URL.
validLocation : (absolute : Bool) -> String -> Bool
validLocation absolute l = noControl l && not (any (\c => c == ' ' || c == '\\') (unpack l)) && wanted
  where
    wanted : Bool
    wanted = if absolute then isPrefixOf "http://" l || isPrefixOf "https://" l
             else isPrefixOf "/" l && not (isPrefixOf "//" l)

||| (Not called `rewrite`: that is a keyword.)
|||
||| Apply the first rule that matches the path of the request, and give the request
||| to `next`, or answer it. The result is not matched again (no rule can loop), and
||| a request that no rule matches goes on as it is. A request is answered with 400
||| when its path has a CR, LF or NUL in it, or when the new path is not valid (not
||| starting with a single `/`, a `.` or `..` segment, a control character, a space or
||| a backslash: what the groups caught from the request must not be able to make
||| `//host` of a redirect, or a path out of a directory).
export
urlRewrite : List RewriteRule -> (next : Handler) -> Handler
urlRewrite rules next req =
  if not (noControl req.path) then refused else
    let (path, query) = break (== '?') req.path
    in case firstMatch path rules of
         Nothing => next req
         Just (r, groups) =>
           let (newPath, newQuery) = break (== '?') (expand r.pieces groups)
               target = newPath ++ (if newQuery == "" then query else newQuery)
           in case r.action of
                Internal => if validPath newPath then next ({ path := target } req) else refused
                Redirect status =>
                  if validLocation r.absolute newPath
                    then liftIO (noBody {headers = [("Location", target)]} status)
                    else refused
  where
    refused : Task Response
    refused = liftIO (text 400 "bad request\n")
