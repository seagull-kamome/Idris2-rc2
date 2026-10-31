module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Server timeouts (idle 300 ms, request 400 ms, write 400 ms):
--   * a connection that sends nothing is closed;
--   * a request that stops half way is answered with 408 and closed;
--   * a request that trickles in a byte at a time is answered with 408 although
--     no single wait is long: the time of a request is one deadline;
--   * a kept-alive connection that goes idle is closed after its answer;
--   * a response to a client that does not read is given up (the client gets
--     only part of it);
--   * and the server still serves an ordinary request;
--   * with at most one connection served at once, a second one is answered with
--     503 and closed, and once the first has gone the next is served.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.List
import Data.Maybe
import Data.String
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data

import System
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Poll

-- Network.Address has the same names; the ones of `network` are the clients'.
%hide System.Posix.Socket.Port.Port
%hide Network.Address.SocketAddress

%default covering

limits : Limits
limits = { idleTimeoutMs := 300, requestTimeoutMs := 400, writeTimeoutMs := 400 } defaultLimits

bigSize : Int
bigSize = 67108864

handler : Handler
handler req = case req.path of
  "/hello" => liftIO (ok "hello\n")
  "/big" => liftIO (bytes 200 "application/octet-stream" <$> newBuf bigSize)
  _ => liftIO (notFound "no\n")

-- Connect, run the client on the socket, close.
withClient : Port -> (Socket -> IO a) -> IO (Maybe a)
withClient port client = do
  Right sock <- socket AF_INET Stream 0
    | Left _ => pure Nothing
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | _ => close sock *> pure Nothing
  r <- client sock
  close sock
  pure (Just r)

-- Everything the server sends until it closes the connection: the text of the
-- first 4096 bytes, and how many bytes there were.
drain : Socket -> IO (String, Nat)
drain sock = go "" 0
  where
    go : String -> Nat -> IO (String, Nat)
    go acc seen = do
      r <- Network.Socket.recv sock 65536
      case r of
        Right (s, n) => if n > 0 then go (if seen < 4096 then acc ++ s else acc) (seen + cast n) else pure (acc, seen)
        Left _ => pure (acc, seen)

firstLine : String -> String
firstLine = pack . takeWhile (/= '\r') . unpack

-- Nothing sent: the server closes the connection.
idle : Port -> IO String
idle port = map (maybe "no client" (\r => "closed, " ++ show (snd r) ++ " bytes")) (withClient port drain)

-- A head that stops half way.
stalled : Port -> IO String
stalled port = map (maybe "no client" (firstLine . fst)) $ withClient port $ \sock => do
  _ <- Network.Socket.send sock "GET /hello HTTP/1.1\r\nHos"
  drain sock

-- A valid request, a byte at a time every 50 ms, until the server speaks.
trickle : Port -> IO String
trickle port = map (maybe "no client" (\r => fst r ++ "; stopped before the end: " ++ show (snd r < 35))) $
  withClient port $ \sock => do
    sent <- go sock (unpack "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n") 0
    (answer, _) <- drain sock
    pure (firstLine answer, sent)
  where
    go : Socket -> List Char -> Nat -> IO Nat
    go _ [] sent = pure sent
    go sock (c :: rest) sent = do
      _ <- Network.Socket.send sock (singleton c)
      case mkFileDesc (cast sock.descriptor) of
        Nothing => pure sent
        Just fd => do
          Right ready <- poll [(fd, POLLIN)] 50
            | Left _ => pure sent
          if any (/= 0) ready then pure (S sent) else go sock rest (S sent)

-- One request, then nothing: the connection is closed after the answer.
keptThenIdle : Port -> IO String
keptThenIdle port = map (maybe "no client" (\r => firstLine (fst r) ++ " then closed")) $ withClient port $ \sock => do
  _ <- Network.Socket.send sock "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n"
  drain sock

-- A big response to a client that does not read for a while.
notReading : Port -> IO String
notReading port = map (maybe "no client" (\r => "got part of it: " ++ show (cast (snd r) < bigSize))) $ withClient port $ \sock => do
  _ <- Network.Socket.send sock "GET /big HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
  usleep 1500000
  drain sock

ordinary : Port -> IO String
ordinary port = map (maybe "no client" (firstLine . fst)) $ withClient port $ \sock => do
  _ <- Network.Socket.send sock "GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
  drain sock

-- A connection that is held (nothing sent), and a second one while it is: the
-- first line of the answer to the second.
overLimit : Port -> IO String
overLimit port = map (fromMaybe "no client") $ withClient port $ \held => do
    usleep 100000   -- (the server has taken the first)
    map (maybe "no client" (firstLine . fst)) $ withClient port $ \sock => do
      _ <- Network.Socket.send sock "GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
      drain sock

main : IO ()
main = do
  r2 <- runTaskWith 3 (race (serve {limits = { maxConnections := 1 } limits} 18762 handler) (do
          a <- blocking (overLimit 18762)
          blocking (usleep 200000)   -- (the server has seen the first one go)
          b <- blocking (ordinary 18762)
          pure [ "over the limit: " ++ a, "after the first has gone: " ++ b ]))
  case r2 of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn "server ended"
    Nothing => putStrLn "no result"
  r <- runTaskWith 3 (race (serve {limits} 18761 handler) (do
         a <- blocking (idle 18761)
         b <- blocking (stalled 18761)
         c <- blocking (trickle 18761)
         d <- blocking (keptThenIdle 18761)
         e <- blocking (notReading 18761)
         f <- blocking (ordinary 18761)
         pure [ "idle: " ++ a, "stalled: " ++ b, "trickle: " ++ c, "kept then idle: " ++ d
              , "not reading: " ++ e, "afterwards: " ++ f ]))
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn "server ended"
    Nothing => putStrLn "no result"
