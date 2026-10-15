module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Stdio against a scratch file: open/close, byte and line
-- reads, writes, position, stream state, buffering, locking, tmpfile,
-- fmemopen, fdopen/fileno, and rename/remove. The input file is made
-- with System.File and the outputs are read back with it, so the checks
-- do not rest on the functions under test.

import Data.Buffer
import Data.String
import System.Directory
import System.FFI
import System.FFI.C.Ptr
import System.File
import System.Posix.Errno
import System.Posix.File
import System.Posix.Stdio

in_ : String
in_ = "TestPosixStdio.in"

out : String
out = "TestPosixStdio.out"

moved : String
moved = "TestPosixStdio.moved"

report : Show a => String -> Either Errno a -> IO ()
report n (Right v) = putStrLn (n ++ ": " ++ show v)
report n (Left e)  = putStrLn (n ++ ": error " ++ show e)

-----------------------------------------------------------------------------
-- Setup and teardown (System.File, not under test)
-----------------------------------------------------------------------------

||| Write the input file: two lines and a last line without newline.
setup : IO ()
setup = do
  _ <- removeFile in_
  _ <- removeFile out
  _ <- removeFile moved
  Right () <- writeFile in_ "line one\nline two\nlast line"
    | Left _ => putStrLn "writeFile failed"
  pure ()

||| Remove every file the tests may have left.
teardown : IO ()
teardown = do
  _ <- removeFile in_
  _ <- removeFile out
  _ <- removeFile moved
  pure ()

-----------------------------------------------------------------------------
-- Tests (System.Posix.Stdio under test)
-----------------------------------------------------------------------------

||| EOF, BUFSIZ and the standard streams.
testConstants : IO ()
testConstants = do
  putStrLn ("EOF=" ++ show EOF)
  putStrLn ("BUFSIZ>0: " ++ show (BUFSIZ > 0))
  putStrLn ("FILENAME_MAX>0: " ++ show (FILENAME_MAX > 0))
  Right fd0 <- fileno stdin | Left e => putStrLn ("fileno stdin: " ++ show e)
  Right fd1 <- fileno stdout | Left e => putStrLn ("fileno stdout: " ++ show e)
  Right fd2 <- fileno stderr | Left e => putStrLn ("fileno stderr: " ++ show e)
  putStrLn ("standard fds: " ++ show (fd0.rawfd, fd1.rawfd, fd2.rawfd))

||| A failing fopen gives ENOENT.
testOpenMissing : IO ()
testOpenMissing = do
  Left e <- fopen "TestPosixStdio.missing" "r"
    | Right _ => putStrLn "fopen of a missing file succeeded"
  putStrLn ("fopen missing: " ++ show (e == ENOENT))

||| fgetc / ungetc / fgets / getline / fread, then the end of the file.
testRead : IO ()
testRead = do
  Right f <- fopen in_ "r"
    | Left e => putStrLn ("fopen: " ++ show e)
  fgetc f >>= printLn
  report "ungetc" =<< ungetc f 108
  fgetc f >>= printLn
  fgets f 100 >>= printLn
  getline f >>= printLn
  Just buf <- newBuffer 4
    | Nothing => putStrLn "newBuffer failed"
  n <- Buffer.fread f buf
  s <- getString buf 0 4
  putStrLn ("Buffer.fread: " ++ show n ++ " " ++ show s)
  p <- malloc 16
  k <- AnyPtr.fread f p 16
  putStrLn ("AnyPtr.fread: " ++ show k)
  free p
  feof f >>= \b => putStrLn ("feof: " ++ show b)
  ferror f >>= \b => putStrLn ("ferror: " ++ show b)
  getline f >>= printLn
  clearerr f
  feof f >>= \b => putStrLn ("feof after clearerr: " ++ show b)
  report "fclose" =<< fclose f

||| fputs / fputc / String.fwrite / Buffer.fwrite / AnyPtr.fwrite, then read back with System.File.
testWrite : IO ()
testWrite = do
  Right f <- fopen out "w"
    | Left e => putStrLn ("fopen: " ++ show e)
  report "fputs" =<< fputs f "abc"
  report "fputc" =<< fputc f 100
  String.fwrite f "ef" >>= \n => putStrLn ("String.fwrite: " ++ show n)
  Just buf <- newBuffer 2
    | Nothing => putStrLn "newBuffer failed"
  setString buf 0 "gh"
  Buffer.fwrite f buf >>= \n => putStrLn ("Buffer.fwrite: " ++ show n)
  p <- malloc 1
  unsafePtrStore (the (Ptr Bits8) (prim__castPtr p)) 0 120
  AnyPtr.fwrite f p 1 >>= \n => putStrLn ("AnyPtr.fwrite: " ++ show n)
  free p
  report "fflush" =<< fflush f
  report "fclose" =<< fclose f
  Right c <- readFile out
    | Left _ => putStrLn "readFile failed"
  putStrLn ("content: " ++ show c)

||| ftell / fseek / fseeko / ftello / rewind.
testPosition : IO ()
testPosition = do
  Right f <- fopen in_ "r"
    | Left e => putStrLn ("fopen: " ++ show e)
  report "ftell" =<< ftell f
  report "fseek" =<< fseek f 5 SEEK_SET
  report "ftell" =<< ftell f
  report "fseeko" =<< fseeko f (-4) SEEK_END
  report "ftello" =<< ftello f
  fgetc f >>= printLn
  rewind f
  report "ftell after rewind" =<< ftell f
  Left e <- fseek f (-1) SEEK_SET
    | Right _ => putStrLn "negative fseek succeeded"
  putStrLn ("negative fseek: " ++ show (e == EINVAL))
  _ <- fclose f
  pure ()

||| fileno / fdopen / setvbuf / locks.
testStreamState : IO ()
testStreamState = do
  Right f <- fopen in_ "r"
    | Left e => putStrLn ("fopen: " ++ show e)
  Right fd <- fileno f
    | Left e => putStrLn ("fileno: " ++ show e)
  putStrLn ("fileno > 2: " ++ show (fd.rawfd > 2))
  report "setvbuf" =<< setvbuf f Unbuffered 0
  flockfile f
  ftrylockfile f >>= \b => putStrLn ("ftrylockfile (own thread): " ++ show b)
  funlockfile f
  funlockfile f
  _ <- fclose f
  -- fdopen on a descriptor from System.Posix.File
  Right pfd <- openFile in_ 0 0
    | Left e => putStrLn ("openFile: " ++ show e)
  Right g <- fdopen pfd "r"
    | Left e => putStrLn ("fdopen: " ++ show e)
  fgets g 100 >>= printLn
  report "fclose" =<< fclose g

||| tmpfile and fmemopen.
testAnonymous : IO ()
testAnonymous = do
  Right t <- tmpfile
    | Left e => putStrLn ("tmpfile: " ++ show e)
  report "fputs" =<< fputs t "scratch text\n"
  rewind t
  fgets t 100 >>= printLn
  _ <- fclose t
  Right m <- fmemopen 16 "w+"
    | Left e => putStrLn ("fmemopen: " ++ show e)
  report "fputs" =<< fputs m "in memory"
  report "fflush" =<< fflush m
  rewind m
  fgets m 100 >>= printLn
  _ <- fclose m
  pure ()

||| freopen onto another file, rename, remove.
testFiles : IO ()
testFiles = do
  Right f <- fopen in_ "r"
    | Left e => putStrLn ("fopen: " ++ show e)
  Right g <- freopen out "w" f
    | Left e => putStrLn ("freopen: " ++ show e)
  report "fputs" =<< fputs g "reopened"
  _ <- fclose g
  readFile out >>= \r => putStrLn ("after freopen: " ++ show (either (const "?") id r))
  report "rename" =<< rename out moved
  Left e <- fopen out "r"
    | Right _ => putStrLn "old name still exists"
  putStrLn ("old name gone: " ++ show (e == ENOENT))
  report "remove" =<< remove moved
  Left e2 <- remove moved
    | Right _ => putStrLn "second remove succeeded"
  putStrLn ("second remove: " ++ show (e2 == ENOENT))

||| open_memstream: write, close, read the bytes back three ways, free.
testMemstream : IO ()
testMemstream = do
  putStrLn "-- open_memstream"
  Right ms <- openMemstream
    | Left e => putStrLn ("openMemstream: " ++ show e)
  report "fputs" =<< fputs (memstreamFile ms) "hello, "
  n <- String.fwrite (memstreamFile ms) "stream"
  putStrLn ("fwrite: " ++ show n)
  report "close" =<< closeMemstream ms
  memstreamSize ms >>= \sz => putStrLn ("size: " ++ show sz)
  memstreamString ms >>= \str => putStrLn ("string: " ++ show str)
  Just buf <- memstreamBuffer ms
    | Nothing => putStrLn "memstreamBuffer failed"
  getString buf 0 13 >>= \str => putStrLn ("buffer: " ++ show str)
  freeMemstream ms
  -- a NUL in the middle: the buffer keeps all of it, the string stops
  Right ms2 <- openMemstream
    | Left e => putStrLn ("openMemstream: " ++ show e)
  Just raw <- newBuffer 3
    | Nothing => putStrLn "newBuffer failed"
  setByte raw 0 65
  setByte raw 1 0
  setByte raw 2 66
  m <- Buffer.fwrite (memstreamFile ms2) raw
  putStrLn ("fwrite with a NUL: " ++ show m)
  report "close" =<< closeMemstream ms2
  memstreamSize ms2 >>= \sz => putStrLn ("size: " ++ show sz)
  memstreamString ms2 >>= \str => putStrLn ("string: " ++ show str)
  Just buf2 <- memstreamBuffer ms2
    | Nothing => putStrLn "memstreamBuffer failed"
  b0 <- getByte buf2 0
  b1 <- getByte buf2 1
  b2 <- getByte buf2 2
  putStrLn ("buffer bytes: " ++ show (b0, b1, b2))
  freeMemstream ms2
  -- nothing written
  Right ms3 <- openMemstream
    | Left e => putStrLn ("openMemstream: " ++ show e)
  report "close" =<< closeMemstream ms3
  memstreamSize ms3 >>= \sz => putStrLn ("empty size: " ++ show sz)
  memstreamString ms3 >>= \str => putStrLn ("empty string: " ++ show str)
  freeMemstream ms3

-----------------------------------------------------------------------------
-- main
-----------------------------------------------------------------------------

main : IO ()
main = do
  setup
  testConstants
  testOpenMissing
  testRead
  testWrite
  testPosition
  testStreamState
  testAnonymous
  testFiles
  testMemstream
  teardown
  putStrLn "done"
