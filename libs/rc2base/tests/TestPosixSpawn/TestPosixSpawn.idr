module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.Posix.Spawn.spawnStdio: the child's stdin and
-- stdout come out right when the caller's descriptors for them are 0 or 1
-- (a process that has closed its own standard input, as a daemon does, gets
-- those numbers from `pipe`). `dup2 stdin 0` used to overwrite a `stdout`
-- that was 0.

import Data.Buffer
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Process
import System.Posix.Spawn

-- Everything the descriptor gives until the end of the file.
slurp : FileDesc -> IO String
slurp fd = do
  Just buf <- newBuffer 256
    | Nothing => pure "newBuffer failed"
  n <- read fd buf
  if n <= 0 then pure "" else do
    s <- getString buf 0 (cast n)
    rest <- slurp fd
    pure (s ++ rest)

-- Run `sh -c script` with the given stdin/stdout, feed it a line, and give what it wrote.
run : (stdin, stdout : FileDesc) -> (feed : FileDesc) -> (collect : FileDesc) -> String -> IO String
run stdin stdout feed collect script = do
  Right pid <- spawnStdio "/bin/sh" "/" ["sh", "-c", script] [] stdin stdout
    | Left e => pure ("spawn failed: " ++ show e)
  -- the child has its ends; the end of the file needs ours closed
  _ <- close stdout
  _ <- write feed "hello\n"
  _ <- close feed
  out <- slurp collect
  _ <- waitpid pid 0
  pure out

main : IO ()
main = do
  Just fd0 <- pure (mkFileDesc 0)
    | Nothing => putStrLn "no fd 0"
  Just fd1 <- pure (mkFileDesc 1)
    | Nothing => putStrLn "no fd 1"

  -- the plain case: descriptors above 2
  Right (inR, inW) <- pipe
    | Left e => putStrLn ("pipe: " ++ show e)
  Right (outR, outW) <- pipe
    | Left e => putStrLn ("pipe: " ++ show e)
  out <- run inR outW inW outR "read x; echo got:$x"
  putStrLn ("plain: " ++ show out)

  -- stdout is descriptor 0: close our standard input and put the pipe there
  Right (inR, inW) <- pipe
    | Left e => putStrLn ("pipe: " ++ show e)
  Right (outR, outW) <- pipe
    | Left e => putStrLn ("pipe: " ++ show e)
  _ <- close fd0
  Right w0 <- dup2 outW fd0
    | Left e => putStrLn ("dup2: " ++ show e)
  _ <- close outW
  -- `run` waits for the end of the file: our write ends must be closed first
  Right pid <- spawnStdio "/bin/sh" "/" ["sh", "-c", "read x; echo got:$x"] [] inR w0
    | Left e => putStrLn ("spawn failed: " ++ show e)
  _ <- close w0
  _ <- write inW "hello\n"
  _ <- close inW
  out0 <- slurp outR
  _ <- waitpid pid 0
  putStrLn ("stdout is 0: " ++ show out0)
