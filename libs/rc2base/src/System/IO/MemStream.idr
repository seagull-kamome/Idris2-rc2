module System.IO.MemStream

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- An in-memory `FILE *` capture stream (POSIX `open_memstream(3)`),
-- for redirecting any C API's own "write to this FILE*" option (e.g.
-- libcurl's `CURLOPT_WRITEDATA`) into memory instead of a real file
-- descriptor -- read back as a `Buffer`/`String`/`TextBuffer`, one
-- copy each, no callback of any kind involved.

import Data.Buffer
import Data.So
import Data.String.FFI
import Data.TextBuffer
import System.FFI

export
data MemStream = MkMemStream AnyPtr

%foreign "C:idris2rc2_memstream_open,libidris2rc2base,memstream.h"
prim__memstreamOpen : PrimIO AnyPtr

%foreign "C:idris2rc2_memstream_filep,libidris2rc2base,memstream.h"
prim__memstreamFilep : AnyPtr -> PrimIO AnyPtr

%foreign "C:idris2rc2_memstream_close,libidris2rc2base,memstream.h"
prim__memstreamClose : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_memstream_data,libidris2rc2base,memstream.h"
prim__memstreamData : AnyPtr -> PrimIO AnyPtr

%foreign "C:idris2rc2_memstream_size,libidris2rc2base,memstream.h"
prim__memstreamSize : AnyPtr -> PrimIO Int

%foreign "C:idris2rc2_memstream_free,libidris2rc2base,memstream.h"
prim__memstreamFree : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_memstream_copy_into_buffer,libidris2rc2base,memstream.h"
prim__memstreamCopyIntoBuffer : AnyPtr -> Buffer -> PrimIO ()

||| Opens an in-memory capture stream -- pass `filePtr`'s own result to
||| any C API's own "write to this FILE*" option, then `close` once
||| every write into it is done, before any `toBuffer`/`toString`/
||| `toTextBuffer`/`size` read. `Nothing` on `open_memstream(3)`/
||| allocation failure.
export
newMemStream : IO (Maybe MemStream)
newMemStream = do
    m <- primIO prim__memstreamOpen
    pure $ if prim__nullAnyPtr m /= 0 then Nothing else Just (MkMemStream m)

||| The `FILE *` to hand to a C API's own "write to this FILE*" option.
export
filePtr : MemStream -> IO AnyPtr
filePtr (MkMemStream m) = primIO (prim__memstreamFilep m)

||| Flushes and finalizes the captured bytes -- call exactly once,
||| after every write into `filePtr`'s own `FILE*` is done, before any
||| `toBuffer`/`toString`/`toTextBuffer`/`size` call.
export
close : MemStream -> IO ()
close (MkMemStream m) = primIO (prim__memstreamClose m)

||| Releases the stream and the bytes it captured -- call once, after
||| every read below is done.
export
free : MemStream -> IO ()
free (MkMemStream m) = primIO (prim__memstreamFree m)

||| Exact captured byte count. Call `close` first.
export
size : MemStream -> IO Int
size (MkMemStream m) = primIO (prim__memstreamSize m)

||| One copy, straight into a freshly allocated Idris `Buffer` at its
||| own native layout (`support/c/memstream.c`'s own doc comment on
||| `idris2rc2_memstream_copy_into_buffer`). The only one of the three
||| `to*` conversions that's exact-byte-count and embedded-NUL-safe
||| (`Buffer`'s whole point). Call `close` first.
export
toBuffer : MemStream -> IO (Maybe Buffer)
toBuffer (MkMemStream m) = do
    len <- primIO (prim__memstreamSize m)
    Just buf <- newBuffer len
        | Nothing => pure Nothing
    primIO (prim__memstreamCopyIntoBuffer m buf)
    pure (Just buf)

||| One copy, via `ptrToString`'s NUL-terminated read -- safe here
||| since `open_memstream(3)` itself always NUL-terminates on `close`;
||| truncates early only if the captured bytes themselves contain an
||| embedded NUL. Call `close` first.
export
toString : MemStream -> IO (Maybe String)
toString (MkMemStream m) = do
    raw <- primIO (prim__memstreamData m)
    pure (ptrToString raw)

||| One copy, via `fromRawUtf8`'s direct raw-bytes decode -- no
||| intermediate `String`. Same NUL-terminated-read caveat as
||| `toString` above. Call `close` first.
export
toTextBuffer : MemStream -> IO (Maybe TextBuffer)
toTextBuffer (MkMemStream m) = do
    raw <- primIO (prim__memstreamData m)
    case choose (prim__nullAnyPtr raw == 0) of
         Right _  => pure Nothing
         Left prf => Just <$> fromRawUtf8 raw prf
