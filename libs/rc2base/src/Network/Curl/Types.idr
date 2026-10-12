module Network.Curl.Types

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

------------------------------------------------------------------------
-- CURLcode
------------------------------------------------------------------------

||| A libcurl `CURLcode` result. Wrapped rather than a bare `Int` so
||| callers can't accidentally compare it against a `CURLoption` value.
public export
record CURLcode where
  constructor MkCURLcode
  code : Int

public export
Eq CURLcode where
  MkCURLcode a == MkCURLcode b = a == b

public export
Show CURLcode where
  show (MkCURLcode c) = "CURLcode " ++ show c

||| Success, per curl/curl.h's `CURLE_OK = 0`.
public export
curle_OK : CURLcode
curle_OK = MkCURLcode 0

------------------------------------------------------------------------
-- CURLoption
------------------------------------------------------------------------

||| A libcurl `CURLoption` -- the value passed as `curl_easy_setopt`'s
||| own second argument. Every option value below is `CURLOPTTYPE_*`
||| (per curl/curl.h) plus the option's own small ordinal, exactly as
||| curl.h's own `CURLOPT()` macro constructs it.
public export
record CURLoption where
  constructor MkCURLoption
  opt : Int

public export
curlopt_VERBOSE : CURLoption
curlopt_VERBOSE = MkCURLoption 41 -- CURLOPTTYPE_LONG + 41

public export
curlopt_URL : CURLoption
curlopt_URL = MkCURLoption 10002 -- CURLOPTTYPE_OBJECTPOINT + 2

public export
curlopt_HTTPHEADER : CURLoption
curlopt_HTTPHEADER = MkCURLoption 10023 -- CURLOPTTYPE_OBJECTPOINT + 23

||| The `FILE *` (or, per `curl_easy_setopt(3)`, any pointer the write
||| callback itself agrees on the meaning of) libcurl's own *default*
||| write callback writes response body bytes to when
||| `CURLOPT_WRITEFUNCTION` is left unset -- `fwrite(ptr, size, nmemb,
||| (FILE *) this)`, i.e. `CURLOPTTYPE_CBPOINT` (`CURLOPTTYPE_OBJECTPOINT`
||| itself, curl/curl.h's own `#define`), not a callback in its own
||| right. See `Network.Curl.Raw`'s own `curlMemstreamOpen`/`Filep` for
||| why this is enough to capture a response body into Idris without
||| ever binding `CURLOPT_WRITEFUNCTION` itself.
public export
curlopt_WRITEDATA : CURLoption
curlopt_WRITEDATA = MkCURLoption 10001 -- CURLOPTTYPE_CBPOINT + 1

||| `1` selects a plain `GET` -- only useful to force it back after a
||| handle was previously configured for `POST`/`CUSTOMREQUEST`/etc.
||| (`curl_easy_setopt(3)`'s own note); a fresh handle already
||| defaults to `GET`. See `Network.Curl.Fetch`'s own `applyMethod`.
public export
curlopt_HTTPGET : CURLoption
curlopt_HTTPGET = MkCURLoption 80 -- CURLOPTTYPE_LONG + 80

||| `1` skips the response body entirely (`HEAD`-shaped request) --
||| still sends whatever HTTP method is otherwise configured, so pair
||| with `curlopt_HTTPGET` for a real `HEAD`.
public export
curlopt_NOBODY : CURLoption
curlopt_NOBODY = MkCURLoption 44 -- CURLOPTTYPE_LONG + 44

||| `1` selects `POST`, sending whatever `curlopt_COPYPOSTFIELDS` (or
||| the older `curlopt_POSTFIELDS`, not bound here) was set to as the
||| request body.
public export
curlopt_POST : CURLoption
curlopt_POST = MkCURLoption 47 -- CURLOPTTYPE_LONG + 47

||| Follow `Location:` response headers automatically (`3xx`
||| redirects) -- `1` to enable, unset (`0`) is libcurl's own default.
public export
curlopt_FOLLOWLOCATION : CURLoption
curlopt_FOLLOWLOCATION = MkCURLoption 52 -- CURLOPTTYPE_LONG + 52

||| Overrides the HTTP method's own verb string sent on the wire --
||| `"PUT"`/`"PATCH"`/`"DELETE"`/anything else libcurl doesn't have a
||| dedicated option for. Does not itself imply a request body; pair
||| with `curlopt_COPYPOSTFIELDS` for one.
public export
curlopt_CUSTOMREQUEST : CURLoption
curlopt_CUSTOMREQUEST = MkCURLoption 10036 -- CURLOPTTYPE_OBJECTPOINT + 36

||| The request body, copied immediately (unlike the older
||| `CURLOPT_POSTFIELDS`, which just stores the pointer -- libcurl
||| would then need the caller's own buffer to outlive the transfer).
||| Despite the name, sent with whatever method is otherwise
||| configured (`curlopt_POST`/`curlopt_CUSTOMREQUEST`), not only
||| `POST` (`curl_easy_setopt(3)`'s own note on `CURLOPT_COPYPOSTFIELDS`).
public export
curlopt_COPYPOSTFIELDS : CURLoption
curlopt_COPYPOSTFIELDS = MkCURLoption 10165 -- CURLOPTTYPE_OBJECTPOINT + 165

||| `curl_mime_init`'s own result, set via `curl_easy_setopt`.
public export
curlopt_MIMEPOST : CURLoption
curlopt_MIMEPOST = MkCURLoption 10269 -- CURLOPTTYPE_OBJECTPOINT + 269

||| Attaches a `curl_share_init` handle to this easy handle, via
||| `curlEasySetoptSlist h curlopt_SHARE sh`.
public export
curlopt_SHARE : CURLoption
curlopt_SHARE = MkCURLoption 10100 -- CURLOPTTYPE_OBJECTPOINT + 100

------------------------------------------------------------------------
-- CURLINFO
------------------------------------------------------------------------

||| A libcurl `CURLINFO` -- the value passed as `curl_easy_getinfo`'s
||| own second argument. Every value below is `CURLINFO_*`'s own
||| `CURLINFO_STRING`/`CURLINFO_LONG`/`CURLINFO_DOUBLE`/`CURLINFO_SLIST`/
||| `CURLINFO_OFF_T`/`CURLINFO_SOCKET` type tag (per curl/curl.h) plus
||| the info's own small ordinal, same construction as `CURLoption`
||| above. All six tags now have a matching `curlEasyGetinfo*` function
||| (`Network.Curl.Raw`); only a hand-picked handful of the several
||| hundred `CURLINFO_*` values libcurl defines are represented here --
||| add more as a concrete need comes up.
public export
record CURLINFO where
  constructor MkCURLINFO
  info : Int

public export
curlinfo_EFFECTIVE_URL : CURLINFO
curlinfo_EFFECTIVE_URL = MkCURLINFO 1048577 -- CURLINFO_STRING + 1

public export
curlinfo_RESPONSE_CODE : CURLINFO
curlinfo_RESPONSE_CODE = MkCURLINFO 2097154 -- CURLINFO_LONG + 2

public export
curlinfo_TOTAL_TIME : CURLINFO
curlinfo_TOTAL_TIME = MkCURLINFO 3145731 -- CURLINFO_DOUBLE + 3

public export
curlinfo_NAMELOOKUP_TIME : CURLINFO
curlinfo_NAMELOOKUP_TIME = MkCURLINFO 3145732 -- CURLINFO_DOUBLE + 4

public export
curlinfo_CONNECT_TIME : CURLINFO
curlinfo_CONNECT_TIME = MkCURLINFO 3145733 -- CURLINFO_DOUBLE + 5

public export
curlinfo_HEADER_SIZE : CURLINFO
curlinfo_HEADER_SIZE = MkCURLINFO 2097163 -- CURLINFO_LONG + 11

public export
curlinfo_REQUEST_SIZE : CURLINFO
curlinfo_REQUEST_SIZE = MkCURLINFO 2097164 -- CURLINFO_LONG + 12

public export
curlinfo_CONTENT_TYPE : CURLINFO
curlinfo_CONTENT_TYPE = MkCURLINFO 1048594 -- CURLINFO_STRING + 18

public export
curlinfo_REDIRECT_COUNT : CURLINFO
curlinfo_REDIRECT_COUNT = MkCURLINFO 2097172 -- CURLINFO_LONG + 20

||| First `CURLINFO_OFF_T`-tagged constant bound -- see
||| `Network.Curl.Raw`'s own `curlEasyGetinfoOfft` for why `off_t`
||| itself is represented as `Int64` here (`curl_off_t` is always a
||| real 64-bit signed integer in libcurl, regardless of the host
||| platform's own `long` width).
public export
curlinfo_SIZE_DOWNLOAD_T : CURLINFO
curlinfo_SIZE_DOWNLOAD_T = MkCURLINFO 6291464 -- CURLINFO_OFF_T + 8

||| First `CURLINFO_SLIST`-tagged constant bound -- see
||| `Network.Curl.Raw`'s own `curlEasyGetinfoSlist`/`curlSlistToList`.
||| Per `curl_easy_getinfo(3)`, the caller owns the returned list and
||| must release it with `curlSlistFreeAll` once done.
public export
curlinfo_COOKIELIST : CURLINFO
curlinfo_COOKIELIST = MkCURLINFO 4194332 -- CURLINFO_SLIST + 28

||| First `CURLINFO_SOCKET`-tagged constant bound -- see
||| `Network.Curl.Raw`'s own `curlEasyGetinfoSocket`. `curl_socket_t`
||| is a plain C `int` on every non-Windows platform (curl/curl.h),
||| so `Int` is an exact fit, not an approximation.
public export
curlinfo_ACTIVESOCKET : CURLINFO
curlinfo_ACTIVESOCKET = MkCURLINFO 5242924 -- CURLINFO_SOCKET + 44

------------------------------------------------------------------------
-- CURLUcode / CURLUPart
------------------------------------------------------------------------

||| A `CURLUcode` result from the URL API (`curl_url_get`/
||| `curl_url_set`) -- a distinct enum from `CURLcode` in curl/curl.h
||| itself, so kept as its own wrapper here too.
public export
record CURLUcode where
  constructor MkCURLUcode
  code : Int

public export
Eq CURLUcode where
  MkCURLUcode a == MkCURLUcode b = a == b

public export
Show CURLUcode where
  show (MkCURLUcode c) = "CURLUcode " ++ show c

||| Success, per curl/curl.h's `CURLUE_OK = 0` (first enum member).
public export
curlue_OK : CURLUcode
curlue_OK = MkCURLUcode 0

||| A `CURLUPart` -- which URL component `curl_url_get`/`curl_url_set`
||| read or write. Values are the enum's own declaration order in
||| curl/curl.h (`CURLUPART_URL = 0`, ...), same as any plain C enum
||| with no explicit initializers.
public export
record CURLUPart where
  constructor MkCURLUPart
  part : Int

public export
curlupart_URL : CURLUPart
curlupart_URL = MkCURLUPart 0

public export
curlupart_SCHEME : CURLUPart
curlupart_SCHEME = MkCURLUPart 1

public export
curlupart_USER : CURLUPart
curlupart_USER = MkCURLUPart 2

public export
curlupart_PASSWORD : CURLUPart
curlupart_PASSWORD = MkCURLUPart 3

public export
curlupart_HOST : CURLUPart
curlupart_HOST = MkCURLUPart 5

public export
curlupart_PORT : CURLUPart
curlupart_PORT = MkCURLUPart 6

public export
curlupart_PATH : CURLUPart
curlupart_PATH = MkCURLUPart 7

public export
curlupart_QUERY : CURLUPart
curlupart_QUERY = MkCURLUPart 8

public export
curlupart_FRAGMENT : CURLUPart
curlupart_FRAGMENT = MkCURLUPart 9

------------------------------------------------------------------------
-- CURLMcode / CURLMSG
------------------------------------------------------------------------

||| A libcurl `CURLMcode` result from the multi interface -- a
||| distinct enum from both `CURLcode` and `CURLUcode` in curl/multi.h.
||| Note `CURLM_CALL_MULTI_PERFORM = -1` is the enum's own first
||| (negative) member, so `CURLM_OK` is `0` same as `CURLcode`/
||| `CURLUcode`, but this enum alone can carry a negative value.
public export
record CURLMcode where
  constructor MkCURLMcode
  code : Int

public export
Eq CURLMcode where
  MkCURLMcode a == MkCURLMcode b = a == b

public export
Show CURLMcode where
  show (MkCURLMcode c) = "CURLMcode " ++ show c

public export
curlm_OK : CURLMcode
curlm_OK = MkCURLMcode 0

||| A libcurl `CURLMSG` -- the `msg` field of a `CURLMsg` read via
||| `curl_multi_info_read`. Only `CURLMSG_DONE` (the one message this
||| repo currently reads meaning from) is bound; `CURLMSG_NONE` (first
||| enum member, never actually sent) and `CURLMSG_LAST` (a sentinel,
||| never sent either) aren't.
public export
record CURLMSG where
  constructor MkCURLMSG
  msg : Int

public export
Eq CURLMSG where
  MkCURLMSG a == MkCURLMSG b = a == b

public export
curlmsg_DONE : CURLMSG
curlmsg_DONE = MkCURLMSG 1

------------------------------------------------------------------------
-- CURLSHcode / CurlLockData
------------------------------------------------------------------------

||| A libcurl `CURLSHcode` result from the share interface -- a
||| distinct enum from `CURLcode`/`CURLUcode`/`CURLMcode` in
||| curl/curl.h itself.
public export
record CURLSHcode where
  constructor MkCURLSHcode
  code : Int

public export
Eq CURLSHcode where
  MkCURLSHcode a == MkCURLSHcode b = a == b

public export
Show CURLSHcode where
  show (MkCURLSHcode c) = "CURLSHcode " ++ show c

public export
curlshe_OK : CURLSHcode
curlshe_OK = MkCURLSHcode 0

||| A `curl_lock_data` value -- which kind of state to share/unshare
||| via `curl_share_setopt`'s own `CURLSHOPT_SHARE`/`CURLSHOPT_UNSHARE`.
||| Only the data types actually useful without a lock/unlock callback
||| (`CURLSHOPT_LOCKFUNC`/`CURLSHOPT_UNLOCKFUNC`, not bound -- see
||| `TODO.md`'s own callback entry; libcurl only *requires* one when a
||| share handle is itself used across multiple threads, which this
||| repo's own single-threaded examples never do) are represented here.
public export
record CurlLockData where
  constructor MkCurlLockData
  lockData : Int

public export
curllockdata_COOKIE : CurlLockData
curllockdata_COOKIE = MkCurlLockData 2

public export
curllockdata_DNS : CurlLockData
curllockdata_DNS = MkCurlLockData 3

public export
curllockdata_SSL_SESSION : CurlLockData
curllockdata_SSL_SESSION = MkCurlLockData 4

------------------------------------------------------------------------
-- curlpause_* bitmask
------------------------------------------------------------------------

||| `curl_easy_pause`'s own `action` bitmask (curl/curl.h's own
||| `CURLPAUSE_*` -- a plain `Int`, not a wrapper record like
||| `CURLoption`/`CURLINFO`/etc. above: unlike those, this one is
||| meant to be OR'd together (`Data.Bits`'s own `.|.` on `Int`, an
||| existing `Bits Int` instance -- see curl/curl.h's own
||| `CURLPAUSE_ALL = CURLPAUSE_RECV | CURLPAUSE_SEND` for precedent),
||| and a wrapper wouldn't compose with `.|.` without its own `Bits`
||| instance duplicating `Int`'s one for no benefit.
public export
curlpause_RECV : Int
curlpause_RECV = 1

public export
curlpause_SEND : Int
curlpause_SEND = 4

public export
curlpause_ALL : Int
curlpause_ALL = 5

public export
curlpause_CONT : Int
curlpause_CONT = 0

------------------------------------------------------------------------
-- CURLHcode / curlh_* bitmask
------------------------------------------------------------------------

||| A libcurl `CURLHcode` result from the structured header API
||| (`curl_easy_header`) -- a distinct enum from every other `*code`
||| wrapper above.
public export
record CURLHcode where
  constructor MkCURLHcode
  code : Int

public export
Eq CURLHcode where
  MkCURLHcode a == MkCURLHcode b = a == b

public export
Show CURLHcode where
  show (MkCURLHcode c) = "CURLHcode " ++ show c

public export
curlhe_OK : CURLHcode
curlhe_OK = MkCURLHcode 0

||| `curl_easy_header`/`curl_easy_nextheader`'s own `origin` bitmask
||| (curl/header.h's own `CURLH_*`) -- a plain `Int`, same "meant to
||| be OR'd together" reasoning as `curlpause_*` above (only
||| `CURLH_HEADER`, an ordinary server response header, is bound;
||| `CURLH_TRAILER`/`CURLH_CONNECT`/`CURLH_1XX`/`CURLH_PSEUDO` aren't,
||| no concrete need yet).
public export
curlh_HEADER : Int
curlh_HEADER = 1
