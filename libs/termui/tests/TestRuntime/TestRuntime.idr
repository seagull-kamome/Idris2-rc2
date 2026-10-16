||| The terminal runtime on a pseudo-terminal: raw mode and its restoration,
||| the alternate screen, key events, a lone Escape, resize, timers and
||| termination signals. The pty comes from posix_openpt, which glibc declares
||| only under _GNU_SOURCE: verify.sh builds this test with
||| IDRIS2_CFLAGS=-D_GNU_SOURCE.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.Bits
import Data.List
import Data.String
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Signal
import System.Posix.Termios
import TermUI.Frame
import TermUI.Loop
import TermUI.Node
import TermUI.Output
import TermUI.Terminal
import Text.Encoding.UTF8

%default covering

visible : List Bits8 -> String
visible bs = concatMap esc (map (cast {to = Int}) bs)
  where
    esc : Int -> String
    esc 27 = "<ESC>"
    esc 10 = "<LF>"
    esc 13 = "<CR>"
    esc b = if b >= 32 && b < 127 then singleton (chr b) else "<" ++ show b ++ ">"

-- The tty layer hands output written to the slave to the master
-- asynchronously: read until the marker has arrived.
readUntil : FileDesc -> String -> IO (List Bits8)
readUntil master marker = go []
  where
    want : List Bits8
    want = encode (unpack marker)

    go : List Bits8 -> IO (List Bits8)
    go acc =
      if isSuffixOf want acc
         then pure acc
         else do
           Right more <- readBytes master
             | Left _ => pure acc
           if null more then pure acc else go (acc ++ more)

fromMaster : FileDesc -> String -> IO ()
fromMaster master marker = do
  r <- readUntil master marker
  putStrLn ("terminal output: " ++ visible r)

send : FileDesc -> String -> IO ()
send master s = ignore (writeString master s)

events : Loop -> Int32 -> IO ()
events l ms = waitEvents l ms >>= putStrLn . show

flags : String -> FileDesc -> IO ()
flags title fd = do
  Right ios <- tcgetattr fd
    | Left e => putStrLn ("tcgetattr: " ++ show e)
  lf <- getLFlag ios
  putStrLn (title ++ ": canonical=" ++ show ((lf .&. ICANON) /= 0)
            ++ " echo=" ++ show ((lf .&. ECHO) /= 0) ++ " isig=" ++ show ((lf .&. ISIG) /= 0))

main : IO ()
main = do
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e)
  _ <- grantpt master
  _ <- unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e)
  _ <- setWinSize master 40 10

  flags "before" slave
  Right term <- openTerminal slave slave
    | Left e => putStrLn ("openTerminal: " ++ show e)
  flags "raw" slave
  fromMaster master "\ESC[2J"
  terminalSize term >>= \s => putStrLn ("size: " ++ show s)

  Right loop <- newLoop term
    | Left e => putStrLn ("newLoop: " ++ show e)

  putStrLn "-- keys"
  send master "a\ESC[A"
  events loop 1000
  send master "\ESC[1;5C"
  events loop 1000
  putStrLn "-- a split sequence"
  send master "\ESC["
  events loop 1000
  send master "B"
  events loop 1000
  putStrLn "-- a lone Escape"
  send master "\ESC"
  events loop 1000
  events loop 1000
  putStrLn "-- nothing happens"
  events loop 20

  putStrLn "-- resize"
  _ <- setWinSize master 50 12
  _ <- raise SIGWINCH
  events loop 1000

  putStrLn "-- timer"
  _ <- addTimer loop 7 20
  events loop 1000
  cancelTimer loop 7
  events loop 80

  putStrLn "-- terminate"
  _ <- raise SIGINT
  events loop 1000

  putStrLn "-- a frame"
  f1 <- render (the (Node ()) (text "hi")) 4 1
  out <- diffFrames Nothing f1
  _ <- writeString slave out
  fromMaster master "hi\ESC[0m"

  closeLoop loop
  closeTerminal term
  fromMaster master "\ESC[?1049l"
  flags "restored" slave
  putStrLn "done"
