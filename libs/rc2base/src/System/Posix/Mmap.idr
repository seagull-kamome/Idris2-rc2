module System.Posix.Mmap

import System.Posix.FileDesc

-------------------------------------------------------------------------------
--
public export MmapFlags : Type
MmapFlags = Int32

%inline %foreign "CExpr:(PROT_EXEC),libc,sys/mman.h"
PROT_EXEC : Int32
%inline %foreign "CExpr:(PROT_READ),libc,sys/mman.h"
PROT_READ : Int32
%inline %foreign "CExpr:(PROT_WRITE),libc,sys/mman.h"
PROT_WRITE : Int32
%inline %foreign "CExpr:(MAP_PRIVATE),libc,sys/mman.h"
MAP_PRIVATE : Int32
%inline %foreign "CExpr:(MAP_SHARED),libc,sys/mman.h"
MAP_SHARED : Int32
%inline %foreign "CExpr:(MAP_32BIT),libc,sys/mman.h"
MAP_32BIT : Int32
%inline %foreign "CExpr:(MAP_ANONYMOUS),libc,sys/mman.h"
MAP_ANONYMOUS : Int32
%inline %foreign "CExpr:(MAP_FIXED),libc,sys/mman.h"
MAP_FIXED : Int32
%inline %foreign "CExpr:(MAP_GROWSDOWN),libc,sys/mman.h"
MAP_GROWSDOWN : Int32
%inline %foreign "CExpr:(MAP_HUGETLB),libc,sys/mman.h"
MAP_HUGETLB : Int32
%inline %foreign "CExpr:(MAP_LOCKED),libc,sys/mman.h"
MAP_LOCKED : Int32
%inline %foreign "CExpr:(MAP_NONBLOCK),libc,sys/mman.h"
MAP_NONBLOCK : Int32
%inline %foreign "CExpr:(MAP_NORESERVE),libc,sys/mman.h"
MAP_NORESERVE : Int32
%inline %foreign "CExpr:(MAP_POPULATE),libc,sys/mman.h"
MAP_POPULATE : Int32
%inline %foreign "CExpr:(MAP_STACK),libc,sys/mman.h"
MAP_STACK : Int32
%inline %foreign "CExpr:(MAP_UNINITIALIZED),libc,sys/mman.h"
MAP_UNINITIALIZED : Int32

%inline %foreign "CExpr:($1 == MAP_FAILED ? 1 : 0),libc,sys/mman.h"
prim__mmap_failed : AnyPtr -> Bool


%inline %foreign "CExpr:(mmap($1, $2, $3, $4, $5, $6)),libc,sys/mman.h"
prim__mmap : AnyPtr -> Int64 -> Int32 -> Int32 -> Bits32 -> Int64 -> PrimIO AnyPtr   

%inline public export
mmap : AnyPtr -> Int64 -> MmapFlags -> MmapFlags -> FileDesc -> Int64 -> IO (Maybe AnyPtr)
mmap addr len prot flags fd offset = do
  ptr <- primIO $ prim__mmap addr len prot flags fd.rawfd offset
  if prim__mmap_failed ptr then pure Nothing else pure (Just ptr)


