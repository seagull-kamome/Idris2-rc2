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

-- A connection is accepted in the step that makes the accept lose the race: the
-- socket is closed (the client sees the end of the stream), not leaked.
droppedAcceptTest : IO ()
droppedAcceptTest = do
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         client <- liftIO connectClient
         -- the right side wins in the step that starts it; the accepted connection
         -- is still on its way to the left side
         _ <- race (accept listener) (spawn (pure ()))
         ended <- race (blocking (peerClosed client)) (sleepFor 500)
         liftIO (close listener)
         pure ended)
  putStrLn ("dropped accept: " ++ show (map (either id (const "still open")) r))
  where
    connectClient : IO (Maybe Socket)
    connectClient = do
      Right sock <- socket AF_INET Stream 0
        | Left _ => pure Nothing
      0 <- connect sock (IPv4Addr 127 0 0 1) port
        | _ => close sock *> pure Nothing
      pure (Just sock)

    peerClosed : Maybe Socket -> IO String
    peerClosed Nothing = pure "no client"
    peerClosed (Just sock) = do
      r <- Network.Socket.recv sock 16
      Network.Socket.close sock
      pure (case r of
              Right (_, 0) => "closed by the server (0 bytes)"
              Right _ => "data"
              Left 0 => "closed by the server"
              Left e => "recv " ++ show e)

main : IO ()
main = echoTest *> giveUpTest *> droppedAcceptTest
