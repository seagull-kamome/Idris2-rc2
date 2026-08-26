module Compiler.RC2.ConstExtPrim

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Folds constant `ExtPrim` calls like `prim__codegen` to their known
-- fixed values at compile time to avoid unnecessary runtime overhead.
-- No special ownership handling is needed here: the `RPrimVal` this
-- pass introduces is just another literal by the time Phase 2 ever
-- sees it, annotated exactly like any other constant (no refcount
-- bookkeeping) rather than needing its own special case.

import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.TT

%default covering

||| `Just` the compile-time-known value for an ExtPrim call site
||| guaranteed to always evaluate to it, `Nothing` otherwise. Matches
||| by base name only (`NS _ (UN (Basic pn))`), the same shape
||| Compiler.RC2.Emit's own known-ExtPrim whitelist uses (see its
||| `emitRC (RExtPrim ...)` case) -- not a fully-qualified-name
||| comparison.
constExtPrimValue : Name -> List RCLocal -> Maybe Constant
constExtPrimValue (NS _ (UN (Basic "prim__codegen"))) [] = Just (Str "rc2")
constExtPrimValue _ _ = Nothing

mutual
  export
  foldConstExtPrim : RCExp -> RCExp
  foldConstExtPrim (RExtPrim fc lazy p args postDrop) =
      case constExtPrimValue p args of
           Just c  => RPrimVal fc c
           Nothing => RExtPrim fc lazy p args postDrop
  foldConstExtPrim (RLet fc var rep value body) =
      RLet fc var rep (foldConstExtPrim value) (foldConstExtPrim body)
  foldConstExtPrim (RCmpCase fc op args postDrop t f) =
      RCmpCase fc op args postDrop (foldConstExtPrim t) (foldConstExtPrim f)
  foldConstExtPrim (RConCase fc sc alts mDef) =
      RConCase fc sc (map foldConstExtPrimAlt alts) (map foldConstExtPrim mDef)
  foldConstExtPrim (RConstCase fc sc alts mDef) =
      RConstCase fc sc (map foldConstExtPrimConstAlt alts) (map foldConstExtPrim mDef)
  foldConstExtPrim (RDup fc v body) = RDup fc v (foldConstExtPrim body)
  foldConstExtPrim (RDrop fc vars body) = RDrop fc vars (foldConstExtPrim body)
  foldConstExtPrim (RFree fc v body) = RFree fc v (foldConstExtPrim body)
  foldConstExtPrim (RReleaseReuse fc v body) = RReleaseReuse fc v (foldConstExtPrim body)
  foldConstExtPrim (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      RReuseOffer fc sc dupOnShared dropOnUnique (foldConstExtPrim body)
  -- This pass's sole caller (Compiler.RC2.RC's `toRCDef`) only ever
  -- runs it on Phase 1's direct output, before RLoop/RLoopContinue
  -- (Compiler.RC2.Loop, much later) or RAppNameRep (Compiler.RC2.
  -- DualABI, later still) can exist. Kept total (as a plain
  -- pass-through) rather than assumed unreachable, same reasoning as
  -- Loop.idr's own `renameRCExp` for these same two cases.
  foldConstExtPrim (RLoop fc loopParams initial prologueDrop body) =
      RLoop fc loopParams initial prologueDrop (foldConstExtPrim body)
  foldConstExtPrim e = e

  foldConstExtPrimAlt : RConAlt -> RConAlt
  foldConstExtPrimAlt (MkRConAlt name ci tag args body) =
      MkRConAlt name ci tag args (foldConstExtPrim body)

  foldConstExtPrimConstAlt : RConstAlt -> RConstAlt
  foldConstExtPrimConstAlt (MkRConstAlt c body) = MkRConstAlt c (foldConstExtPrim body)

export
foldConstExtPrimDef : RCDef -> RCDef
foldConstExtPrimDef (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (foldConstExtPrim body)
foldConstExtPrimDef (MkRCError body) = MkRCError (foldConstExtPrim body)
foldConstExtPrimDef d@(MkRCCon _ _ _) = d
foldConstExtPrimDef d@(MkRCForeign _ _ _) = d
