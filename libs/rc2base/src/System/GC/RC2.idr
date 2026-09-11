||| Raw access to rc2's own reference-counting primitives
||| (`idris2rc2_dup`/`idris2rc2_dup_n`/`idris2rc2_drop`,
||| `rc2/support/rc2/memory.h`) -- for the one case rc2's own
||| compiler-inserted dup/drop bookkeeping can't see: a value whose
||| only remaining reference lives inside a raw pointer smuggled out
||| through an opaque FFI slot (e.g. a C callback's own `void *`
||| userdata), read back later from C-triggered Idris code with no
||| ordinary Idris-level use in between. rc2's ownership analysis only
||| tracks a value's *visible* uses in Idris source
||| (`Compiler.RC2.RC`'s `dropIfLastUse`) -- a reference held solely by
||| external C code is invisible to it, and gets dropped/collected out
||| from under that C code exactly as if it had never been referenced
||| there at all. Bracket a smuggled-out reference with `unsafeGCDup`
||| before handing its raw pointer to C, and `unsafeGCDrop` once it's
||| read back and no longer needed, to keep the refcount honest across
||| that gap.
|||
||| **rc2-only, and genuinely unsafe**: every function here takes/
||| returns an arbitrary `a`, but the C primitives underneath only
||| understand rc2's own **boxed** value representation
||| (`IDRIS2RC2_Value *`) -- calling any of them on a value rc2 chose
||| to represent unboxed/natively instead (a native `Int`/`Double`/
||| `Char` local) reinterprets whatever raw bits that native value
||| happens to hold as a heap pointer and dereferences it: an instant
||| crash, or worse, silent memory corruption, with nothing in the
||| type system to catch the mistake before it happens. Safe only on a
||| value already known to be heap-boxed (a constructor, a `String`,
||| an `IORef`, a closure) -- never a bare scalar, and never without
||| first checking how rc2 actually chose to represent the specific
||| value in hand. Get the dup/drop pairing wrong (missing one,
||| doubled one) and the failure mode is the ordinary refcounting one
||| instead: a use-after-free or a leak, typically far away from and
||| long after the actual mistake.
module System.GC.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

data Boxed : Type where [external]

-------------------------------------------------------------------------------
-- Raw FFI

%inline %foreign "RC2:idris2rc2_dup"
prim__unsafeGCDup : Boxed -> PrimIO Boxed
%inline %foreign "RC2:idris2rc2_dup_n"
prim__unsafeGCDupN : Boxed -> Int -> PrimIO Boxed

%inline %foreign "RC2:idris2rc2_drop"
prim__unsafeGCDrop : Boxed -> PrimIO ()

-------------------------------------------------------------------------------

||| Increments `x`'s own refcount by one -- see this module's own
||| header comment for when this is actually needed, and how easily
||| misused. `believe_me`'s own risk here is nothing beyond the
||| ordinary "must already be boxed" caveat documented above -- `x`'s
||| real runtime representation is untouched, only its refcount.
export
unsafeGCDup : a -> IO a
unsafeGCDup x = do
  y <- primIO $ prim__unsafeGCDup $ believe_me x
  pure $ believe_me y

||| Batched form of `unsafeGCDup`: increments `x`'s own refcount by
||| `n` in one call, for `n` separate copies of the same smuggled
||| reference about to be handed out (e.g. registered against `n`
||| different C callback slots) -- cheaper than `n` individual
||| `unsafeGCDup` calls. `n` itself is not checked against anything
||| here; passing `0` or a negative count is whatever
||| `idris2rc2_dup_n` itself does with it.
export
unsafeGCDupN : a -> Int -> IO a
unsafeGCDupN x n = do
  y <- primIO $ prim__unsafeGCDupN (believe_me x) n
  pure $ believe_me y

||| Decrements `x`'s own refcount by one, freeing it (recursively, per
||| rc2's ordinary drop semantics) if that was the last reference --
||| the balancing half of `unsafeGCDup`/`unsafeGCDupN` for a reference
||| this code itself dup'd earlier. Dropping a reference this code
||| never actually held its own dup'd copy of is a use-after-free,
||| exactly as it would be in C.
export
unsafeGCDrop : a -> IO ()
unsafeGCDrop x = primIO $ prim__unsafeGCDrop $ believe_me x
