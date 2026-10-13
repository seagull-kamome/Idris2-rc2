module System.Posix.Signal



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

