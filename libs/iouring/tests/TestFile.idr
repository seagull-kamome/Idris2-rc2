||| Automated smoke test: a real temp file, driven entirely through
||| io_uring -- openat(O_CREAT|O_WRONLY|O_TRUNC) -> write -> fsync ->
||| close -> openat(O_RDONLY) -> read back -> close -> compare.
module Main

import Data.Bits
import Data.Buffer
import System.File
import System.IO.Uring

path : String
path = "iouring_test_file.tmp"

message : String
message = "hello from io_uring"

||| Submits `sqe`'s own already-prepared op and waits for its one
||| completion -- every step in this test is a single in-flight
||| request at a time, so this is enough (no need for a general
||| multi-request submit/drain loop).
runOne : URing -> SQE -> IO (Maybe Int)
runOne ring sqe = do
  n <- submit ring
  if n /= 1
     then pure Nothing
     else do
       Just completion <- waitCompletion ring
         | Nothing => pure Nothing
       pure (Just completion.res)

main : IO ()
main = do
  Just ring <- init 8
    | Nothing => putStrLn "FAIL: init failed"

  Just buf <- newBuffer (cast (length message))
    | Nothing => putStrLn "FAIL: newBuffer failed"
  setString buf 0 message

  Just openSqe <- getSqe ring
    | Nothing => putStrLn "FAIL: getSqe (open for write) failed"
  prepOpenat openSqe atFdcwd path (OpenFlags.creat .|. OpenFlags.wronly .|. OpenFlags.trunc) 0o644
  Just fd <- runOne ring openSqe
    | Nothing => putStrLn "FAIL: submit/wait (open for write) failed"
  if fd < 0
     then putStrLn $ "FAIL: openat (write) res=" ++ show fd
     else do
       Just writeSqe <- getSqe ring
         | Nothing => putStrLn "FAIL: getSqe (write) failed"
       prepWrite ring writeSqe fd buf (cast (length message)) 0
       Just written <- runOne ring writeSqe
         | Nothing => putStrLn "FAIL: submit/wait (write) failed"
       if written /= cast (length message)
          then putStrLn $ "FAIL: write res=" ++ show written ++ ", expected " ++ show (length message)
          else do
            Just fsyncSqe <- getSqe ring
              | Nothing => putStrLn "FAIL: getSqe (fsync) failed"
            prepFsync fsyncSqe fd 0
            Just fsyncRes <- runOne ring fsyncSqe
              | Nothing => putStrLn "FAIL: submit/wait (fsync) failed"
            Just closeSqe <- getSqe ring
              | Nothing => putStrLn "FAIL: getSqe (close write fd) failed"
            prepClose closeSqe fd
            _ <- runOne ring closeSqe

            Just readOpenSqe <- getSqe ring
              | Nothing => putStrLn "FAIL: getSqe (open for read) failed"
            prepOpenat readOpenSqe atFdcwd path OpenFlags.rdonly 0
            Just readFd <- runOne ring readOpenSqe
              | Nothing => putStrLn "FAIL: submit/wait (open for read) failed"
            if readFd < 0
               then putStrLn $ "FAIL: openat (read) res=" ++ show readFd
               else do
                 Just readBuf <- newBuffer (cast (length message))
                   | Nothing => putStrLn "FAIL: newBuffer (read) failed"
                 Just readSqe <- getSqe ring
                   | Nothing => putStrLn "FAIL: getSqe (read) failed"
                 prepRead ring readSqe readFd readBuf (cast (length message)) 0
                 Just readRes <- runOne ring readSqe
                   | Nothing => putStrLn "FAIL: submit/wait (read) failed"
                 Just closeReadSqe <- getSqe ring
                   | Nothing => putStrLn "FAIL: getSqe (close read fd) failed"
                 prepClose closeReadSqe readFd
                 _ <- runOne ring closeReadSqe

                 exit ring
                 _ <- removeFile path

                 readBack <- getString readBuf 0 (cast (length message))
                 if readRes == cast (length message) && readBack == message
                    then putStrLn "PASS: file round-trip"
                    else putStrLn $ "FAIL: read res=" ++ show readRes ++ " content=" ++ show readBack
