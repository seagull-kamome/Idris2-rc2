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

||| `args`, but with every entry `used` doesn't contain -- genuinely
||| referenced nowhere in the definition, not even by an `RDrop` --
||| replaced by `0`.
|||
||| `used` is `RCExp.mentionedLocals` over the *whole* definition,
||| computed once by `applyDeadVars` below rather than per alt. Asking
||| per alt instead (`freeLocalsR` of that alt's own body, as this
||| originally did) re-walks everything below each alt once per level
||| of case nesting, which real pattern matching produces a lot of:
||| measured on `idris2-lsp`, that was 2.74s of this pass's own 2.82s.
||| One whole-definition set answers the same question because every
||| local id within a definition is unique (see `mentionedLocals`'s own
||| doc comment), and erasing a field only ever rewrites a *binder*,
||| never a use, so no erasure this pass performs can invalidate the
||| set it started from.
eraseDeadConAltFields : SortedSet RCLocal -> List Int -> List Int
eraseDeadConAltFields used args =
    map (\i => if contains (RCLoc i) used then i else 0) args

eraseDeadVars : SortedSet RCLocal -> RCExp -> RCExp
eraseDeadVars used (RLet fc var rep value body) =
    RLet fc var rep (eraseDeadVars used value) (eraseDeadVars used body)
eraseDeadVars used (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (eraseDeadVars used t) (eraseDeadVars used f)
eraseDeadVars used (RConCase fc sc alts mDef) =
    RConCase fc sc
      (map (\(MkRConAlt n ci tag args body) =>
              MkRConAlt n ci tag (eraseDeadConAltFields used args) (eraseDeadVars used body)) alts)
      (map (eraseDeadVars used) mDef)
eraseDeadVars used (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (eraseDeadVars used body)) alts)
      (map (eraseDeadVars used) mDef)
eraseDeadVars used (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (eraseDeadVars used body)
eraseDeadVars used (RDup fc v extra body) = RDup fc v extra (eraseDeadVars used body)
eraseDeadVars used (RDrop fc vs body) = RDrop fc vs (eraseDeadVars used body)
eraseDeadVars used (RFree fc v body) = RFree fc v (eraseDeadVars used body)
eraseDeadVars used (RReleaseReuse fc v body) = RReleaseReuse fc v (eraseDeadVars used body)
eraseDeadVars used (RReuseOffer fc sc dupOnShared dropOnUnique body) =
    RReuseOffer fc sc dupOnShared dropOnUnique (eraseDeadVars used body)
eraseDeadVars used (RMemoize fc n rep body) = RMemoize fc n rep (eraseDeadVars used body)
-- Every other constructor is a leaf as far as this walk is concerned
-- (no RConAlt reachable inside one without going through an RCExp
-- child already covered above).
eraseDeadVars _ e = e

||| Apply dead-variable erasure to one top-level definition.
export
applyDeadVars : RCDef -> RCDef
applyDeadVars (MkRCFun args retRep isWorker body) =
    MkRCFun args retRep isWorker (eraseDeadVars (mentionedLocals body) body)
applyDeadVars (MkRCError body) = MkRCError (eraseDeadVars (mentionedLocals body) body)
applyDeadVars d@(MkRCCon _ _ _) = d
applyDeadVars d@(MkRCForeign _ _ _) = d
