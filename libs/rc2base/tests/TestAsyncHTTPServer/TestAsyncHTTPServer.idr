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
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data
import System.Posix.Errno

%default covering

port : Port
port = 18741

handler : Handler
handler req = case req.path of
  "/hello" => liftIO (ok "hello\n")
  "/slow" => sleepFor 100 *> liftIO (ok "slow\n")
  "/echo" => do
    body <- liftIO (toString req.body)
    liftIO (ok (req.method ++ " " ++ body ++ "\n"))
  _ => liftIO (notFound "no\n")

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

get : String -> (closing : Bool) -> String
get path closing =
  "GET " ++ path ++ " HTTP/1.1\r\nHost: t\r\n" ++ (if closing then "Connection: close\r\n" else "") ++ "\r\n"

post : String -> String -> String
post path body =
  "POST " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: "
    ++ show (length body) ++ "\r\n\r\n" ++ body

-- The sessions, run together where it matters.
clients : Task (List (List String))
clients = do
  one <- blocking (session [get "/hello" True])
  body <- blocking (session [post "/echo" "payload"])
  alive <- blocking (session [get "/hello" False, get "/nowhere" True])
  (slowA, slowB) <- both (blocking (session [get "/slow" True])) (blocking (session [get "/slow" True]))
  pure [one, body, alive, slowA, slowB]

main : IO ()
main = do
  r <- runTaskWith 3 (race (serve port handler) clients)
  case r of
    Just (Right sessions) => traverse_ (putStrLn . show) sessions
    Just (Left stopped) => putStrLn ("server ended: " ++ show stopped)
    Nothing => putStrLn "no result"
