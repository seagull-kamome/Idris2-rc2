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

||| Tries each route in order and runs the handler of the first whose method and
||| path both match; `notFound` answers the others, and also a request whose
||| method string `Method` does not recognize. A `HEAD` request that no `head`
||| route takes goes to the `get` route for the same path (the server leaves the
||| body out). (A program that uses both routers names this one in full:
||| `Network.Async.HTTP.Router.router`.)
export
router : (notFound : Handler) -> List Network.Async.HTTP.Router.RouteEntry -> Handler
router notFound entries req =
  fromMaybe (notFound req) (lookupRoute entries req.method req.path <|> headAsGet)
  where
    headAsGet : Maybe (Task Response)
    headAsGet = if req.method == "HEAD" then lookupRoute entries "GET" req.path else Nothing
