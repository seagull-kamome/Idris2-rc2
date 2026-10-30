||| An Express-style route table on top of `Network.HTTP.Route`'s
||| type-safe path patterns. `router` turns a `List RouteEntry` into
||| a plain `Network.HTTP.Server.Handler`, so it plugs straight into
||| `serve`. See `libs/web/doc/http-router.md`.
module Network.HTTP.Router

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Network.HTTP.Route
import Network.HTTP.Server

public export
data Method = GET | POST | PUT | DELETE | PATCH | OPTIONS | HEAD

export
Eq Method where
  GET     == GET     = True
  POST    == POST    = True
  PUT     == PUT     = True
  DELETE  == DELETE  = True
  PATCH   == PATCH   = True
  OPTIONS == OPTIONS = True
  HEAD    == HEAD    = True
  _       == _       = False

methodFromString : String -> Maybe Method
methodFromString "GET"     = Just GET
methodFromString "POST"    = Just POST
methodFromString "PUT"     = Just PUT
methodFromString "DELETE"  = Just DELETE
methodFromString "PATCH"   = Just PATCH
methodFromString "OPTIONS" = Just OPTIONS
methodFromString "HEAD"    = Just HEAD
methodFromString _         = Nothing

||| One registered route: a method, a path pattern, and the handler that
||| pattern's captures require, giving an `r`. `tys` (the pattern's own capture
||| types) is erased here so routes of different shapes can share one
||| `List (RouteEntryOf r)`.
public export
record RouteEntryOf (r : Type) where
  constructor MkRouteEntry
  method  : Method
  {0 tys  : List Type}
  route   : Route tys
  handler : HandlerOf r tys

||| A route of `Network.HTTP.Server`'s `respond`-continuation handlers.
public export
RouteEntry : Type
RouteEntry = RouteEntryOf ((Response -> IO ()) -> IO ())

export
get, post, put, delete, patch, head, options : Route ts -> HandlerOf r ts -> RouteEntryOf r
get     = MkRouteEntry GET
post    = MkRouteEntry POST
put     = MkRouteEntry PUT
delete  = MkRouteEntry DELETE
patch   = MkRouteEntry PATCH
head    = MkRouteEntry HEAD
options = MkRouteEntry OPTIONS

tryMatch : Method -> List String -> RouteEntryOf r -> Maybe r
tryMatch m segs entry =
  if m == entry.method then matchRoute entry.route segs entry.handler else Nothing

firstJust : (a -> Maybe b) -> List a -> Maybe b
firstJust f []        = Nothing
firstJust f (x :: xs) = case f x of
  Just y  => Just y
  Nothing => firstJust f xs

||| What the first entry whose method and path both match gives; `Nothing` when
||| none does, and also when the method string is not one `Method` recognizes.
export
lookupRoute : List (RouteEntryOf r) -> (method, path : String) -> Maybe r
lookupRoute entries method path = do
  m <- methodFromString method
  firstJust (tryMatch m (splitPath (pathOnly path))) entries

||| Builds a `Handler` that tries each `RouteEntry` in order,
||| dispatching to the first whose method and path both match; falls
||| back to `notFound` (e.g. a plain 404 responder) otherwise, and also
||| when the request's method string isn't one `Method` recognizes.
export
router : (notFound : Handler) -> List RouteEntry -> Handler
router notFound entries req respond =
  case lookupRoute entries req.method req.path of
    Nothing => notFound req respond
    Just f  => f respond
