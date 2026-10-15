||| `timerfd`: timers that are read from a file descriptor, so they can be
||| waited on with `poll` or `System.Linux.Epoll`.
|||
||| Linux only.
module System.Linux.Timerfd

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Time

%default total

||| The setting of a timer: first expiry after `value`, then every `interval`
||| (an `interval` of zero makes it one-shot, a `value` of zero disarms it).
||| The constructor takes `interval` first: `MkITimerSpec interval value`.
public export
record ITimerSpec where
  constructor MkITimerSpec
  interval : TimeSpec
  value : TimeSpec

export
Show ITimerSpec where
  show t = "ITimerSpec " ++ show t.interval ++ " " ++ show t.value

export
Eq ITimerSpec where
  a == b = a.interval == b.interval && a.value == b.value

%inline %foreign "CExpr:(TFD_NONBLOCK),libc,sys/timerfd.h"
export TFD_NONBLOCK : Bits32
%inline %foreign "CExpr:(TFD_CLOEXEC),libc,sys/timerfd.h"
export TFD_CLOEXEC : Bits32
%inline %foreign "CExpr:(TFD_TIMER_ABSTIME),libc,sys/timerfd.h"
export TFD_TIMER_ABSTIME : Bits32

%inline %foreign "CExpr:(sizeof(struct itimerspec)),libc,sys/timerfd.h;time.h"
prim__sizeofItimerspec : Int
%inline %foreign "CExpr:(&((struct itimerspec *)($1))->it_interval),libc,sys/timerfd.h;time.h"
prim__it_interval : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(&((struct itimerspec *)($1))->it_value),libc,sys/timerfd.h;time.h"
prim__it_value : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(timerfd_create($1, $2)),libc,sys/timerfd.h"
prim__timerfd_create : Int32 -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(timerfd_settime($1, $2, (struct itimerspec *)($3), (struct itimerspec *)($4))),libc,sys/timerfd.h"
prim__timerfd_settime : Bits32 -> Bits32 -> AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(timerfd_gettime($1, (struct itimerspec *)($2))),libc,sys/timerfd.h"
prim__timerfd_gettime : Bits32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(read($1, $2, 8)),libc,unistd.h"
prim__read8 : Bits32 -> AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(*(uint64_t *)($1)),libc,stdint.h"
prim__u64At : AnyPtr -> PrimIO Bits64

readITimerSpec : AnyPtr -> IO ITimerSpec
readITimerSpec p = do
  i <- primIO (prim__it_interval p) >>= readTimeSpec
  v <- primIO (prim__it_value p) >>= readTimeSpec
  pure (MkITimerSpec i v)

writeITimerSpec : AnyPtr -> ITimerSpec -> IO ()
writeITimerSpec p t = do
  primIO (prim__it_interval p) >>= \q => writeTimeSpec q t.interval
  primIO (prim__it_value p) >>= \q => writeTimeSpec q t.value

||| Create a timer on a clock. `flags` is an `or` of `TFD_NONBLOCK` and `TFD_CLOEXEC`.
export
timerfd_create : ClockId -> (flags : Bits32) -> IO (Either Errno FileDesc)
timerfd_create (MkClockId c) flags = do
  r <- primIO (prim__timerfd_create c flags)
  primFdToFileDesc r

||| Arm or disarm a timer (`flags` is 0 or `TFD_TIMER_ABSTIME`); returns the previous setting.
export
timerfd_settime : FileDesc -> (flags : Bits32) -> ITimerSpec -> IO (Either Errno ITimerSpec)
timerfd_settime fd flags new = do
  n <- malloc prim__sizeofItimerspec
  o <- malloc prim__sizeofItimerspec
  writeITimerSpec n new
  r <- primIO (prim__timerfd_settime fd.rawfd flags n o)
  res <- if r == 0 then Right <$> readITimerSpec o else Left <$> errno
  free n
  free o
  pure res

||| The current setting of a timer: the time to the next expiry and the interval.
export
timerfd_gettime : FileDesc -> IO (Either Errno ITimerSpec)
timerfd_gettime fd = do
  p <- malloc prim__sizeofItimerspec
  r <- primIO (prim__timerfd_gettime fd.rawfd p)
  res <- if r == 0 then Right <$> readITimerSpec p else Left <$> errno
  free p
  pure res

||| Read the number of expirations since the last read. Blocks until the timer
||| expires, or `Left EAGAIN` for a `TFD_NONBLOCK` timer that has not.
export
timerfd_read : FileDesc -> IO (Either Errno Bits64)
timerfd_read fd = do
  p <- malloc 8
  n <- primIO (prim__read8 fd.rawfd p)
  res <- if n < 0 then Left <$> errno else Right <$> primIO (prim__u64At p)
  free p
  pure res
