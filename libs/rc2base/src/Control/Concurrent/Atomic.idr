module Control.Concurrent.Atomic

import System.FFI

data AtomicCounter = MkAtomicCounter GCAnyPtr


%inline %foreign "CExpr:atomic_fetch_add((int64_t _Atomic *)$1, 1),libc,stdatomic.h"
prim__atomicCounterNext : GCAnyPtr -> PrimIO Int64


%inline export
newAtomicCounter : Int64 -> IO (Maybe AtomicCounter)
newAtomicCounter n = do
    ptr <- malloc 8
    case prim__nullAnyPtr ptr of
        0 => do
            gcptr <- onCollectAny ptr free
            pure $ Just $ MkAtomicCounter gcptr
        _ => pure Nothing


%inline export
next : AtomicCounter -> IO Int64
next (MkAtomicCounter ptr) = primIO $ prim__atomicCounterNext ptr



