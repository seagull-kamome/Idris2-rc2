||| Descriptors for `Control.Task`: `System.Posix.File` as tasks. A `Handle` is a
||| descriptor with what several tasks (and threads) need to share it safely.
|||
||| * Pipes, terminals, sockets and the like are waited for on the scheduler's
|||   `epoll`: a read or write that would block lets the other tasks run. A
|||   descriptor that is not `O_NONBLOCK` (a shared standard input) is waited for
|||   first, and then read or written once; a write is cut to 4096 bytes, which
|||   such a descriptor takes without blocking once it is writable. A read can
|||   still block the scheduler if another process takes the data in between.
||| * Regular files cannot be waited for, and a call on one may block: it runs
|||   on a worker thread. With no worker threads (`runTask`, `runTaskWith 0`) it
|||   runs at once and stops the scheduler, so a program that reads files starts
|||   the scheduler with workers. A call on a regular file is carried out even if
|||   the task is given up after it was issued, and its result is lost: a `read`
|||   moves the file offset, `readAt` does not. The handle stays open until the
|||   call is over.
||| * Reads are served one at a time, and so are writes: two tasks that
|||   `writeAll` to one pipe do not mix their bytes. (A call on a regular file that
|||   was given up leaves the line before it ends.)
||| * `close` takes effect when the calls that are running on the handle end, so
|||   that the descriptor number cannot be reused under a task that is waiting
|||   on it. It does not wake a read that waits for data: end that task (give it
|||   up) as well, which `withHandle` does. Later calls answer `EBADF`.
|||
||| Import it qualified: its names are those of `System.Posix.File`.
module System.Posix.Async.File

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Control.Task.MVar
import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import System.FFI
import System.Linux.Epoll
import System.Linux.Pipe
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File as Posix
import System.Posix.FileDesc
import System.Posix.Stat

%default covering

%inline %foreign "CExpr:((long)read($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__readAt : Int32 -> Buffer -> Int -> Int -> PrimIO Int
%inline %foreign "CExpr:((long)write($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__writeAt : Int32 -> Buffer -> Int -> Int -> PrimIO Int
%inline %foreign "CExpr:((long)pread($1, (char *)($2) + ($3), (size_t)($4), (off_t)($5))),libc,unistd.h"
prim__preadAt : Int32 -> Buffer -> Int -> Int -> Int64 -> PrimIO Int
%inline %foreign "CExpr:((long)pwrite($1, (char *)($2) + ($3), (size_t)($4), (off_t)($5))),libc,unistd.h"
prim__pwriteAt : Int32 -> Buffer -> Int -> Int -> Int64 -> PrimIO Int

record Gate where
  constructor MkGate
  live : Bool
  users : Nat
  closed : Bool

||| A descriptor shared by tasks.
export
record Handle where
  constructor MkHandle
  fd : FileDesc
  plain : Bool
  nonblock : Bool
  gate : IORef Gate
  readLock : MVar ()
  writeLock : MVar ()

||| The descriptor, for `Control.Task.awaitReadable` and the like. Do not close it.
export
(.descriptor) : Handle -> FileDesc
(.descriptor) = fd

||| Whether it is a regular file (or a directory, or a block device): calls on it
||| go to a worker thread.
export
(.isPlain) : Handle -> Bool
(.isPlain) = plain

-------------------------------------------------------------------------------
-- Making a handle

count : Int -> IO (Either Errno Int)
count r = if r < 0 then Left <$> errno else pure (Right r)

-- Whether the descriptor is a plain file, and whether it is already non-blocking.
classify : FileDesc -> IO (Either Errno (Bool, Bool))
classify fd = do
  Right st <- fstat fd
    | Left e => pure (Left e)
  Right flags <- getStatusFlags fd
    | Left e => pure (Left e)
  pure (Right (isRegular st || isDirectory st || isBlockDevice st, (flags .&. O_NONBLOCK) /= 0))

makeHandle : FileDesc -> (plain, nonblock : Bool) -> IO Handle
makeHandle fd plain nonblock = do
  gate <- newIORef (MkGate True 0 False)
  rl <- newMVarIO ()
  wl <- newMVarIO ()
  pure (MkHandle fd plain nonblock gate rl wl)

-- Take over a descriptor; `makeNonBlocking` sets `O_NONBLOCK` on one that can be
-- waited for (do not, for a descriptor that other processes share).
takeIO : (makeNonBlocking : Bool) -> FileDesc -> IO (Either Errno Handle)
takeIO makeNb fd = do
  Right (plain, nb) <- classify fd
    | Left e => pure (Left e)
  if makeNb && not plain && not nb
     then do
       Right flags <- getStatusFlags fd
         | Left e => pure (Left e)
       Right () <- setStatusFlags fd (flags .|. O_NONBLOCK)
         | Left e => pure (Left e)
       Right <$> makeHandle fd plain True
     else Right <$> makeHandle fd plain nb

||| Take over a descriptor without changing how it is set up: a shared standard
||| input stays blocking, and is waited for before each read.
export
adopt : FileDesc -> Task (Either Errno Handle)
adopt fd = onReactor (takeIO False fd)

-------------------------------------------------------------------------------
-- Closing

settleClose : Handle -> IO ()
settleClose h = do
  g <- readIORef h.gate
  when (not g.live && g.users == 0 && not g.closed) $ do
    writeIORef h.gate ({ closed := True } g)
    ignore (System.Posix.FileDesc.close h.fd)

||| Close the handle now, or as soon as the calls running on it end. Closing again
||| does nothing. Call it on the thread of the scheduler (`onReactor`, or from
||| `finally`).
export
closeNow : Handle -> IO ()
closeNow h = do
  modifyIORef h.gate ({ live := False })
  settleClose h

||| `closeNow` as a task.
export
close : Handle -> Task ()
close h = onReactor (closeNow h)

||| Run the task and close the handle when it ends or is given up.
export
withHandle : Handle -> Task a -> Task a
withHandle h = finally (\_ => closeNow h)

-- A call is running on the handle: the descriptor stays open until it ends.
enter : Handle -> IO Bool
enter h = do
  g <- readIORef h.gate
  if g.live
     then True <$ writeIORef h.gate ({ users := S g.users } g)
     else pure False

leave : Handle -> IO ()
leave h = do
  modifyIORef h.gate (\g => { users := minus g.users 1 } g)
  settleClose h

-------------------------------------------------------------------------------
-- Opening

||| Open a file (`O_CLOEXEC` is added). The open itself may block (a FIFO waits
||| for the other end) and runs on a worker thread. A descriptor that can be
||| waited for is made `O_NONBLOCK`. A task given up while the file is being
||| opened closes it.
export
openFile : String -> (flags : Bits32) -> (mode : Bits32) -> Task (Either Errno Handle)
openFile path flags mode = handoff start undo
  where
    undo : Either Errno Handle -> IO ()
    undo (Right h) = closeNow h
    undo (Left _) = pure ()

    opened : IO (Either Errno Handle)
    opened = do
      Right fd <- Posix.openFile path (flags .|. O_CLOEXEC) mode
        | Left e => pure (Left e)
      r <- takeIO True fd
      case r of
        Left e => Left e <$ ignore (System.Posix.FileDesc.close fd)
        Right h => pure (Right h)

    start : Env -> Completion (Either Errno Handle) -> IO Cancel
    start env done = noCancel <$ env.offload (opened >>= \r => env.post (done r))

||| A pipe: the read end and the write end, both non-blocking and `O_CLOEXEC`.
export
pipe : Task (Either Errno (Handle, Handle))
pipe = handoff start undo
  where
    undo : Either Errno (Handle, Handle) -> IO ()
    undo (Right (a, b)) = closeNow a *> closeNow b
    undo (Left _) = pure ()

    made : IO (Either Errno (Handle, Handle))
    made = do
      Right (r, w) <- pipe2 (O_CLOEXEC .|. O_NONBLOCK)
        | Left e => pure (Left e)
      hr <- makeHandle r False True
      hw <- makeHandle w False True
      pure (Right (hr, hw))

    start : Env -> Completion (Either Errno (Handle, Handle)) -> IO Cancel
    start _ done = noCancel <$ (made >>= done)

-------------------------------------------------------------------------------
-- Reading and writing

-- The range, if it lies inside the buffer and is not empty; `EINVAL` otherwise.
within : Buffer -> (off, len : Int) -> Task (Either Errno a) -> Task (Either Errno a)
within buf off len call = do
  size <- onReactor (rawSize buf)
  if off >= 0 && len > 0 && len <= size - off then call else pure (Left EINVAL)

retryEintr : IO (Either Errno a) -> IO (Either Errno a)
retryEintr call = do
  r <- call
  case r of
    Left e => if e == EINTR then retryEintr call else pure r
    Right _ => pure r

-- A call on a plain file: on a worker thread, with the handle kept open until it
-- is over. Its job is not taken back when the task is given up (the worker has
-- to give the handle back).
plainCall : Handle -> IO (Either Errno a) -> Task (Either Errno a)
plainCall h act = Async $ \env, done => do
  ok <- enter h
  if ok
     then noCancel <$ env.offload (act >>= \r => env.post (leave h *> done r))
     else noCancel <$ done (Left EBADF)

-- `enter` is made with `handoff`, so that a task given up between taking the
-- place and going on gives it back.
inUse : Handle -> Task (Either Errno a) -> Task (Either Errno a)
inUse h body = do
  ok <- handoff (\_, done => noCancel <$ (enter h >>= done)) (\ok => when ok (leave h))
  if ok then finally (\_ => leave h) body else pure (Left EBADF)

-- One attempt on the thread of the scheduler; `EINTR` counts as "not yet".
attempt : IO (Either Errno Int) -> Task (Either Errno Int)
attempt call = do
  r <- onReactor call
  pure $ case r of
    Left e => if e == EINTR then Left EAGAIN else r
    Right _ => r

-- Try, and wait for the descriptor when it would block. A descriptor that is not
-- non-blocking is waited for first.
retrying : Handle -> Task a -> IO (Either Errno Int) -> Task (Either Errno Int)
retrying h wait call = if h.nonblock then go else wait *> go
  where
    go : Task (Either Errno Int)
    go = do
      r <- attempt call
      case r of
        Left e => if e == EAGAIN then wait *> go else pure r
        Right _ => pure r

-- One read or write, as the kind of the handle asks.
step : Handle -> (wait : Task a) -> IO (Either Errno Int) -> Task (Either Errno Int)
step h wait call =
  if h.plain then plainCall h (retryEintr call) else inUse h (retrying h wait call)

readSome : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
readSome h buf off len =
  within buf off len (step h (awaitReadable h.fd) (primIO (prim__readAt h.fd.rawfd buf off len) >>= count))

-- A descriptor that is not non-blocking takes at most this much at once without blocking.
pipeBuf : Int
pipeBuf = 4096

writeSome : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
writeSome h buf off len =
  within buf off len (step h (awaitWritable h.fd) (primIO (prim__writeAt h.fd.rawfd buf off (cut len)) >>= count))
  where
    cut : Int -> Int
    cut n = if h.nonblock || h.plain then n else min n pipeBuf

writeLoop : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno ())
writeLoop h buf off len =
  if len <= 0 then pure (Right ()) else do
    r <- writeSome h buf off len
    case r of
      Left e => pure (Left e)
      Right 0 => pure (Left EIO)
      Right n => writeLoop h buf (off + n) (len - n)

||| Read up to `len` bytes into `buf[off ..]` (`len` positive and the range inside
||| the buffer, else `EINVAL`). `Right 0` is the end of the file, or a pipe whose
||| writers have closed.
export
read : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
read h buf off len = withMVar h.readLock (\_ => readSome h buf off len)

||| Write some of `buf[off .. off+len)` (`len` positive and the range inside the
||| buffer, else `EINVAL`); the result is how many bytes went out.
export
write : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
write h buf off len = withMVar h.writeLock (\_ => writeSome h buf off len)

||| Write all of `buf[off .. off+len)` (nothing to do for an empty range). No other
||| write on the handle goes in between.
export
writeAll : Handle -> Buffer -> (off, len : Int) -> Task (Either Errno ())
writeAll h buf off len = withMVar h.writeLock (\_ => writeLoop h buf off len)

||| `read` of a regular file at an offset, which neither uses nor moves the file
||| offset (`pread`). `ESPIPE` for a handle that is not a regular file.
export
readAt : Handle -> (pos : Int64) -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
readAt h pos buf off len =
  if not h.plain then pure (Left ESPIPE)
  else within buf off len (plainCall h (retryEintr (primIO (prim__preadAt h.fd.rawfd buf off len pos) >>= count)))

||| `write` to a regular file at an offset (`pwrite`; with `O_APPEND` the bytes go
||| to the end all the same). `ESPIPE` for a handle that is not a regular file.
export
writeAt : Handle -> (pos : Int64) -> Buffer -> (off, len : Int) -> Task (Either Errno Int)
writeAt h pos buf off len =
  if not h.plain then pure (Left ESPIPE)
  else within buf off len (plainCall h (retryEintr (primIO (prim__pwriteAt h.fd.rawfd buf off len pos) >>= count)))

||| Flush a regular file to the disk (`fsync`), on a worker thread.
export
fsync : Handle -> Task (Either Errno ())
fsync h = plainCall h (retryEintr (Posix.fsync h.fd))

-- Read to the end into chunks of 8 KiB; the chunks and their sizes, last first.
chunks : Handle -> List (Buffer, Int) -> Task (Either Errno (List (Buffer, Int)))
chunks h acc = do
  Just buf <- onReactor (newBuffer 8192)
    | Nothing => pure (Left ENOMEM)
  r <- readSome h buf 0 8192
  case r of
    Left e => pure (Left e)
    Right 0 => pure (Right acc)
    Right n => chunks h ((buf, n) :: acc)

-- The largest buffer: the size of a `Buffer` is a C `int`.
maxBuffer : Int
maxBuffer = 2147483647

||| Read until the end into one buffer. `EFBIG` when it would not fit a buffer (2 GiB).
export
readAll : Handle -> Task (Either Errno Buffer)
readAll h = withMVar h.readLock (\_ => chunks h [] >>= either (pure . Left) assemble)
  where
    bytesIn : List (Buffer, Int) -> Int
    bytesIn = sum . map snd

    fill : Buffer -> Int -> List (Buffer, Int) -> IO ()
    fill _ _ [] = pure ()
    fill out end ((b, n) :: rest) = do
      copyData b 0 n out (end - n)
      fill out (end - n) rest

    assemble : List (Buffer, Int) -> Task (Either Errno Buffer)
    assemble cs =
      if bytesIn cs > maxBuffer then pure (Left EFBIG) else do
        Just out <- onReactor (newBuffer (bytesIn cs))
          | Nothing => pure (Left ENOMEM)
        onReactor (fill out (bytesIn cs) cs)
        pure (Right out)

||| Read until the end as a string. The bytes are not checked: invalid UTF-8 and
||| NUL bytes go into the string as they are.
export
readString : Handle -> Task (Either Errno String)
readString h = do
  Right buf <- readAll h
    | Left e => pure (Left e)
  onReactor (do size <- rawSize buf
                Right <$> getString buf 0 size)
