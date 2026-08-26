module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System.Directory (idris_directory.c, still a
-- libidris2_support.a fallback -- rc2 has no native port of this one,
-- unlike Data.Buffer/System.Clock/network's idrnet_*): currentDir,
-- createDir, changeDir, openDir/nextDirEntry/closeDir, removeDir.
-- Membership-only checks on directory listing (never order -- the
-- underlying readdir(3) order is not specified).

import System.Directory
import System.File

dirName : String
dirName = "test37_scratch_dir"

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
