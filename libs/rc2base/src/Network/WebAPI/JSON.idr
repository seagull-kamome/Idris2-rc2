module Network.WebAPI.JSON

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Language.JSON plus what the web API modules share: an encoder and
-- field accessors.

import Data.String

import public Language.JSON

%default total

quote : String -> String
quote s = "\"" ++ concatMap esc (unpack s) ++ "\""
  where
    hex4 : Int -> String
    hex4 n = pack (map digit [n `div` 4096, (n `div` 256) `mod` 16, (n `div` 16) `mod` 16, n `mod` 16])
      where
        digit : Int -> Char
        digit d = if d < 10 then chr (ord '0' + d) else chr (ord 'a' + d - 10)

    esc : Char -> String
    esc '"'  = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc c    = if ord c < 0x20 then "\\u" ++ hex4 (ord c) else singleton c

||| Unlike `Language.JSON`'s `show`, an integral number has no `.0`:
||| APIs reject `1024.0` for an integer field such as `max_tokens`.
export
render : JSON -> String
render JNull         = "null"
render (JBoolean b)  = if b then "true" else "false"
render (JNumber d)   = let i = the Integer (cast d) in
                       if cast i == d then show i else show d
render (JString s)   = quote s
render (JArray xs)   = "[" ++ joinBy "," (assert_total (map render xs)) ++ "]"
render (JObject kvs) = "{" ++ joinBy "," (assert_total (map (\(k, v) => quote k ++ ":" ++ render v) kvs)) ++ "}"

export
str : JSON -> Maybe String
str (JString s) = Just s
str _           = Nothing

export
num : JSON -> Maybe Double
num (JNumber d) = Just d
num _           = Nothing

export
arr : JSON -> Maybe (List JSON)
arr (JArray xs) = Just xs
arr _           = Nothing

||| `path` of object keys, e.g. `at ["error", "message"]`.
export
at : List String -> JSON -> Maybe JSON
at []        j = Just j
at (k :: ks) j = lookup k j >>= at ks
