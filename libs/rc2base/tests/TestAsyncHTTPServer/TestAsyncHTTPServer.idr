module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Server: a plain blocking client on the pool talks to the
-- server running as tasks. Three servers, one after the other:
--   * limits 1024 / 4096: a quick answer, a request body, a route with a
--     capture, keep-alive, two handlers that wait on a timer (they overlap), a
--     head that ends in a later segment, a head of exactly the limit, two
--     requests in one segment, HEAD and 204, what a request and a handler say
--     about `Connection`, and the requests that are refused: a head over the limit
--     (431), a body over the limit (413), heads and framing headers that cannot be
--     trusted (400);
--   * limits 65536 / 2048 (the head limit above the request limit): still answered;
--   * default limits: a body of 70000 bytes, more than one read.

import Control.Task
import Control.Task.Scheduler
import Data.List
import Data.String
import Network.Async.HTTP.Router
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.HTTP.Router
import Network.Socket
import Network.Socket.Data
import System
import System.Posix.Errno

%default covering

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
  , get ("none" // end) (liftIO (noBody 204))
  , get ("bye" // end) (liftIO (ok {headers = [("Connection", "close")]} "bye\n"))
  , get ("stay" // end) (liftIO (ok {headers = [("Connection", "keep-alive")]} "stay\n"))
  ]

handler : Handler
handler = Network.Async.HTTP.Router.router plain routes

-- Connect to the server, send the pieces one after the other (with a pause
-- between them, so that the server reads them separately) and read an answer
-- after each but the last; the last is read to the end of the connection.
session : Port -> (pause : Bool) -> List String -> IO (List String)
session port pause pieces = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ["socket " ++ show e]
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | e => close sock *> pure ["connect " ++ show e]
  answers <- go sock pieces
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
    go sock (piece :: rest) = do
      Right _ <- Network.Socket.send sock piece
        | Left e => pure ["send " ++ show e]
      when pause (usleep 100000)
      answer <- if null rest then drain sock ""
                else if pause then pure ""
                else either (const "recv failed") fst <$> Network.Socket.recv sock 4096
      (answer ::) <$> go sock rest

-- One session on `port`: each piece is answered before the next is sent.
exchange : Port -> List String -> Task (List String)
exchange port = blocking . session port False

-- One session on `port`: the pieces are sent with a pause between them and the
-- answer is read at the end.
pieces : Port -> List String -> Task String
pieces port = map concat . blocking . session port True

getReq : String -> (closing : Bool) -> String
getReq path closing =
  "GET " ++ path ++ " HTTP/1.1\r\nHost: t\r\n" ++ (if closing then "Connection: close\r\n" else "") ++ "\r\n"

postReq : String -> String -> String
postReq path body =
  "POST " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: "
    ++ show (length body) ++ "\r\n\r\n" ++ body

headReq : String -> String
headReq path = "HEAD " ++ path ++ " HTTP/1.1\r\nHost: t\r\n\r\n"

-- A request whose headers do not frame the body: the server refuses it and
-- closes, instead of taking its body for the next request.
badFraming : String -> String
badFraming header =
  "POST /echo HTTP/1.1\r\nHost: t\r\n" ++ header ++ "\r\n\r\nGET /hello HTTP/1.1\r\n\r\n"

-- `n` bytes that make a request line and headers without ending them.
unfinishedHead : (n : Nat) -> String
unfinishedHead n = pack (take n (unpack "GET / HTTP/1.1\r\nX: " ++ replicate (n + 100) 'a'))

-- A head of exactly `n` bytes, the terminator included.
headOfSize : (n : Nat) -> String
headOfSize n =
  let start = "GET /hello HTTP/1.1\r\nConnection: close\r\nX: "
  in start ++ pack (replicate (minus n (length start + 4)) 'a') ++ "\r\n\r\n"

-- The body of an answer.
bodyOf : String -> String
bodyOf = pack . go . unpack
  where
    go : List Char -> List Char
    go ('\r' :: '\n' :: '\r' :: '\n' :: rest) = rest
    go (_ :: rest) = go rest
    go [] = []

-- Run the server, and the clients until they are done; the server is given up.
scenario : Port -> Limits -> Task (List String) -> IO ()
scenario port limits clients = do
  r <- runTaskWith 3 (race (serve {limits} port handler) clients)
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn ("server ended: " ++ show stopped)
    Nothing => putStrLn "no result"

-- The body announced over the request limit (4096) is not read: only the head is sent.
bigAnnounced : String
bigAnnounced = "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 5000\r\n\r\n"

-- The first server: limits 1024 / 4096.
smallLimits : Port -> Task (List String)
smallLimits port = do
  let ask = exchange port
  one <- ask [getReq "/hello" True]
  body <- ask [postReq "/echo" "payload"]
  alive <- ask [getReq "/hello" False, getReq "/nowhere" True]
  user <- ask [getReq "/users/7" True]
  headed <- ask [headReq "/echo", getReq "/hello" True]
  noContent <- ask [getReq "/none" True]
  piped <- ask [getReq "/hello" False ++ getReq "/users/3" True]
  split <- pieces port ["GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r", "\n"]
  exact <- ask [headOfSize 1024]
  -- what the request and the handler say about `Connection`
  tokens <- ask ["GET /hello HTTP/1.1\r\nHost: t\r\nConnection: keep-alive, close\r\n\r\n"]
  handlerCloses <- ask [getReq "/bye" False]
  handlerStays <- ask [getReq "/stay" True]
  -- refused
  refusedLimits <- traverse (\r => ask [r]) [unfinishedHead 1024, bigAnnounced, "GARBAGE\r\n\r\n"]
  refusedHeads <- traverse (\h => ask ["GET /hello HTTP/1.1\r\nHost: t\r\n" ++ h ++ "\r\n\r\n"])
                    [ "Content-Length : 0"   -- space before the colon
                    , " folded: line"        -- an obsolete line fold
                    , "NoColon"
                    ]
  refusedFraming <- traverse (\h => ask [badFraming h])
                      [ "Content-Length: 18446744073709551619", "Content-Length: abc"
                      , "Content-Length: 5\r\nContent-Length: 6", "Transfer-Encoding: chunked" ]
  (slowA, slowB) <- both (ask [getReq "/slow" True]) (ask [getReq "/slow" True])
  pure (map show ([one, body, alive, user, headed, noContent, piped, [split], exact, tokens, handlerCloses, handlerStays]
                  ++ refusedLimits ++ refusedHeads ++ refusedFraming ++ [slowA, slowB]))

-- The second server: the head limit (65536) is above the request limit (2048).
headAboveRequest : Port -> Task (List String)
headAboveRequest port = do
  fine <- exchange port [getReq "/hello" True]
  big <- exchange port [unfinishedHead 2048]
  pure (map show [fine, big])

-- The third server: a body of 70000 bytes.
bigBody : Port -> Task (List String)
bigBody port = do
  let sent = pack (replicate 70000 'x')
  answers <- exchange port [postReq "/echo" sent]
  pure [show (map (\a => bodyOf a == "POST " ++ sent ++ "\n") answers)]

main : IO ()
main = do
  scenario 18741 ({ maxHeadBytes := 1024, maxRequestBytes := 4096 } defaultLimits) (smallLimits 18741)
  scenario 18742 ({ maxRequestBytes := 2048 } defaultLimits) (headAboveRequest 18742)
  scenario 18743 defaultLimits (bigBody 18743)
