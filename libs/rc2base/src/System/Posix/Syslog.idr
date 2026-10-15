||| The system log: `openlog`, `syslog`, `closelog`.
module System.Posix.Syslog

import System.FFI

%default total

||| A severity: `LOG_EMERG` (most severe) to `LOG_DEBUG`.
public export
Priority : Type
Priority = Int32

%inline %foreign "CExpr:(LOG_EMERG),libc,syslog.h"
export LOG_EMERG : Priority
%inline %foreign "CExpr:(LOG_ALERT),libc,syslog.h"
export LOG_ALERT : Priority
%inline %foreign "CExpr:(LOG_CRIT),libc,syslog.h"
export LOG_CRIT : Priority
%inline %foreign "CExpr:(LOG_ERR),libc,syslog.h"
export LOG_ERR : Priority
%inline %foreign "CExpr:(LOG_WARNING),libc,syslog.h"
export LOG_WARNING : Priority
%inline %foreign "CExpr:(LOG_NOTICE),libc,syslog.h"
export LOG_NOTICE : Priority
%inline %foreign "CExpr:(LOG_INFO),libc,syslog.h"
export LOG_INFO : Priority
%inline %foreign "CExpr:(LOG_DEBUG),libc,syslog.h"
export LOG_DEBUG : Priority

||| An `or` of `LOG_PID`, `LOG_CONS` and `LOG_NDELAY`.
public export
LogOptions : Type
LogOptions = Int32

||| Put the process id in each message.
%inline %foreign "CExpr:(LOG_PID),libc,syslog.h"
export LOG_PID : LogOptions
||| Write to the console when the system log is unavailable.
%inline %foreign "CExpr:(LOG_CONS),libc,syslog.h"
export LOG_CONS : LogOptions
||| Open the connection now instead of at the first message.
%inline %foreign "CExpr:(LOG_NDELAY),libc,syslog.h"
export LOG_NDELAY : LogOptions

||| Who is logging.
public export
Facility : Type
Facility = Int32

%inline %foreign "CExpr:(LOG_USER),libc,syslog.h"
export LOG_USER : Facility
%inline %foreign "CExpr:(LOG_DAEMON),libc,syslog.h"
export LOG_DAEMON : Facility
%inline %foreign "CExpr:(LOG_AUTH),libc,syslog.h"
export LOG_AUTH : Facility
%inline %foreign "CExpr:(LOG_LOCAL0),libc,syslog.h"
export LOG_LOCAL0 : Facility
%inline %foreign "CExpr:(LOG_LOCAL1),libc,syslog.h"
export LOG_LOCAL1 : Facility

-- `openlog` keeps the pointer it is given, so the identifier is copied; the
-- copy of the previous call is freed once the new one is in use.
%inline %foreign "CExpr:(({ static char *keep; char *n = strdup($1); openlog(n, $2, $3); free(keep); keep = n; 0; })),libc,syslog.h;string.h;stdlib.h"
prim__openlog : String -> LogOptions -> Facility -> PrimIO Int32
%inline %foreign "CExpr:((syslog($1, \"%s\", $2), 0)),libc,syslog.h"
prim__syslog : Priority -> String -> PrimIO Int32
%inline %foreign "CExpr:((closelog(), 0)),libc,syslog.h"
prim__closelog : PrimIO Int32

||| Open the log (again, if it was open).
export
openlog : (ident : String) -> LogOptions -> Facility -> IO ()
openlog ident opts facility = ignore (primIO (prim__openlog ident opts facility))

||| Log a message at a priority. The text is not a format string.
export
syslog : Priority -> String -> IO ()
syslog p msg = ignore (primIO (prim__syslog p msg))

||| Close the log.
export
closelog : IO ()
closelog = ignore (primIO prim__closelog)
