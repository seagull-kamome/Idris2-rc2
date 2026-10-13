module Network.HTTP.Client.Curl.Raw

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Direct libcurl FFI bindings: one `%foreign` per libcurl function,
-- plus thin `HasIO` wrappers that turn NULL into `Maybe` and raw ints
-- into the `Network.HTTP.Client.Curl.Types` wrappers. No C shim of its own: output
-- pointers and C structs go through `System.FFI.Struct`, see
-- doc/http-client.md.

import Data.Buffer
import Data.Maybe
import System.FFI

import Network.HTTP.Client.Curl.Types

------------------------------------------------------------------------
-- Out-parameter cells and struct views
------------------------------------------------------------------------

-- Own struct names rather than libcurl's: `curl_header`/`curl_slist`
-- are bare struct tags (no typedef) and would need rc2's
-- `externStruct` directive otherwise, which a Chez-built TTC drops.
-- Every field list therefore spells out the real C layout in order.

CellI64 : Type
CellI64 = Struct "idris2curl_cell_i64" [("v", Int64)]

CellI32 : Type
CellI32 = Struct "idris2curl_cell_i32" [("v", Int32)]

CellDbl : Type
CellDbl = Struct "idris2curl_cell_dbl" [("v", Double)]

CellPtr : Type
CellPtr = Struct "idris2curl_cell_ptr" [("v", AnyPtr)]

SlistView : Type
SlistView = Struct "idris2curl_slist" [("data", AnyPtr), ("next", AnyPtr)]

HeaderView : Type
HeaderView = Struct "idris2curl_header"
    [ ("name", AnyPtr), ("value", AnyPtr), ("amount", Bits64)
    , ("index", Bits64), ("origin", Bits32), ("anchor", AnyPtr) ]

-- `CURLMsg`'s last member is `union { void *whatever; CURLcode result; }`;
-- `result` is read as the union's low 32 bits, which holds on the
-- little-endian targets this library supports.
MsgView : Type
MsgView = Struct "idris2curl_msg"
    [ ("msg", Int32), ("easy_handle", AnyPtr), ("result", Int32) ]

-- A prefix of `curl_version_info_data`, starting at its first field.
VersionInfoView : Type
VersionInfoView = Struct "idris2curl_version_info"
    [ ("age", Int32), ("version", AnyPtr), ("version_num", Bits32)
    , ("host", AnyPtr), ("features", Int32), ("ssl_version", AnyPtr) ]

-- A cell must come from a `%foreign` return typed as the `Struct`:
-- Chez represents a `Struct` as an ftype pointer, which neither
-- `System.FFI.malloc` nor `believe_me` on an `AnyPtr` produces.
%foreign "C:malloc,libc,stdlib.h"
prim__newCellI64 : Int -> PrimIO CellI64

%foreign "C:malloc,libc,stdlib.h"
prim__newCellI32 : Int -> PrimIO CellI32

%foreign "C:malloc,libc,stdlib.h"
prim__newCellDbl : Int -> PrimIO CellDbl

%foreign "C:malloc,libc,stdlib.h"
prim__newCellPtr : Int -> PrimIO CellPtr

%foreign "C:free,libc,stdlib.h"
prim__freeCellI64 : CellI64 -> PrimIO ()

%foreign "C:free,libc,stdlib.h"
prim__freeCellI32 : CellI32 -> PrimIO ()

%foreign "C:free,libc,stdlib.h"
prim__freeCellDbl : CellDbl -> PrimIO ()

%foreign "C:free,libc,stdlib.h"
prim__freeCellPtr : CellPtr -> PrimIO ()

-- `memset(p, 0, 0)` returns `p` untouched: the one portable way to
-- view a non-NULL `AnyPtr` as a `Struct` on Chez (see the cells above).
%foreign "C:memset,libc,string.h"
prim__viewSlist : AnyPtr -> Int -> Int -> PrimIO SlistView

%foreign "C:memset,libc,string.h"
prim__viewHeader : AnyPtr -> Int -> Int -> PrimIO HeaderView

%foreign "C:memset,libc,string.h"
prim__viewMsg : AnyPtr -> Int -> Int -> PrimIO MsgView

withCell : HasIO io => PrimIO c -> (c -> PrimIO ()) -> (c -> io a) -> io a
withCell new del body = do
    c <- primIO new
    r <- body c
    primIO (del c)
    pure r

nonNull : AnyPtr -> Maybe AnyPtr
nonNull p = if prim__nullAnyPtr p /= 0 then Nothing else Just p

-- A copy of the NUL-terminated string at `p`, read through upstream's
-- own `idris2_getString`.
ptrToString : AnyPtr -> Maybe String
ptrToString p = map (\q => prim__getString (prim__castPtr q)) (nonNull p)

------------------------------------------------------------------------
-- Foreign declarations
------------------------------------------------------------------------

%foreign "C:curl_global_init,libcurl,curl/curl.h"
prim__curlGlobalInit : Int -> PrimIO Int

%foreign "C:curl_global_cleanup,libcurl,curl/curl.h"
prim__curlGlobalCleanup : PrimIO ()

%foreign "C:curl_easy_init,libcurl,curl/curl.h"
prim__curlEasyInit : PrimIO AnyPtr

%foreign "C:curl_easy_cleanup,libcurl,curl/curl.h"
prim__curlEasyCleanup : AnyPtr -> PrimIO ()

%foreign "C:curl_easy_setopt,libcurl,curl/curl.h"
prim__curlEasySetoptString : AnyPtr -> Int -> String -> PrimIO Int

%foreign "C:curl_easy_setopt,libcurl,curl/curl.h"
prim__curlEasySetoptLong : AnyPtr -> Int -> Int -> PrimIO Int

%foreign "C:curl_easy_setopt,libcurl,curl/curl.h"
prim__curlEasySetoptPointer : AnyPtr -> Int -> AnyPtr -> PrimIO Int

%foreign "C:curl_easy_perform,libcurl,curl/curl.h"
prim__curlEasyPerform : AnyPtr -> PrimIO Int

%foreign "C:curl_easy_duphandle,libcurl,curl/curl.h"
prim__curlEasyDuphandle : AnyPtr -> PrimIO AnyPtr

%foreign "C:curl_easy_reset,libcurl,curl/curl.h"
prim__curlEasyReset : AnyPtr -> PrimIO ()

%foreign "C:curl_easy_strerror,libcurl,curl/curl.h"
prim__curlEasyStrerror : Int -> PrimIO String

%foreign "C:curl_easy_getinfo,libcurl,curl/curl.h"
prim__curlEasyGetinfoI64 : AnyPtr -> Int -> CellI64 -> PrimIO Int

%foreign "C:curl_easy_getinfo,libcurl,curl/curl.h"
prim__curlEasyGetinfoI32 : AnyPtr -> Int -> CellI32 -> PrimIO Int

%foreign "C:curl_easy_getinfo,libcurl,curl/curl.h"
prim__curlEasyGetinfoDbl : AnyPtr -> Int -> CellDbl -> PrimIO Int

%foreign "C:curl_easy_getinfo,libcurl,curl/curl.h"
prim__curlEasyGetinfoPtr : AnyPtr -> Int -> CellPtr -> PrimIO Int

%foreign "C:curl_slist_append,libcurl,curl/curl.h"
prim__curlSlistAppend : AnyPtr -> String -> PrimIO AnyPtr

%foreign "C:curl_slist_free_all,libcurl,curl/curl.h"
prim__curlSlistFreeAll : AnyPtr -> PrimIO ()

-- `outlength` is passed NULL; a decoded length would only matter for
-- a result with an embedded NUL, which a `String` can't carry anyway.
%foreign "C:curl_easy_escape,libcurl,curl/curl.h"
prim__curlEasyEscapeRaw : AnyPtr -> String -> Int -> PrimIO AnyPtr

%foreign "C:curl_easy_unescape,libcurl,curl/curl.h"
prim__curlEasyUnescapeRaw : AnyPtr -> String -> Int -> AnyPtr -> PrimIO AnyPtr

%foreign "C:curl_free,libcurl,curl/curl.h"
prim__curlFree : AnyPtr -> PrimIO ()

-- `idris2_getString` retyped to read through a `GCAnyPtr`, so the
-- string is copied out before `curl_free` can run.
%foreign "C:idris2_getString,libidris2_support,idris_support.h"
prim__curlGetStringGC : GCAnyPtr -> PrimIO String

%foreign "C:curl_version,libcurl,curl/curl.h"
prim__curlVersion : PrimIO String

%foreign "C:curl_version_info,libcurl,curl/curl.h"
prim__curlVersionInfo : Int -> PrimIO VersionInfoView

%foreign "C:curl_url,libcurl,curl/curl.h"
prim__curlUrl : PrimIO AnyPtr

%foreign "C:curl_url_cleanup,libcurl,curl/curl.h"
prim__curlUrlCleanup : AnyPtr -> PrimIO ()

%foreign "C:curl_url_dup,libcurl,curl/curl.h"
prim__curlUrlDup : AnyPtr -> PrimIO AnyPtr

%foreign "C:curl_url_set,libcurl,curl/curl.h"
prim__curlUrlSet : AnyPtr -> Int -> String -> Int -> PrimIO Int

%foreign "C:curl_url_get,libcurl,curl/curl.h"
prim__curlUrlGet : AnyPtr -> Int -> CellPtr -> Int -> PrimIO Int

%foreign "C:curl_url_strerror,libcurl,curl/curl.h"
prim__curlUrlStrerror : Int -> PrimIO String

%foreign "C:curl_multi_init,libcurl,curl/multi.h"
prim__curlMultiInit : PrimIO AnyPtr

%foreign "C:curl_multi_cleanup,libcurl,curl/multi.h"
prim__curlMultiCleanup : AnyPtr -> PrimIO Int

%foreign "C:curl_multi_add_handle,libcurl,curl/multi.h"
prim__curlMultiAddHandle : AnyPtr -> AnyPtr -> PrimIO Int

%foreign "C:curl_multi_remove_handle,libcurl,curl/multi.h"
prim__curlMultiRemoveHandle : AnyPtr -> AnyPtr -> PrimIO Int

%foreign "C:curl_multi_strerror,libcurl,curl/multi.h"
prim__curlMultiStrerror : Int -> PrimIO String

%foreign "C:curl_multi_perform,libcurl,curl/multi.h"
prim__curlMultiPerform : AnyPtr -> CellI32 -> PrimIO Int

-- `extra_fds`/`extra_nfds` (non-curl sockets to watch too) are always
-- NULL/0; nothing here needs them yet.
%foreign "C:curl_multi_wait,libcurl,curl/multi.h"
prim__curlMultiWait : AnyPtr -> AnyPtr -> Bits32 -> Int -> CellI32 -> PrimIO Int

%foreign "C:curl_multi_info_read,libcurl,curl/multi.h"
prim__curlMultiInfoRead : AnyPtr -> CellI32 -> PrimIO AnyPtr

%foreign "C:curl_share_init,libcurl,curl/curl.h"
prim__curlShareInit : PrimIO AnyPtr

%foreign "C:curl_share_cleanup,libcurl,curl/curl.h"
prim__curlShareCleanup : AnyPtr -> PrimIO Int

%foreign "C:curl_share_setopt,libcurl,curl/curl.h"
prim__curlShareSetoptInt : AnyPtr -> Int -> Int -> PrimIO Int

%foreign "C:curl_share_strerror,libcurl,curl/curl.h"
prim__curlShareStrerror : Int -> PrimIO String

%foreign "C:curl_mime_init,libcurl,curl/curl.h"
prim__curlMimeInit : AnyPtr -> PrimIO AnyPtr

%foreign "C:curl_mime_free,libcurl,curl/curl.h"
prim__curlMimeFree : AnyPtr -> PrimIO ()

%foreign "C:curl_mime_addpart,libcurl,curl/curl.h"
prim__curlMimeAddpart : AnyPtr -> PrimIO AnyPtr

%foreign "C:curl_mime_name,libcurl,curl/curl.h"
prim__curlMimeName : AnyPtr -> String -> PrimIO Int

%foreign "C:curl_mime_filename,libcurl,curl/curl.h"
prim__curlMimeFilename : AnyPtr -> String -> PrimIO Int

%foreign "C:curl_mime_type,libcurl,curl/curl.h"
prim__curlMimeType : AnyPtr -> String -> PrimIO Int

-- Not `CURL_ZERO_TERMINATED`: `-1 : Int` is a 32-bit `int` on Chez and
-- doesn't widen to `(size_t)-1`, see doc/http-client.md.
%foreign "C:curl_mime_data,libcurl,curl/curl.h"
prim__curlMimeData : AnyPtr -> String -> Int -> PrimIO Int

%foreign "C:curl_mime_filedata,libcurl,curl/curl.h"
prim__curlMimeFiledata : AnyPtr -> String -> PrimIO Int

%foreign "C:curl_mime_headers,libcurl,curl/curl.h"
prim__curlMimeHeaders : AnyPtr -> AnyPtr -> Int -> PrimIO Int

%foreign "C:curl_easy_pause,libcurl,curl/curl.h"
prim__curlEasyPause : AnyPtr -> Int -> PrimIO Int

%foreign "C:curl_easy_upkeep,libcurl,curl/curl.h"
prim__curlEasyUpkeep : AnyPtr -> PrimIO Int

%foreign "C:curl_easy_header,libcurl,curl/curl.h"
prim__curlEasyHeader : AnyPtr -> String -> Bits64 -> Bits32 -> Int -> CellPtr -> PrimIO Int

%foreign "C:curl_easy_nextheader,libcurl,curl/curl.h"
prim__curlEasyNextheader : AnyPtr -> Bits32 -> Int -> AnyPtr -> PrimIO AnyPtr

-- libc, not rc2base's `System.IO.MemStream`: a Chez build has no rc2
-- toolchain to provide rc2base's C library (doc/http-client.md).
%foreign "C:open_memstream,libc,stdio.h"
prim__openMemstream : CellPtr -> CellI64 -> PrimIO AnyPtr

%foreign "C:fclose,libc,stdio.h"
prim__fclose : AnyPtr -> PrimIO Int

%foreign "C:free,libc,stdlib.h"
prim__freeRaw : AnyPtr -> PrimIO ()

%foreign "C:memcpy,libc,string.h"
prim__memcpyToBuffer : Buffer -> AnyPtr -> Int -> PrimIO AnyPtr

------------------------------------------------------------------------
-- Global init/cleanup
------------------------------------------------------------------------

||| `CURL_GLOBAL_ALL`, per curl/curl.h.
curlGlobalAll : Int
curlGlobalAll = 3

export
curlGlobalInit : HasIO io => io CURLcode
curlGlobalInit = MkCURLcode <$> primIO (prim__curlGlobalInit curlGlobalAll)

export
curlGlobalCleanup : HasIO io => io ()
curlGlobalCleanup = primIO prim__curlGlobalCleanup

------------------------------------------------------------------------
-- Easy handle lifecycle
------------------------------------------------------------------------

||| `Nothing` on allocation failure (`curl_easy_init(3)`).
export
curlEasyInit : HasIO io => io (Maybe AnyPtr)
curlEasyInit = nonNull <$> primIO prim__curlEasyInit

export
curlEasyCleanup : HasIO io => AnyPtr -> io ()
curlEasyCleanup h = primIO (prim__curlEasyCleanup h)

export
curlEasySetoptString : HasIO io => AnyPtr -> CURLoption -> String -> io CURLcode
curlEasySetoptString h (MkCURLoption o) v = MkCURLcode <$> primIO (prim__curlEasySetoptString h o v)

export
curlEasySetoptLong : HasIO io => AnyPtr -> CURLoption -> Int -> io CURLcode
curlEasySetoptLong h (MkCURLoption o) v = MkCURLcode <$> primIO (prim__curlEasySetoptLong h o v)

||| Any object-pointer-valued option: a `curl_slist *`, `curl_mime *`,
||| `CURLSH *`, `FILE *`, ...
export
curlEasySetoptPointer : HasIO io => AnyPtr -> CURLoption -> AnyPtr -> io CURLcode
curlEasySetoptPointer h (MkCURLoption o) v = MkCURLcode <$> primIO (prim__curlEasySetoptPointer h o v)

export
curlEasyPerform : HasIO io => AnyPtr -> io CURLcode
curlEasyPerform h = MkCURLcode <$> primIO (prim__curlEasyPerform h)

export
curlEasyStrerror : CURLcode -> String
curlEasyStrerror (MkCURLcode c) = unsafePerformIO $ primIO (prim__curlEasyStrerror c)

||| `Nothing` on allocation failure (`curl_easy_duphandle(3)`).
export
curlEasyDuphandle : HasIO io => AnyPtr -> io (Maybe AnyPtr)
curlEasyDuphandle h = nonNull <$> primIO (prim__curlEasyDuphandle h)

export
curlEasyReset : HasIO io => AnyPtr -> io ()
curlEasyReset h = primIO (prim__curlEasyReset h)

------------------------------------------------------------------------
-- curl_easy_getinfo
------------------------------------------------------------------------

getinfo : HasIO io
       => PrimIO c -> (c -> PrimIO ()) -> (AnyPtr -> Int -> c -> PrimIO Int)
       -> (c -> a) -> AnyPtr -> CURLINFO -> io (Either CURLcode a)
getinfo new del call read h (MkCURLINFO i) = withCell new del $ \c => do
    rc <- primIO (call h i c)
    pure $ if rc == 0 then Right (read c) else Left (MkCURLcode rc)

||| For `CURLINFO_LONG` infos.
export
curlEasyGetinfoLong : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode Int)
curlEasyGetinfoLong = getinfo (prim__newCellI64 8) prim__freeCellI64 prim__curlEasyGetinfoI64
                              (\c => cast {to = Int} (the Int64 (getField c "v")))

||| For `CURLINFO_STRING` infos; a NULL result reads as `""`.
export
curlEasyGetinfoString : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode String)
curlEasyGetinfoString = getinfo (prim__newCellPtr 8) prim__freeCellPtr prim__curlEasyGetinfoPtr
                                (\c => fromMaybe "" (ptrToString (getField c "v")))

||| For `CURLINFO_DOUBLE` infos.
export
curlEasyGetinfoDouble : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode Double)
curlEasyGetinfoDouble = getinfo (prim__newCellDbl 8) prim__freeCellDbl prim__curlEasyGetinfoDbl
                                (\c => getField c "v")

||| For `CURLINFO_OFF_T` infos (`curl_off_t` is always 64-bit).
export
curlEasyGetinfoOfft : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode Int64)
curlEasyGetinfoOfft = getinfo (prim__newCellI64 8) prim__freeCellI64 prim__curlEasyGetinfoI64
                              (\c => getField c "v")

||| For `CURLINFO_SLIST` infos. Unlike every other info, the list is
||| caller-owned: read it with `curlSlistToList`, then release it with
||| `curlSlistFreeAll`.
export
curlEasyGetinfoSlist : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode AnyPtr)
curlEasyGetinfoSlist = getinfo (prim__newCellPtr 8) prim__freeCellPtr prim__curlEasyGetinfoPtr
                               (\c => getField c "v")

||| For `CURLINFO_SOCKET` infos; `-1` is `CURL_SOCKET_BAD`.
export
curlEasyGetinfoSocket : HasIO io => AnyPtr -> CURLINFO -> io (Either CURLcode Int)
curlEasyGetinfoSocket = getinfo (prim__newCellI32 8) prim__freeCellI32 prim__curlEasyGetinfoI32
                                (\c => cast {to = Int} (the Int32 (getField c "v")))

------------------------------------------------------------------------
-- curl_slist
------------------------------------------------------------------------

||| An empty list: `curl_slist_append(3)` starts a fresh one from NULL.
export
curlSlistEmpty : AnyPtr
curlSlistEmpty = prim__getNullAnyPtr

||| Returns the new list head; `list` must not be reused afterwards.
export
curlSlistAppend : HasIO io => AnyPtr -> String -> io AnyPtr
curlSlistAppend list s = primIO (prim__curlSlistAppend list s)

export
curlSlistFreeAll : HasIO io => AnyPtr -> io ()
curlSlistFreeAll list = primIO (prim__curlSlistFreeAll list)

||| Copies every node's `data`; `list` itself is left for
||| `curlSlistFreeAll`.
covering export
curlSlistToList : HasIO io => AnyPtr -> io (List String)
curlSlistToList list = case nonNull list of
    Nothing => pure []
    Just p => do
        node <- primIO (prim__viewSlist p 0 0)
        rest <- curlSlistToList (getField node "next")
        pure $ maybe rest (:: rest) (ptrToString (getField node "data"))

------------------------------------------------------------------------
-- Escape/unescape
------------------------------------------------------------------------

||| Reads a non-NULL libcurl-allocated `char *` and releases it with
||| `curl_free`.
export
curlReadAndFree : HasIO io => AnyPtr -> io String
curlReadAndFree raw = do
    gcptr <- onCollectAny raw (\p => primIO (prim__curlFree p))
    primIO (prim__curlGetStringGC gcptr)

readAndFreeNonNull : HasIO io => AnyPtr -> io (Maybe String)
readAndFreeNonNull raw = traverse curlReadAndFree (nonNull raw)

||| `Nothing` if libcurl reports an error (`curl_easy_escape(3)`).
export
curlEasyEscape : HasIO io => AnyPtr -> String -> io (Maybe String)
curlEasyEscape h s = primIO (prim__curlEasyEscapeRaw h s 0) >>= readAndFreeNonNull

||| `Nothing` if libcurl reports an error (`curl_easy_unescape(3)`).
export
curlEasyUnescape : HasIO io => AnyPtr -> String -> io (Maybe String)
curlEasyUnescape h s = primIO (prim__curlEasyUnescapeRaw h s 0 prim__getNullAnyPtr) >>= readAndFreeNonNull

------------------------------------------------------------------------
-- Version / curl_version_info
------------------------------------------------------------------------

export
curlVersion : HasIO io => io String
curlVersion = primIO prim__curlVersion

||| The `CURLVERSION_FIRST` fields of `curl_version_info_data`.
public export
record VersionInfo where
  constructor MkVersionInfo
  version    : String
  versionNum : Int
  host       : String
  features   : Int
  sslVersion : Maybe String

-- `CURLVERSION_NOW` as of libcurl 8.8.0; every field read here has
-- existed since `CURLVERSION_FIRST`, so an older libcurl is still safe.
curlversionNow : Int
curlversionNow = 11

export
curlVersionInfo : HasIO io => io VersionInfo
curlVersionInfo = do
    v <- primIO (prim__curlVersionInfo curlversionNow)
    let str = \f => fromMaybe "" (ptrToString f)
    pure $ MkVersionInfo
        (str (getField v "version"))
        (cast (the Bits32 (getField v "version_num")))
        (str (getField v "host"))
        (cast (the Int32 (getField v "features")))
        (ptrToString (getField v "ssl_version"))

------------------------------------------------------------------------
-- URL API
------------------------------------------------------------------------

||| `Nothing` on allocation failure (`curl_url(3)`).
export
curlUrl : HasIO io => io (Maybe AnyPtr)
curlUrl = nonNull <$> primIO prim__curlUrl

export
curlUrlCleanup : HasIO io => AnyPtr -> io ()
curlUrlCleanup u = primIO (prim__curlUrlCleanup u)

||| `Nothing` on allocation failure (`curl_url_dup(3)`).
export
curlUrlDup : HasIO io => AnyPtr -> io (Maybe AnyPtr)
curlUrlDup u = nonNull <$> primIO (prim__curlUrlDup u)

||| `flags`: curl/urlapi.h's `CURLU_*` bits, `0` for none.
export
curlUrlSet : HasIO io => AnyPtr -> CURLUPart -> String -> Int -> io CURLUcode
curlUrlSet u (MkCURLUPart p) s flags = MkCURLUcode <$> primIO (prim__curlUrlSet u p s flags)

||| `Nothing` on any `curl_url_get` failure; `Just ""` for a part that
||| is present but empty.
export
curlUrlGet : HasIO io => AnyPtr -> CURLUPart -> Int -> io (Maybe String)
curlUrlGet u (MkCURLUPart p) flags =
    withCell (prim__newCellPtr 8) prim__freeCellPtr $ \c => do
        0 <- primIO (prim__curlUrlGet u p c flags)
            | _ => pure Nothing
        readAndFreeNonNull (getField c "v")

export
curlUrlStrerror : CURLUcode -> String
curlUrlStrerror (MkCURLUcode c) = unsafePerformIO $ primIO (prim__curlUrlStrerror c)

------------------------------------------------------------------------
-- Multi interface
------------------------------------------------------------------------

||| `Nothing` on allocation failure (`curl_multi_init(3)`).
export
curlMultiInit : HasIO io => io (Maybe AnyPtr)
curlMultiInit = nonNull <$> primIO prim__curlMultiInit

export
curlMultiCleanup : HasIO io => AnyPtr -> io CURLMcode
curlMultiCleanup m = MkCURLMcode <$> primIO (prim__curlMultiCleanup m)

export
curlMultiAddHandle : HasIO io => AnyPtr -> AnyPtr -> io CURLMcode
curlMultiAddHandle m h = MkCURLMcode <$> primIO (prim__curlMultiAddHandle m h)

export
curlMultiRemoveHandle : HasIO io => AnyPtr -> AnyPtr -> io CURLMcode
curlMultiRemoveHandle m h = MkCURLMcode <$> primIO (prim__curlMultiRemoveHandle m h)

export
curlMultiStrerror : CURLMcode -> String
curlMultiStrerror (MkCURLMcode c) = unsafePerformIO $ primIO (prim__curlMultiStrerror c)

multiCount : HasIO io => (CellI32 -> PrimIO Int) -> io (Either CURLMcode Int)
multiCount call = withCell (prim__newCellI32 8) prim__freeCellI32 $ \c => do
    rc <- primIO (call c)
    pure $ if rc == 0 then Right (cast (the Int32 (getField c "v"))) else Left (MkCURLMcode rc)

||| The number of easy handles still transferring.
export
curlMultiPerform : HasIO io => AnyPtr -> io (Either CURLMcode Int)
curlMultiPerform m = multiCount (prim__curlMultiPerform m)

||| Blocks up to `timeoutMs` for activity on `m`'s handles; the number
||| of file descriptors that became ready.
export
curlMultiWait : HasIO io => AnyPtr -> (timeoutMs : Int) -> io (Either CURLMcode Int)
curlMultiWait m timeoutMs = multiCount (prim__curlMultiWait m prim__getNullAnyPtr 0 timeoutMs)

||| `Nothing` once the message queue is empty. `(kind, easy handle,
||| its result)`; the result is meaningful only for `curlmsg_DONE`.
export
curlMultiInfoRead : HasIO io => AnyPtr -> io (Maybe (CURLMSG, AnyPtr, CURLcode))
curlMultiInfoRead m = withCell (prim__newCellI32 8) prim__freeCellI32 $ \c => do
    Just p <- nonNull <$> primIO (prim__curlMultiInfoRead m c)
        | Nothing => pure Nothing
    msg <- primIO (prim__viewMsg p 0 0)
    pure $ Just ( MkCURLMSG (cast (the Int32 (getField msg "msg")))
                , getField msg "easy_handle"
                , MkCURLcode (cast (the Int32 (getField msg "result"))) )

------------------------------------------------------------------------
-- Share interface
------------------------------------------------------------------------

||| `Nothing` on allocation failure (`curl_share_init(3)`).
export
curlShareInit : HasIO io => io (Maybe AnyPtr)
curlShareInit = nonNull <$> primIO prim__curlShareInit

export
curlShareCleanup : HasIO io => AnyPtr -> io CURLSHcode
curlShareCleanup sh = MkCURLSHcode <$> primIO (prim__curlShareCleanup sh)

||| `share`: `True` for `CURLSHOPT_SHARE` (1), `False` for
||| `CURLSHOPT_UNSHARE` (2). Attach `sh` to an easy handle with
||| `curlopt_SHARE`.
export
curlShareSetopt : HasIO io => AnyPtr -> (share : Bool) -> CurlLockData -> io CURLSHcode
curlShareSetopt sh share (MkCurlLockData d) =
    MkCURLSHcode <$> primIO (prim__curlShareSetoptInt sh (if share then 1 else 2) d)

export
curlShareStrerror : CURLSHcode -> String
curlShareStrerror (MkCURLSHcode c) = unsafePerformIO $ primIO (prim__curlShareStrerror c)

------------------------------------------------------------------------
-- Mime interface
------------------------------------------------------------------------

||| `Nothing` on allocation failure (`curl_mime_init(3)`). `h` is the
||| easy handle the mime structure will be attached to via
||| `curlopt_MIMEPOST`.
export
curlMimeInit : HasIO io => AnyPtr -> io (Maybe AnyPtr)
curlMimeInit h = nonNull <$> primIO (prim__curlMimeInit h)

||| Only for a mime structure that never got attached: an attached one
||| is freed by `curl_easy_cleanup`/`curl_easy_reset`.
export
curlMimeFree : HasIO io => AnyPtr -> io ()
curlMimeFree mime = primIO (prim__curlMimeFree mime)

||| `Nothing` on allocation failure (`curl_mime_addpart(3)`).
export
curlMimeAddpart : HasIO io => AnyPtr -> io (Maybe AnyPtr)
curlMimeAddpart mime = nonNull <$> primIO (prim__curlMimeAddpart mime)

export
curlMimeName : HasIO io => AnyPtr -> String -> io CURLcode
curlMimeName part name = MkCURLcode <$> primIO (prim__curlMimeName part name)

export
curlMimeFilename : HasIO io => AnyPtr -> String -> io CURLcode
curlMimeFilename part filename = MkCURLcode <$> primIO (prim__curlMimeFilename part filename)

export
curlMimeType : HasIO io => AnyPtr -> String -> io CURLcode
curlMimeType part mimetype = MkCURLcode <$> primIO (prim__curlMimeType part mimetype)

export
curlMimeData : HasIO io => AnyPtr -> String -> io CURLcode
curlMimeData part data_ = MkCURLcode <$> primIO (prim__curlMimeData part data_ (stringByteLength data_))

export
curlMimeFiledata : HasIO io => AnyPtr -> String -> io CURLcode
curlMimeFiledata part filename = MkCURLcode <$> primIO (prim__curlMimeFiledata part filename)

||| `takeOwnership`: whether libcurl frees `headers` along with `part`
||| (`curl_mime_headers(3)`).
export
curlMimeHeaders : HasIO io => AnyPtr -> AnyPtr -> (takeOwnership : Bool) -> io CURLcode
curlMimeHeaders part headers takeOwnership =
    MkCURLcode <$> primIO (prim__curlMimeHeaders part headers (if takeOwnership then 1 else 0))

------------------------------------------------------------------------
-- Pause/upkeep
------------------------------------------------------------------------

||| `action`: `curlpause_*` bits.
export
curlEasyPause : HasIO io => AnyPtr -> (action : Int) -> io CURLcode
curlEasyPause h action = MkCURLcode <$> primIO (prim__curlEasyPause h action)

export
curlEasyUpkeep : HasIO io => AnyPtr -> io CURLcode
curlEasyUpkeep h = MkCURLcode <$> primIO (prim__curlEasyUpkeep h)

------------------------------------------------------------------------
-- Structured headers
------------------------------------------------------------------------

readHeader : HasIO io => AnyPtr -> io (String, String)
readHeader p = do
    hdr <- primIO (prim__viewHeader p 0 0)
    let str = \f => fromMaybe "" (ptrToString f)
    pure (str (getField hdr "name"), str (getField hdr "value"))

||| The first header called `name`. `Nothing` for any non-OK
||| `CURLHcode`, all of which mean the header isn't available.
||| `origin`: `curlh_*` bits; `request`: `0` for the first request,
||| `-1` for the last.
export
curlEasyHeader : HasIO io => AnyPtr -> (name : String) -> (origin : Int) -> (request : Int) -> io (Maybe (String, String))
curlEasyHeader h name origin request =
    withCell (prim__newCellPtr 8) prim__freeCellPtr $ \c => do
        0 <- primIO (prim__curlEasyHeader h name 0 (cast origin) request c)
            | _ => pure Nothing
        Just <$> readHeader (getField c "v")

||| Iterates headers: pass `curlSlistEmpty` as `prev` to start, then the
||| pointer from the previous result. `Nothing` at the end.
export
curlEasyNextheader : HasIO io => AnyPtr -> (origin : Int) -> (request : Int) -> (prev : AnyPtr) -> io (Maybe (AnyPtr, String, String))
curlEasyNextheader h origin request prev = do
    Just p <- nonNull <$> primIO (prim__curlEasyNextheader h (cast origin) request prev)
        | Nothing => pure Nothing
    (name, value) <- readHeader p
    pure (Just (p, name, value))

------------------------------------------------------------------------
-- Response-body capture
------------------------------------------------------------------------

||| Performs the transfer with `CURLOPT_WRITEDATA` pointed at an
||| `open_memstream(3)` stream, then hands `read` the captured body's
||| NUL-terminated bytes and length, both valid only until `read`
||| returns (doc/http-client.md). The building block for
||| `curlEasyPerformToBuffer`/`ToString` and for other targets such as
||| `curl-rc2`'s `TextBuffer`.
export
curlEasyPerformCapture : HasIO io => (AnyPtr -> Int -> IO (Maybe a)) -> AnyPtr -> io (Maybe (CURLcode, a))
curlEasyPerformCapture read h =
    withCell (prim__newCellPtr 8) prim__freeCellPtr $ \bufCell =>
    withCell (prim__newCellI64 8) prim__freeCellI64 $ \sizeCell => do
        Just fp <- nonNull <$> primIO (prim__openMemstream bufCell sizeCell)
            | Nothing => pure Nothing
        MkCURLcode 0 <- curlEasySetoptPointer h curlopt_WRITEDATA fp
            | _ => do _ <- primIO (prim__fclose fp)
                      primIO (prim__freeRaw (getField bufCell "v"))
                      pure Nothing
        result <- curlEasyPerform h
        _ <- primIO (prim__fclose fp)
        raw <- pure (the AnyPtr (getField bufCell "v"))
        size <- pure (cast {to = Int} (the Int64 (getField sizeCell "v")))
        body <- liftIO (read raw size)
        primIO (prim__freeRaw raw)
        pure (map (result,) body)

||| Performs the transfer, capturing the body. `Nothing` only when the
||| capture itself fails; a transfer failure comes back as the
||| `CURLcode` alongside whatever body was received. `h`'s
||| `CURLOPT_WRITEDATA` is left pointing at the closed stream: set it
||| again before performing on `h` without capture.
export
curlEasyPerformToBuffer : HasIO io => AnyPtr -> io (Maybe (CURLcode, Buffer))
curlEasyPerformToBuffer = curlEasyPerformCapture $ \raw, size => do
    Just buf <- newBuffer size
        | Nothing => pure Nothing
    _ <- primIO (prim__memcpyToBuffer buf raw size)
    pure (Just buf)

||| Same as `curlEasyPerformToBuffer`; the body is cut at its first NUL.
export
curlEasyPerformToString : HasIO io => AnyPtr -> io (Maybe (CURLcode, String))
curlEasyPerformToString = curlEasyPerformCapture $ \raw, _ => pure (ptrToString raw)

