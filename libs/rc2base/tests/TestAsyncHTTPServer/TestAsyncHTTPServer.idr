module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Server: a plain blocking client on the pool talks to the
-- server running as tasks. Covers a quick answer, a handler that waits on a
-- timer (two such requests overlap), a request body, two requests on one
-- keep-alive connection, `Connection: close`, and ending the server by a race.

import Control.Task
import Control.Task.Scheduler
import Data.IORef
import Data.List
import Data.String
import Network.Async.HTTP.Router
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.HTTP.Router
import Network.Socket
import Network.Socket.Data
import System.Posix.Errno

%default covering

port : Port
port = 18741

-- What the routes do not take: the body is not part of a route's handler.
plain : Handler
plain req = case req.path of
  "/echo" => do
    body <- liftIO (toString req.body)
    liftIO (ok (req.method ++ " " ++ body ++ "\n"))
  _ => liftIO (notFound "no\n")

routes : List Network.Async.HTTP.Router.RouteEntry
routes =
  [ get ("hello" // end) (liftIO (ok "hello\n"))
  , get ("slow" // end) (sleepFor 100 *> liftIO (ok "slow\n"))
  , get ("users" // capture "id" Int end) (\n => liftIO (ok ("user " ++ show n ++ "\n")))
  ]

handler : Handler
handler = Network.Async.HTTP.Router.router plain routes

-- Connect, send each request in turn and read an answer after each; the last
-- one is read to the end of the connection.
session : List String -> IO (List String)
session reqs = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ["socket " ++ show e]
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | e => close sock *> pure ["connect " ++ show e]
  answers <- go sock reqs
  close sock
  pure answers
  where
    drain : Socket -> String -> IO String
    drain sock acc = do
      r <- Network.Socket.recv sock 4096
      case r of
        Right (s, n) => if n > 0 then drain sock (acc ++ s) else pure acc
        Left _ => pure acc
    go : Socket -> List String -> IO (List String)
    go sock [] = pure []
    go sock (req :: rest) = do
      Right _ <- Network.Socket.send sock req
        | Left e => pure ["send " ++ show e]
      answer <- if null rest then drain sock ""
                else either (const "recv failed") fst <$> Network.Socket.recv sock 4096
      (answer ::) <$> go sock rest

getReq : String -> (closing : Bool) -> String
getReq path closing =
  "GET " ++ path ++ " HTTP/1.1\r\nHost: t\r\n" ++ (if closing then "Connection: close\r\n" else "") ++ "\r\n"

postReq : String -> String -> String
postReq path body =
  "POST " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: "
    ++ show (length body) ++ "\r\n\r\n" ++ body

-- A request whose headers do not frame the body: the server refuses it and
-- closes, instead of taking its body for the next request.
badFraming : String -> String
badFraming header =
  "POST /echo HTTP/1.1\r\nHost: t\r\n" ++ header ++ "\r\n\r\nGET /hello HTTP/1.1\r\n\r\n"

-- The sessions, run together where it matters.
clients : Task (List (List String))
clients = do
  one <- blocking (session [getReq "/hello" True])
  body <- blocking (session [postReq "/echo" "payload"])
  alive <- blocking (session [getReq "/hello" False, getReq "/nowhere" True])
  user <- blocking (session [getReq "/users/7" True])
  refused <- traverse (\h => blocking (session [badFraming h]))
               ["Content-Length: 18446744073709551619", "Content-Length: abc", "Content-Length: 5\r\nContent-Length: 6", "Transfer-Encoding: chunked"]
  (slowA, slowB) <- both (blocking (session [getReq "/slow" True])) (blocking (session [getReq "/slow" True]))
  pure ([one, body, alive, user] ++ refused ++ [slowA, slowB])

main : IO ()
main = do
  r <- runTaskWith 3 (race (serve port handler) clients)
  case r of
    Just (Right sessions) => traverse_ (putStrLn . show) sessions
    Just (Left stopped) => putStrLn ("server ended: " ++ show stopped)
    Nothing => putStrLn "no result"
