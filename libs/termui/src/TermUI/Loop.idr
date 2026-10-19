||| The event loop: waits on the terminal input, the signals the terminal
||| cares about and any timers, and turns what happens into `Event`s.
||| Design notes and limits: libs/termui/doc/design.md ("Runtime").
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Loop

import TermUI.Len
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
import Text.Encoding.UTF8

%default covering

-------------------------------------------------------------------------------
-- Events

||| What names a timer: the number a caller gave to `addTimer` or `addOneShot`,
||| told apart by kind, so that the two cannot be taken for one another, and
||| the loop's own timer (the Escape key), which no caller can name.
public export
data TimerId = Ticker Nat | Shot Nat | EscapeKey

export
Eq TimerId where
  Ticker a == Ticker b = a == b
  Shot a == Shot b = a == b
  EscapeKey == EscapeKey = True
  _ == _ = False

export
Show TimerId where
  show (Ticker n) = show n
  show (Shot n) = show n
  show EscapeKey = "escape"

public export
data Event
  = EInput Input
  | EResize Len Len          -- columns, rows
  | ETimer TimerId           -- the timer that fired
  | ETerminate               -- SIGINT, SIGTERM or SIGHUP
  | EResume                  -- SIGCONT: the program was stopped and continued
  | ESuspend                 -- SIGTSTP sent from outside: stop as `Suspend` does
  | EReady Int32             -- a descriptor given to `watchFd` is readable
  | EEndOfInput              -- the terminal input was closed or failed

export
Show Event where
  show (EInput i) = "EInput " ++ show i
  show (EResize c r) = "EResize " ++ show c ++ " " ++ show r
  show (ETimer n) = "ETimer " ++ show n
  show ETerminate = "ETerminate"
  show EResume = "EResume"
  show ESuspend = "ESuspend"
  show (EReady fd) = "EReady " ++ show fd
  show EEndOfInput = "EEndOfInput"

-------------------------------------------------------------------------------
-- Loop

export
record Loop where
  constructor MkLoop
  input, output : FileDesc
  epoll : EPoll
  sigfd : FileDesc
  oldMask : SigSet
  timers : IORef (List (Int32, TimerId, FileDesc))   -- (rawfd, id, descriptor)
  watched : IORef (List Int32)                    -- descriptors of `watchFd`
  pending : IORef (List Bits8)
  paste : IORef (Maybe (List (List Bits8), List Bits8))

-- A paste is cut into chunks; this many bytes at the end are held back so
-- that the closing sequence cannot be split between two reads unnoticed.
holdBack : Nat
holdBack = 5

||| Create a loop for a terminal. Call it before `openTerminal`, so that no
||| signal can end the process while the terminal is in raw mode.
export
newLoop : (input : FileDesc) -> (output : FileDesc) -> IO (Either Errno Loop)
newLoop input output = do
  Right set <- sigSetOf [SIGWINCH, SIGINT, SIGTERM, SIGHUP, SIGPIPE, SIGCONT, SIGTSTP, SIGTTOU, SIGTTIN]
    | Left e => pure (Left e)
  Right old <- sigprocmask SIG_BLOCK set
    | Left e => pure (Left e)
  let abort : List (IO ()) -> Errno -> IO (Either Errno Loop)
      abort cleanups e = sequence_ cleanups >> ignore (sigprocmask SIG_SETMASK old) >> pure (Left e)
  Right sfd <- signalfd set (SFD_NONBLOCK .|. SFD_CLOEXEC)
    | Left e => abort [] e
  Right ep <- epollCreate 16
    | Left e => abort [ignore (close sfd)] e
  let closeBoth = [ignore (epollClose ep), ignore (close sfd)]
  Right () <- epollAdd ep input EPOLLIN
    | Left e => abort closeBoth e
  Right () <- epollAdd ep sfd EPOLLIN
    | Left e => abort closeBoth e
  timers <- newIORef []
  pending <- newIORef []
  paste <- newIORef Nothing
  watched <- newIORef []
  pure (Right (MkLoop input output ep sfd old timers watched pending paste))

||| Wait for a descriptor too: `EReady fd` comes when it is readable (the
||| caller reads it, or does what makes it quiet, as it is level-triggered).
export
watchFd : Loop -> FileDesc -> IO (Either Errno ())
watchFd l fd = do
  Right () <- epollAdd l.epoll fd EPOLLIN
    | Left e => pure (Left e)
  modifyIORef l.watched (fd.rawfd ::)
  pure (Right ())

||| Stop and forget a timer.
export
cancelTimer : Loop -> (id : TimerId) -> IO ()
cancelTimer l ident = do
  ts <- readIORef l.timers
  let (gone, kept) = partition (\(_, n, _) => n == ident) ts
  traverse_ (\(_, _, fd) => ignore (epollDel l.epoll fd) >> ignore (close fd)) gone
  writeIORef l.timers kept

armTimer : Loop -> (id : TimerId) -> (ms : Nat) -> (repeat : Bool) -> IO (Either Errno ())
armTimer l ident ms repeat = do
  cancelTimer l ident
  Right fd <- timerfd_create CLOCK_MONOTONIC (TFD_NONBLOCK .|. TFD_CLOEXEC)
    | Left e => pure (Left e)
  -- an all-zero value would disarm the timer
  let ms' = max 1 ms
      span = MkTimeSpec (cast (div ms' 1000)) (cast (mod ms' 1000 * 1000000))
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
addTimer l ident ms = armTimer l (Ticker ident) ms True

||| Start a timer that fires `ETimer id` once, after `ms` milliseconds. The
||| expired timer stays registered until `cancelTimer`.
export
addOneShot : Loop -> (id : Nat) -> (ms : Nat) -> IO (Either Errno ())
addOneShot l ident ms = armTimer l (Shot ident) ms False

||| Close the loop's descriptors and unblock the signals; a signal that is
||| still pending is taken first, so that it cannot kill the process now.
||| The terminal is left as it is.
export
closeLoop : Loop -> IO ()
closeLoop l = do
  ts <- readIORef l.timers
  traverse_ (\(_, _, fd) => close fd) ts
  drain
  _ <- close l.sigfd
  _ <- epollClose l.epoll
  _ <- sigprocmask SIG_SETMASK l.oldMask
  pure ()
  where
    drain : IO ()
    drain = do
      r <- readSignal l.sigfd
      case r of
        Left _ => pure ()
        Right _ => drain

-------------------------------------------------------------------------------
-- Waiting

||| Wait for up to `timeoutMs` milliseconds (-1: for ever) and return what
||| happened; the list is empty when the time ran out.
export
waitEvents : Loop -> (timeoutMs : Int32) -> IO (List Event)
waitEvents l timeoutMs = do
  r <- epollWait l.epoll timeoutMs
  case r of
    Left e => pure (if e == EINTR then [] else [EEndOfInput])
    Right ready => concat <$> traverse handle ready
  where
    sameSignal : Signal -> Signal -> Bool
    sameSignal (MkSignal a) (MkSignal b) = a == b

    drainSignals : IO (List Event)
    drainSignals = go False Nothing False False
      where
        go : (term : Bool) -> (resize : Maybe ()) -> (resume : Bool) -> (stop : Bool) -> IO (List Event)
        go term resize resume stop = do
          r <- readSignal l.sigfd
          case r of
            Left _ => do
              size <- case resize of
                        Just () => (\(c, r') => [EResize c r']) <$> outputSize l.output
                        Nothing => pure []
              pure ((if resume then [EResume] else []) ++ size ++ (if stop then [ESuspend] else [])
                    ++ (if term then [ETerminate] else []))
            Right info =>
              if sameSignal info.signo SIGWINCH then go term (Just ()) resume stop
              else if sameSignal info.signo SIGPIPE || sameSignal info.signo SIGTTOU || sameSignal info.signo SIGTTIN
                      then go term resize resume stop
              else if sameSignal info.signo SIGCONT then go term resize True stop
              else if sameSignal info.signo SIGTSTP then go term resize resume True
              else go True resize resume stop

    -- The bytes of a paste in progress: the closing sequence has come, or more of the body.
    -- (`consume` and `feedPaste` call each other.)
    consume : List Bits8 -> IO (List Event)
    consume new = do
      state <- readIORef l.paste
      case state of
        Just st => feedPaste st new
        Nothing => do
          old <- readIORef l.pending
          let (inputs, rest) = parseInput False (old ++ new)
          if isPrefixOf pasteStart rest
             then do
               writeIORef l.pending []
               cancelTimer l EscapeKey
               writeIORef l.paste (Just ([], []))
               more <- feedPaste ([], []) (drop (length pasteStart) rest)
               pure (map EInput inputs ++ more)
             else do
               writeIORef l.pending rest
               if null rest
                  then cancelTimer l EscapeKey
                  else ignore (armTimer l EscapeKey 30 False)
               pure (map EInput inputs)
      where
        feedPaste : (List (List Bits8), List Bits8) -> List Bits8 -> IO (List Event)
        feedPaste (chunks, hold) new = do
          let dat = hold ++ new
          case splitAtMarker pasteEnd dat of
            Just (before, after) => do
              writeIORef l.paste Nothing
              let body = concat (reverse (before :: chunks))
              rest <- consume after
              pure (EInput (Paste (pack (decode body))) :: rest)
            Nothing => do
              let cut = length dat `minus` holdBack
              writeIORef l.paste (Just (take cut dat :: chunks, drop cut dat))
              pure []

    readInput : IO (List Event)
    readInput = do
      r <- readBytes l.input
      case r of
        Left e => pure (if e == EINTR || e == EAGAIN then [] else [EEndOfInput])
        Right [] => pure [EEndOfInput]
        Right bytes => consume bytes

    -- Nothing followed an ESC (or the beginning of a sequence) for long enough:
    -- decode what is there as it stands. A paste in progress is not cut.
    flushPending : IO (List Event)
    flushPending = do
      state <- readIORef l.paste
      case state of
        Just _ => pure []
        Nothing => do
          held <- readIORef l.pending
          writeIORef l.pending []
          pure (map EInput (fst (parseInput True held)))

    fireTimer : Int32 -> IO (List Event)
    fireTimer raw = do
      ts <- readIORef l.timers
      case find (\(fd, _, _) => fd == raw) ts of
        Nothing => pure []
        Just (_, ident, fd) => do
          _ <- timerfd_read fd
          if ident == EscapeKey
             then cancelTimer l ident >> flushPending
             else pure [ETimer ident]

    handle : ReadyEvent -> IO (List Event)
    handle e =
      if e.fd == l.input.rawfd then readInput
      else if e.fd == l.sigfd.rawfd then drainSignals
      else do
        ws <- readIORef l.watched
        if elem e.fd ws then pure [EReady e.fd] else fireTimer e.fd
