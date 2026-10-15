module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Linux.*: pipe2 with O_CLOEXEC / O_NONBLOCK set at creation.
-- pipe2 is declared by glibc only under _GNU_SOURCE, so verify.sh builds
-- this test with IDRIS2_CFLAGS=-D_GNU_SOURCE.

import Data.Bits
import System.FFI
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Linux.Pipe

main : IO ()
main = do
  Right (rd, wr) <- pipe2 (O_CLOEXEC .|. O_NONBLOCK)
    | Left _ => putStrLn "pipe2 failed"
  getFdFlags rd >>= \r => putStrLn ("cloexec on the read end: " ++ show r)
  getFdFlags wr >>= \r => putStrLn ("cloexec on the write end: " ++ show r)
  Right fl <- getStatusFlags rd
    | Left _ => putStrLn "getStatusFlags failed"
  putStrLn ("nonblock on the read end: " ++ show ((fl .&. O_NONBLOCK) /= 0))
  _ <- write wr "ping"
  _ <- close wr
  _ <- close rd
  Right (rd2, wr2) <- pipe2 0
    | Left _ => putStrLn "pipe2 failed"
  getFdFlags rd2 >>= \r => putStrLn ("no flags: " ++ show r)
  _ <- close rd2
  _ <- close wr2
  putStrLn "done"
