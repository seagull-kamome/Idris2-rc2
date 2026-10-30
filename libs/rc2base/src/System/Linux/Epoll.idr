||| `epoll`: wait for readiness on many descriptors at once.
|||
||| `Network.HTTP.Server` is built on it: a single-threaded, event-driven
||| server needs non-blocking descriptors and one wait over all of them (see
||| `libs/web/doc/http-server.md`).
|||
||| An `EPoll` owns the buffer `epollWait` fills, so any number of them can be in
||| use at once; none of them is safe to use from two threads at the same time.
|||
||| Linux only.
module System.Linux.Epoll

import Data.Bits
import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

-------------------------------------------------------------------------------
-- Event flags

||| An `or` of `EPOLL*` event bits.
public export
EpollEvents : Type
EpollEvents = Bits32

||| There is data to read.
%inline %foreign "CExpr:(EPOLLIN),libc,sys/epoll.h"
export EPOLLIN : EpollEvents
||| There is urgent data to read.
%inline %foreign "CExpr:(EPOLLPRI),libc,sys/epoll.h"
export EPOLLPRI : EpollEvents
||| Writing will not block.
%inline %foreign "CExpr:(EPOLLOUT),libc,sys/epoll.h"
export EPOLLOUT : EpollEvents
||| An error happened (always reported).
%inline %foreign "CExpr:(EPOLLERR),libc,sys/epoll.h"
export EPOLLERR : EpollEvents
||| The other end hung up (always reported).
%inline %foreign "CExpr:(EPOLLHUP),libc,sys/epoll.h"
export EPOLLHUP : EpollEvents
||| The peer of a stream socket closed its writing end.
%inline %foreign "CExpr:(EPOLLRDHUP),libc,sys/epoll.h"
export EPOLLRDHUP : EpollEvents
||| Report a change of readiness once (edge-triggered), not for as long as it lasts.
%inline %foreign "CExpr:(EPOLLET),libc,sys/epoll.h"
export EPOLLET : EpollEvents
||| Report one event, then stop watching the descriptor until `epollMod` re-arms it.
%inline %foreign "CExpr:(EPOLLONESHOT),libc,sys/epoll.h"
export EPOLLONESHOT : EpollEvents

||| Whether all the bits of `want` are set in `have`.
export
hasEvent : (want : EpollEvents) -> (have : EpollEvents) -> Bool
hasEvent want have = (want .&. have) == want

-------------------------------------------------------------------------------
-- Raw FFI

%inline %foreign "CExpr:(epoll_create1(EPOLL_CLOEXEC)),libc,sys/epoll.h"
prim__epoll_create : PrimIO Int32
%inline %foreign "CExpr:(EPOLL_CTL_ADD),libc,sys/epoll.h"
prim__EPOLL_CTL_ADD : Int32
%inline %foreign "CExpr:(EPOLL_CTL_MOD),libc,sys/epoll.h"
prim__EPOLL_CTL_MOD : Int32
%inline %foreign "CExpr:(EPOLL_CTL_DEL),libc,sys/epoll.h"
prim__EPOLL_CTL_DEL : Int32
%inline %foreign "CExpr:(({ struct epoll_event e; memset(&e, 0, sizeof(e)); e.events = $4; e.data.fd = $3; epoll_ctl($1, $2, $3, &e); })),libc,sys/epoll.h;string.h"
prim__epoll_ctl : Int32 -> Int32 -> Int32 -> EpollEvents -> PrimIO Int32
%inline %foreign "CExpr:(sizeof(struct epoll_event)),libc,sys/epoll.h"
prim__sizeofEvent : Int
%inline %foreign "CExpr:(epoll_wait($1, (struct epoll_event *)($2), $3, $4)),libc,sys/epoll.h"
prim__epoll_wait : Int32 -> AnyPtr -> Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct epoll_event *)($1))[$2].data.fd),libc,sys/epoll.h"
prim__event_fd : AnyPtr -> Int -> PrimIO Int32
%inline %foreign "CExpr:(((struct epoll_event *)($1))[$2].events),libc,sys/epoll.h"
prim__event_events : AnyPtr -> Int -> PrimIO EpollEvents

-------------------------------------------------------------------------------
-- EPoll

||| One `epoll` instance, with the buffer for the events one `epollWait` returns.
export
record EPoll where
  constructor MkEPoll
  efd : FileDesc
  buffer : AnyPtr
  capacity : Nat

||| One ready descriptor from `epollWait`.
public export
record ReadyEvent where
  constructor MkReadyEvent
  fd : Int32
  events : EpollEvents

||| The descriptor of the `epoll` instance, to be waited for by another `epoll`.
export
epollDescriptor : EPoll -> FileDesc
epollDescriptor ep = ep.efd

||| Create an `epoll` instance (close-on-exec) whose `epollWait` returns at most
||| `maxEvents` (at least 1) descriptors at a time. A descriptor that is ready but
||| does not fit is reported by the next `epollWait`.
export
epollCreate : (maxEvents : Nat) -> IO (Either Errno EPoll)
epollCreate maxEvents = do
  let cap = max 1 maxEvents
  r <- primIO prim__epoll_create >>= primFdToFileDesc
  case r of
    Left e => pure (Left e)
    Right fd => do
      buf <- malloc (prim__sizeofEvent * cast cap)
      pure (Right (MkEPoll fd buf cap))

ctl : Int32 -> EPoll -> FileDesc -> EpollEvents -> IO (Either Errno ())
ctl op ep fd events = primIO (prim__epoll_ctl ep.efd.rawfd op fd.rawfd events) >>= checkUnit

||| Start watching a descriptor for the given events.
export
epollAdd : EPoll -> FileDesc -> EpollEvents -> IO (Either Errno ())
epollAdd = ctl prim__EPOLL_CTL_ADD

||| Change the events watched for a descriptor that was added.
export
epollMod : EPoll -> FileDesc -> EpollEvents -> IO (Either Errno ())
epollMod = ctl prim__EPOLL_CTL_MOD

||| Stop watching a descriptor. Do it before closing the descriptor: a
||| registration belongs to the open file description, so closing one number
||| does not drop it while a `dup` or a forked copy of the descriptor is open.
export
epollDel : EPoll -> FileDesc -> IO (Either Errno ())
epollDel ep fd = ctl prim__EPOLL_CTL_DEL ep fd 0

||| Wait for at least one watched descriptor to be ready, at most `timeoutMs`
||| milliseconds (negative: no limit, 0: do not wait). An empty list means the
||| time ran out. `Left EINTR` when a signal interrupted the wait.
export
epollWait : EPoll -> (timeoutMs : Int32) -> IO (Either Errno (List ReadyEvent))
epollWait ep timeoutMs = do
  n <- primIO (prim__epoll_wait ep.efd.rawfd ep.buffer (cast ep.capacity) timeoutMs)
  if n < 0 then Left <$> errno else Right <$> collect (cast n) []
  where
    -- From the last event down, so that prepending leaves them in order.
    collect : Nat -> List ReadyEvent -> IO (List ReadyEvent)
    collect Z acc = pure acc
    collect (S k) acc = do
      fd <- primIO (prim__event_fd ep.buffer (cast k))
      events <- primIO (prim__event_events ep.buffer (cast k))
      collect k (MkReadyEvent fd events :: acc)

||| Close the `epoll` instance and free its buffer. The descriptors it watched are
||| not closed. Call once, and do not use the `EPoll` (`epollWait`, `epollAdd`, ...)
||| afterwards: the buffer is gone.
export
epollClose : EPoll -> IO (Either Errno ())
epollClose ep = do
  res <- close ep.efd
  free ep.buffer
  pure res
