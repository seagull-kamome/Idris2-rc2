module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async: a task serves one connection (accept, recv, sendAll)
-- while a plain blocking client talks to it on the pool; then a race gives the
-- listener up and `withSock` closes it, so the port refuses connections.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Network.Async
import Network.Socket
import Network.Socket.Data
import System.Posix.Errno

%default covering

port : Port
port = 18731

-- The client side: connect, send `msg`, read the answer.
talk : String -> IO String
talk msg = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("client socket " ++ show e)
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | e => close sock *> pure ("connect refused " ++ show e)
  Right _ <- Network.Socket.send sock msg
    | Left e => close sock *> pure ("client send " ++ show e)
  r <- Network.Socket.recv sock 64
  close sock
  pure (either (\e => "client recv " ++ show e) fst r)

-- Answer one request with "echo:" and what was received.
serveOne : Sock -> Task String
serveOne listener = do
  Right conn <- accept listener
    | Left e => pure ("accept " ++ show e)
  withSock conn $ do
    Just buf <- liftIO (newBuffer 64)
      | Nothing => pure "newBuffer"
    Right n <- recv conn buf 0 64
      | Left e => pure ("recv " ++ show e)
    got <- liftIO (getString buf 0 n)
    let reply = "echo:" ++ got
    let size = cast (length reply)
    Just out <- liftIO (newBuffer size)
      | Nothing => pure "newBuffer"
    liftIO (setString out 0 reply)
    Right () <- sendAll conn out 0 size
      | Left e => pure ("send " ++ show e)
    pure ("served " ++ got)

echoTest : IO ()
echoTest = do
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (serveOne listener)
         answer <- blocking (talk "hello")
         served <- wait server
         pure (served, answer))
  close listener
  putStrLn ("echo: " ++ show r)

-- The listener is only waited on; the timer ends the race and closes it.
giveUpTest : IO ()
giveUpTest = do
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         _ <- race (withSock listener (accept listener)) (sleepFor 50)
         blocking (talk "late"))
  putStrLn ("after give-up: " ++ show r)

main : IO ()
main = echoTest *> giveUpTest
