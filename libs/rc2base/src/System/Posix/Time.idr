||| POSIX time: `clock_gettime`/`clock_getres`, `nanosleep`, `time`, and the
||| broken-down time of `<time.h>` (`gmtime_r`, `localtime_r`, `mktime`,
||| `strftime`).
|||
||| `struct timespec` and `struct tm` are copied into the Idris records
||| `TimeSpec` and `Tm` at once, so no C struct is visible to the caller.
||| Clocks that only Linux has (`CLOCK_MONOTONIC_RAW`, `CLOCK_BOOTTIME`, ...)
||| are in `System.Linux.Clock`.
|||
||| A `Tm` carries `tm_gmtoff` and `tm_zone` (BSD/glibc extensions of `struct tm`,
||| visible by default; a strict `-std=c11` build hides them), so `strftime`'s `%z` and
||| `%Z` show the zone of a `Tm` made by `localtime`.
module System.Posix.Time

import Data.String
import Data.String.FFI
import System.FFI
import System.Posix.Errno

%default total

-------------------------------------------------------------------------------
-- TimeSpec

||| A `struct timespec`: seconds and nanoseconds.
public export
record TimeSpec where
  constructor MkTimeSpec
  tvSec : Int64
  tvNsec : Int64

export
Show TimeSpec where
  show t = "TimeSpec " ++ show t.tvSec ++ " " ++ show t.tvNsec

export
Eq TimeSpec where
  a == b = a.tvSec == b.tvSec && a.tvNsec == b.tvNsec

export
Ord TimeSpec where
  compare a b = compare (a.tvSec, a.tvNsec) (b.tvSec, b.tvNsec)

%inline %foreign "CExpr:(sizeof(struct timespec)),libc,time.h"
export prim__sizeofTimespec : Int

%inline %foreign "CExpr:(((struct timespec *)($1))->tv_sec),libc,time.h"
prim__get_tv_sec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct timespec *)($1))->tv_nsec),libc,time.h"
prim__get_tv_nsec : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:(((struct timespec *)($1))->tv_sec = ($2)),libc,time.h"
prim__set_tv_sec : AnyPtr -> Int64 -> PrimIO Int64
%inline %foreign "CExpr:(((struct timespec *)($1))->tv_nsec = ($2)),libc,time.h"
prim__set_tv_nsec : AnyPtr -> Int64 -> PrimIO Int64

||| Read a `struct timespec` at the pointer.
export
readTimeSpec : AnyPtr -> IO TimeSpec
readTimeSpec p = do
  s <- primIO (prim__get_tv_sec p)
  n <- primIO (prim__get_tv_nsec p)
  pure (MkTimeSpec s n)

||| Write a `TimeSpec` into the `struct timespec` at the pointer.
export
writeTimeSpec : AnyPtr -> TimeSpec -> IO ()
writeTimeSpec p t = do
  _ <- primIO (prim__set_tv_sec p t.tvSec)
  _ <- primIO (prim__set_tv_nsec p t.tvNsec)
  pure ()

||| Run an action on a freshly allocated `struct timespec`.
export
withTimeSpec : (AnyPtr -> IO a) -> IO a
withTimeSpec act = do
  p <- malloc prim__sizeofTimespec
  r <- act p
  free p
  pure r

-------------------------------------------------------------------------------
-- Clocks

||| A clock identifier (`clockid_t`).
public export
data ClockId = MkClockId Int32

export
Show ClockId where
  show (MkClockId c) = "ClockId " ++ show c

%inline %foreign "CExpr:(CLOCK_REALTIME),libc,time.h"
prim__CLOCK_REALTIME : Int32
%inline %foreign "CExpr:(CLOCK_MONOTONIC),libc,time.h"
prim__CLOCK_MONOTONIC : Int32
%inline %foreign "CExpr:(CLOCK_PROCESS_CPUTIME_ID),libc,time.h"
prim__CLOCK_PROCESS_CPUTIME_ID : Int32
%inline %foreign "CExpr:(CLOCK_THREAD_CPUTIME_ID),libc,time.h"
prim__CLOCK_THREAD_CPUTIME_ID : Int32

||| The system-wide wall clock; can jump when the time is set.
export CLOCK_REALTIME : ClockId
CLOCK_REALTIME = MkClockId prim__CLOCK_REALTIME
||| A clock that never goes backwards (a POSIX option every mainstream system has).
export CLOCK_MONOTONIC : ClockId
CLOCK_MONOTONIC = MkClockId prim__CLOCK_MONOTONIC
||| The CPU time used by the calling process.
export CLOCK_PROCESS_CPUTIME_ID : ClockId
CLOCK_PROCESS_CPUTIME_ID = MkClockId prim__CLOCK_PROCESS_CPUTIME_ID
||| The CPU time used by the calling thread.
export CLOCK_THREAD_CPUTIME_ID : ClockId
CLOCK_THREAD_CPUTIME_ID = MkClockId prim__CLOCK_THREAD_CPUTIME_ID

%inline %foreign "CExpr:(clock_gettime($1, (struct timespec *)($2))),libc,time.h"
prim__clock_gettime : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(clock_getres($1, (struct timespec *)($2))),libc,time.h"
prim__clock_getres : Int32 -> AnyPtr -> PrimIO Int32

||| The current value of a clock.
export
clock_gettime : ClockId -> IO (Either Errno TimeSpec)
clock_gettime (MkClockId c) = withTimeSpec $ \p => do
  r <- primIO (prim__clock_gettime c p)
  case r of
       0 => Right <$> readTimeSpec p
       _ => Left <$> errno

||| The resolution of a clock.
export
clock_getres : ClockId -> IO (Either Errno TimeSpec)
clock_getres (MkClockId c) = withTimeSpec $ \p => do
  r <- primIO (prim__clock_getres c p)
  case r of
       0 => Right <$> readTimeSpec p
       _ => Left <$> errno

%inline %foreign "CExpr:(nanosleep((struct timespec *)($1), NULL)),libc,time.h"
prim__nanosleep : AnyPtr -> PrimIO Int32

||| Sleep for the given time. `Left EINTR` when a signal interrupted the sleep
||| (the remaining time is not returned: ask the clock again to resume).
export
nanosleep : TimeSpec -> IO (Either Errno ())
nanosleep t = withTimeSpec $ \p => do
  writeTimeSpec p t
  primIO (prim__nanosleep p) >>= checkUnit

%inline %foreign "CExpr:(time(NULL)),libc,time.h"
prim__time : PrimIO Int64

||| The current time in seconds since the Epoch (`time(NULL)`).
export
time : IO Int64
time = primIO prim__time

-------------------------------------------------------------------------------
-- Broken-down time

||| A `struct tm`: the standard fields plus `tm_gmtoff` and `tm_zone`. `year`
||| counts from 1900 and `mon` from 0, as in C.
|||
||| `tmGmtoff` is the offset east of UTC in seconds and `tmZone` the zone
||| abbreviation (`Nothing` when C leaves it NULL). `gmtime` and `localtime` fill them;
||| `mktime` ignores them (it works from the local zone) and `strftime` uses them for
||| `%z` and `%Z`. A `Tm` you build by hand gets `0` and `Nothing` from `mkTm`.
public export
record Tm where
  constructor MkTm
  tmSec : Int32
  tmMin : Int32
  tmHour : Int32
  tmMday : Int32
  tmMon : Int32
  tmYear : Int32
  tmWday : Int32
  tmYday : Int32
  tmIsdst : Int32
  tmGmtoff : Int64
  tmZone : Maybe String

||| A `Tm` from the nine standard fields, with no zone information.
export
mkTm : (sec, min, hour, mday, mon, year, wday, yday, isdst : Int32) -> Tm
mkTm s mi h d mo y w yd dst = MkTm s mi h d mo y w yd dst 0 Nothing

export
Show Tm where
  show t = "Tm " ++ unwords (map show [t.tmSec, t.tmMin, t.tmHour, t.tmMday, t.tmMon, t.tmYear, t.tmWday, t.tmYday, t.tmIsdst])
        ++ " " ++ show t.tmGmtoff ++ " " ++ show t.tmZone

export
Eq Tm where
  a == b = a.tmSec == b.tmSec && a.tmMin == b.tmMin && a.tmHour == b.tmHour && a.tmMday == b.tmMday
        && a.tmMon == b.tmMon && a.tmYear == b.tmYear && a.tmWday == b.tmWday && a.tmYday == b.tmYday
        && a.tmIsdst == b.tmIsdst && a.tmGmtoff == b.tmGmtoff && a.tmZone == b.tmZone

%inline %foreign "CExpr:(sizeof(struct tm)),libc,time.h"
prim__sizeofTm : Int
%inline %foreign "CExpr:(memset($1, 0, sizeof(struct tm)), 0),libc,time.h;string.h"
prim__zeroTm : AnyPtr -> PrimIO Int32

%inline %foreign "CExpr:(((struct tm *)($1))->tm_sec),libc,time.h"
prim__get_tm_sec : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_min),libc,time.h"
prim__get_tm_min : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_hour),libc,time.h"
prim__get_tm_hour : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_mday),libc,time.h"
prim__get_tm_mday : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_mon),libc,time.h"
prim__get_tm_mon : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_year),libc,time.h"
prim__get_tm_year : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_wday),libc,time.h"
prim__get_tm_wday : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_yday),libc,time.h"
prim__get_tm_yday : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_isdst),libc,time.h"
prim__get_tm_isdst : AnyPtr -> PrimIO Int32

%inline %foreign "CExpr:(((struct tm *)($1))->tm_sec = ($2)),libc,time.h"
prim__set_tm_sec : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_min = ($2)),libc,time.h"
prim__set_tm_min : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_hour = ($2)),libc,time.h"
prim__set_tm_hour : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_mday = ($2)),libc,time.h"
prim__set_tm_mday : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_mon = ($2)),libc,time.h"
prim__set_tm_mon : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_year = ($2)),libc,time.h"
prim__set_tm_year : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_wday = ($2)),libc,time.h"
prim__set_tm_wday : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_yday = ($2)),libc,time.h"
prim__set_tm_yday : AnyPtr -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(((struct tm *)($1))->tm_isdst = ($2)),libc,time.h"
prim__set_tm_isdst : AnyPtr -> Int32 -> PrimIO Int32

%inline %foreign "CExpr:(((struct tm *)($1))->tm_gmtoff),libc,time.h"
prim__get_tm_gmtoff : AnyPtr -> PrimIO Int64
%inline %foreign "CExpr:((void *)(((struct tm *)($1))->tm_zone)),libc,time.h"
prim__get_tm_zone : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(((struct tm *)($1))->tm_gmtoff = ($2)),libc,time.h"
prim__set_tm_gmtoff : AnyPtr -> Int64 -> PrimIO Int64
-- A malloc'd copy, so the cell outlives the Idris string; `clearTmZone` frees it.
%inline %foreign "CExpr:(((struct tm *)($1))->tm_zone = strdup($2), 0),libc,time.h;string.h"
prim__set_tm_zone : AnyPtr -> String -> PrimIO Int32
%inline %foreign "CExpr:(free((void *)((struct tm *)($1))->tm_zone), ((struct tm *)($1))->tm_zone = NULL, 0),libc,time.h;stdlib.h"
prim__free_tm_zone : AnyPtr -> PrimIO Int32

readTm : AnyPtr -> IO Tm
readTm p = do
  s <- primIO (prim__get_tm_sec p)
  mi <- primIO (prim__get_tm_min p)
  h <- primIO (prim__get_tm_hour p)
  d <- primIO (prim__get_tm_mday p)
  mo <- primIO (prim__get_tm_mon p)
  y <- primIO (prim__get_tm_year p)
  w <- primIO (prim__get_tm_wday p)
  yd <- primIO (prim__get_tm_yday p)
  dst <- primIO (prim__get_tm_isdst p)
  off <- primIO (prim__get_tm_gmtoff p)
  zone <- primIO (prim__get_tm_zone p)
  pure (MkTm s mi h d mo y w yd dst off (ptrToString zone))

writeTm : AnyPtr -> Tm -> IO ()
writeTm p t = do
  _ <- primIO (prim__zeroTm p)
  _ <- primIO (prim__set_tm_sec p t.tmSec)
  _ <- primIO (prim__set_tm_min p t.tmMin)
  _ <- primIO (prim__set_tm_hour p t.tmHour)
  _ <- primIO (prim__set_tm_mday p t.tmMday)
  _ <- primIO (prim__set_tm_mon p t.tmMon)
  _ <- primIO (prim__set_tm_year p t.tmYear)
  _ <- primIO (prim__set_tm_wday p t.tmWday)
  _ <- primIO (prim__set_tm_yday p t.tmYday)
  _ <- primIO (prim__set_tm_isdst p t.tmIsdst)
  pure ()

-- Write the zone fields too, for `strftime`. `tm_zone` of the struct is then a
-- malloc'd copy that the caller must release with `clearTmZone`. `mktime` does not
-- use this: it overwrites `tm_zone` with a pointer into libc's own zone table.
writeTmZone : AnyPtr -> Tm -> IO ()
writeTmZone p t = do
  writeTm p t
  _ <- primIO (prim__set_tm_gmtoff p t.tmGmtoff)
  case t.tmZone of
       Nothing => pure ()
       Just z => ignore (primIO (prim__set_tm_zone p z))

clearTmZone : AnyPtr -> IO ()
clearTmZone p = ignore (primIO (prim__free_tm_zone p))

withTm : (AnyPtr -> IO a) -> IO a
withTm act = do
  p <- malloc prim__sizeofTm
  r <- act p
  free p
  pure r

-- A time_t cell for the pointer argument of gmtime_r/localtime_r.
%inline %foreign "CExpr:(*(time_t *)($1) = ($2)),libc,time.h"
prim__set_time_t : AnyPtr -> Int64 -> PrimIO Int64
%inline %foreign "CExpr:(sizeof(time_t)),libc,time.h"
prim__sizeofTimeT : Int

%inline %foreign "CExpr:(gmtime_r((time_t *)($1), (struct tm *)($2)) == NULL ? -1 : 0),libc,time.h"
prim__gmtime_r : AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(localtime_r((time_t *)($1), (struct tm *)($2)) == NULL ? -1 : 0),libc,time.h"
prim__localtime_r : AnyPtr -> AnyPtr -> PrimIO Int32

withBroken : (AnyPtr -> AnyPtr -> PrimIO Int32) -> Int64 -> IO (Either Errno Tm)
withBroken f t = do
  cell <- malloc prim__sizeofTimeT
  _ <- primIO (prim__set_time_t cell t)
  r <- withTm $ \p => do
    rc <- primIO (f cell p)
    case rc of
         0 => Right <$> readTm p
         _ => Left <$> errno
  free cell
  pure r

||| Broken-down UTC time of a time in seconds since the Epoch.
export
gmtime : Int64 -> IO (Either Errno Tm)
gmtime = withBroken prim__gmtime_r

||| Broken-down local time (per the `TZ` environment) of a time in seconds since the Epoch.
export
localtime : Int64 -> IO (Either Errno Tm)
localtime = withBroken prim__localtime_r

%inline %foreign "CExpr:(mktime((struct tm *)($1))),libc,time.h"
prim__mktime : AnyPtr -> PrimIO Int64

||| The time in seconds since the Epoch for a local broken-down time; `Nothing`
||| when it cannot be represented. `mktime` reports that by the value -1, so
||| the one real time 23:59:59 on 1969-12-31 UTC cannot be told from a failure.
export
mktime : Tm -> IO (Maybe Int64)
mktime t = withTm $ \p => do
  writeTm p t
  r <- primIO (prim__mktime p)
  pure (if r == -1 then Nothing else Just r)

%inline %foreign "CExpr:(strftime((char *)($1), $2, $3, (struct tm *)($4))),libc,time.h"
prim__strftime : AnyPtr -> Bits64 -> String -> AnyPtr -> PrimIO Bits64

||| Format a broken-down time (`strftime`). `Nothing` when the result is longer than 4096
||| bytes, when it is empty (`strftime` reports both by the value 0), and when it is not
||| valid UTF-8.
export
strftime : (format : String) -> Tm -> IO (Maybe String)
strftime fmt t = withTm $ \p => do
  writeTmZone p t
  buf <- malloc 4096
  n <- primIO (prim__strftime buf 4096 fmt p)
  clearTmZone p
  case (n == 0, ptrToString buf) of
       (True, _) => free buf >> pure (if fmt == "" then Just "" else Nothing)
       (False, r) => free buf >> pure r
