module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for the untested plain-file-handle pieces of idris_file.c
-- (a libidris2_support.a fallback rc2 has no native port of):
-- readLine (not readBufferData -- TestBuffer.idr already covers that
-- one), fEOF, chmod, removeFile. openFile/writeLine/closeFile
-- themselves are already known-working via TestBuffer.idr's own
-- coverage.

import System.File
import System.File.Permissions

fileName : String
fileName = "test43_scratch.txt"

main : IO ()
main = do
  Right f <- openFile fileName WriteTruncate
    | Left err => putStrLn ("openFile (write) failed: " ++ show err)
  _ <- fPutStrLn f "line one"
  _ <- fPutStrLn f "line two"
  closeFile f

  Right g <- openFile fileName Read
    | Left err => putStrLn ("openFile (read) failed: " ++ show err)
  Right l1 <- fGetLine g
    | Left err => putStrLn ("fGetLine 1 failed: " ++ show err)
  putStrLn ("line 1: " ++ show l1)
  Right l2 <- fGetLine g
    | Left err => putStrLn ("fGetLine 2 failed: " ++ show err)
  putStrLn ("line 2: " ++ show l2)
  atEof <- fEOF g
  putStrLn ("eof after two lines: " ++ show atEof)
  closeFile g

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
