||| `poll`: wait for events on several descriptors.
module System.Posix.Poll

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

||| An `or` of `POLL*` event bits.
public export
PollEvents : Type
PollEvents = Bits16

||| There is data to read.
%inline %foreign "CExpr:(POLLIN),libc,poll.h"
export POLLIN : PollEvents
||| There is urgent data to read.
%inline %foreign "CExpr:(POLLPRI),libc,poll.h"
export POLLPRI : PollEvents
||| Writing will not block.
%inline %foreign "CExpr:(POLLOUT),libc,poll.h"
export POLLOUT : PollEvents
||| An error happened (reported only).
%inline %foreign "CExpr:(POLLERR),libc,poll.h"
export POLLERR : PollEvents
||| The other end hung up (reported only).
%inline %foreign "CExpr:(POLLHUP),libc,poll.h"
export POLLHUP : PollEvents
||| The descriptor is not open (reported only).
%inline %foreign "CExpr:(POLLNVAL),libc,poll.h"
export POLLNVAL : PollEvents

%inline %foreign "CExpr:(sizeof(struct pollfd)),libc,poll.h"
prim__sizeofPollfd : Int
%inline %foreign "CExpr:(((struct pollfd *)($1))[$2].fd = ($3)),libc,poll.h"
prim__set_fd : AnyPtr -> Int -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct pollfd *)($1))[$2].events = ($3)),libc,poll.h"
prim__set_events : AnyPtr -> Int -> Bits16 -> PrimIO Bits16
%inline %foreign "CExpr:(((struct pollfd *)($1))[$2].revents),libc,poll.h"
prim__get_revents : AnyPtr -> Int -> PrimIO Bits16
%inline %foreign "CExpr:(poll((struct pollfd *)($1), $2, $3)),libc,poll.h"
prim__poll : AnyPtr -> Bits64 -> Int32 -> PrimIO Int32

||| Wait until one of the descriptors is ready for the events asked for, or
||| for `timeoutMs` milliseconds (-1: forever, 0: do not wait). Returns the
||| events that happened on each descriptor, in the order given (0: none);
||| `Left EINTR` when a signal interrupted the wait.
export
poll : List (FileDesc, PollEvents) -> (timeoutMs : Int32) -> IO (Either Errno (List PollEvents))
poll fds timeout = do
  let n = length fds
  p <- malloc (prim__sizeofPollfd * cast (max 1 n))
  fill p 0 fds
  rc <- primIO (prim__poll p (cast n) timeout)
  res <- if rc < 0
            then Left <$> errno
            else Right <$> collect p 0 n
  free p
  pure res
  where
    fill : AnyPtr -> Int -> List (FileDesc, PollEvents) -> IO ()
    fill p i [] = pure ()
    fill p i ((fd, ev) :: rest) = do
      _ <- primIO (prim__set_fd p i fd.rawfd)
      _ <- primIO (prim__set_events p i ev)
      fill p (i + 1) rest
    collect : AnyPtr -> Int -> Nat -> IO (List PollEvents)
    collect p i Z = pure []
    collect p i (S k) = do
      r <- primIO (prim__get_revents p i)
      (r ::) <$> collect p (i + 1) k
