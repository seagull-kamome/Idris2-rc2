module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Signal: every signal constant (a "CExpr:" template over
-- <signal.h>) is printed with `show`; the .expected file holds the values
-- a plain C program prints for the same macros on Linux. Also the
-- Cast Int32 <-> Signal instances.

import System.Posix.Signal

main : IO ()
main = do
  putStrLn ("SIGHUP=" ++ show SIGHUP)
  putStrLn ("SIGINT=" ++ show SIGINT)
  putStrLn ("SIGQUIT=" ++ show SIGQUIT)
  putStrLn ("SIGILL=" ++ show SIGILL)
  putStrLn ("SIGTRAP=" ++ show SIGTRAP)
  putStrLn ("SIGABRT=" ++ show SIGABRT)
  putStrLn ("SIGBUS=" ++ show SIGBUS)
  putStrLn ("SIGFPE=" ++ show SIGFPE)
  putStrLn ("SIGKILL=" ++ show SIGKILL)
  putStrLn ("SIGUSR1=" ++ show SIGUSR1)
  putStrLn ("SIGSEGV=" ++ show SIGSEGV)
  putStrLn ("SIGUSR2=" ++ show SIGUSR2)
  putStrLn ("SIGPIPE=" ++ show SIGPIPE)
  putStrLn ("SIGALRM=" ++ show SIGALRM)
  putStrLn ("SIGTERM=" ++ show SIGTERM)
  putStrLn ("SIGSTKFLT=" ++ show SIGSTKFLT)
  putStrLn ("SIGCHLD=" ++ show SIGCHLD)
  putStrLn ("SIGCONT=" ++ show SIGCONT)
  putStrLn ("SIGSTOP=" ++ show SIGSTOP)
  putStrLn ("SIGTSTP=" ++ show SIGTSTP)
  putStrLn ("SIGTTIN=" ++ show SIGTTIN)
  putStrLn ("SIGTTOU=" ++ show SIGTTOU)
  putStrLn ("SIGURG=" ++ show SIGURG)
  putStrLn ("SIGXCPU=" ++ show SIGXCPU)
  putStrLn ("SIGXFSZ=" ++ show SIGXFSZ)
  putStrLn ("SIGVTALRM=" ++ show SIGVTALRM)
  putStrLn ("SIGPROF=" ++ show SIGPROF)
  putStrLn ("SIGSYS=" ++ show SIGSYS)
  putStrLn ("SIGWINCH=" ++ show SIGWINCH)
  putStrLn ("SIGIO=" ++ show SIGIO)
  printLn (cast {to=Int32} SIGTERM)
  putStrLn (show (cast {to=Signal} (the Int32 10)))
