module Data.IORef.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Data.IORef's own `IORef`/`Mut` pair is entirely backend-agnostic
-- (`Mut a` is `[external]`, no visible structure at the Idris2 source
-- level) -- rc2's own representation for it (rc2/support/rc2/
-- idris2rc2_datatypes.h's IDRIS2RC2_IORef, a spinlock-guarded single
-- Boxed slot) happens to make an atomic compare-and-swap on that slot
-- a small, safe addition, so this module exposes exactly that: not
-- part of Data.IORef itself (every backend would need its own
-- equivalent primitive, and Chez/RefC/etc. have none), but an
-- rc2-specific extension.

import Data.IORef

%default total

%foreign "C:idris2rc2_ioref_cas"
prim__casIORef : Mut a -> a -> a -> PrimIO (Maybe a)

||| Atomic compare-and-swap on an `IORef`'s current value, compared by
||| reference identity -- the exact boxed value a prior `readIORef`
||| (or an earlier `casIORef`'s own `Just` witness) returned, never
||| `Eq`, and never merely a separately-constructed "equal" value --
||| against `expected`. On success (`Nothing`), the ref now holds
||| `desired`. On failure (`Just current`), the ref is left unchanged
||| and `current` is the value actually found there, obtained
||| atomically alongside the failed compare itself -- a retry loop's
||| own witness for the next attempt, without a separate `readIORef`
||| call that could race a concurrent writer in between.
||| (rc2/support/rc2/idris2rc2_ioprims.c's own `idris2rc2_ioref_cas`
||| has the C implementation; guarded by the same spinlock
||| `readIORef`/`writeIORef` already use on this same slot.)
export
casIORef : HasIO io => IORef a -> (expected : a) -> (desired : a) -> io (Maybe a)
casIORef (MkRef m) expected desired = primIO (prim__casIORef m expected desired)
