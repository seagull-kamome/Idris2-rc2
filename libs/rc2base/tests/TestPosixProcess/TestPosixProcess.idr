module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Process: getpid, kill (signal 0 to itself, SIGKILL to a
-- child it forked), fork + exit + wait/waitpid, and the wait option
-- constants (compared with a plain C program through the .expected file).
-- Only the test's own children are ever signalled.

import Data.Bits
import System
import System.File
import System.Posix.Process
import System.Posix.Signal

opt : String -> Int32 -> IO ()
opt n v = putStrLn (n ++ "=" ++ show v)

exitCode : ProcessStatus -> Int32
exitCode (MkProcessStatus s) = (s `shiftR` 8) .&. 255

main : IO ()
main = do
  opt "WEXITED" WEXITED
  opt "WSTOPPED" WSTOPPED
  opt "WNOHANG" WNOHANG
  opt "WUNTRACED" WUNTRACED
  opt "WCONTINUED" WCONTINUED
  me <- getpid
  putStrLn ("getpid positive: " ++ show (cast {to=Int32} me > 0))
  kill me (cast {to=Signal} (the Int32 0)) >>= \r => putStrLn ("kill self 0: " ++ show r)
  -- child 1: exits with status 7
  ignore $ fflush stdout
  c1 <- fork
  if (cast {to=Int32} c1) == 0
    then exit 7
    else pure ()
  Just (p1, st1) <- waitpid c1 0
    | Nothing => putStrLn "waitpid failed"
  putStrLn ("child 1 pid matches: " ++ show (cast {to=Int32} p1 == cast c1))
  putStrLn ("child 1 exit status: " ++ show (exitCode st1))
  -- child 2: killed by SIGKILL while sleeping
  ignore $ fflush stdout
  c2 <- fork
  if (cast {to=Int32} c2) == 0
    then sleep 30 >> exit 0
    else pure ()
  kill c2 SIGKILL >>= \r => putStrLn ("kill child: " ++ show r)
  Just (p2, MkProcessStatus st2) <- wait
    | Nothing => putStrLn "wait failed"
  putStrLn ("child 2 pid matches: " ++ show (cast {to=Int32} p2 == cast c2))
  putStrLn ("child 2 terminating signal: " ++ show (st2 .&. 127))
  -- no children left: WNOHANG on any child returns -1 (ECHILD)
  Just (p3, _) <- waitpid (cast {to=ProcessID} (the Int32 (-1))) WNOHANG
    | Nothing => putStrLn "waitpid failed"
  putStrLn ("no children: " ++ show (cast {to=Int32} p3))
