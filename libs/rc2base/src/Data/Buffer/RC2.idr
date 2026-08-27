module Data.Buffer.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Patches the five upstream `Data.Buffer` primitives that carry only a
-- `"scheme:..."` %foreign tag and are therefore unusable on refc/rc2 (or
-- any C backend) at all -- see TODO.md's "Upstream stdlib `%foreign`
-- declarations with no C/RefC backend at all" entry. Unlike
-- `System.Random.Xoshiro128PlusPlus` (a from-scratch replacement, since
-- upstream's own primitives there have no C-reachable implementation
-- whatsoever to patch onto), rc2's own runtime
-- (`rc2/support/rc2/buffer.h`) already has every one of these under a
-- different name -- `setInt16`/`getInt32`/`setInt32` (already usable on
-- rc2 unpatched, via upstream's own `"RefC:..."` tags matching that
-- runtime's own symbol names verbatim) show the same runtime was always
-- meant to cover the rest of `Data.Buffer` too; this module just wires
-- the remaining five up via `%foreign_impl`, the same mechanism
-- `System.Concurrency.RC2` uses.
--
--   prim__setInt8  -> setBufferUInt8    (existing)
--   prim__getInt8  -> getBufferByte     (existing -- also the symbol
--                                        upstream's own already-working
--                                        "RefC:getBufferByte" tags onto
--                                        prim__getByte, a *different*
--                                        primitive with a plain Int
--                                        return; reused as-is rather
--                                        than renamed, see buffer.h's
--                                        own comment on why a rename
--                                        here would silently break that
--                                        other, already-shipped patch)
--   prim__getInt16 -> getBufferInt16LE  (existing, already used by
--                                        getInt32's sibling on the set
--                                        side; upstream just never
--                                        tagged the get side)
--   prim__setInt64 -> setBufferInt64LE  (existing)
--   prim__getInt64 -> getBufferInt64LE  (existing)
--
-- No sign-extension shim needed on the read side despite `Int8`/`Int16`
-- being signed and every one of these C macros building its result via
-- an unsigned `getBufferUIntLE`: `Compiler.RC2.EmitUtil.cTypeOfCFType`
-- declares the FFI call's own return-holding C local at the *target*
-- width (`int8_t`/`int16_t`), so the implicit narrowing conversion at
-- that assignment does the sign-reinterpretation correctly regardless
-- of how wide (or how sign-agnostic) the callee's own return type is --
-- confirmed by this module's own test, which round-trips negative
-- values through each of the five.
--
-- Tagged `"RC2:"`, not `"RefC:"`, unlike upstream's own three already-
-- working entries above: those are upstream's own pre-existing
-- declarations that happen to name real rc2 runtime symbols, not
-- something *this* module adds -- adding a *new* `"RefC:"`-tagged ccs
-- entry ourselves would make a real `idris2 --cg refc` build believe
-- upstream itself supports these (it doesn't; there's no such symbol in
-- its own runtime), failing confusingly at final link instead of not
-- compiling at all. `"RC2:"` is rc2-exclusive (`EmitUtil.idr`'s own
-- `ffiTags`) and silently ignored by any other backend, same as
-- `System.Concurrency.RC2`'s own patches.
--
-- Needed a small rc2 compiler fix alongside this module the first time
-- around: `Compiler.RC2.Emit`'s `emitGenericForeignWrapper` treated
-- every non-`"RefC"` tag (including `"RC2"`) as generic-C for the
-- purpose of unwrapping a `CFBuffer` argument (`EmitUtil.idr`'s
-- `extractValue`'s two `CFBuffer` cases differ: `CLangRefC` passes the
-- whole size-header-carrying allocation `buffer.h`'s own functions
-- expect, `CLangC` skips past that header entirely for generic byte-
-- buffer functions with no notion of it) -- silently correct for
-- `System.Concurrency.RC2`, which never has a `CFBuffer`-typed
-- argument, but wrong here. Fixed by treating `"RC2"` the same as
-- `"RefC"` for that one purpose (`Emit.idr`'s own `cLang` binding).

import Data.Buffer

%foreign_impl Data.Buffer.prim__setInt8
  "RC2:setBufferUInt8"
%foreign_impl Data.Buffer.prim__getInt8
  "RC2:getBufferByte"
%foreign_impl Data.Buffer.prim__getInt16
  "RC2:getBufferInt16LE"
%foreign_impl Data.Buffer.prim__setInt64
  "RC2:setBufferInt64LE"
%foreign_impl Data.Buffer.prim__getInt64
  "RC2:getBufferInt64LE"
