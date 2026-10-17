||| The source of `Control.Task` that waits for the readiness of descriptors
||| with an `epoll` of its own. The registration is level-triggered and the
||| waiters are one-shot: a descriptor ready for a waiter wakes it and takes it
||| out of the table, and the mask of the descriptor follows the waiters left.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Epoll

import Control.Task
import Control.Task.Source
import Data.Bits
import Data.IORef
import Data.List
import Data.Maybe
import Data.SortedMap
import System.Linux.Epoll
import System.Posix.Errno
import System.Posix.FileDesc

%default covering

record Waiter where
  constructor MkWaiter
  ident : Nat
  wanted : EpollEvents
  wake : EpollEvents -> IO ()

export
record FdWatcher where
  constructor MkFdWatcher
  ep : EPoll
  table : IORef (SortedMap Int32 (List Waiter))
  counter : IORef Nat

export
newFdWatcher : IO (Either Errno FdWatcher)
newFdWatcher = do
  Right ep <- epollCreate 64
    | Left e => pure (Left e)
  table <- newIORef empty
  counter <- newIORef 0
  pure (Right (MkFdWatcher ep table counter))

||| Close the `epoll` of the watcher; the waiters are forgotten.
export
closeFdWatcher : FdWatcher -> IO ()
closeFdWatcher w = ignore (epollClose w.ep)

maskOf : List Waiter -> EpollEvents
maskOf = foldl (\acc, x => acc .|. x.wanted) 0

-- Make the registration of the descriptor what the waiters left want.
settle : FdWatcher -> Int32 -> List Waiter -> IO ()
settle w raw ws =
  case mkFileDesc raw of
    Nothing => pure ()
    Just fd =>
      if null ws
         then do modifyIORef w.table (delete raw)
                 ignore (epollDel w.ep fd)
         else do modifyIORef w.table (insert raw ws)
                 ignore (epollMod w.ep fd (maskOf ws))

||| Call `wake` with the events that came, once, when the descriptor is ready
||| for one of `events`. The result takes the wait back. A descriptor that
||| `epoll` cannot watch (a regular file) is always ready: `wake` is called at
||| once with `events`; any other failure wakes with `EPOLLERR`.
export
watch : FdWatcher -> FileDesc -> EpollEvents -> (EpollEvents -> IO ()) -> IO Cancel
watch w fd events wake = do
  ident <- readIORef w.counter
  writeIORef w.counter (S ident)
  tbl <- readIORef w.table
  let existing = fromMaybe [] (lookup fd.rawfd tbl)
      waiters = existing ++ [MkWaiter ident events wake]
  r <- if null existing then epollAdd w.ep fd (maskOf waiters) else epollMod w.ep fd (maskOf waiters)
  case r of
    Left e => do
      wake (if e == EPERM then events else EPOLLERR)
      pure noCancel
    Right () => do
      writeIORef w.table (insert fd.rawfd waiters tbl)
      pure (MkCancel (withdraw ident))
  where
    withdraw : Nat -> IO ()
    withdraw ident = do
      tbl <- readIORef w.table
      let ws = fromMaybe [] (lookup fd.rawfd tbl)
          kept = filter (\x => x.ident /= ident) ws
      when (length kept /= length ws) $ settle w fd.rawfd kept

-- Wake the waiters of a ready descriptor.
fire : FdWatcher -> ReadyEvent -> IO ()
fire w ev = do
  tbl <- readIORef w.table
  let ws = fromMaybe [] (lookup ev.fd tbl)
      matches = \x => ((x.wanted .|. EPOLLERR .|. EPOLLHUP) .&. ev.events) /= 0
      (woken, kept) = partition matches ws
  settle w ev.fd kept
  traverse_ (\x => x.wake ev.events) woken

||| The source: its descriptor is the `epoll` of the watcher.
export
watcherSource : FdWatcher -> Source
watcherSource w = MkSource (epollDescriptor w.ep) drainAll
  where
    drainAll : IO ()
    drainAll = do
      Right evs <- epollWait w.ep 0
        | Left _ => pure ()
      traverse_ (fire w) evs
