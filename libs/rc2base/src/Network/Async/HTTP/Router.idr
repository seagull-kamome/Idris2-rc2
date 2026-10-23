||| `Network.HTTP.Router`'s route table for `Network.Async.HTTP.Server`: the
||| handlers of the routes give a `Task Response`, and `router` makes a `Handler`
||| of them. The routes are built with the same `get`, `post`, ... and
||| `Network.HTTP.Route` patterns.
module Network.Async.HTTP.Router

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Maybe
import Network.Async.HTTP.Server
import Network.HTTP.Router

||| A route whose handler gives a `Task Response`.
public export
RouteEntry : Type
RouteEntry = RouteEntryOf (Task Response)

||| A route whose handler is given the `Request` after its captures: `get ("users" //
||| capture "id" Int end) (\n, req => ...)`.
public export
RouteEntryWith : Type
RouteEntryWith = RouteEntryOf (Request -> Task Response)

-- The matching of both routers: the handler of the first route whose method and path
-- match, run on the request; a `HEAD` that no `head` route takes goes to the `get` route
-- for the same path.
dispatch : (r -> Request -> Task Response) -> Handler -> List (RouteEntryOf r) -> Handler
dispatch run notFound entries req =
  maybe (notFound req) (\h => run h req) (lookupRoute entries req.method req.path <|> headAsGet)
  where
    headAsGet : Maybe r
    headAsGet = if req.method == "HEAD" then lookupRoute entries "GET" req.path else Nothing

||| Tries each route in order and runs the handler of the first whose method and
||| path both match; `notFound` answers the others, and also a request whose
||| method string `Method` does not recognize. A `HEAD` request that no `head`
||| route takes goes to the `get` route for the same path (the server leaves the
||| body out). (A program that uses both routers names this one in full:
||| `Network.Async.HTTP.Router.router`.)
export
router : (notFound : Handler) -> List Network.Async.HTTP.Router.RouteEntry -> Handler
router = dispatch (\task, _ => task)

||| `router` for routes whose handlers are given the `Request` (headers, body) as well
||| as the captures of the path.
export
routerWith : (notFound : Handler) -> List RouteEntryWith -> Handler
routerWith = dispatch id
