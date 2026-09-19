module Compiler.RC2.DeadVars

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Blanks out a bound variable id to `0` -- `Compiler.RC2.Util`'s own
-- `VarId` counter starts at 1 specifically so `0` is never a genuine
-- variable id anywhere in the program, see that module's own doc
-- comment -- wherever it turns out to be referenced nowhere at all in
-- its own binding's body: not read, not even dropped.
--
-- Currently only `RConAlt`'s own destructured fields (see
-- `rc2/doc/dead-vars.md` for the motivating case). Written generally
-- enough -- the module's own name, `eraseDeadVars`'s own whole-tree
-- structural walk -- to grow into whatever other binding site turns
-- out to need the same treatment later, without needing a rename.
--
-- Measured far broader in practice than first expected: compiling
-- `idris2-lsp` with `--directive dumprcexpr` erased over 19000 fields.
-- The original guess was that this would only ever fire for a
-- *native*-classified field (never drop-tracked at all, see
-- `Compiler.RC2.RC`'s own `definitionNatives`) whose one and only use
-- got optimised away by some later pass -- reasoning every genuinely
-- *Boxed* unused field already gets an explicit `RDrop` from
-- `Compiler.RC2.RC`'s own `annotate`, which would count as a real
-- reference here. That turned out to describe only part of what
-- actually reaches Emit: for an ordinary (non-reuse-eligible) match,
-- the fields actually kept get an explicit `dup` and the *whole*
-- scrutinee gets one plain `drop` afterward -- e.g. `dup v9457; drop
-- [v9453]` for a 3-field record keeping only one field -- relying on
-- that drop's own recursive teardown to release every field never
-- separately dup'd, `annotate`'s own synthesized per-field `RDrop`
-- notwithstanding. Whichever pass resolves that shape apparently
-- doesn't need the individual field references `annotate` first
-- produced to survive to Emit at all, so this catches the ordinary,
-- ubiquitous "record pattern match, only using some fields" case, not
-- just the narrow one originally motivating it. None of this affects
-- correctness -- the `freeLocalsR`-over-the-final-body check below
-- doesn't care *why* a field ended up unreferenced, only whether it
-- is -- just the estimate of how often it matters.
--
-- Runs as the pipeline's very last `RCExp` rewrite, strictly after
-- `Compiler.RC2.DupMerge`: every pass that renames or freshens a
-- variable id (`Compiler.RC2.Loop`/`MutualLoop`/`LateInline`/
-- `SpecClosure`/`DualABI`) has already had its turn by then, so a `0`
-- placed here is never at risk of being renamed into a genuine id
-- afterward. Disable with `--directive nodeadvars`.

import Compiler.RC2.RCExp

import Core.FC

import Data.SortedSet

%default covering

||| `args`, but with every entry `freeLocalsR body` doesn't contain --
||| genuinely referenced nowhere in `body`, not even by an `RDrop` --
||| replaced by `0`. `body` is expected already fully processed by
||| `eraseDeadVars` itself (mutual recursion below), so a field only
||| used inside some nested `RConAlt` this same walk has already
||| erased down to `0` correctly no longer counts as used here either.
eraseDeadConAltFields : List Int -> RCExp -> List Int
eraseDeadConAltFields args body =
    let used = freeLocalsR body
    in map (\i => if contains (RCLoc i) used then i else 0) args

mutual
  eraseDeadVars : RCExp -> RCExp
  eraseDeadVars (RLet fc var rep value body) =
      RLet fc var rep (eraseDeadVars value) (eraseDeadVars body)
  eraseDeadVars (RCmpCase fc op args postDrop t f) =
      RCmpCase fc op args postDrop (eraseDeadVars t) (eraseDeadVars f)
  eraseDeadVars (RConCase fc sc alts mDef) =
      RConCase fc sc (map eraseDeadVarsAlt alts) (map eraseDeadVars mDef)
  eraseDeadVars (RConstCase fc sc alts mDef) =
      RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (eraseDeadVars body)) alts)
        (map eraseDeadVars mDef)
  eraseDeadVars (RLoop fc loopParams initial prologueDrop body) =
      RLoop fc loopParams initial prologueDrop (eraseDeadVars body)
  eraseDeadVars (RDup fc v extra body) = RDup fc v extra (eraseDeadVars body)
  eraseDeadVars (RDrop fc vs body) = RDrop fc vs (eraseDeadVars body)
  eraseDeadVars (RFree fc v body) = RFree fc v (eraseDeadVars body)
  eraseDeadVars (RReleaseReuse fc v body) = RReleaseReuse fc v (eraseDeadVars body)
  eraseDeadVars (RReuseOffer fc sc dupOnShared dropOnUnique body) =
      RReuseOffer fc sc dupOnShared dropOnUnique (eraseDeadVars body)
  eraseDeadVars (RMemoize fc n rep body) = RMemoize fc n rep (eraseDeadVars body)
  -- Every other constructor is a leaf as far as this walk is concerned
  -- (no RConAlt reachable inside one without going through an RCExp
  -- child already covered above).
  eraseDeadVars e = e

  eraseDeadVarsAlt : RConAlt -> RConAlt
  eraseDeadVarsAlt (MkRConAlt n ci tag args body) =
      let body' = eraseDeadVars body
      in MkRConAlt n ci tag (eraseDeadConAltFields args body') body'

||| Apply dead-variable erasure to one top-level definition.
export
applyDeadVars : RCDef -> RCDef
applyDeadVars (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (eraseDeadVars body)
applyDeadVars (MkRCError body) = MkRCError (eraseDeadVars body)
applyDeadVars d@(MkRCCon _ _ _) = d
applyDeadVars d@(MkRCForeign _ _ _) = d
