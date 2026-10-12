module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Uio: writev/readv over two memory regions, and
-- pread/pwrite through both the AnyPtr and the Buffer overloads, on a
-- scratch file removed before exit. The module exposes no wrapper for
-- preadv/pwritev/preadv2/pwritev2, so those are not called.

import Data.Bits
import Data.Buffer
import System.Directory
import System.File
import System.FFI
import System.FFI.C.Ptr
import System.Posix.Errno
import System.Posix.File
import System.Posix.Uio

path : String
path = "TestPosixUio.scratch"

fill : Ptr Bits8 -> Bits8 -> Int32 -> IO ()
fill p v n = for_ [0 .. n - 1] $ \i => unsafePtrStore p i (v + cast i)

dump : Ptr Bits8 -> Int32 -> IO (List Bits8)
dump p n = traverse (unsafePtrFetch p) [0 .. n - 1]

main : IO ()
main = do
  _ <- removeFile path
  Right fd <- openFile path (2 .|. O_CREAT .|. O_TRUNC) 420
    | Left e => putStrLn ("open failed: " ++ show e)
  a <- malloc 4
  b <- malloc 3
  let pa : Ptr Bits8 = prim__castPtr a
  let pb : Ptr Bits8 = prim__castPtr b
  fill pa 10 4
  fill pb 100 3
  writev fd [(a, 4), (b, 3)] >>= \r => putStrLn ("writev: " ++ show r)
  -- pread into memory at an offset, without moving the file position
  c <- malloc 8
  let pc : Ptr Bits8 = prim__castPtr c
  AnyPtr.pread fd c 5 2 >>= \r => putStrLn ("AnyPtr.pread: " ++ show r)
  dump pc 5 >>= \l => putStrLn ("  " ++ show l)
  -- pwrite from memory over bytes 1..2, then read everything back
  AnyPtr.pwrite fd b 2 1 >>= \r => putStrLn ("AnyPtr.pwrite: " ++ show r)
  Just buf <- newBuffer 7
    | Nothing => putStrLn "newBuffer failed"
  Buffer.pread fd buf 7 0 >>= \r => putStrLn ("Buffer.pread: " ++ show r)
  bs <- traverse (getBits8 buf) [0 .. 6]
  putStrLn ("  " ++ show bs)
  setBits8 buf 0 99
  Buffer.pwrite fd buf 1 6 >>= \r => putStrLn ("Buffer.pwrite: " ++ show r)
  -- readv back into two regions
  d <- malloc 4
  e <- malloc 3
  _ <- seekStart fd
  readv fd [(d, 4), (e, 3)] >>= \r => putStrLn ("readv: " ++ show r)
  dump (prim__castPtr d) 4 >>= \l => putStrLn ("  " ++ show l)
  dump (prim__castPtr e) 3 >>= \l => putStrLn ("  " ++ show l)
  putStrLn ("sizeof iovec: " ++ show SizeOfIOVec)
  for_ [a, b, c, d, e] free
  _ <- close fd
  _ <- removeFile path
  putStrLn "done"
 where
  seekStart : FileDesc -> IO Int64
  seekStart fd = lseek fd (cast (the Int64 0)) SEEK_SET
