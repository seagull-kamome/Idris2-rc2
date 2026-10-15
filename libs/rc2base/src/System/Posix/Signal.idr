||| Signal numbers, signal sets (`sigprocmask`, `sigpending`, `sigwait`) and
||| `raise`/`alarm`/`pause`.
|||
||| A handler cannot be an Idris function (there is no C function pointer to
||| one), so signals are taken synchronously: block them with `sigprocmask`
||| and then `sigwait`, or read them from a `signalfd`
||| (`System.Linux.Signalfd`).
module System.Posix.Signal

import System.FFI
import System.Posix.Errno
import System.Posix.Time

%default total



public export data Signal = MkSignal Int32
export
Cast Int32 Signal where cast x = MkSignal x
export
Cast Signal Int32 where cast (MkSignal x) = x
export
Show Signal where
  show (MkSignal x) = "Signal " ++ show x

-------------------------------------------------------------------------------
-- Signals

%inline %foreign "CExpr:(SIGHUP),libc,signal.h"
prim__SIGHUP : Int32
||| Hangup detected on the controlling terminal.
public export SIGHUP : Signal
SIGHUP = MkSignal prim__SIGHUP

%inline %foreign "CExpr:(SIGINT),libc,signal.h"
prim__SIGINT : Int32
||| Interrupt from the keyboard.
public export SIGINT : Signal
SIGINT = MkSignal prim__SIGINT

%inline %foreign "CExpr:(SIGQUIT),libc,signal.h"
prim__SIGQUIT : Int32
||| Quit from the keyboard (core dump).
public export SIGQUIT : Signal
SIGQUIT = MkSignal prim__SIGQUIT

%inline %foreign "CExpr:(SIGILL),libc,signal.h"
prim__SIGILL : Int32
||| Illegal instruction.
public export SIGILL : Signal
SIGILL = MkSignal prim__SIGILL

%inline %foreign "CExpr:(SIGTRAP),libc,signal.h"
prim__SIGTRAP : Int32
||| Trace or breakpoint trap.
public export SIGTRAP : Signal
SIGTRAP = MkSignal prim__SIGTRAP

%inline %foreign "CExpr:(SIGABRT),libc,signal.h"
prim__SIGABRT : Int32
||| Abort signal from `abort(3)`.
public export SIGABRT : Signal
SIGABRT = MkSignal prim__SIGABRT

%inline %foreign "CExpr:(SIGBUS),libc,signal.h"
prim__SIGBUS : Int32
||| Bus error (bad memory access).
public export SIGBUS : Signal
SIGBUS = MkSignal prim__SIGBUS

%inline %foreign "CExpr:(SIGFPE),libc,signal.h"
prim__SIGFPE : Int32
||| Arithmetic exception.
public export SIGFPE : Signal
SIGFPE = MkSignal prim__SIGFPE

%inline %foreign "CExpr:(SIGKILL),libc,signal.h"
prim__SIGKILL : Int32
||| Kill; cannot be caught, blocked or ignored.
public export SIGKILL : Signal
SIGKILL = MkSignal prim__SIGKILL

%inline %foreign "CExpr:(SIGUSR1),libc,signal.h"
prim__SIGUSR1 : Int32
||| User-defined signal 1.
public export SIGUSR1 : Signal
SIGUSR1 = MkSignal prim__SIGUSR1

%inline %foreign "CExpr:(SIGSEGV),libc,signal.h"
prim__SIGSEGV : Int32
||| Invalid memory reference.
public export SIGSEGV : Signal
SIGSEGV = MkSignal prim__SIGSEGV

%inline %foreign "CExpr:(SIGUSR2),libc,signal.h"
prim__SIGUSR2 : Int32
||| User-defined signal 2.
public export SIGUSR2 : Signal
SIGUSR2 = MkSignal prim__SIGUSR2

%inline %foreign "CExpr:(SIGPIPE),libc,signal.h"
prim__SIGPIPE : Int32
||| Write to a pipe or socket with no reader.
public export SIGPIPE : Signal
SIGPIPE = MkSignal prim__SIGPIPE

%inline %foreign "CExpr:(SIGALRM),libc,signal.h"
prim__SIGALRM : Int32
||| Timer signal from `alarm(2)`.
public export SIGALRM : Signal
SIGALRM = MkSignal prim__SIGALRM

%inline %foreign "CExpr:(SIGTERM),libc,signal.h"
prim__SIGTERM : Int32
||| Termination request.
public export SIGTERM : Signal
SIGTERM = MkSignal prim__SIGTERM

%inline %foreign "CExpr:(SIGSTKFLT),libc,signal.h"
prim__SIGSTKFLT : Int32
||| Stack fault on a coprocessor. Linux only (not on BSD); not in POSIX. See `signal(7)`.
public export SIGSTKFLT : Signal
SIGSTKFLT = MkSignal prim__SIGSTKFLT

%inline %foreign "CExpr:(SIGCHLD),libc,signal.h"
prim__SIGCHLD : Int32
||| Child stopped or terminated.
public export SIGCHLD : Signal
SIGCHLD = MkSignal prim__SIGCHLD

%inline %foreign "CExpr:(SIGCONT),libc,signal.h"
prim__SIGCONT : Int32
||| Continue if stopped.
public export SIGCONT : Signal
SIGCONT = MkSignal prim__SIGCONT

%inline %foreign "CExpr:(SIGSTOP),libc,signal.h"
prim__SIGSTOP : Int32
||| Stop the process; cannot be caught, blocked or ignored.
public export SIGSTOP : Signal
SIGSTOP = MkSignal prim__SIGSTOP

%inline %foreign "CExpr:(SIGTSTP),libc,signal.h"
prim__SIGTSTP : Int32
||| Stop typed at the terminal.
public export SIGTSTP : Signal
SIGTSTP = MkSignal prim__SIGTSTP

%inline %foreign "CExpr:(SIGTTIN),libc,signal.h"
prim__SIGTTIN : Int32
||| Background process read from the terminal.
public export SIGTTIN : Signal
SIGTTIN = MkSignal prim__SIGTTIN

%inline %foreign "CExpr:(SIGTTOU),libc,signal.h"
prim__SIGTTOU : Int32
||| Background process wrote to the terminal.
public export SIGTTOU : Signal
SIGTTOU = MkSignal prim__SIGTTOU



-------------------------------------------------------------------------------
-- Signal sets

||| An opaque `sigset_t`.
public export
data RawSigSet : Type where [external]

||| A signal set, freed when it is garbage collected.
public export
SigSet : Type
SigSet = GCPtr RawSigSet

%inline %foreign "CExpr:(sizeof(sigset_t)),libc,signal.h"
prim__sizeofSigset : Int
%inline %foreign "CExpr:(sigemptyset((sigset_t *)($1))),libc,signal.h"
prim__sigemptyset : GCPtr RawSigSet -> PrimIO Int32
%inline %foreign "CExpr:(sigfillset((sigset_t *)($1))),libc,signal.h"
prim__sigfillset : GCPtr RawSigSet -> PrimIO Int32
%inline %foreign "CExpr:(sigaddset((sigset_t *)($1), $2)),libc,signal.h"
prim__sigaddset : GCPtr RawSigSet -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(sigdelset((sigset_t *)($1), $2)),libc,signal.h"
prim__sigdelset : GCPtr RawSigSet -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(sigismember((sigset_t *)($1), $2)),libc,signal.h"
prim__sigismember : GCPtr RawSigSet -> Int32 -> PrimIO Int32

newRaw : IO SigSet
newRaw = do
  p <- malloc prim__sizeofSigset >>= pure . prim__castPtr
  onCollect p (\x => free (prim__forgetPtr x))

||| A signal set with no signals.
export
emptySigSet : IO SigSet
emptySigSet = do
  s <- newRaw
  _ <- primIO (prim__sigemptyset s)
  pure s

||| A signal set with every signal.
export
fullSigSet : IO SigSet
fullSigSet = do
  s <- newRaw
  _ <- primIO (prim__sigfillset s)
  pure s

||| A set holding exactly the given signals (`EINVAL` for an invalid number).
export
sigSetOf : List Signal -> IO (Either Errno SigSet)
sigSetOf sigs = do
  s <- emptySigSet
  go s sigs
  where
    go : SigSet -> List Signal -> IO (Either Errno SigSet)
    go s [] = pure (Right s)
    go s (MkSignal n :: rest) = do
      r <- primIO (prim__sigaddset s n)
      if r == 0 then go s rest else Left <$> errno

||| Add a signal to the set.
export
sigaddset : SigSet -> Signal -> IO (Either Errno ())
sigaddset s (MkSignal n) = primIO (prim__sigaddset s n) >>= checkUnit

||| Remove a signal from the set.
export
sigdelset : SigSet -> Signal -> IO (Either Errno ())
sigdelset s (MkSignal n) = primIO (prim__sigdelset s n) >>= checkUnit

||| Is the signal in the set? An invalid signal number counts as not in the set.
export
sigismember : SigSet -> Signal -> IO Bool
sigismember s (MkSignal n) = (== 1) <$> primIO (prim__sigismember s n)

-------------------------------------------------------------------------------
-- Masking, waiting, raising

||| How `sigprocmask` combines the set with the current mask.
public export
data MaskHow = MkMaskHow Int32

%inline %foreign "CExpr:(SIG_BLOCK),libc,signal.h"
prim__SIG_BLOCK : Int32
%inline %foreign "CExpr:(SIG_UNBLOCK),libc,signal.h"
prim__SIG_UNBLOCK : Int32
%inline %foreign "CExpr:(SIG_SETMASK),libc,signal.h"
prim__SIG_SETMASK : Int32

||| Add the set to the blocked signals.
export SIG_BLOCK : MaskHow
SIG_BLOCK = MkMaskHow prim__SIG_BLOCK
||| Remove the set from the blocked signals.
export SIG_UNBLOCK : MaskHow
SIG_UNBLOCK = MkMaskHow prim__SIG_UNBLOCK
||| Replace the blocked signals with the set.
export SIG_SETMASK : MaskHow
SIG_SETMASK = MkMaskHow prim__SIG_SETMASK

%inline %foreign "CExpr:(sigprocmask($1, (sigset_t *)($2), (sigset_t *)($3))),libc,signal.h"
prim__sigprocmask : Int32 -> GCPtr RawSigSet -> GCPtr RawSigSet -> PrimIO Int32
%inline %foreign "CExpr:(sigpending((sigset_t *)($1))),libc,signal.h"
prim__sigpending : GCPtr RawSigSet -> PrimIO Int32
%inline %foreign "CExpr:(sigwait((sigset_t *)($1), (int *)($2))),libc,signal.h"
prim__sigwait : GCPtr RawSigSet -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(*(int *)($1)),libc,signal.h"
prim__intAt : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sizeof(int)),libc,signal.h"
prim__sizeofInt : Int

||| Change the calling thread's blocked signals; returns the previous mask.
||| (In a program with several threads each thread has its own mask.)
export
sigprocmask : MaskHow -> SigSet -> IO (Either Errno SigSet)
sigprocmask (MkMaskHow how) s = do
  old <- emptySigSet
  r <- primIO (prim__sigprocmask how s old)
  if r == 0 then pure (Right old) else Left <$> errno

||| The signals that are blocked and pending for the calling thread.
export
sigpending : IO (Either Errno SigSet)
sigpending = do
  s <- emptySigSet
  r <- primIO (prim__sigpending s)
  if r == 0 then pure (Right s) else Left <$> errno

||| Wait for one of the signals in the set (which should be blocked) and take it.
export
sigwait : SigSet -> IO (Either Errno Signal)
sigwait s = do
  buf <- malloc prim__sizeofInt
  r <- primIO (prim__sigwait s buf)
  res <- if r == 0
            then do n <- primIO (prim__intAt buf)
                    pure (Right (MkSignal n))
            else pure (Left (MkErrno r))
  free buf
  pure res

%inline %foreign "CExpr:(sigtimedwait((sigset_t *)($1), NULL, (struct timespec *)($2))),libc,signal.h;time.h"
prim__sigtimedwait : GCPtr RawSigSet -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sigsuspend((sigset_t *)($1))),libc,signal.h"
prim__sigsuspend : GCPtr RawSigSet -> PrimIO Int32

||| `sigwait` that gives up after the time: `Left EAGAIN` on timeout,
||| `Left EINTR` when an unblocked signal was handled first.
export
sigtimedwait : SigSet -> TimeSpec -> IO (Either Errno Signal)
sigtimedwait s t = withTimeSpec $ \p => do
  writeTimeSpec p t
  r <- primIO (prim__sigtimedwait s p)
  if r >= 0 then pure (Right (MkSignal r)) else Left <$> errno

||| Replace the signal mask by the set and sleep until a signal that is
||| handled or terminates the process arrives; the old mask comes back
||| afterwards. Returns `EINTR`.
export
sigsuspend : SigSet -> IO Errno
sigsuspend s = do
  _ <- primIO (prim__sigsuspend s)
  errno

%inline %foreign "CExpr:(raise($1)),libc,signal.h"
prim__raise : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(alarm($1)),libc,unistd.h"
prim__alarm : Bits32 -> PrimIO Bits32
%inline %foreign "CExpr:(pause()),libc,unistd.h"
prim__pause : PrimIO Int32

||| Send a signal to the calling thread.
export
raise : Signal -> IO (Either Errno ())
raise (MkSignal n) = primIO (prim__raise n) >>= checkUnit

||| Deliver `SIGALRM` after that many seconds (0 cancels); returns the seconds
||| left of the previous alarm.
export
alarm : Bits32 -> IO Bits32
alarm n = primIO (prim__alarm n)

||| Sleep until a signal that is handled or terminates the process arrives.
||| With the default `SIGALRM` action the process terminates; use `sigwait`
||| for an alarm that is taken as a value. Returns `EINTR`.
export
pause : IO Errno
pause = do
  _ <- primIO prim__pause
  errno

-------------------------------------------------------------------------------
-- More signals

%inline %foreign "CExpr:(SIGURG),libc,signal.h"
prim__SIGURG : Int32
%inline %foreign "CExpr:(SIGXCPU),libc,signal.h"
prim__SIGXCPU : Int32
%inline %foreign "CExpr:(SIGXFSZ),libc,signal.h"
prim__SIGXFSZ : Int32
%inline %foreign "CExpr:(SIGVTALRM),libc,signal.h"
prim__SIGVTALRM : Int32
%inline %foreign "CExpr:(SIGPROF),libc,signal.h"
prim__SIGPROF : Int32
%inline %foreign "CExpr:(SIGSYS),libc,signal.h"
prim__SIGSYS : Int32
%inline %foreign "CExpr:(SIGWINCH),libc,signal.h"
prim__SIGWINCH : Int32
%inline %foreign "CExpr:(SIGIO),libc,signal.h"
prim__SIGIO : Int32

||| Urgent condition on a socket.
public export SIGURG : Signal
SIGURG = MkSignal prim__SIGURG
||| CPU time limit exceeded.
public export SIGXCPU : Signal
SIGXCPU = MkSignal prim__SIGXCPU
||| File size limit exceeded.
public export SIGXFSZ : Signal
SIGXFSZ = MkSignal prim__SIGXFSZ
||| Virtual alarm clock.
public export SIGVTALRM : Signal
SIGVTALRM = MkSignal prim__SIGVTALRM
||| Profiling timer expired.
public export SIGPROF : Signal
SIGPROF = MkSignal prim__SIGPROF
||| Bad system call.
public export SIGSYS : Signal
SIGSYS = MkSignal prim__SIGSYS
||| The terminal window was resized (not in POSIX; Linux and BSD).
public export SIGWINCH : Signal
SIGWINCH = MkSignal prim__SIGWINCH
||| I/O is possible on a descriptor (not in POSIX; Linux and BSD).
public export SIGIO : Signal
SIGIO = MkSignal prim__SIGIO
