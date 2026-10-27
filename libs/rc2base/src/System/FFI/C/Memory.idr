module System.FFI.C.Memory

import Data.So
import Decidable.Equality
import System.FFI.C.Null
import System.Posix.Errno


-------------------------------------------------------------------------------
--

||| `Right` for a non-NULL pointer, else the `errno` of the call that gave NULL.
||| Only for calls where NULL means failure and sets `errno`: `malloc 0` and
||| `calloc 0 n` may return NULL without failing, which is why `malloc` and
||| `calloc` below take a size that is proved not to be 0.
public export
fromAnyPtr : AnyPtr -> IO (Either Errno NonNullAnyPtr)
fromAnyPtr ptr with (decEq (isNullAnyPtr ptr) False)
  _ | Yes _ =  pure $ Right $ MkNonNullAnyPtr ptr
  _ | No _  = pure $ Left !(errno)



public export Cast AnyPtr (Ptr a) where cast ptr = believe_me ptr
public export Cast (Ptr a) AnyPtr where cast ptr = believe_me ptr

public export
Cast NonNullAnyPtr (NonNullPtr a) where
  cast ptr = MkNonNullPtr (cast ptr.ptr) {prf=believe_me ptr.prf}
public export
Cast (NonNullPtr a) NonNullAnyPtr where
  cast ptr = MkNonNullAnyPtr (cast ptr.ptr) {prf=believe_me ptr.prf}


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:malloc($1),libc,stdlib.h"
prim__malloc : Bits64 -> PrimIO AnyPtr

||| Allocate `size` bytes; release them with `free`. `size` is proved not to be 0
||| (`malloc 0` may return NULL as a success, which cannot be told from failure);
||| for a literal the proof is found by evaluation.
%inline public export
malloc : HasIO io => (size : Bits64) -> {auto 0 nonZero : So (size /= 0)}
      -> io (Either Errno NonNullAnyPtr)
malloc size = liftIO $ (primIO (prim__malloc size) >>= fromAnyPtr)


%inline %foreign "CExpr:calloc($1, $2),libc,stdlib.h"
prim__calloc : Bits64 -> Bits64 -> PrimIO AnyPtr

||| Allocate `count * size` zeroed bytes; release them with `free`. Neither is
||| proved to be 0, for the reason given at `malloc`.
%inline public export
calloc : HasIO io => (count : Bits64) -> (size : Bits64)
      -> {auto 0 countNonZero : So (count /= 0)} -> {auto 0 sizeNonZero : So (size /= 0)}
      -> io (Either Errno NonNullAnyPtr)
calloc count size = liftIO $ (primIO (prim__calloc count size) >>= fromAnyPtr)



%inline %foreign "CExpr:free($1),libc,stdlib.h"
prim__free : AnyPtr -> PrimIO ()

public export free : HasIO io => (ptr : AnyPtr) -> io ()
free ptr = liftIO $ primIO $ prim__free ptr

-------------------------------------------------------------------------------
-- <memory.h> / <string.h>
--
-- The `mem*` group is declared by both <string.h> and the historical
-- <memory.h> (which some systems no longer ship); these bindings include
-- <string.h>, which every target has. All `char *`/`void *` parameters
-- are `AnyPtr` (`cast` converts a `Ptr a`; take `.ptr` of a `NonNullAnyPtr`);
-- `strdupString` is the one place an Idris `String` is accepted, since
-- the FFI marshals it to a temporary NUL-terminated `char *`. Sizes are
-- byte counts (`size_t`, 64-bit on the hosts rc2 targets).

%inline %foreign "C:memcpy,libc,string.h"
prim__memcpy : AnyPtr -> AnyPtr -> Bits64 -> PrimIO AnyPtr

||| Copy `size` bytes from `src` to `dest`. The regions must not overlap;
||| use `memmove` when they may.
%inline public export
memcpy : (dest : AnyPtr) -> (src : AnyPtr) -> (size : Bits64) -> IO ()
memcpy dest src size = ignore $ primIO (prim__memcpy dest src size)


%inline %foreign "C:memmove,libc,string.h"
prim__memmove : AnyPtr -> AnyPtr -> Bits64 -> PrimIO AnyPtr

||| Copy `size` bytes from `src` to `dest`. The regions may overlap.
%inline public export
memmove : (dest : AnyPtr) -> (src : AnyPtr) -> (size : Bits64) -> IO ()
memmove dest src size = ignore $ primIO (prim__memmove dest src size)


%inline %foreign "C:memset,libc,string.h"
prim__memset : AnyPtr -> Int32 -> Bits64 -> PrimIO AnyPtr

||| Fill `size` bytes at `dest` with the low 8 bits of `value`.
%inline public export
memset : (dest : AnyPtr) -> (value : Int32) -> (size : Bits64) -> IO ()
memset dest value size = ignore $ primIO (prim__memset dest value size)


%inline %foreign "C:memcmp,libc,string.h"
prim__memcmp : AnyPtr -> AnyPtr -> Bits64 -> PrimIO Int32

||| Compare the first `size` bytes of two regions: negative, zero or
||| positive as the first is less than, equal to or greater than the second.
%inline public export
memcmp : AnyPtr -> AnyPtr -> Bits64 -> IO Int32
memcmp a b size = primIO $ prim__memcmp a b size


%inline %foreign "C:memchr,libc,string.h"
prim__memchr : AnyPtr -> Int32 -> Bits64 -> PrimIO AnyPtr

||| The first occurrence of the byte `value` in the first `size` bytes of
||| `ptr`, or NULL (check with `isNullAnyPtr`).
%inline public export
memchr : AnyPtr -> Int32 -> Bits64 -> IO AnyPtr
memchr ptr value size = primIO $ prim__memchr ptr value size


%inline %foreign "C:strlen,libc,string.h"
prim__strlen : AnyPtr -> PrimIO Bits64

||| The length of a NUL-terminated string, excluding the terminator.
%inline public export
strlen : AnyPtr -> IO Bits64
strlen ptr = primIO $ prim__strlen ptr


%inline %foreign "C:strcmp,libc,string.h"
prim__strcmp : AnyPtr -> AnyPtr -> PrimIO Int32

||| Compare two NUL-terminated strings: negative, zero or positive as the
||| first is less than, equal to or greater than the second.
%inline public export
strcmp : AnyPtr -> AnyPtr -> IO Int32
strcmp a b = primIO $ prim__strcmp a b


%inline %foreign "C:strncmp,libc,string.h"
prim__strncmp : AnyPtr -> AnyPtr -> Bits64 -> PrimIO Int32

||| Compare at most the first `size` bytes of two NUL-terminated strings.
%inline public export
strncmp : AnyPtr -> AnyPtr -> Bits64 -> IO Int32
strncmp a b size = primIO $ prim__strncmp a b size


%inline %foreign "C:strcpy,libc,string.h"
prim__strcpy : AnyPtr -> AnyPtr -> PrimIO AnyPtr

||| Copy a NUL-terminated string, including its terminator, to `dest`,
||| which must have room for it. The regions must not overlap.
%inline public export
strcpy : (dest : AnyPtr) -> (src : AnyPtr) -> IO ()
strcpy dest src = ignore $ primIO (prim__strcpy dest src)


%inline %foreign "C:strncpy,libc,string.h"
prim__strncpy : AnyPtr -> AnyPtr -> Bits64 -> PrimIO AnyPtr

||| Copy at most `size` bytes of a string to `dest`, NUL-padding when the
||| source is shorter. If the source is at least `size` bytes, the result
||| is not NUL-terminated.
%inline public export
strncpy : (dest : AnyPtr) -> (src : AnyPtr) -> (size : Bits64) -> IO ()
strncpy dest src size = ignore $ primIO (prim__strncpy dest src size)


%inline %foreign "C:strcat,libc,string.h"
prim__strcat : AnyPtr -> AnyPtr -> PrimIO AnyPtr

||| Append a copy of the NUL-terminated `src` (including its terminator)
||| to the NUL-terminated `dest`, which must have room for both.
%inline public export
strcat : (dest : AnyPtr) -> (src : AnyPtr) -> IO ()
strcat dest src = ignore $ primIO (prim__strcat dest src)


%inline %foreign "C:strncat,libc,string.h"
prim__strncat : AnyPtr -> AnyPtr -> Bits64 -> PrimIO AnyPtr

||| Append at most `size` bytes of `src` to the NUL-terminated `dest`, then
||| terminate the result. `dest` must have room for its text, those bytes
||| and the terminator.
%inline public export
strncat : (dest : AnyPtr) -> (src : AnyPtr) -> (size : Bits64) -> IO ()
strncat dest src size = ignore $ primIO (prim__strncat dest src size)


%inline %foreign "C:strchr,libc,string.h"
prim__strchr : AnyPtr -> Int32 -> PrimIO AnyPtr

||| The first occurrence of the character `value` in a NUL-terminated
||| string, or NULL (check with `isNullAnyPtr`).
%inline public export
strchr : AnyPtr -> Int32 -> IO AnyPtr
strchr ptr value = primIO $ prim__strchr ptr value


%inline %foreign "C:strrchr,libc,string.h"
prim__strrchr : AnyPtr -> Int32 -> PrimIO AnyPtr

||| The last occurrence of the character `value` in a NUL-terminated
||| string, or NULL (check with `isNullAnyPtr`).
%inline public export
strrchr : AnyPtr -> Int32 -> IO AnyPtr
strrchr ptr value = primIO $ prim__strrchr ptr value


%inline %foreign "C:strstr,libc,string.h"
prim__strstr : AnyPtr -> AnyPtr -> PrimIO AnyPtr

||| The first occurrence of the NUL-terminated `needle` in the
||| NUL-terminated `haystack`, or NULL (check with `isNullAnyPtr`).
%inline public export
strstr : (haystack : AnyPtr) -> (needle : AnyPtr) -> IO AnyPtr
strstr haystack needle = primIO $ prim__strstr haystack needle


%inline %foreign "C:strdup,libc,string.h"
prim__strdup : AnyPtr -> PrimIO AnyPtr

||| Allocate a fresh copy of a NUL-terminated string (POSIX, declared by
||| <string.h>); release it with `free`.
%inline public export
strdup : AnyPtr -> IO (Either Errno NonNullAnyPtr)
strdup ptr = primIO (prim__strdup ptr) >>= fromAnyPtr


%inline %foreign "C:strdup,libc,string.h"
prim__strdupString : String -> PrimIO AnyPtr

||| `strdup` for an Idris `String`: the FFI passes a temporary
||| NUL-terminated copy, and the result is a fresh allocation to `free`.
%inline public export
strdupString : String -> IO (Either Errno NonNullAnyPtr)
strdupString str = primIO (prim__strdupString str) >>= fromAnyPtr

-------------------------------------------------------------------------------
--

