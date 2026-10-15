||| Clocks that only Linux has, for `System.Posix.Time.clock_gettime`.
|||
||| `System.Linux.Timerfd.timerfd_create` takes only `CLOCK_REALTIME`,
||| `CLOCK_MONOTONIC`, `CLOCK_BOOTTIME` and the two `*_ALARM` clocks below; the
||| other clocks give `EINVAL`.
module System.Linux.Clock

import System.Posix.Time

%default total

%inline %foreign "CExpr:(CLOCK_MONOTONIC_RAW),libc,time.h"
prim__CLOCK_MONOTONIC_RAW : Int32
%inline %foreign "CExpr:(CLOCK_REALTIME_COARSE),libc,time.h"
prim__CLOCK_REALTIME_COARSE : Int32
%inline %foreign "CExpr:(CLOCK_MONOTONIC_COARSE),libc,time.h"
prim__CLOCK_MONOTONIC_COARSE : Int32
%inline %foreign "CExpr:(CLOCK_BOOTTIME),libc,time.h"
prim__CLOCK_BOOTTIME : Int32
%inline %foreign "CExpr:(CLOCK_TAI),libc,time.h"
prim__CLOCK_TAI : Int32
%inline %foreign "CExpr:(CLOCK_REALTIME_ALARM),libc,time.h"
prim__CLOCK_REALTIME_ALARM : Int32
%inline %foreign "CExpr:(CLOCK_BOOTTIME_ALARM),libc,time.h"
prim__CLOCK_BOOTTIME_ALARM : Int32

||| Monotonic time not adjusted by NTP slewing.
export CLOCK_MONOTONIC_RAW : ClockId
CLOCK_MONOTONIC_RAW = MkClockId prim__CLOCK_MONOTONIC_RAW
||| A faster, less precise `CLOCK_REALTIME`.
export CLOCK_REALTIME_COARSE : ClockId
CLOCK_REALTIME_COARSE = MkClockId prim__CLOCK_REALTIME_COARSE
||| A faster, less precise `CLOCK_MONOTONIC`.
export CLOCK_MONOTONIC_COARSE : ClockId
CLOCK_MONOTONIC_COARSE = MkClockId prim__CLOCK_MONOTONIC_COARSE
||| Like `CLOCK_MONOTONIC`, but counts the time the system is suspended.
export CLOCK_BOOTTIME : ClockId
CLOCK_BOOTTIME = MkClockId prim__CLOCK_BOOTTIME
||| International Atomic Time.
export CLOCK_TAI : ClockId
CLOCK_TAI = MkClockId prim__CLOCK_TAI
||| Like `CLOCK_REALTIME`; a timer on it wakes a suspended system (needs `CAP_WAKE_ALARM`).
export CLOCK_REALTIME_ALARM : ClockId
CLOCK_REALTIME_ALARM = MkClockId prim__CLOCK_REALTIME_ALARM
||| Like `CLOCK_BOOTTIME`; a timer on it wakes a suspended system (needs `CAP_WAKE_ALARM`).
export CLOCK_BOOTTIME_ALARM : ClockId
CLOCK_BOOTTIME_ALARM = MkClockId prim__CLOCK_BOOTTIME_ALARM
