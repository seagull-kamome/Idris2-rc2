||| The event loop: waits on the terminal input, the signals the terminal
||| cares about and any timers, and turns what happens into `Event`s.
|||
||| SIGWINCH, SIGINT, SIGTERM and SIGHUP are blocked in the calling thread
||| for as long as a `Loop` exists and are read through a signalfd, so a
||| program that uses the loop receives them as events instead of dying.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Loop

import Data.Bits
import Data.IORef
import Data.List
import System.Linux.Epoll
import System.Linux.Signalfd
import System.Linux.Timerfd
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Signal
import System.Posix.Time
import TermUI.Input
import TermUI.Terminal

%default covering

-------------------------------------------------------------------------------
-- Events

public export
data Event
  = EInput Input
  | EResize Nat Nat          -- columns, rows
  | ETimer Nat               -- the id given to `addTimer`
  | ETerminate               -- SIGINT, SIGTERM or SIGHUP
  | EEndOfInput              -- the terminal input was closed

export
Show Event where
  show (EInput i) = "EInput " ++ show i
  show (EResize c r) = "EResize " ++ show c ++ " " ++ show r
  show (ETimer n) = "ETimer " ++ show n
  show ETerminate = "ETerminate"
  show EEndOfInput = "EEndOfInput"

-------------------------------------------------------------------------------
-- Loop

export
record Loop where
  constructor MkLoop
  terminal : Terminal
  epoll : EPoll
  sigfd : FileDesc
  oldMask : SigSet
  timers : IORef (List (Int32, Nat, FileDesc))   -- (rawfd, id, descriptor)
  pending : IORef (List Bits8)                   -- incomplete input

-- How long a lone ESC waits for the rest of a sequence.
escapeWaitMs : Int32
escapeWaitMs = 30

sameSignal : Signal -> Signal -> Bool
sameSignal (MkSignal a) (MkSignal b) = a == b

||| Create a loop on a terminal in raw mode.
export
newLoop : Terminal -> IO (Either Errno Loop)
newLoop t = do
  Right set <- sigSetOf [SIGWINCH, SIGINT, SIGTERM, SIGHUP]
    | Left e => pure (Left e)
  Right old <- sigprocmask SIG_BLOCK set
    | Left e => pure (Left e)
  Right sfd <- signalfd set (SFD_NONBLOCK .|. SFD_CLOEXEC)
    | Left e => ignore (sigprocmask SIG_SETMASK old) >> pure (Left e)
  Right ep <- epollCreate 16
    | Left e => ignore (sigprocmask SIG_SETMASK old) >> pure (Left e)
  Right () <- epollAdd ep t.input EPOLLIN
    | Left e => ignore (sigprocmask SIG_SETMASK old) >> pure (Left e)
  Right () <- epollAdd ep sfd EPOLLIN
    | Left e => ignore (sigprocmask SIG_SETMASK old) >> pure (Left e)
  timers <- newIORef []
  pending <- newIORef []
  pure (Right (MkLoop t ep sfd old timers pending))

||| Close the loop's descriptors and unblock the signals. The terminal is
||| left as it is.
export
closeLoop : Loop -> IO ()
closeLoop l = do
  ts <- readIORef l.timers
  traverse_ (\(_, _, fd) => close fd) ts
  _ <- close l.sigfd
  _ <- epollClose l.epoll
  _ <- sigprocmask SIG_SETMASK l.oldMask
  pure ()

||| Stop a timer.
export
cancelTimer : Loop -> (id : Nat) -> IO ()
cancelTimer l ident = do
  ts <- readIORef l.timers
  let (gone, kept) = partition (\(_, n, _) => n == ident) ts
  traverse_ (\(_, _, fd) => ignore (epollDel l.epoll fd) >> ignore (close fd)) gone
  writeIORef l.timers kept

armTimer : Loop -> (id : Nat) -> (ms : Nat) -> (repeat : Bool) -> IO (Either Errno ())
armTimer l ident ms repeat = do
  cancelTimer l ident
  Right fd <- timerfd_create CLOCK_MONOTONIC (TFD_NONBLOCK .|. TFD_CLOEXEC)
    | Left e => pure (Left e)
  let span = MkTimeSpec (cast (div ms 1000)) (cast (mod ms 1000 * 1000000))
      none = MkTimeSpec 0 0
  Right _ <- timerfd_settime fd 0 (MkITimerSpec (if repeat then span else none) span)
    | Left e => ignore (close fd) >> pure (Left e)
  Right () <- epollAdd l.epoll fd EPOLLIN
    | Left e => ignore (close fd) >> pure (Left e)
  modifyIORef l.timers ((fd.rawfd, ident, fd) ::)
  pure (Right ())

||| Start a timer that fires `ETimer id` every `ms` milliseconds (the first
||| time after the same delay). Replaces a timer with the same id.
export
addTimer : Loop -> (id : Nat) -> (ms : Nat) -> IO (Either Errno ())
addTimer l ident ms = armTimer l ident ms True

||| Start a timer that fires `ETimer id` once, after `ms` milliseconds. The
||| expired timer stays registered until `cancelTimer`.
export
addOneShot : Loop -> (id : Nat) -> (ms : Nat) -> IO (Either Errno ())
addOneShot l ident ms = armTimer l ident ms False

-------------------------------------------------------------------------------
-- Waiting

drainSignals : Loop -> IO (List Event)
drainSignals l = do
  r <- readSignal l.sigfd
  case r of
    Left _ => pure []
    Right info => do
      rest <- drainSignals l
      here <- if sameSignal info.signo SIGWINCH
                 then (\(c, r') => [EResize c r']) <$> terminalSize l.terminal
                 else pure [ETerminate]
      pure (here ++ rest)

readInput : Loop -> IO (List Event)
readInput l = do
  r <- readBytes l.terminal.input
  case r of
    Left _ => pure [EEndOfInput]
    Right [] => pure [EEndOfInput]
    Right bytes => do
      old <- readIORef l.pending
      let (inputs, rest) = parseInput False (old ++ bytes)
      writeIORef l.pending rest
      pure (map EInput inputs)

fireTimer : Loop -> Int32 -> IO (List Event)
fireTimer l raw = do
  ts <- readIORef l.timers
  case find (\(fd, _, _) => fd == raw) ts of
    Nothing => pure []
    Just (_, ident, fd) => do
      _ <- timerfd_read fd
      pure [ETimer ident]

||| Wait for up to `timeoutMs` milliseconds (-1: for ever) and return what
||| happened; the list is empty when the time ran out.
export
waitEvents : Loop -> (timeoutMs : Int32) -> IO (List Event)
waitEvents l timeoutMs = do
  held <- readIORef l.pending
  let wait = if null held then timeoutMs
             else if timeoutMs < 0 || timeoutMs > escapeWaitMs then escapeWaitMs else timeoutMs
  Right ready <- epollWait l.epoll wait
    | Left _ => pure []
  case ready of
    [] => if null held || wait /= escapeWaitMs
             then pure []
             else do
               -- nothing followed the ESC: it was the Escape key
               let (inputs, _) = parseInput True held
               writeIORef l.pending []
               pure (map EInput inputs)
    _ => concat <$> traverse handle ready
  where
    handle : ReadyEvent -> IO (List Event)
    handle e =
      if e.fd == l.terminal.input.rawfd then readInput l
      else if e.fd == l.sigfd.rawfd then drainSignals l
      else fireTimer l e.fd
