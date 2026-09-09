||| Type-safe path patterns for `Network.HTTP.Router`.
||| A `Route tys` describes both a URL shape (fixed segments, named
||| captures, an optional trailing wildcard) and, via `tys`, the list
||| of types its captures produce -- `HandlerFor tys` then reads off
||| exactly the handler signature that shape requires. See
||| `libs/rc2base/doc/http-router.md` for the design and examples.
module Network.HTTP.Route

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.List
import Data.List1
import Data.String

import Network.HTTP.Server

-------------------------------------------------------------------------------
-- Path segment splitting
-------------------------------------------------------------------------------

||| Splits a path into its non-empty `/`-separated segments
||| (`"/users/1"` and `"users/1/"` both give `["users", "1"]`).
||| `Data.String.split` unpacks once and walks the resulting `List
||| Char` in a single pass (`Data.List.split`'s own `break`-then-
||| recurse-on-the-remainder shape) -- no repeated `strSubstr`/`break`
||| rescans of the same text, just the one `pack` per segment that's
||| unavoidable once each is held as its own `String`.
export
splitPath : String -> List String
splitPath path = filter (/= "") (forget (split (== '/') path))

||| Drops a trailing `?...` query string before `splitPath` sees the
||| path -- `Network.HTTP.Server`'s own `Request.path` passes the query
||| string through verbatim (see its doc comment).
export
pathOnly : String -> String
pathOnly = fst . break (== '?')

-------------------------------------------------------------------------------
-- Capturing a segment as a value
-------------------------------------------------------------------------------

||| Converts one path segment's raw text into a captured value.
||| `Nothing` fails the match for that route (falling through to the
||| next one registered, or to the router's 404) rather than crashing.
public export
interface FromSegment ty where
  fromSegment : String -> Maybe ty

export
FromSegment String where
  fromSegment = Just

export
FromSegment Int where
  fromSegment = parseInteger

export
FromSegment Integer where
  fromSegment = parseInteger

-------------------------------------------------------------------------------
-- Route: a path pattern indexed by the types its captures produce
-------------------------------------------------------------------------------

||| A path pattern. `tys` lists the types of `Capture`d segments left
||| to right; `Splat` (only ever the last segment, since it takes no
||| further `Route` to continue into) captures every remaining segment
||| as one `/`-joined `String`.
public export
data Route : List Type -> Type where
  End     : Route []
  Fixed   : String -> Route tys -> Route tys
  Capture : (name : String) -> (ty : Type) -> FromSegment ty => Route tys -> Route (ty :: tys)
  Splat   : Route [String]

export infixr 5 //

||| Matches a literal segment, then continues into the rest of the
||| route. `infixr` so `"a" // "b" // end` reads left to right without
||| parens.
export
(//) : String -> Route tys -> Route tys
(//) = Fixed

||| Captures one segment as `ty`, then continues into the rest of the
||| route.
export
capture : (name : String) -> (ty : Type) -> FromSegment ty => Route tys -> Route (ty :: tys)
capture = Capture

export
end : Route []
end = End

||| Captures every remaining segment as one `/`-joined `String`. Must
||| be the last thing in a route -- there's no `Route`-continuation
||| argument to put anything after it, so this is enforced by
||| `Route`'s own shape, not a separate check.
export
splat : Route [String]
splat = Splat

-------------------------------------------------------------------------------
-- HandlerFor: the handler signature a Route of a given shape expects
-------------------------------------------------------------------------------

||| The type of a handler matching a route whose captures are `tys`,
||| left to right -- one extra leading argument per captured type,
||| ending in `Network.HTTP.Server`'s own `respond`-continuation shape.
public export
HandlerFor : List Type -> Type
HandlerFor []         = (Response -> IO ()) -> IO ()
HandlerFor (ty :: tys) = ty -> HandlerFor tys

-------------------------------------------------------------------------------
-- Matching
-------------------------------------------------------------------------------

||| Matches `route` against already-split path segments, applying
||| `handler` to each captured value as it goes. `Nothing` on a length
||| or literal-segment mismatch, or a `FromSegment` parse failure.
export
matchRoute : Route tys -> List String -> HandlerFor tys -> Maybe ((Response -> IO ()) -> IO ())
matchRoute End         []           h = Just h
matchRoute End         (_ :: _)     h = Nothing
matchRoute (Fixed s r) (seg :: segs) h = if s == seg then matchRoute r segs h else Nothing
matchRoute (Fixed _ _) []           h = Nothing
matchRoute (Capture _ ty r) (seg :: segs) h =
  case fromSegment {ty} seg of
    Nothing => Nothing
    Just v  => matchRoute r segs (h v)
matchRoute (Capture _ _ _) [] h = Nothing
matchRoute Splat segs h = Just (h (joinBy "/" segs))
