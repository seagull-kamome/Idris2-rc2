module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System.Directory (idris_directory.c, still a
-- libidris2_support.a fallback -- rc2 has no native port of this one,
-- unlike Data.Buffer/System.Clock/network's idrnet_*): currentDir,
-- createDir, changeDir, openDir/nextDirEntry/closeDir, removeDir.
-- Membership-only checks on directory listing (never order -- the
-- underlying readdir(3) order is not specified). Formerly
-- Test37SystemDirectory.idr -- renamed Test37SystemMisc and absorbed
-- four sibling libidris2_support.a-fallback smoke tests below (former
-- Test38SystemSignal, Test39SystemTerm, Test40SystemProcess,
-- Test43FileExtra), all plain sequential IO smoke checks with no
-- compiler-internals angle of their own, so kept as a light-touch
-- concatenation rather than woven together.

import System.Directory
import System.File
import System.File.Permissions
import System
import System.Signal
import System.Term

dirName : String
dirName = "test37_scratch_dir"

fileName : String
fileName = "test43_scratch.txt"

main : IO ()
main = do
  Just startDir <- currentDir
    | Nothing => putStrLn "currentDir failed"
  putStrLn "currentDir: ok"

  Right () <- createDir dirName
    | Left err => putStrLn ("createDir failed: " ++ show err)
  putStrLn "createDir: ok"

  True <- changeDir dirName
    | False => putStrLn "changeDir failed"
  putStrLn "changeDir: ok"

  Right f <- openFile "a.txt" WriteTruncate
    | Left err => putStrLn ("openFile a.txt failed: " ++ show err)
  _ <- fPutStrLn f "hello"
  closeFile f
  Right g <- openFile "b.txt" WriteTruncate
    | Left err => putStrLn ("openFile b.txt failed: " ++ show err)
  _ <- fPutStrLn g "world"
  closeFile g

  Right entries <- listDir "."
    | Left err => putStrLn ("listDir failed: " ++ show err)
  let hasA = elem "a.txt" entries
  let hasB = elem "b.txt" entries
  putStrLn ("has a.txt: " ++ show hasA)
  putStrLn ("has b.txt: " ++ show hasB)

  Right () <- removeFile "a.txt"
    | Left err => putStrLn ("removeFile a.txt failed: " ++ show err)
  Right () <- removeFile "b.txt"
    | Left err => putStrLn ("removeFile b.txt failed: " ++ show err)

  True <- changeDir startDir
    | False => putStrLn "changeDir back failed"
  putStrLn "changeDir back: ok"

  removeDir dirName
  putStrLn "removeDir: ok"

  putStrLn "done"

  -- absorbed from former Test38SystemSignal: collectSignal registers
  -- SIGUSR1 for collection instead of default handling, raiseSignal
  -- sends it to this same process, handleNextCollectedSignal retrieves
  -- it. Fully sequential (self-signal then immediately poll) -- no
  -- concurrency, so no raciness.
  Right () <- collectSignal (SigPosix SigUser1)
    | Left err => putStrLn "collectSignal failed"
  putStrLn "collectSignal: ok"

  Right () <- raiseSignal (SigPosix SigUser1)
    | Left err => putStrLn "raiseSignal failed"
  putStrLn "raiseSignal: ok"

  Just sig <- handleNextCollectedSignal
    | Nothing => putStrLn "handleNextCollectedSignal: nothing pending"
  putStrLn ("collected signal is SigUser1: " ++ show (sig == SigPosix SigUser1))

  Nothing <- handleNextCollectedSignal
    | Just _ => putStrLn "unexpected extra pending signal"
  putStrLn "no more pending signals: ok"

  Right () <- defaultSignal (SigPosix SigUser1)
    | Left err => putStrLn "defaultSignal failed"
  putStrLn "defaultSignal: ok"

  putStrLn "done"

  -- absorbed from former Test39SystemTerm: getTermCols/getTermLines.
  -- Per System.Term's own doc comment, both return 0 (not an error)
  -- when stdout isn't a real TTY -- true for every automated test run
  -- here -- so this only asserts non-negativity, never a specific
  -- terminal size, to stay deterministic across environments.
  setupTerm
  cols <- getTermCols
  termLines <- getTermLines
  putStrLn ("cols non-negative: " ++ show (cols >= 0))
  putStrLn ("lines non-negative: " ++ show (termLines >= 0))
  putStrLn "done"

  -- absorbed from former Test40SystemProcess: System's system/run
  -- (idris_system.c's idris2_system, plus idris_file.c's popen/pclose
  -- via System.File.Process): system runs a command and reports its
  -- exit code, run captures stdout too.
  trueCode <- System.system "true"
  putStrLn ("system true exit code: " ++ show trueCode)

  falseCode <- System.system "false"
  putStrLn ("system false exit code: " ++ show falseCode)

  (out, code) <- System.run "echo hello-rc2"
  putStrLn ("run output: " ++ show out)
  putStrLn ("run exit code: " ++ show code)

  putStrLn "done"

  -- absorbed from former Test43FileExtra: the untested plain-file-
  -- handle pieces of idris_file.c: readLine (not readBufferData --
  -- TestBuffer.idr already covers that one), fEOF, chmod, removeFile.
  -- openFile/writeLine/closeFile themselves are already known-working
  -- via TestBuffer.idr's own coverage.
  Right h <- openFile fileName WriteTruncate
    | Left err => putStrLn ("openFile (write) failed: " ++ show err)
  _ <- fPutStrLn h "line one"
  _ <- fPutStrLn h "line two"
  closeFile h

  Right i <- openFile fileName Read
    | Left err => putStrLn ("openFile (read) failed: " ++ show err)
  Right l1 <- fGetLine i
    | Left err => putStrLn ("fGetLine 1 failed: " ++ show err)
  putStrLn ("line 1: " ++ show l1)
  Right l2 <- fGetLine i
    | Left err => putStrLn ("fGetLine 2 failed: " ++ show err)
  putStrLn ("line 2: " ++ show l2)
  atEof <- fEOF i
  putStrLn ("eof after two lines: " ++ show atEof)
  closeFile i

  Right () <- chmod fileName (MkPermissions [Read, Write] [Read] [Read])
    | Left err => putStrLn ("chmod failed: " ++ show err)
  putStrLn "chmod: ok"

  Right () <- removeFile fileName
    | Left err => putStrLn ("removeFile failed: " ++ show err)
  putStrLn "removeFile: ok"

  Left _ <- openFile fileName Read
    | Right _ => putStrLn "unexpected: file still openable after removeFile"
  putStrLn "file gone after removeFile: ok"

  putStrLn "done"
