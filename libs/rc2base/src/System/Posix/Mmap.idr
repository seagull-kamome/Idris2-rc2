module System.Posix.Mmap

import System.Posix.Errno
import System.Posix.FileDesc

-------------------------------------------------------------------------------
--
||| A `PROT_*` or `MAP_*` bit set (or an `or` of them), as taken by `mmap`.
public export MmapFlags : Type
MmapFlags = Int32

||| Protection: pages may be executed.
%inline %foreign "CExpr:(PROT_EXEC),libc,sys/mman.h"
export PROT_EXEC : Int32
||| Protection: pages may be read.
%inline %foreign "CExpr:(PROT_READ),libc,sys/mman.h"
export PROT_READ : Int32
||| Protection: pages may be written.
%inline %foreign "CExpr:(PROT_WRITE),libc,sys/mman.h"
export PROT_WRITE : Int32
||| Mapping: private copy-on-write; updates are not visible to other processes.
%inline %foreign "CExpr:(MAP_PRIVATE),libc,sys/mman.h"
export MAP_PRIVATE : Int32
||| Mapping: updates are visible to other processes and carried through to the file.
%inline %foreign "CExpr:(MAP_SHARED),libc,sys/mman.h"
export MAP_SHARED : Int32
||| Mapping: place it in the low 2 GiB of the address space (x86-64).
|||
||| Linux (x86-64) and FreeBSD, not in POSIX. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_32BIT),libc,sys/mman.h"
export MAP_32BIT : Int32
||| Mapping: not backed by a file; the contents are zero and the fd is ignored.
|||
||| Linux and BSD, not in POSIX (older BSDs spell it `MAP_ANON`). See `mmap(2)`.
%inline %foreign "CExpr:(MAP_ANONYMOUS),libc,sys/mman.h"
export MAP_ANONYMOUS : Int32
||| Mapping: use exactly the given address, replacing any mapping there.
%inline %foreign "CExpr:(MAP_FIXED),libc,sys/mman.h"
export MAP_FIXED : Int32
||| Mapping: stack-like, grows downwards.
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_GROWSDOWN),libc,sys/mman.h"
export MAP_GROWSDOWN : Int32
||| Mapping: use huge pages.
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_HUGETLB),libc,sys/mman.h"
export MAP_HUGETLB : Int32
||| Mapping: lock the pages in memory.
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_LOCKED),libc,sys/mman.h"
export MAP_LOCKED : Int32
||| Mapping: with `MAP_POPULATE`, do not read ahead (block).
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_NONBLOCK),libc,sys/mman.h"
export MAP_NONBLOCK : Int32
||| Mapping: do not reserve swap space.
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_NORESERVE),libc,sys/mman.h"
export MAP_NORESERVE : Int32
||| Mapping: pre-fault the page tables (read ahead for a file).
|||
||| Linux only. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_POPULATE),libc,sys/mman.h"
export MAP_POPULATE : Int32
||| Mapping: allocate at an address suitable for a thread stack.
|||
||| Linux and BSD, not in POSIX. See `mmap(2)`.
%inline %foreign "CExpr:(MAP_STACK),libc,sys/mman.h"
export MAP_STACK : Int32

%inline %foreign "CExpr:($1 == MAP_FAILED ? 1 : 0),libc,sys/mman.h"
prim__mmap_failed : AnyPtr -> Int32


%inline %foreign "CExpr:(mmap($1, $2, $3, $4, $5, $6)),libc,sys/mman.h"
prim__mmap : AnyPtr -> Int64 -> Int32 -> Int32 -> Int32 -> Int64 -> PrimIO AnyPtr   

||| Map a file or anonymous memory into the address space; `Nothing` when `mmap` returns `MAP_FAILED`
||| (the cause is in `errno`). The descriptor is `Nothing` for `MAP_ANONYMOUS` (as `mmap` is given -1).
|||
||| See also: `mmap(2)`.
%inline public export
mmap : AnyPtr -> Int64 -> MmapFlags -> MmapFlags -> Maybe FileDesc -> Int64 -> IO (Maybe AnyPtr)
mmap addr len prot flags fd offset = do
  ptr <- primIO $ prim__mmap addr len prot flags (maybe (-1) rawfd fd) offset
  if prim__mmap_failed ptr /= 0 then pure Nothing else pure (Just ptr)

%inline %foreign "CExpr:(munmap($1, $2)),libc,sys/mman.h"
prim__munmap : AnyPtr -> Int64 -> PrimIO Int32

||| Remove the mapping of `len` bytes at `addr` (an address `mmap` gave; the
||| length is rounded up to a whole page).
|||
||| See also: `munmap(2)`.
%inline public export
munmap : AnyPtr -> Int64 -> IO (Either Errno ())
munmap addr len = primIO (prim__munmap addr len) >>= checkUnit
