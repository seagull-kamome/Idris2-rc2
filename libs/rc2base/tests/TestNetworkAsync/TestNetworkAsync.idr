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

-- Network.Address has the same names; the ones of `network` are the clients'.
%hide System.Posix.Socket.Port.Port
%hide Network.Address.SocketAddress

%default covering

port : Port
port = 18731

-- A plain blocking client socket connected to the server.
connectClient : IO (Maybe Socket)
connectClient = do
  Right sock <- socket AF_INET Stream 0
    | Left _ => pure Nothing
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | _ => Network.Socket.close sock *> pure Nothing
  pure (Just sock)

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
  Right listener <- listen (cast port)
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
  Right listener <- listen (cast port)
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         _ <- race (withSock listener (accept listener)) (sleepFor 50)
         blocking (talk "late"))
  putStrLn ("after give-up: " ++ show r)

-- Whether the server has closed the connection `sock` (`Network.Socket.recv`
-- reports the end of the stream as `Left 0`, no error code).
peerClosed : Maybe Socket -> IO String
peerClosed Nothing = pure "no client"
peerClosed (Just sock) = do
  r <- Network.Socket.recv sock 16
  Network.Socket.close sock
  pure (case r of
          Left 0 => "closed by the server"
          Left e => "recv " ++ show e
          Right _ => "data")

-- A connection is accepted in the step that makes the accept lose the race: the
-- socket is closed (the client sees the end of the stream), not leaked.
droppedAcceptTest : IO ()
droppedAcceptTest = do
  Right listener <- listen (cast port)
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

-- Ranges that would reach outside the buffer, or no bytes at all, are refused
-- before any system call.
boundsTest : IO ()
boundsTest = do
  Right listener <- listen (cast port)
    | Left e => putStrLn ("listen " ++ show e)
  Just buf <- newBuffer 8
    | Nothing => putStrLn "newBuffer"
  r <- runTaskWith 2 (do
         client <- liftIO connectClient
         Right conn <- accept listener
           | Left e => pure ["accept " ++ show e]
         rs <- traverse (\(off, len) => Network.Async.recv conn buf off len)
                 [(0, 9), (4, 5), (-1, 4), (0, 0), (0, -3), (9223372036854775800, 16)]
         ss <- traverse (\(off, len) => Network.Async.send conn buf off len) [(0, 9), (0, 0), (-1, 1)]
         liftIO (close conn)
         liftIO (close listener)
         liftIO (traverse_ Network.Socket.close client)
         pure (map show rs ++ map show ss))
  putStrLn ("bounds: " ++ show r)

-- The client is a task too: `connect`, `sendAll`, `recv`. A port nobody listens
-- on is refused, and a host name is not looked up.
connectTest : IO ()
connectTest = do
  Right listener <- listen (cast port)
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (serveOne listener)
         answer <- client
         served <- wait server
         pure (served, answer))
  close listener
  putStrLn ("connect: " ++ show r)
  refused <- runTaskWith 2 (Network.Async.connect (IPv4Addr 127 0 0 1) (cast port))
  putStrLn ("refused: " ++ show (map (either show (const "connected")) refused))
  named <- runTaskWith 2 (Network.Async.connect (Hostname "localhost") (cast port))
  putStrLn ("host name: " ++ show (map (either show (const "connected")) named))
  where
    client : Task String
    client = do
      Right sock <- Network.Async.connect (IPv4Addr 127 0 0 1) (cast port)
        | Left e => pure ("connect " ++ show e)
      withSock sock $ do
        Just out <- liftIO (newBuffer 4)
          | Nothing => pure "newBuffer"
        liftIO (setString out 0 "ping")
        Right () <- sendAll sock out 0 4
          | Left e => pure ("send " ++ show e)
        Just buf <- liftIO (newBuffer 64)
          | Nothing => pure "newBuffer"
        Right n <- recv sock buf 0 64
          | Left e => pure ("recv " ++ show e)
        liftIO (getString buf 0 n)

-- `recvUntil` and `sendAllUntil` give the answer at once when the call does not
-- block, and `Nothing` when nothing arrives before the time.
deadlineTest : IO ()
deadlineTest = do
  Right listener <- listen (cast port)
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (accept listener)
         Right c <- Network.Async.connect (IPv4Addr 127 0 0 1) (cast port)
           | Left e => pure ["connect " ++ show e]
         Right s <- wait server
           | Left e => pure ["accept " ++ show e]
         Just out <- liftIO (newBuffer 2)
           | Nothing => pure ["newBuffer"]
         liftIO (setString out 0 "hi")
         t0 <- now
         sent <- sendAllUntil (t0 + 5000) c out 0 2
         Just buf <- liftIO (newBuffer 16)
           | Nothing => pure ["newBuffer"]
         got <- recvUntil (t0 + 5000) s buf 0 16
         t1 <- now
         none <- recvUntil (t1 + 100) s buf 0 16
         -- the call blocks, the data arrives in time and the timeout is withdrawn
         _ <- fork (sleepFor 20 *> sendAll c out 0 2)
         t2 <- now
         late <- recvUntil (t2 + 5000) s buf 0 16
         -- a later timer must still fire on time after the withdrawn one
         t3 <- now
         sleepFor 30
         t4 <- now
         liftIO (close c *> close s)
         pure [show sent, show got, show none, show late, show (the Bool (minus t4 t3 < 2000))])
  close listener
  putStrLn ("deadline: " ++ show r)

main : IO ()
main = echoTest *> giveUpTest *> droppedAcceptTest *> boundsTest *> connectTest *> deadlineTest
