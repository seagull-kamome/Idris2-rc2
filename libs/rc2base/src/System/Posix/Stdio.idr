||| C standard I/O (`<stdio.h>`): buffered `FILE *` streams.
|||
||| Failures come back as `Left errno`. Where the C function reports a
||| failure without setting `errno` (a short `fread`/`fwrite`, `EOF` from
||| `fgetc`), the function returns the count or `Nothing` and `feof`/`ferror`
||| tell the cases apart.
|||
||| `File`, `stdin`, `stdout` and `stderr` here are not the ones of the
||| Prelude's `System.File`: import this module qualified, or hide those
||| names, when both are in scope.
|||
||| Not bound: the `printf`/`scanf` families (variadic), `fgetpos`/`fsetpos`
||| (opaque `fpos_t`; use `ftell`/`fseek`), `setbuf` and `tmpnam`/`tempnam`
||| (race-prone).
module System.Posix.Stdio

import Decidable.Equality
import Data.Buffer
import Data.String
import Data.String.FFI
import Data.String.RC2
import System.FFI
import System.FFI.C.Null
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc

-------------------------------------------------------------------------------
-- Types and constants

||| The C type `FILE`.
public export data RawFile : Type where

||| A stream: a `FILE *`.
export File : Type
File = NonNullPtr RawFile



||| How a stream is buffered, see `setvbuf`.
public export
data BufMode = FullyBuffered | LineBuffered | Unbuffered

||| The `EOF` value of the C functions returning an `int` character.
%inline %foreign "CExpr:(EOF),libc,stdio.h"
export EOF : Int32

||| The default buffer size of a stream.
%inline %foreign "CExpr:(BUFSIZ),libc,stdio.h"
export BUFSIZ : Int32

||| The longest file name an implementation guarantees to handle.
%inline %foreign "CExpr:(FILENAME_MAX),libc,stdio.h"
export FILENAME_MAX : Int32

%inline %foreign "CExpr:(_IOFBF),libc,stdio.h"
prim__IOFBF : Int32
%inline %foreign "CExpr:(_IOLBF),libc,stdio.h"
prim__IOLBF : Int32
%inline %foreign "CExpr:(_IONBF),libc,stdio.h"
prim__IONBF : Int32

%foreign "CExpr:(stdin),libc,stdio.h"
prim__stdin : Ptr RawFile
%foreign "CExpr:(stdout),libc,stdio.h"
prim__stdout : Ptr RawFile
%foreign "CExpr:(stderr),libc,stdio.h"
prim__stderr : Ptr RawFile

||| The standard input stream.
export stdin : File
stdin = MkNonNullPtr {prf=believe_me $ Refl{x=False}} prim__stdin

||| The standard output stream.
export stdout : File
stdout = MkNonNullPtr {prf=believe_me $ Refl{x=False}} prim__stdout 

||| The standard error stream.
export stderr : File
stderr = MkNonNullPtr {prf=believe_me $ Refl{x=False}} prim__stderr

||| Turn a C status (0 on success, nonzero such as `EOF` on failure) into a result.
status : Int32 -> IO (Either Errno ())
status 0 = pure (Right ())
status _ = Left <$> errno

||| Turn a `FILE *` (NULL on failure) into a result.
stream : Ptr RawFile -> IO (Either Errno File)
stream x with (decEq (isNullPtr x) False)
  _ | Yes _ = pure $ Right $ MkNonNullPtr x
  _ | No _  = pure $ Left !(errno)

-------------------------------------------------------------------------------
-- Open and close

%inline %foreign "CExpr:(fopen($1, $2)),libc,stdio.h"
prim__fopen : String -> String -> PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(fdopen($1, $2)),libc,stdio.h"
prim__fdopen : Int32 -> String -> PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(freopen($1, $2, $3)),libc,stdio.h"
prim__freopen : String -> String -> Ptr RawFile -> PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(tmpfile()),libc,stdio.h"
prim__tmpfile : PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(fmemopen(NULL, $1, $2)),libc,stdio.h"
prim__fmemopen : Bits64 -> String -> PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(fclose($1)),libc,stdio.h"
prim__fclose : Ptr RawFile -> PrimIO Int32

||| Open the file at `path`; `mode` is `"r"`, `"w"`, `"a"`, `"r+"`, ... .
export
fopen : String -> (mode : String) -> IO (Either Errno File)
fopen path mode = primIO (prim__fopen path mode) >>= stream

||| Associate a stream with an open file descriptor.
export
fdopen : FileDesc -> (mode : String) -> IO (Either Errno File)
fdopen fd mode = primIO (prim__fdopen fd.rawfd mode) >>= stream

||| Reopen `file` on `path`, closing what it was on. Failure closes `file`.
export
freopen : String -> (mode : String) -> File -> IO (Either Errno File)
freopen path mode file = primIO (prim__freopen path mode file.ptr) >>= stream

||| A fresh anonymous file, opened `"w+"` and removed when closed.
export
tmpfile : IO (Either Errno File)
tmpfile = primIO prim__tmpfile >>= stream

||| A stream over a new zeroed memory area of `size` bytes (POSIX.1-2008
||| `fmemopen` with a NULL buffer; the area is freed on `fclose`).
export
fmemopen : (size : Bits64) -> (mode : String) -> IO (Either Errno File)
fmemopen size mode = primIO (prim__fmemopen size mode) >>= stream

||| Flush and close a stream. The stream is gone even when this fails.
export
fclose : File -> IO (Either Errno ())
fclose file = primIO (prim__fclose file.ptr) >>= status

-------------------------------------------------------------------------------
-- Memory output stream

||| A stream that collects what is written to it in memory (`open_memstream`).
||| Write to `memstreamFile` (or hand `memstreamFilePtr` to a C function that wants
||| a `FILE *`, such as libcurl's `CURLOPT_WRITEDATA`), then `closeMemstream`, then
||| read the bytes; `freeMemstream` releases them.
export
record MemStream where
  constructor MkMemStream
  mfile : File
  bufCell : AnyPtr
  sizeCell : AnyPtr

%inline %foreign "CExpr:(open_memstream((char **)($1), (size_t *)($2))),libc,stdio.h"
prim__open_memstream : AnyPtr -> AnyPtr -> PrimIO (Ptr RawFile)
%inline %foreign "CExpr:(*(void **)($1)),libc,stdlib.h"
prim__ptrAt : AnyPtr -> PrimIO AnyPtr
%inline %foreign "CExpr:(*(size_t *)($1)),libc,stdlib.h"
prim__sizeAt : AnyPtr -> PrimIO Bits64
%inline %foreign "CExpr:(({ *(void **)($1) = NULL; 0; })),libc,stdlib.h"
prim__clearPtr : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(({ *(size_t *)($1) = 0; 0; })),libc,stdlib.h"
prim__clearSize : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(({ free(*(void **)($1)); 0; })),libc,stdlib.h"
prim__freeAt : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(memcpy($1, $2, $3)),libc,string.h"
prim__memcpyToBuffer : Buffer -> AnyPtr -> Bits64 -> PrimIO AnyPtr

||| Open a memory output stream.
export
openMemstream : IO (Either Errno MemStream)
openMemstream = do
  buf <- malloc 8
  size <- malloc 8
  _ <- primIO (prim__clearPtr buf)
  _ <- primIO (prim__clearSize size)
  r <- primIO (prim__open_memstream buf size) >>= stream
  case r of
    Right file => pure (Right (MkMemStream file buf size))
    Left e => free buf >> free size >> pure (Left e)

||| The stream to write to with the functions of this module.
export
memstreamFile : MemStream -> File
memstreamFile ms = ms.mfile

||| The `FILE *` of a stream, for a C function that takes one.
export
filePtr : File -> AnyPtr
filePtr file = prim__forgetPtr file.ptr

||| The `FILE *` of the memory stream, for a C function that takes one.
export
memstreamFilePtr : MemStream -> AnyPtr
memstreamFilePtr ms = filePtr ms.mfile

||| Flush and close the stream: only now do `memstreamData` and `memstreamSize`
||| give the whole of what was written. The stream is gone afterwards, so do not
||| use `memstreamFile` or `memstreamFilePtr` again. When this fails the data and
||| size may be stale, but `freeMemstream` is still safe.
export
closeMemstream : MemStream -> IO (Either Errno ())
closeMemstream ms = fclose ms.mfile

||| The bytes written, followed by a NUL that is not counted in the size. Valid
||| until `freeMemstream`, and only after `closeMemstream`.
export
memstreamData : MemStream -> IO AnyPtr
memstreamData ms = primIO (prim__ptrAt ms.bufCell)

||| The number of bytes written. Only after `closeMemstream`.
export
memstreamSize : MemStream -> IO Bits64
memstreamSize ms = primIO (prim__sizeAt ms.sizeCell)

||| The bytes written, copied into a new `Buffer` (embedded NULs stay). Only after
||| `closeMemstream`.
export
memstreamBuffer : MemStream -> IO (Maybe Buffer)
memstreamBuffer ms = do
  size <- memstreamSize ms
  Just buf <- newBuffer (cast size)
    | Nothing => pure Nothing
  p <- memstreamData ms
  _ <- primIO (prim__memcpyToBuffer buf p size)
  pure (Just buf)

||| The bytes written, copied into a `String`; an embedded NUL cuts it short.
||| Only after `closeMemstream`.
export
memstreamString : MemStream -> IO (Maybe String)
memstreamString ms = memstreamData ms >>= ptrToString

||| Release the bytes and the stream's bookkeeping. Call `closeMemstream` first
||| (without it the stream itself leaks), and read what is wanted before.
export
freeMemstream : MemStream -> IO ()
freeMemstream ms = do
  _ <- primIO (prim__freeAt ms.bufCell)
  free ms.bufCell
  free ms.sizeCell

-------------------------------------------------------------------------------
-- Reading and writing

namespace AnyPtr
  %inline %foreign "CExpr:(fread($1, 1, $2, $3)),libc,stdio.h"
  prim__fread : AnyPtr -> Bits64 -> Ptr RawFile -> PrimIO Bits64
  %inline %foreign "CExpr:(fwrite($1, 1, $2, $3)),libc,stdio.h"
  prim__fwrite : AnyPtr -> Bits64 -> Ptr RawFile -> PrimIO Bits64

  ||| Read up to `count` bytes into memory; the number of bytes read, fewer at
  ||| the end of the file or on error (see `feof`/`ferror`).
  %inline export
  fread : File -> AnyPtr -> (count : Bits64) -> IO Bits64
  fread file buf count = primIO (prim__fread buf count file.ptr)

  ||| Write `count` bytes from memory; the number of bytes written, fewer on error.
  %inline export
  fwrite : File -> AnyPtr -> (count : Bits64) -> IO Bits64
  fwrite file buf count = primIO (prim__fwrite buf count file.ptr)

namespace Buffer
  %inline %foreign "CExpr:(fread($1, 1, $2, $3)),libc,stdio.h"
  prim__fread : Buffer -> Bits64 -> Ptr RawFile -> PrimIO Bits64
  %inline %foreign "CExpr:(fwrite($1, 1, $2, $3)),libc,stdio.h"
  prim__fwrite : Buffer -> Bits64 -> Ptr RawFile -> PrimIO Bits64

  ||| Fill the whole buffer; the number of bytes read, fewer at the end of the
  ||| file or on error (see `feof`/`ferror`).
  %inline export
  fread : File -> Buffer -> IO Bits64
  fread file buf = primIO (prim__fread buf (cast {to = Bits64} !(rawSize buf)) file.ptr)

  ||| Write the whole buffer; the number of bytes written, fewer on error.
  %inline export
  fwrite : File -> Buffer -> IO Bits64
  fwrite file buf = primIO (prim__fwrite buf (cast {to = Bits64} !(rawSize buf)) file.ptr)

namespace String
  %inline %foreign "CExpr:(fwrite($1, 1, $2, $3)),libc,stdio.h"
  prim__fwrite : String -> Bits64 -> Ptr RawFile -> PrimIO Bits64

  ||| Write the UTF-8 bytes of a string (including any NUL); the number of bytes written.
  %inline export
  fwrite : File -> String -> IO Bits64
  fwrite file str = primIO (prim__fwrite str (cast {to = Bits64} (byteLength str)) file.ptr)

%inline %foreign "CExpr:(fgetc($1)),libc,stdio.h"
prim__fgetc : Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(fputc($1, $2)),libc,stdio.h"
prim__fputc : Int32 -> Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(ungetc($1, $2)),libc,stdio.h"
prim__ungetc : Int32 -> Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(fputs($1, $2)),libc,stdio.h"
prim__fputs : String -> Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(fgets($1, $2, $3)),libc,stdio.h"
prim__fgets : AnyPtr -> Int32 -> Ptr RawFile -> PrimIO AnyPtr
%inline %foreign "CExpr:(ferror($1)),libc,stdio.h"
prim__ferror : Ptr RawFile -> PrimIO Int32

||| The next byte; `Nothing` at the end of the file or on error.
export
fgetc : File -> IO (Maybe Bits8)
fgetc file = do
  c <- primIO (prim__fgetc file.ptr)
  pure (if c < 0 then Nothing else Just (cast c))

||| Write one byte.
export
fputc : File -> Bits8 -> IO (Either Errno ())
fputc file c = do
  r <- primIO (prim__fputc (cast c) file.ptr)
  if r < 0 then Left <$> errno else pure (Right ())

||| Push one byte back; only one byte of pushback is guaranteed.
export
ungetc : File -> Bits8 -> IO (Either Errno ())
ungetc file c = do
  r <- primIO (prim__ungetc (cast c) file.ptr)
  if r < 0 then Left <$> errno else pure (Right ())

||| Write a string (without the trailing newline `puts` would add). The string
||| is written up to its first NUL; use `String.fwrite` for the whole of it.
export
fputs : File -> String -> IO (Either Errno ())
fputs file str = do
  r <- primIO (prim__fputs str file.ptr)
  if r < 0 then Left <$> errno else pure (Right ())

||| Read a line of at most `size - 1` bytes, with its newline if it fit.
||| `Right Nothing` at the end of the file. The text is cut at a NUL byte.
export
fgets : File -> (size : Int32) -> IO (Either Errno (Maybe String))
fgets file size = do
  buf <- malloc (cast {to = Int} size)
  p <- primIO (prim__fgets buf size file.ptr)
  r <- if prim__nullAnyPtr p /= 0
         then do e <- primIO (prim__ferror file.ptr)
                 if e /= 0 then Left <$> errno else pure (Right Nothing)
         else Right <$> ptrToString buf
  free buf
  pure r

-------------------------------------------------------------------------------
-- getline (POSIX.1-2008)

CellPtr : Type
CellPtr = Struct "rc2base_stdio_cell_ptr" [("v", AnyPtr)]

CellSize : Type
CellSize = Struct "rc2base_stdio_cell_size" [("v", Bits64)]

-- A cell must come from a `%foreign` return typed as the `Struct`
-- (see `Network.HTTP.Client.Curl.Raw`); `calloc` zeroes it, which is what
-- `getline` needs (a NULL line buffer and a zero size).
%foreign "CExpr:(calloc($1, $2)),libc,stdlib.h"
prim__newCellPtr : Bits64 -> Bits64 -> PrimIO CellPtr
%foreign "CExpr:(calloc($1, $2)),libc,stdlib.h"
prim__newCellSize : Bits64 -> Bits64 -> PrimIO CellSize
%foreign "CExpr:(free($1)),libc,stdlib.h"
prim__freeCellPtr : CellPtr -> PrimIO ()
%foreign "CExpr:(free($1)),libc,stdlib.h"
prim__freeCellSize : CellSize -> PrimIO ()
%foreign "CExpr:(free($1)),libc,stdlib.h"
prim__freeLine : AnyPtr -> PrimIO ()
%foreign "CExpr:(getline((char **)$1, (size_t *)$2, $3)),libc,stdio.h"
prim__getline : CellPtr -> CellSize -> Ptr RawFile -> PrimIO Int64

||| Read a whole line of any length, without its trailing newline.
||| `Right Nothing` at the end of the file. The text is cut at a NUL byte.
export
getline : File -> IO (Either Errno (Maybe String))
getline file = do
  line <- primIO (prim__newCellPtr 1 8)
  size <- primIO (prim__newCellSize 1 8)
  n <- primIO (prim__getline line size file.ptr)
  let raw = the AnyPtr (getField line "v")
  r <- if n < 0
         then do e <- primIO (prim__ferror file.ptr)
                 if e /= 0 then Left <$> errno else pure (Right Nothing)
         else Right . map dropNewline <$> ptrToString raw
  primIO (prim__freeLine raw)
  primIO (prim__freeCellPtr line)
  primIO (prim__freeCellSize size)
  pure r
 where
  dropNewline : String -> String
  dropNewline s = if isSuffixOf "\n" s then substr 0 (minus (length s) 1) s else s

-------------------------------------------------------------------------------
-- Position

%inline %foreign "CExpr:(fseek($1, $2, $3)),libc,stdio.h"
prim__fseek : Ptr RawFile -> Int64 -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(ftell($1)),libc,stdio.h"
prim__ftell : Ptr RawFile -> PrimIO Int64
%inline %foreign "CExpr:(fseeko($1, $2, $3)),libc,stdio.h"
prim__fseeko : Ptr RawFile -> Int64 -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(ftello($1)),libc,stdio.h"
prim__ftello : Ptr RawFile -> PrimIO Int64
%inline %foreign "CExpr:(rewind($1)),libc,stdio.h"
prim__rewind : Ptr RawFile -> PrimIO ()

whence : SeekWhence -> Bits32
whence (MkSeekWhence w) = w

||| Move the position (`long` offset).
export
fseek : File -> Int64 -> SeekWhence -> IO (Either Errno ())
fseek file off w = primIO (prim__fseek file.ptr off (whence w)) >>= status

||| The position (`long`); `Left` on error.
export
ftell : File -> IO (Either Errno Int64)
ftell file = do
  p <- primIO (prim__ftell file.ptr)
  if p < 0 then Left <$> errno else pure (Right p)

||| Move the position (`off_t` offset).
export
fseeko : File -> Int64 -> SeekWhence -> IO (Either Errno ())
fseeko file off w = primIO (prim__fseeko file.ptr off (whence w)) >>= status

||| The position (`off_t`); `Left` on error.
export
ftello : File -> IO (Either Errno Int64)
ftello file = do
  p <- primIO (prim__ftello file.ptr)
  if p < 0 then Left <$> errno else pure (Right p)

||| Back to the start of the stream and clear its error indicator.
export
rewind : File -> IO ()
rewind file = primIO (prim__rewind file.ptr)

-------------------------------------------------------------------------------
-- State, buffering, file descriptor

%inline %foreign "CExpr:(fflush($1)),libc,stdio.h"
prim__fflush : Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(fflush(NULL)),libc,stdio.h"
prim__fflushAll : PrimIO Int32
%inline %foreign "CExpr:(feof($1)),libc,stdio.h"
prim__feof : Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(clearerr($1)),libc,stdio.h"
prim__clearerr : Ptr RawFile -> PrimIO ()
%inline %foreign "CExpr:(fileno($1)),libc,stdio.h"
prim__fileno : Ptr RawFile -> PrimIO Int32
%inline %foreign "CExpr:(setvbuf($1, NULL, $2, $3)),libc,stdio.h"
prim__setvbuf : Ptr RawFile -> Int32 -> Bits64 -> PrimIO Int32

||| Write out the buffered data of one stream.
export
fflush : File -> IO (Either Errno ())
fflush file = primIO (prim__fflush file.ptr) >>= status

||| Write out the buffered data of every open output stream.
export
fflushAll : IO (Either Errno ())
fflushAll = primIO prim__fflushAll >>= status

||| True once a read hit the end of the file.
export
feof : File -> IO Bool
feof file = (/= 0) <$> primIO (prim__feof file.ptr)

||| True once an error happened on the stream.
export
ferror : File -> IO Bool
ferror file = (/= 0) <$> primIO (prim__ferror file.ptr)

||| Clear the end-of-file and error indicators.
export
clearerr : File -> IO ()
clearerr file = primIO (prim__clearerr file.ptr)

||| The file descriptor under the stream.
export
fileno : File -> IO (Either Errno FileDesc)
fileno file = primIO (prim__fileno file.ptr) >>= primFdToFileDesc

||| Set the buffering mode and, for the buffered modes, the size of a buffer
||| the library allocates (the stdio default when 0). Call it before any
||| other operation on the stream.
export
setvbuf : File -> BufMode -> (size : Bits64) -> IO (Either Errno ())
setvbuf file mode size = primIO (prim__setvbuf file.ptr (modeValue mode) size) >>= status
 where
  modeValue : BufMode -> Int32
  modeValue FullyBuffered = prim__IOFBF
  modeValue LineBuffered  = prim__IOLBF
  modeValue Unbuffered    = prim__IONBF

-------------------------------------------------------------------------------
-- Locking

%inline %foreign "CExpr:(flockfile($1)),libc,stdio.h"
prim__flockfile : Ptr RawFile -> PrimIO ()
%inline %foreign "CExpr:(funlockfile($1)),libc,stdio.h"
prim__funlockfile : Ptr RawFile -> PrimIO ()
%inline %foreign "CExpr:(ftrylockfile($1)),libc,stdio.h"
prim__ftrylockfile : Ptr RawFile -> PrimIO Int32

||| Take the lock of a stream (recursive, per thread).
export
flockfile : File -> IO ()
flockfile file = primIO (prim__flockfile file.ptr)

||| Release the lock of a stream.
export
funlockfile : File -> IO ()
funlockfile file = primIO (prim__funlockfile file.ptr)

||| Take the lock if it is free; True when it was taken.
export
ftrylockfile : File -> IO Bool
ftrylockfile file = (== 0) <$> primIO (prim__ftrylockfile file.ptr)

-------------------------------------------------------------------------------
-- Files by name

%inline %foreign "CExpr:(remove($1)),libc,stdio.h"
prim__remove : String -> PrimIO Int32
%inline %foreign "CExpr:(rename($1, $2)),libc,stdio.h"
prim__rename : String -> String -> PrimIO Int32

||| Remove a file or an empty directory.
export
remove : String -> IO (Either Errno ())
remove path = primIO (prim__remove path) >>= status

||| Rename (move) a file.
export
rename : (from, to : String) -> IO (Either Errno ())
rename from to = primIO (prim__rename from to) >>= status


