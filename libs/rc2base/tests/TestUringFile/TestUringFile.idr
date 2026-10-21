||| Automated smoke test: a real temp file, driven entirely through
||| io_uring -- openat(O_CREAT|O_WRONLY|O_TRUNC) -> write -> fsync ->
||| close -> openat(O_RDONLY) -> read back -> close -> compare.
module Main

import Data.Bits
import Data.Buffer
import System.File
import System.Linux.Uring
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc

path : String
path = "iouring_test_file.tmp"

message : String
message = "hello from io_uring"

||| Submits the `SQE` `prep` fills in and waits for its one completion --
||| every step in this test is a single request in flight at a time.
runOne : URing -> (what : String) -> (SQE -> IO ()) -> IO (Either String Completion)
runOne ring what prep = do
  Just sqe <- getSqe ring
    | Nothing => pure (Left ("getSqe (" ++ what ++ ") failed"))
  prep sqe
  Right 1 <- submit ring
    | other => pure (Left ("submit (" ++ what ++ ") returned " ++ show other))
  Right completion <- waitCompletion ring
    | Left e => pure (Left ("waitCompletion (" ++ what ++ ") " ++ show e))
  pure (Right completion)

||| `runOne` for a request whose result is a new descriptor.
openFd : URing -> (what : String) -> (SQE -> IO ()) -> IO (Either String FileDesc)
openFd ring what prep = do
  Right completion <- runOne ring what prep
    | Left e => pure (Left e)
  pure (either (\e => Left (what ++ " " ++ show e)) Right (fdResult completion))

roundTrip : URing -> Buffer -> Buffer -> IO (Either String String)
roundTrip ring buf readBuf = do
  let size = cast {to = Bits32} (length message)
  Right fd <- openFd ring "open for write" (\sqe => prepOpenat sqe Nothing path (O_CREAT .|. O_WRONLY .|. O_TRUNC) 0o644)
    | Left e => pure (Left e)
  Right written <- runOne ring "write" (\sqe => prepWrite ring sqe fd buf size 0 0)
    | Left e => pure (Left e)
  if result written /= Right (length message)
     then pure (Left ("write " ++ show written.res))
     else do
       Right _ <- runOne ring "fsync" (\sqe => prepFsync sqe fd 0)
         | Left e => pure (Left e)
       Right _ <- runOne ring "close (write)" (\sqe => prepClose sqe fd)
         | Left e => pure (Left e)
       Right readFd <- openFd ring "open for read" (\sqe => prepOpenat sqe Nothing path O_RDONLY 0)
         | Left e => pure (Left e)
       Right readC <- runOne ring "read" (\sqe => prepRead ring sqe readFd readBuf size 0 0)
         | Left e => pure (Left e)
       Right _ <- runOne ring "close (read)" (\sqe => prepClose sqe readFd)
         | Left e => pure (Left e)
       if result readC /= Right (length message)
          then pure (Left ("read " ++ show readC.res))
          else Right <$> getString readBuf 0 (cast (length message))

main : IO ()
main = do
  Right ring <- init 8
    | Left e => putStrLn ("FAIL: init " ++ show e)
  Just buf <- newBuffer (cast (length message))
    | Nothing => putStrLn "FAIL: newBuffer failed"
  setString buf 0 message
  Just readBuf <- newBuffer (cast (length message))
    | Nothing => putStrLn "FAIL: newBuffer (read) failed"

  outcome <- roundTrip ring buf readBuf
  exit ring
  _ <- removeFile path
  case outcome of
       Left e => putStrLn ("FAIL: " ++ e)
       Right readBack =>
         putStrLn (if readBack == message then "PASS: file round-trip" else "FAIL: content " ++ show readBack)
