module Control.Concurrent.Atomic

import System.FFI

data AtomicCounter = MkAtomicCounter GCAnyPtr


%inline %foreign "RC2:idris2rc2_concurrent_atomic_counter_next"
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



