||| `memfd_create`: an anonymous file that lives in memory, with file seals that
||| stop it from being changed once it is shared.
|||
||| Linux only. `memfd_create` and the seals are declared by glibc only under
||| `_GNU_SOURCE`: build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`.
module System.Linux.Memfd

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

||| Close the descriptor on `exec`. Needs `_GNU_SOURCE`.
%inline %foreign "CExpr:(MFD_CLOEXEC),libc,sys/mman.h"
export MFD_CLOEXEC : Bits32
||| Allow `addSeals` on the file. Needs `_GNU_SOURCE`.
%inline %foreign "CExpr:(MFD_ALLOW_SEALING),libc,sys/mman.h"
export MFD_ALLOW_SEALING : Bits32

||| An `or` of `F_SEAL_*` bits (these need `_GNU_SOURCE`).
public export
Seals : Type
Seals = Int32

||| No more seals can be added.
%inline %foreign "CExpr:(F_SEAL_SEAL),libc,fcntl.h"
export F_SEAL_SEAL : Seals
||| The file cannot shrink.
%inline %foreign "CExpr:(F_SEAL_SHRINK),libc,fcntl.h"
export F_SEAL_SHRINK : Seals
||| The file cannot grow.
%inline %foreign "CExpr:(F_SEAL_GROW),libc,fcntl.h"
export F_SEAL_GROW : Seals
||| The contents cannot be written (existing writable mappings stop it from being added).
%inline %foreign "CExpr:(F_SEAL_WRITE),libc,fcntl.h"
export F_SEAL_WRITE : Seals

%inline %foreign "CExpr:(memfd_create($1, $2)),libc,sys/mman.h"
prim__memfd_create : String -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(fcntl($1, F_ADD_SEALS, $2)),libc,fcntl.h"
prim__add_seals : Int32 -> Seals -> PrimIO Int32
%inline %foreign "CExpr:(fcntl($1, F_GET_SEALS)),libc,fcntl.h"
prim__get_seals : Int32 -> PrimIO Int32

||| Create an empty in-memory file. `name` only shows in `/proc/self/fd`;
||| `flags` is an `or` of `MFD_CLOEXEC` and `MFD_ALLOW_SEALING`.
export
memfd_create : (name : String) -> (flags : Bits32) -> IO (Either Errno FileDesc)
memfd_create name flags = primIO (prim__memfd_create name flags) >>= primFdToFileDesc

||| Add seals; the file must have been created with `MFD_ALLOW_SEALING`.
export
addSeals : FileDesc -> Seals -> IO (Either Errno ())
addSeals fd seals = primIO (prim__add_seals fd.rawfd seals) >>= checkUnit

||| The seals of the file.
export
getSeals : FileDesc -> IO (Either Errno Seals)
getSeals fd = primIO (prim__get_seals fd.rawfd) >>= checkNonNeg
