||| Automated smoke test: a real temp file, driven entirely through
||| io_uring -- openat(O_CREAT|O_WRONLY|O_TRUNC) -> write -> fsync ->
||| close -> openat(O_RDONLY) -> read back -> close -> compare.
module Main

import Data.Bits
import Data.Buffer
import Data.List
import Data.String
import System
import System.Directory
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
  pure (mapFst (\e => what ++ " " ++ show e) (fdResult completion))

roundTrip : URing -> Buffer -> Buffer -> IO (Either String String)
roundTrip ring buf readBuf = do
  let size = cast {to = Bits32} (length message)
  Right fd <- openFd ring "open for write" (\sqe => prepOpenat ring sqe Nothing path (O_CREAT .|. O_WRONLY .|. O_TRUNC) 0o644 1)
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
       Right readFd <- openFd ring "open for read" (\sqe => prepOpenat ring sqe Nothing path O_RDONLY 0 1)
         | Left e => pure (Left e)
       Right readC <- runOne ring "read" (\sqe => prepRead ring sqe readFd readBuf size 0 0)
         | Left e => pure (Left e)
       Right _ <- runOne ring "close (read)" (\sqe => prepClose sqe readFd)
         | Left e => pure (Left e)
       if result readC /= Right (length message)
          then pure (Left ("read " ++ show readC.res))
          else Right <$> getString readBuf 0 (cast (length message))

-- Heap churn between `prep` and `submit`: a path that the caller no longer
-- holds is freed on return, and the kernel reads it at `submit`.
churn : Int -> Int
churn n = go 1 0
  where
    go : Int -> Int -> Int
    go i acc = if i > n then acc
               else go (i + 1) (acc + cast (length (pack (replicate 24 (chr (65 + i `mod` 26))) ++ show i)))

runtimeName : Int -> String
runtimeName n = "iouring_runtime_path_" ++ show (1000 + n) ++ ".tmp"

||| `openat` with a path built at run time, the heap churned before `submit`:
||| the file must be created under that name.
runtimePath : URing -> IO String
runtimePath ring = do
  args <- getArgs
  let n = the Int (cast (length args))
  Just sqe <- getSqe ring
    | Nothing => pure "FAIL: getSqe"
  -- built twice: the string given to `prepOpenat` is held by nobody else
  prepOpenat ring sqe Nothing (runtimeName n) (O_CREAT .|. O_WRONLY .|. O_TRUNC) 0o644 7
  -- evaluated here, before `submit`
  when (churn 200000 < 0) $ putStrLn "unreachable"
  Right 1 <- submit ring
    | other => pure "FAIL: submit"
  Right completion <- waitCompletion ring
    | Left e => pure "FAIL: waitCompletion"
  let name = runtimeName n
  found <- exists name
  _ <- removeFile name
  pure $ case fdResult completion of
    Left e => "FAIL: openat " ++ show e
    Right fd => if found then "PASS: openat with a path built at run time" else "FAIL: no file named " ++ name

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
  runtimePath ring >>= putStrLn
  exit ring
  _ <- removeFile path
  case outcome of
       Left e => putStrLn ("FAIL: " ++ e)
       Right readBack =>
         putStrLn (if readBack == message then "PASS: file round-trip" else "FAIL: content " ++ show readBack)
