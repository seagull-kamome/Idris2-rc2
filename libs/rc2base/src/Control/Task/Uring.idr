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
import System.Posix.Socket

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
  found <- getSqe ring.uring
  case found of
       Nothing => submit ring.uring *> getSqe ring.uring
       Just _ => pure found

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

-- Fill an entry for the tag.
Prep : Type
Prep = URing -> SQE -> Bits64 -> IO ()

-- A submission that fails for a moment (a signal, no memory, a full completion
-- queue) leaves the entries queued, and the next submission takes them: so the
-- request is not failed, which would let it run after its caller was told it did
-- not. The submission is tried again from the scheduler until it goes through.
-- Any other error means the ring is unusable, and nothing is queued for good.
transient : Errno -> Bool
transient e = e == EINTR || e == EAGAIN || e == EBUSY

-- Submit; `failed` is told of an error that is not transient.
submitRetrying : Env -> Ring -> (failed : Errno -> IO ()) -> IO ()
submitRetrying env ring failed = do
  r <- submit ring.uring
  case r of
       Right _ => pure ()
       Left e =>
         if transient e
            then drain ring *> env.post (submitRetrying env ring failed)   -- the drain makes room in the completion queue
            else failed e

-- Start a request. The result is what `decode` makes of its completion.
request : (decode : Completion -> Either Errno a) -> Prep -> Task (Either Errno a)
request decode prep = Async $ \env, done => do
  let failWith = \e => done (Left e) *> pure noCancel
  Right ring <- ringOf env
    | Left e => failWith e
  Just sqe <- freeSqe ring
    | Nothing => failWith EBUSY
  tag <- fresh ring
  prep ring.uring sqe tag
  modifyIORef ring.waiting (insert tag (done . decode))
  r <- submit ring.uring
  case r of
       Right _ => pure (MkCancel (cancelRequest ring tag))
       Left e =>
         if transient e
            then env.post (submitRetrying env ring (\e' => modifyIORef ring.waiting (delete tag) *> done (Left e')))
                 *> pure (MkCancel (cancelRequest ring tag))
            else modifyIORef ring.waiting (delete tag) *> failWith e

-- A request that has no result but success.
unit : Prep -> Task (Either Errno ())
unit = request (map (const ()) . result)

-- A request made of one call that does not take the tag, so the entry is tagged here.
untagged : (SQE -> IO ()) -> Prep
untagged make _ sqe tag = make sqe *> setUserData sqe tag

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
uringRead fd buf nbytes offset = request result (\ring, sqe, tag => prepRead ring sqe fd buf nbytes offset tag)

||| Write `nbytes` from the start of the buffer, at `offset` of the file; the
||| number of bytes written.
export
uringWrite : FileDesc -> Buffer -> (nbytes : Bits32) -> (offset : Bits64) -> Task (Either Errno Nat)
uringWrite fd buf nbytes offset = request result (\ring, sqe, tag => prepWrite ring sqe fd buf nbytes offset tag)

||| Send `len` bytes from the start of the buffer on a connected socket.
export
uringSend : FileDesc -> Buffer -> (len : Bits64) -> (flags : Int32) -> Task (Either Errno Nat)
uringSend fd buf len flags = request result (\ring, sqe, tag => prepSend ring sqe fd buf len flags tag)

||| Receive up to `len` bytes into the start of the buffer; `0` when the peer
||| closed its end.
export
uringRecv : FileDesc -> Buffer -> (len : Bits64) -> (flags : Int32) -> Task (Either Errno Nat)
uringRecv fd buf len flags = request result (\ring, sqe, tag => prepRecv ring sqe fd buf len flags tag)

||| Accept one connection on a listening socket; the new socket. The address
||| of the peer is not given (`getpeername` on the socket gives it).
export
uringAccept : FileDesc -> (flags : Int32) -> Task (Either Errno FileDesc)
uringAccept fd flags = request fdResult (untagged (\sqe => prepAccept sqe fd flags))

||| Connect a socket to a host (a name or a numeric address) and port. The name
||| is resolved on a worker thread (`blocking`) first; `EINVAL` when it does
||| not resolve.
export
uringConnect : FileDesc -> (host : String) -> (port : Bits16) -> Task (Either Errno ())
uringConnect fd host port = do
  Just addr <- blocking (resolve host port)
    | Nothing => pure (Left EINVAL)
  unit (\ring, sqe, tag => prepConnect ring sqe fd addr tag)

||| Open a file, relative to a directory (`Nothing`: the current one); the new
||| descriptor. `flags` and `mode` are those of `System.Posix.File.openat`.
export
uringOpenat : Maybe DirDesc -> String -> (flags : Bits32) -> (mode : Bits32) -> Task (Either Errno FileDesc)
uringOpenat dir path flags mode = request fdResult (\ring, sqe, tag => prepOpenat ring sqe dir path flags mode tag)

||| Close a descriptor.
export
uringClose : FileDesc -> Task (Either Errno ())
uringClose fd = unit (untagged (\sqe => prepClose sqe fd))

||| Flush a file to the disk (`fdatasync` with `fsyncDatasync`, `0` for a full
||| `fsync`).
export
uringFsync : FileDesc -> (flags : Bits32) -> Task (Either Errno ())
uringFsync fd flags = unit (untagged (\sqe => prepFsync sqe fd flags))
