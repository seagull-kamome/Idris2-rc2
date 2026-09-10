||| URL / URI parsing and building, and the percent-encoding underneath.
||| Best-effort, not a validator: `parse` always produces a `URL` (an
||| unrecognisable input mostly lands in `path`). `Network.HTTP.Router`
||| deliberately doesn't touch query strings -- this is where that
||| lives.
|||
||| Bytes, not codepoints: `percentDecode "%C3%A9"` is the two UTF-8
||| bytes of "é", correct under `--cg rc2`/`--cg refc` (where `String`
||| is byte-indexed) but not under `--cg chez`.
module Network.URL

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.List
import Data.List1
import Data.String

-- `Data.String.strTail` isn't total upstream; the string splitting
-- here uses a `pack . drop 1 . unpack` helper (`rest1`) instead, so
-- this module stays under rc2base.ipkg's package-wide `--total`.

rest1 : String -> String
rest1 = pack . drop 1 . unpack

-------------------------------------------------------------------------------
-- Percent-encoding (RFC 3986)
-------------------------------------------------------------------------------

hexVal : Char -> Maybe Int
hexVal c =
  if isDigit c            then Just (ord c - ord '0')
  else if c >= 'a' && c <= 'f' then Just (ord c - ord 'a' + 10)
  else if c >= 'A' && c <= 'F' then Just (ord c - ord 'A' + 10)
  else Nothing

hexDigit : Int -> Char
hexDigit n = if n < 10 then chr (ord '0' + n) else chr (ord 'A' + n - 10)

||| RFC 3986 `unreserved`: `A-Z a-z 0-9` and `- . _ ~`. Never encoded.
export
unreserved : Char -> Bool
unreserved c = isAlphaNum c || c == '-' || c == '.' || c == '_' || c == '~'

pctByte : Char -> List Char
pctByte c = let b = ord c `mod` 256 in ['%', hexDigit (b `div` 16), hexDigit (b `mod` 16)]

||| Decode `%XX` escapes to bytes. A `+` is left as-is (it only means
||| "space" in `application/x-www-form-urlencoded` -- see `parseQuery`).
||| A `%` not followed by two hex digits is kept literally.
export
percentDecode : String -> String
percentDecode = pack . go . unpack
  where
    go : List Char -> List Char
    go ('%' :: h :: l :: rest) =
      case (hexVal h, hexVal l) of
        (Just hi, Just lo) => chr (hi * 16 + lo) :: go rest
        _                  => '%' :: go (h :: l :: rest)
    go (c :: rest) = c :: go rest
    go []          = []

||| Percent-encode every byte that isn't `unreserved`. Space becomes
||| `%20`. For a path segment or a fragment.
export
percentEncode : String -> String
percentEncode = pack . concatMap enc . unpack
  where
    enc : Char -> List Char
    enc c = if unreserved c then [c] else pctByte c

-- application/x-www-form-urlencoded: like percentEncode but ' ' -> '+'.
formEncode : String -> String
formEncode = pack . concatMap enc . unpack
  where
    enc : Char -> List Char
    enc ' ' = ['+']
    enc c   = if unreserved c then [c] else pctByte c

-- '+' -> ' ' first (so a literal '%2B' still decodes to '+'), then %XX.
formDecode : String -> String
formDecode = percentDecode . pack . map plus . unpack
  where
    plus : Char -> Char
    plus '+' = ' '
    plus c   = c

-------------------------------------------------------------------------------
-- Query strings
-------------------------------------------------------------------------------

nonEmpty : String -> Maybe String
nonEmpty s = if s == "" then Nothing else Just s

||| Parse a query string: `"a=1&b=two+words&c"` becomes
||| `[("a","1"), ("b","two words"), ("c","")]`. A leading `?` is
||| tolerated. Keys and values are form-decoded (`+` to space, `%XX`).
||| Empty segments (a `&&`) are dropped.
export
parseQuery : String -> List (String, String)
parseQuery s0 =
  let s = if isPrefixOf "?" s0 then rest1 s0 else s0
  in map pair (filter (/= "") (forget (split (== '&') s)))
  where
    pair : String -> (String, String)
    pair kv =
      let (k, rest) = break (== '=') kv
      in (formDecode k, formDecode (if isPrefixOf "=" rest then rest1 rest else ""))

||| Inverse of `parseQuery`: each pair form-encoded as `k=v`, joined
||| with `&`.
export
buildQuery : List (String, String) -> String
buildQuery = concat . intersperse "&" . map (\(k, v) => formEncode k ++ "=" ++ formEncode v)

-------------------------------------------------------------------------------
-- Whole URLs
-------------------------------------------------------------------------------

||| A URL split into components. `query` and `fragment` are decoded;
||| `path` is left percent-encoded (decoding it would blur a `%2F`
||| inside a segment against a real separator -- use `pathSegments`).
public export
record URL where
  constructor MkURL
  scheme   : Maybe String            -- lowercased; Nothing for a relative reference
  host     : Maybe String            -- Nothing when there is no `//authority`; keeps `[...]` for IPv6
  port     : Maybe Int
  path     : String
  query    : List (String, String)
  fragment : Maybe String

-- (before, Just after) if `c` occurs, else (whole, Nothing).
breakOn : Char -> String -> (String, Maybe String)
breakOn c s =
  let (a, b) = break (== c) s
  in if b == "" then (a, Nothing) else (a, Just (rest1 b))

-- scheme = ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) followed by ":"
splitScheme : String -> (Maybe String, String)
splitScheme s =
  let (a, b) = break (== ':') s
  in if b /= "" && ok a then (Just a, rest1 b) else (Nothing, s)
  where
    schemeChar : Char -> Bool
    schemeChar c = isAlphaNum c || c == '+' || c == '-' || c == '.'
    ok : String -> Bool
    ok str = case unpack str of
               []       => False
               (h :: t) => isAlpha h && all schemeChar t

-- "//authority/rest" -> (Just authority, "/rest"); else (Nothing, s).
-- `?`/`#` are already stripped before this runs.
splitAuthority : String -> (Maybe String, String)
splitAuthority s =
  if isPrefixOf "//" s
    then let (auth, path) = break (== '/') (pack (drop 2 (unpack s)))
         in (Just auth, path)
    else (Nothing, s)

portOf : String -> Maybe Int
portOf str = if isPrefixOf ":" str then parsePositive (rest1 str) else Nothing

-- drop "userinfo@" (up to and including the last '@')
dropUserinfo : String -> String
dropUserinfo s = case reverse (forget (split (== '@') s)) of
                   (h :: _) => h
                   []       => s

parseAuthority : String -> (Maybe String, Maybe Int)
parseAuthority auth =
  let hp = dropUserinfo auth in
  if isPrefixOf "[" hp
    then let (h, rest) = break (== ']') hp
         in if rest == ""
              then (nonEmpty hp, Nothing)
              else (Just (h ++ "]"), portOf (rest1 rest))
    else let (h, rest) = break (== ':') hp
         in (nonEmpty h, portOf rest)

||| Best-effort split into components. Always succeeds. Not a validator.
||| Expects `scheme://[userinfo@]host[:port]/path?query#fragment`, but
||| also handles a scheme-relative `//host/path`, a bare `/path?q#f`,
||| and an IPv6 host literal `[::1]:port`. `userinfo` is discarded.
export
parse : String -> URL
parse input =
  let (beforeFrag, mFrag)   = breakOn '#' input
      (beforeQ, mQ)         = breakOn '?' beforeFrag
      (mScheme, afterScheme) = splitScheme beforeQ
      (mAuth, path)         = splitAuthority afterScheme
      (host, port)          = maybe (Nothing, Nothing) parseAuthority mAuth
  in MkURL (toLower <$> mScheme) host port path
           (maybe [] parseQuery mQ) (percentDecode <$> mFrag)

||| Reassemble. `query` goes through `buildQuery` and `fragment`
||| through `percentEncode`; `path` is emitted as-is. Not guaranteed
||| byte-identical to the string `parse` was given.
export
render : URL -> String
render u =
  maybe "" (++ ":") u.scheme
  ++ maybe "" (\h => "//" ++ h ++ maybe "" (\p => ":" ++ show p) u.port) u.host
  ++ u.path
  ++ (if null u.query then "" else "?" ++ buildQuery u.query)
  ++ maybe "" (\f => "#" ++ percentEncode f) u.fragment

||| Split a path on `/`, drop empty segments (leading/trailing/doubled
||| slash), and percent-decode each.
export
pathSegments : String -> List String
pathSegments = map percentDecode . filter (/= "") . forget . split (== '/')
