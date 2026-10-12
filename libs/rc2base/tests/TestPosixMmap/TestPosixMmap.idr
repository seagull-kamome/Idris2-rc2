module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Mmap: the PROT_*/MAP_* constants (compared with a plain C
-- program through the .expected file), an anonymous mapping written and
-- read back through System.FFI.C.Ptr, a read-only file-backed mapping,
-- and the failing mmap (zero length) mapped to Nothing. The module has no
-- munmap, so the test declares its own.

import System.Directory
import System.File
import System.FFI
import System.FFI.C.Ptr
import System.Posix.Errno
import System.Posix.File
import System.Posix.Mmap

%foreign "CExpr:(NULL),libc,stddef.h"
nullPtr : AnyPtr

%foreign "CExpr:(munmap($1, $2)),libc,sys/mman.h"
prim__munmap : AnyPtr -> Int64 -> PrimIO Int32

c : String -> Int32 -> IO ()
c n v = putStrLn (n ++ "=" ++ show v)

main : IO ()
main = do
  c "PROT_EXEC" PROT_EXEC
  c "PROT_READ" PROT_READ
  c "PROT_WRITE" PROT_WRITE
  c "MAP_PRIVATE" MAP_PRIVATE
  c "MAP_SHARED" MAP_SHARED
  c "MAP_32BIT" MAP_32BIT
  c "MAP_ANONYMOUS" MAP_ANONYMOUS
  c "MAP_FIXED" MAP_FIXED
  c "MAP_GROWSDOWN" MAP_GROWSDOWN
  c "MAP_HUGETLB" MAP_HUGETLB
  c "MAP_LOCKED" MAP_LOCKED
  c "MAP_NONBLOCK" MAP_NONBLOCK
  c "MAP_NORESERVE" MAP_NORESERVE
  c "MAP_POPULATE" MAP_POPULATE
  c "MAP_STACK" MAP_STACK
  -- anonymous read/write mapping
  Just p <- mmap nullPtr 4096 (PROT_READ + PROT_WRITE) (MAP_PRIVATE + MAP_ANONYMOUS) (MkFileDesc 4294967295) 0
    | Nothing => putStrLn "anonymous mmap failed"
  let bytes : Ptr Bits8 = prim__castPtr p
  unsafePtrStore bytes 0 42
  unsafePtrStore bytes 4095 7
  a <- unsafePtrFetch bytes 0
  b <- unsafePtrFetch bytes 4095
  z <- unsafePtrFetch bytes 100
  putStrLn ("anonymous: " ++ show (a, b, z))
  primIO (prim__munmap p 4096) >>= \r => putStrLn ("munmap: " ++ show r)
  -- file-backed read-only mapping
  let path = "TestPosixMmap.scratch"
  _ <- removeFile path
  Right () <- writeFile path "mapped file"
    | Left _ => putStrLn "writeFile failed"
  Right fd <- openFile path 0 0
    | Left e => putStrLn ("open failed: " ++ show e)
  Just q <- mmap nullPtr 11 PROT_READ MAP_PRIVATE fd 0
    | Nothing => putStrLn "file mmap failed"
  let fb : Ptr Bits8 = prim__castPtr q
  f0 <- unsafePtrFetch fb 0
  f10 <- unsafePtrFetch fb 10
  putStrLn ("file: " ++ show (f0, f10))
  _ <- primIO (prim__munmap q 11)
  _ <- close fd
  _ <- removeFile path
  -- failing mmap: zero length is EINVAL
  r <- mmap nullPtr 0 PROT_READ (MAP_PRIVATE + MAP_ANONYMOUS) (MkFileDesc 4294967295) 0
  putStrLn ("zero length: " ++ maybe "Nothing" (const "Just") r)
