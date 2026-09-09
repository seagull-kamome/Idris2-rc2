||| Thin FFI wrapper around Linux `epoll`.
||| The standard `network` package's `Socket` gives no way to put a
||| descriptor in non-blocking mode or wait on several of them at
||| once -- both required for a single-threaded, event-driven server --
||| so this module adds exactly that (plus `SO_REUSEADDR`, needed to
||| rebind a just-restarted server's listening port). See
||| `libs/rc2base/doc/http-server.md` for the design this exists to
||| support.
module System.Net.Epoll

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Bits
import System.FFI

-- readyEvents' Int-indexed loop isn't structurally recursive, so it
-- doesn't satisfy rc2base.ipkg's package-wide `--total` on its own.
%default covering

-------------------------------------------------------------------------------
-- Raw FFI
-------------------------------------------------------------------------------

%foreign "C:idris2rc2_epoll_create, libidris2rc2base, event_util.h"
prim__epollCreate : PrimIO Int

%foreign "C:idris2rc2_epoll_add, libidris2rc2base, event_util.h"
prim__epollAdd : Int -> Int -> Int -> PrimIO Int

%foreign "C:idris2rc2_epoll_mod, libidris2rc2base, event_util.h"
prim__epollMod : Int -> Int -> Int -> PrimIO Int

%foreign "C:idris2rc2_epoll_del, libidris2rc2base, event_util.h"
prim__epollDel : Int -> Int -> PrimIO Int

%foreign "C:idris2rc2_epoll_wait, libidris2rc2base, event_util.h"
prim__epollWait : Int -> Int -> PrimIO Int

%foreign "C:idris2rc2_epoll_event_fd, libidris2rc2base, event_util.h"
prim__epollEventFd : Int -> PrimIO Int

%foreign "C:idris2rc2_epoll_event_flags, libidris2rc2base, event_util.h"
prim__epollEventFlags : Int -> PrimIO Int

%foreign "C:idris2rc2_epollin, libidris2rc2base, event_util.h"
prim__epollin : PrimIO Int

%foreign "C:idris2rc2_epollout, libidris2rc2base, event_util.h"
prim__epollout : PrimIO Int

%foreign "C:idris2rc2_epollerr, libidris2rc2base, event_util.h"
prim__epollerr : PrimIO Int

%foreign "C:idris2rc2_epollhup, libidris2rc2base, event_util.h"
prim__epollhup : PrimIO Int

%foreign "C:idris2rc2_set_nonblocking, libidris2rc2base, event_util.h"
prim__setNonBlocking : Int -> PrimIO Int

%foreign "C:idris2rc2_set_reuseaddr, libidris2rc2base, event_util.h"
prim__setReuseAddr : Int -> PrimIO Int

-------------------------------------------------------------------------------
-- Event flags
-------------------------------------------------------------------------------

||| A bitmask of epoll event flags (`EPOLLIN`/`EPOLLOUT`/...). `<+>`
||| combines flags requested together (e.g. wanting both read and
||| write readiness); `hasEvent` tests a `wait` result against one.
public export
record EventFlags where
  constructor MkEventFlags
  raw : Int

export
Semigroup EventFlags where
  MkEventFlags a <+> MkEventFlags b = MkEventFlags (a .|. b)

export
Monoid EventFlags where
  neutral = MkEventFlags 0

export
hasEvent : (want : EventFlags) -> (have : EventFlags) -> Bool
hasEvent (MkEventFlags want) (MkEventFlags have) = (want .&. have) == want

-- Cached via unsafePerformIO, same pattern as Network.Socket.Data's own
-- AF_*/SocketFamily constants -- these are OS-fixed values, not
-- something that varies per call.
export
epollIn : EventFlags
epollIn = MkEventFlags $ unsafePerformIO $ primIO prim__epollin

export
epollOut : EventFlags
epollOut = MkEventFlags $ unsafePerformIO $ primIO prim__epollout

export
epollErr : EventFlags
epollErr = MkEventFlags $ unsafePerformIO $ primIO prim__epollerr

export
epollHup : EventFlags
epollHup = MkEventFlags $ unsafePerformIO $ primIO prim__epollhup

-------------------------------------------------------------------------------
-- Socket setup helpers
-------------------------------------------------------------------------------

||| Puts a file descriptor in non-blocking mode. Must be called on
||| every socket (listening and accepted) that will be registered with
||| an `EPoll` -- a blocking `accept`/`recv`/`send` call on a wrongly-
||| configured descriptor would stall the whole single-threaded loop.
export
setNonBlocking : HasIO io => (fd : Int) -> io Bool
setNonBlocking fd = (== 0) <$> primIO (prim__setNonBlocking fd)

||| Sets `SO_REUSEADDR` on a socket, so a restarted server can rebind
||| its port immediately instead of hitting `TIME_WAIT`.
export
setReuseAddr : HasIO io => (fd : Int) -> io Bool
setReuseAddr fd = (== 0) <$> primIO (prim__setReuseAddr fd)

-------------------------------------------------------------------------------
-- EPoll
-------------------------------------------------------------------------------

||| A handle to one `epoll` instance. One process is expected to run
||| exactly one `EPoll` at a time -- `wait`'s underlying C call caches
||| its result in a single static buffer (see `event_util.c`), so
||| interleaving `wait` calls from two different `EPoll`s is unsafe.
public export
record EPoll where
  constructor MkEPoll
  fd : Int

||| Creates a new `epoll` instance. `Nothing` on failure (`epoll_create1`
||| errno, not surfaced further -- this only fails on resource
||| exhaustion, nothing a caller can meaningfully recover from).
export
create : HasIO io => io (Maybe EPoll)
create = do
  fd <- primIO prim__epollCreate
  pure $ if fd == -1 then Nothing else Just (MkEPoll fd)

||| Starts watching `fd` for the given events.
export
add : HasIO io => EPoll -> (fd : Int) -> EventFlags -> io Bool
add ep fd flags = (== 0) <$> primIO (prim__epollAdd ep.fd fd flags.raw)

||| Changes the set of events watched for an already-added `fd`.
export
modify : HasIO io => EPoll -> (fd : Int) -> EventFlags -> io Bool
modify ep fd flags = (== 0) <$> primIO (prim__epollMod ep.fd fd flags.raw)

||| Stops watching `fd`. Callers must do this before closing `fd` --
||| `epoll` drops a closed descriptor's registration on its own, but
||| relying on that leaves a window where a reused fd number could be
||| misattributed to the old registration.
export
remove : HasIO io => EPoll -> (fd : Int) -> io Bool
remove ep fd = (== 0) <$> primIO (prim__epollDel ep.fd fd)

||| One ready descriptor from a `wait` call.
public export
record ReadyEvent where
  constructor MkReadyEvent
  fd    : Int
  flags : EventFlags

readyEvents : HasIO io => Int -> io (List ReadyEvent)
readyEvents n = go 0
  where
    go : Int -> io (List ReadyEvent)
    go i = if i >= n
             then pure []
             else do
               fd    <- primIO (prim__epollEventFd i)
               flags <- primIO (prim__epollEventFlags i)
               rest  <- go (i + 1)
               pure (MkReadyEvent fd (MkEventFlags flags) :: rest)

||| Blocks (for at most `timeoutMs`, or indefinitely if negative) until
||| at least one watched descriptor is ready, then returns all of them.
||| An empty result means the timeout elapsed with nothing ready; `wait`
||| itself never reports `epoll_wait`'s own error case (a single
||| `EPOLLERR`/`EPOLLHUP` on the offending descriptor is how a lost
||| connection actually surfaces instead).
export
wait : HasIO io => EPoll -> (timeoutMs : Int) -> io (List ReadyEvent)
wait ep timeoutMs = do
  n <- primIO (prim__epollWait ep.fd timeoutMs)
  if n <= 0 then pure [] else readyEvents n
