module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Async.File: a pipe between tasks, two writers whose bytes do not
-- mix, a read that is given up taking nothing, a close that waits for the call
-- running on the handle, and a regular file on a worker thread.

import Control.Task
import Control.Task.Scheduler
import Data.Bits
import Data.Buffer
import Data.List
import Data.String
import System.Posix.Async.File as A
import System.Posix.Errno
import System.Posix.File
import System.Posix.Stdio as C

%default covering

failed : Show e => e -> String
failed e = "error " ++ show e

bufferOf : String -> Task Buffer
bufferOf s = do
  Just b <- liftIO (newBuffer (cast (length s)))
    | Nothing => pure (assert_total (idris_crash "buffer"))
  liftIO (setString b 0 s)
  pure b

pipeTest : Task String
pipeTest = do
  Right (r, w) <- A.pipe
    | Left e => pure (failed e)
  writer <- fork (do b <- bufferOf "hello pipe"
                     _ <- A.writeAll w b 0 10
                     A.close w)
  s <- A.readString r
  _ <- wait writer
  A.close r
  pure (either (const "read failed") id s)

sizeOf : Nat
sizeOf = 100000

mixTest : Task String
mixTest = do
  Right (r, w) <- A.pipe
    | Left e => pure (failed e)
  let run = \c => do b <- bufferOf (pack (replicate sizeOf c))
                     A.writeAll w b 0 (cast sizeOf)
  wa <- fork (run 'a')
  wb <- fork (run 'b')
  reader <- fork (A.readString r)
  _ <- wait wa
  _ <- wait wb
  A.close w
  Right s <- wait reader
    | Left e => pure (failed e)
  A.close r
  let cs = unpack s
      changes = length (filter id (zipWith (/=) cs (drop 1 cs)))
  pure ("length " ++ show (length cs) ++ ", changes " ++ show changes)

giveUpTest : Task String
giveUpTest = do
  Right (r, w) <- A.pipe
    | Left e => pure (failed e)
  Just buf <- liftIO (newBuffer 16)
    | Nothing => pure "no buffer"
  lost <- race (A.read r buf 0 16) (sleepFor 10)
  b <- bufferOf "x"
  _ <- A.writeAll w b 0 1
  Right n <- A.read r buf 0 16
    | Left e => pure (failed e)
  A.close w
  A.close r
  pure (either (const "the read won") (const "the timer won") lost ++ ", then " ++ show n ++ " byte")

closeTest : Task String
closeTest = do
  Right (r, w) <- A.pipe
    | Left e => pure (failed e)
  Just buf <- liftIO (newBuffer 16)
    | Nothing => pure "no buffer"
  reading <- fork (A.read r buf 0 16)
  sleepFor 10
  A.close r
  b <- bufferOf "late"
  _ <- A.writeAll w b 0 4
  got <- wait reading
  after <- A.read r buf 0 16
  A.close w
  pure ("read in progress: " ++ either (const "error") show got ++ ", after close: " ++ either (\e => if e == EBADF then "EBADF" else "other") show after)

path : String
path = "TestPosixAsyncFile.tmp"

fileTest : Task String
fileTest = do
  Right h <- A.openFile path (O_RDWR .|. O_CREAT .|. O_TRUNC) 0o600
    | Left e => pure (failed e)
  b <- bufferOf "0123456789"
  Right () <- A.writeAll h b 0 10
    | Left e => pure (failed e)
  _ <- A.fsync h
  Just buf <- liftIO (newBuffer 4)
    | Nothing => pure "no buffer"
  Right n <- A.readAt h 3 buf 0 4
    | Left e => pure (failed e)
  s <- liftIO (getString buf 0 4)
  A.close h
  _ <- liftIO (C.remove path)
  pure ("plain " ++ show h.isPlain ++ ", readAt " ++ show n ++ " " ++ s)

errName : Errno -> String
errName e = if e == EBADF then "EBADF" else if e == EINVAL then "EINVAL" else if e == ENOENT then "ENOENT" else "other"

-- A file of more than one chunk comes back whole and in order; a missing file,
-- an empty range and a closed handle are errors.
bigTest : Task String
bigTest = do
  let text = concat (replicate 2000 "abcdefghij")
  Right h <- A.openFile path (O_RDWR .|. O_CREAT .|. O_TRUNC) 0o600
    | Left e => pure (failed e)
  b <- bufferOf text
  Right () <- A.writeAll h b 0 20000
    | Left e => pure (failed e)
  Right h2 <- A.openFile path O_RDONLY 0
    | Left e => pure (failed e)
  Right back <- A.readString h2
    | Left e => pure (failed e)
  empty <- A.write h b 0 0
  A.close h
  closed <- A.write h b 0 1
  missing <- A.openFile "/nonexistent/TestPosixAsyncFile" O_RDONLY 0
  A.close h2
  _ <- liftIO (C.remove path)
  pure ("same " ++ show (back == text) ++ ", empty " ++ either errName show empty
        ++ ", closed " ++ either errName show closed ++ ", missing " ++ either errName (const "opened") missing)

-- A call on a regular file that is given up still keeps the handle open until it ends.
plainGivenUp : Task String
plainGivenUp = do
  Right h <- A.openFile path (O_RDWR .|. O_CREAT .|. O_TRUNC) 0o600
    | Left e => pure (failed e)
  b <- bufferOf "0123456789"
  lost <- race (A.writeAt h 0 b 0 10) (pure ())
  A.close h
  Right h2 <- A.openFile path O_RDONLY 0
    | Left e => pure (failed e)
  Just buf <- liftIO (newBuffer 16)
    | Nothing => pure "no buffer"
  sleepFor 20
  r <- A.readAt h2 0 buf 0 16
  A.close h2
  _ <- liftIO (C.remove path)
  pure ("race " ++ either (const "write won") (const "other won") lost ++ ", file has " ++ either errName show r ++ " bytes")

main : IO ()
main = do
  r <- runTaskWith 2 (do
         a <- pipeTest
         b <- mixTest
         c <- giveUpTest
         d <- closeTest
         e <- fileTest
         f <- bigTest
         g <- plainGivenUp
         pure [ "pipe: " ++ a, "two writers: " ++ b, "given up: " ++ c, "close: " ++ d, "file: " ++ e
              , "big: " ++ f, "plain given up: " ++ g ])
  traverse_ putStrLn (maybe ["no result"] id r)
  p <- runTaskParallel 3 pipeTest
  putStrLn ("parallel pipe: " ++ maybe "no result" id p)
