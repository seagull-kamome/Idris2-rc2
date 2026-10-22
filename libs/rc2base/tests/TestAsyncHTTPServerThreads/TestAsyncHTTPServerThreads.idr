module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The same server run with one thread and with several (runServer): four
-- clients ask for a handler that keeps its thread busy for 60 ms. With one
-- thread the handlers never overlap; with several they do, and every client
-- still gets its answer.

import Control.Concurrent.MVar
import Control.Task
import Control.Task.Scheduler
import Data.String
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data
import System
import System.Posix.Errno

%default covering

-- One request on a new connection; the answer's body.
ask : Port -> IO String
ask port = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("socket " ++ show e)
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | e => close sock *> pure ("connect " ++ show e)
  Right _ <- send sock "GET /work HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"
    | Left e => close sock *> pure ("send " ++ show e)
  answer <- drain sock ""
  close sock
  pure (if isInfixOf "200 OK" answer then "ok" else answer)
  where
    drain : Socket -> String -> IO String
    drain sock acc = do
      r <- recv sock 4096
      case r of
        Right (s, n) => if n > 0 then drain sock (acc ++ s) else pure acc
        Left _ => pure acc

-- Counts the handlers that are busy at the same moment, and the most it saw.
-- The count is changed inside the one action that also keeps the thread busy,
-- so only actions that run on several threads can overlap.
handler : MVar (Nat, Nat) -> Handler
handler busy _ = do
  liftIO (do modifyMVar_ busy (\(n, peak) => pure (S n, max peak (S n)))
             usleep 60000
             modifyMVar_ busy (\(n, peak) => pure (minus n 1, peak)))
  liftIO (ok "done\n")

together : List (Task a) -> Task (List a)
together ts = traverse fork ts >>= traverse wait

-- How the tasks are run: `runTaskWith` keeps their actions on one thread (the
-- extra threads are for `blocking`), `runServer` runs them on several.
Runner : Type
Runner = {a : Type} -> Task a -> IO (Maybe a)

run : (name : String) -> Runner -> Port -> IO ()
run name runner port = do
  r <- runner (do
         busy <- liftIO (newMVar (the Nat 0, the Nat 0))
         -- threads for the blocking clients as well as for the server's actions
         answers <- race (serve port (handler busy))
                         (together (replicate 4 (blocking (ask port))))
         seen <- liftIO (map snd (readMVar busy))
         pure (answers, seen))
  case r of
    Just (Right answers, seen) =>
      putStrLn (name ++ ": answers " ++ show answers
                ++ ", handlers overlapped: " ++ show (seen > 1))
    Just (Left stopped, _) => putStrLn ("server ended: " ++ show stopped)
    Nothing => putStrLn "no result"

main : IO ()
main = run "one thread" (runTaskWith 8) 18751 *> run "eight threads" (runServer 8) 18752
