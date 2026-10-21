||| `io_uring` requests as `Task`s. Each scheduler has one ring, made by the
||| first request (`Env.slot`) and given to the scheduler as a source
||| (`Env.addSource`): the descriptor of the ring is readable while completions
||| wait, and `drain` reaps them and calls the completion kept under each
||| request's tag. A program that makes no request makes no ring, and one that
||| does not reach this module needs no liburing at all (see
||| `libs/rc2base/doc/task.md`, "io_uring").
|||
||| The requests are made on the thread of the scheduler, as the ring needs.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Uring

import Control.Task
import Control.Task.Source
import Data.Buffer
import Data.IORef
import Data.SortedMap
import System.Linux.Uring
import System.Posix.Errno
import System.Posix.FileDesc

%default covering

-- The submission queue of the ring of a scheduler.
ringDepth : Nat
ringDepth = 256

record Ring where
  constructor MkRing
  uring : URing
  nextTag : IORef Bits64
  waiting : IORef (SortedMap Bits64 (Completion -> IO ()))

-- Reap every completion that is waiting, calling the one kept for its tag.
drain : Ring -> IO ()
drain ring = do
  Right (Just c) <- pollCompletion ring.uring
    | _ => pure ()
  found <- lookup c.userData <$> readIORef ring.waiting
  modifyIORef ring.waiting (delete c.userData)
  traverse_ (\wake => wake c) found
  drain ring

-- The ring of the scheduler of `env`, made on the first call.
ringOf : Env -> IO (Either Errno Ring)
ringOf env = env.slot "Control.Task.Uring" $ do
  Right uring <- init ringDepth
    | Left e => pure (Left e)
  Right fd <- ringFd uring
    | Left e => exit uring *> pure (Left e)
  ring <- MkRing uring <$> newIORef 1 <*> newIORef empty
  Right cancel <- env.addSource (MkSource fd (drain ring))
    | Left e => exit uring *> pure (Left e)
  pure (Right (ring, runCancel cancel *> exit uring))

-- A free entry of the submission queue; when it is full, what is prepared is
-- submitted to make room.
freeSqe : Ring -> IO (Maybe SQE)
freeSqe ring = do
  Nothing <- getSqe ring.uring
    | found => pure found
  ignore (submit ring.uring)
  getSqe ring.uring

fresh : Ring -> IO Bits64
fresh ring = do
  tag <- readIORef ring.nextTag
  writeIORef ring.nextTag (tag + 1)
  pure tag

-- Give a request up: ask the kernel to cancel it. Its completion still comes
-- (with `ECANCELED`, or its result if it was over) and is dropped, and what the
-- request holds stays alive until then.
cancelRequest : Ring -> Bits64 -> IO ()
cancelRequest ring tag = do
  cancelTag <- fresh ring
  Just sqe <- freeSqe ring
    | Nothing => pure ()
  prepCancel64 sqe tag 0
  setUserData sqe cancelTag
  ignore (submit ring.uring)

-- Fill an entry for the tag; `False` when the request cannot be made.
Prep : Type
Prep = URing -> SQE -> Bits64 -> IO Bool

-- Start a request. The result is the completion of the request; `EINVAL` when
-- `prep` says it cannot be made (an entry that was taken stays in the queue,
-- unfilled, which the kernel takes for a request that does nothing; its
-- completion has the tag 0, which no request has, and is dropped).
request : Prep -> Task (Either Errno Completion)
request prep = Async $ \env, done => do
  let failWith = \e => done (Left e) *> pure noCancel
  Right ring <- ringOf env
    | Left e => failWith e
  Just sqe <- freeSqe ring
    | Nothing => failWith EBUSY
  tag <- fresh ring
  True <- prep ring.uring sqe tag
    | False => failWith EINVAL
  modifyIORef ring.waiting (insert tag (done . Right))
  Right _ <- submit ring.uring
    | Left e => modifyIORef ring.waiting (delete tag) *> failWith e
  pure (MkCancel (cancelRequest ring tag))

-- A request whose result is a count.
byteCount : Prep -> Task (Either Errno Nat)
byteCount prep = map (>>= result) (request prep)

-- A request that has no result but success.
unit : Prep -> Task (Either Errno ())
unit prep = map (map (const ())) (byteCount prep)

-- A request whose result is a descriptor.
descriptor : Prep -> Task (Either Errno FileDesc)
descriptor prep = map (>>= fdResult) (request prep)

-- A request made of one call that takes the tag itself.
tagged : (URing -> SQE -> Bits64 -> IO ()) -> Prep
tagged make ring sqe tag = make ring sqe tag *> pure True

-- A request made of one call that does not, so the entry is tagged here.
untagged : (SQE -> IO ()) -> Prep
untagged make _ sqe tag = make sqe *> setUserData sqe tag *> pure True

-------------------------------------------------------------------------------
-- Requests

||| A request that does nothing.
export
uringNop : Task (Either Errno ())
uringNop = unit (untagged prepNop)

||| Read up to `nbytes` into the start of the buffer, from `offset` of the file;
||| the number of bytes read, `0` at the end of the file.
export
uringRead : FileDesc -> Buffer -> (nbytes : Bits32) -> (offset : Bits64) -> Task (Either Errno Nat)
uringRead fd buf nbytes offset = byteCount (tagged (\ring, sqe => prepRead ring sqe fd buf nbytes offset))

||| Write `nbytes` from the start of the buffer, at `offset` of the file; the
||| number of bytes written.
export
uringWrite : FileDesc -> Buffer -> (nbytes : Bits32) -> (offset : Bits64) -> Task (Either Errno Nat)
uringWrite fd buf nbytes offset = byteCount (tagged (\ring, sqe => prepWrite ring sqe fd buf nbytes offset))

||| Send `len` bytes from the start of the buffer on a connected socket.
export
uringSend : FileDesc -> Buffer -> (len : Bits64) -> (flags : Int32) -> Task (Either Errno Nat)
uringSend fd buf len flags = byteCount (tagged (\ring, sqe => prepSend ring sqe fd buf len flags))

||| Receive up to `len` bytes into the start of the buffer; `0` when the peer
||| closed its end.
export
uringRecv : FileDesc -> Buffer -> (len : Bits64) -> (flags : Int32) -> Task (Either Errno Nat)
uringRecv fd buf len flags = byteCount (tagged (\ring, sqe => prepRecv ring sqe fd buf len flags))

||| Accept one connection on a listening socket; the new socket. The address
||| of the peer is not given (`getpeername` on the socket gives it).
export
uringAccept : FileDesc -> (flags : Int32) -> Task (Either Errno FileDesc)
uringAccept fd flags = descriptor (untagged (\sqe => prepAccept sqe fd flags))

||| Connect a socket to a host (a name or a numeric address) and port. The name
||| is resolved at once, on the thread of the scheduler; `EINVAL` when it does
||| not resolve.
export
uringConnect : FileDesc -> (host : String) -> (port : Bits16) -> Task (Either Errno ())
uringConnect fd host port = unit (\ring, sqe, tag => prepConnect ring sqe fd host port tag)

||| Open a file, relative to a directory (`Nothing`: the current one); the new
||| descriptor. `flags` and `mode` are those of `System.Posix.File.openat`.
export
uringOpenat : Maybe DirDesc -> String -> (flags : Bits32) -> (mode : Bits32) -> Task (Either Errno FileDesc)
uringOpenat dir path flags mode = descriptor (untagged (\sqe => prepOpenat sqe dir path flags mode))

||| Close a descriptor.
export
uringClose : FileDesc -> Task (Either Errno ())
uringClose fd = unit (untagged (\sqe => prepClose sqe fd))

||| Flush a file to the disk (`fdatasync` with `fsyncDatasync`, `0` for a full
||| `fsync`).
export
uringFsync : FileDesc -> (flags : Bits32) -> Task (Either Errno ())
uringFsync fd flags = unit (untagged (\sqe => prepFsync sqe fd flags))
