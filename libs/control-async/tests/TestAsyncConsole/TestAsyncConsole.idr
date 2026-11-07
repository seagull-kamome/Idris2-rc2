module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- IO.Async.Console: lines read from a pipe (UTF-8, a CR kept, empty lines, a
-- newline at the end of a chunk, a character across two chunks, a line longer
-- than a chunk, no final newline, the end), a read given up in the middle of a
-- line losing nothing, a closed handle, strings written whole, and the console
-- of the process. The output of the Prelude is buffered and comes last.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.List
import Data.String
import Data.String.RC2
import IO.Async.Console
import System.Posix.Async.File as A
import System.Posix.Errno

%default covering

failed : Show e => e -> String
failed e = "error " ++ show e

-- Write the string to the handle, then close it.
feed : Handle -> String -> Task ()
feed w s = do
  let size = byteLength s
  Just b <- liftIO (newBuffer size)
    | Nothing => pure ()
  liftIO (setString b 0 s)
  _ <- A.writeAll w b 0 size
  A.close w

-- Whether the line read is the expected one.
is : String -> Either Errno (Maybe String) -> String
is want (Right (Just got)) = if got == want then "ok" else "differs"
is _ (Right Nothing) = "end"
is _ (Left e) = "error"

linesTest : Task (List String)
linesTest = do
  Right (ir, iw) <- A.pipe
    | Left e => pure [failed e]
  Right (orr, ow) <- A.pipe
    | Left e => pure [failed e]
  Right (er, ew) <- A.pipe
    | Left e => pure [failed e]
  c <- consoleOf ir ow ew
  let a8191 = pack (replicate 8191 'a')
      c8189 = pack (replicate 8189 'c') ++ "\246"
      long = pack (replicate 20000 'x')
  _ <- fork (feed iw ("hello\nw\246rld\r\n\n" ++ long ++ "\n" ++ a8191 ++ "\nb\n" ++ c8189 ++ "\nlast"))
  r1 <- readLine c
  r2 <- readLine c
  r3 <- readLine c
  r4 <- readLine c
  r5 <- readLine c
  r6 <- readLine c
  r7 <- readLine c
  r8 <- readLine c
  r9 <- readLine c
  traverse_ A.close [ir, orr, er, ow, ew]
  pure [ is "hello" r1, is "w\246rld\r" r2, is "" r3, is long r4, is a8191 r5
       , is "b" r6, is c8189 r7, is "last" r8, is "" r9 ]

-- A read given up in the middle of a line, then the rest of the line.
cancelTest : Task String
cancelTest = do
  Right (ir, iw) <- A.pipe
    | Left e => pure (failed e)
  Right (_, ow) <- A.pipe
    | Left e => pure (failed e)
  c <- consoleOf ir ow ow
  _ <- fork (do b1 <- bytes "abc"
                _ <- A.writeAll iw b1 0 3
                sleepFor 60
                b2 <- bytes "def\n"
                _ <- A.writeAll iw b2 0 4
                A.close iw)
  lost <- race (readLine c) (sleepFor 20)
  r <- readLine c
  pure ((either (const "read won") (const "timer won") lost) ++ ", then " ++ is "abcdef" r)
  where
    bytes : String -> Task Buffer
    bytes s = do
      Just b <- liftIO (newBuffer (byteLength s))
        | Nothing => pure (assert_total (idris_crash "buffer"))
      liftIO (setString b 0 s)
      pure b

closedTest : Task String
closedTest = do
  Right (ir, iw) <- A.pipe
    | Left e => pure (failed e)
  Right (_, ow) <- A.pipe
    | Left e => pure (failed e)
  c <- consoleOf ir ow ow
  A.close ir
  r <- readLine c
  s <- putStrLn c "x"
  A.close iw
  pure ("read " ++ either (\e => if e == EBADF then "EBADF" else "other") (const "ok") r)

-- What went to the handle, until `n` bytes are in.
drain : Handle -> Int -> Task String
drain h n = do
  Just buf <- liftIO (newBuffer n)
    | Nothing => pure "no buffer"
  go buf 0
  where
    go : Buffer -> Int -> Task String
    go buf got =
      if got >= n then liftIO (getString buf 0 got) else do
        r <- A.read h buf got (n - got)
        case r of
          Left e => pure (failed e)
          Right 0 => liftIO (getString buf 0 got)
          Right k => go buf (got + k)

sizes : String -> String
sizes s = "chars " ++ show (length s) ++ " bytes " ++ show (byteLength s)

outputTest : Task (List String)
outputTest = do
  Right (ir, iw) <- A.pipe
    | Left e => pure [failed e]
  Right (orr, ow) <- A.pipe
    | Left e => pure [failed e]
  Right (er, ew) <- A.pipe
    | Left e => pure [failed e]
  c <- consoleOf ir ow ew
  let big = pack (replicate 10000 'z')
  _ <- putStr c "a"
  _ <- putStrLn c "b\246"
  _ <- eputStr c "e"
  _ <- eputStrLn c "!"
  o <- drain orr 5
  e <- drain er 3
  w <- fork (putStrLn c big)
  b <- drain orr 10001
  _ <- wait w
  traverse_ A.close [ir, iw, orr, ow, er, ew]
  pure [sizes o, sizes e, "big " ++ show (length b) ++ " " ++ show (b == big ++ "\n")]

realTest : Task String
realTest = do
  Right c <- stdConsole
    | Left e => pure (failed e)
  Right c2 <- stdConsole
    | Left e => pure (failed e)
  _ <- putStrLn c "stdout works"
  _ <- eputStrLn c2 "stderr works"
  pure "std console done"

main : IO ()
main = do
  r <- runTask (do
         a <- linesTest
         b <- cancelTest
         c <- closedTest
         d <- outputTest
         e <- realTest
         pure (map ("line: " ++) a ++ ["cancel: " ++ b, "closed: " ++ c] ++ map ("output: " ++) d ++ [e]))
  traverse_ putStrLn (maybe ["no result"] id r)
