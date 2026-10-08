module Compiler.RC2.Reuse

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Constructor-reuse-in-place: recycles a dying value's storage for a
-- new constructor of the same shape, decided and encoded directly on
-- the IR so `Emit.idr` never needs its own runtime uniqueness-check
-- logic. See `doc/reuse-analysis.md` for the full protocol (per-alt
-- eligibility, the `tryConsume`/`tryClaim` search, why resolution
-- proceeds bottom-up) and its own "Bugs found and fixed".

import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.CompileExpr
import Core.FC
import Core.Name.Scoped

import Data.List
import Data.SortedSet

%default covering

||| Inverse of `Compiler.RC2.Util.peelDrop`.
rewrapDrop : List RCLocal -> RCExp -> RCExp
rewrapDrop [] cont = cont
rewrapDrop locs cont = RDrop emptyFC locs cont

||| Claim `target`'s construction at one position (possibly `RDup`-
||| wrapped, see `annotate`'s `wrapDups`), if unclaimed -- a one-shot
||| check, not a search. See `doc/reuse-analysis.md`'s "tryConsume /
||| tryClaim".
tryClaim : Name -> RCLocal -> RCExp -> Maybe RCExp
tryClaim target sc (RDup fc v extra inner) = RDup fc v extra <$> tryClaim target sc inner
tryClaim target sc (RCon fc n ci tag args Nothing) =
    if n == target then Just (RCon fc n ci tag args (Just sc)) else Nothing
tryClaim target sc _ = Nothing

||| Search `e` for the first reachable, unclaimed `RCon` of `target`'s
||| name, claiming it for `sc`; every path that doesn't reach one gets
||| `RReleaseReuse` instead. The flag reports whether *any* path
||| claimed -- `False` means `usedConstructorsR`'s own cheap
||| "same-named constructor appears somewhere" pre-filter was
||| optimistic and `tryClaim` reached none of them, so the offer is
||| statically dead and `resolveAlt` releases it up front instead.
||| See `doc/reuse-analysis.md`'s "tryConsume / tryClaim" and
||| "Ordering: bottom-up, not top-down". With `nested`, an `RLet` whose
||| body claims nothing is searched through its *value* tree instead
||| (`doc/reuse-analysis.md`, "Nested let values"); every leaf of that
||| tree then claims or releases, so the body is left alone.
tryConsume : (nested : Bool) -> Name -> RCLocal -> RCExp -> (Bool, RCExp)
tryConsume nested target sc (RLet fc var rep value body) =
    case tryClaim target sc value of
         Just value' => (True, RLet fc var rep value' body)
         Nothing     =>
             let (claimed, body') = tryConsume nested target sc body
             in if claimed || not nested
                   then (claimed, RLet fc var rep value body')
                   -- Nothing in the body claims. Look inside the value
                   -- (a `case`/`let` tree): `tryConsume value` resolves
                   -- every leaf of it (claim or release), so the shell
                   -- is dead by the time the value is built and `body`
                   -- stays as it was. The body's own all-release
                   -- rewrite `body'` is dropped. See
                   -- `doc/reuse-analysis.md`'s "Nested let values".
                   else case tryConsume nested target sc value of
                             (True, value') => (True, RLet fc var rep value' body)
                             (False, _)     => (False, RLet fc var rep value body')
tryConsume nested target sc (RDup fc v extra body) =
    let (claimed, body') = tryConsume nested target sc body in (claimed, RDup fc v extra body')
tryConsume nested target sc (RDrop fc vs body) =
    let (claimed, body') = tryConsume nested target sc body in (claimed, RDrop fc vs body')
tryConsume nested target sc (RFree fc v body) =
    let (claimed, body') = tryConsume nested target sc body in (claimed, RFree fc v body')
-- Not actually produced yet at the point this pass runs -- kept total
-- rather than assumed unreachable.
tryConsume nested target sc (RReleaseReuse fc v body) =
    let (claimed, body') = tryConsume nested target sc body in (claimed, RReleaseReuse fc v body')
tryConsume nested target sc (RReuseOffer fc sc2 dupOnShared dropOnUnique body) =
    let (claimed, body') = tryConsume nested target sc body
    in (claimed, RReuseOffer fc sc2 dupOnShared dropOnUnique body')
tryConsume nested target sc (RConCase fc sc2 alts mDef) =
    let altResults = map (tryConsumeAlt nested target sc) alts
        defResult = map (tryConsume nested target sc) mDef
    in (any fst altResults || maybe False fst defResult,
        RConCase fc sc2 (map snd altResults) (map snd defResult))
  where
    tryConsumeAlt : Bool -> Name -> RCLocal -> RConAlt -> (Bool, RConAlt)
    tryConsumeAlt nested target sc (MkRConAlt name ci tag args body) =
        let (claimed, body') = tryConsume nested target sc body
        in (claimed, MkRConAlt name ci tag args body')
tryConsume nested target sc (RConstCase fc sc2 alts mDef) =
    let altResults = map (tryConsumeConstAlt nested target sc) alts
        defResult = map (tryConsume nested target sc) mDef
    in (any fst altResults || maybe False fst defResult,
        RConstCase fc sc2 (map snd altResults) (map snd defResult))
  where
    tryConsumeConstAlt : Bool -> Name -> RCLocal -> RConstAlt -> (Bool, RConstAlt)
    tryConsumeConstAlt nested target sc (MkRConstAlt c body) =
        let (claimed, body') = tryConsume nested target sc body in (claimed, MkRConstAlt c body')
tryConsume nested target sc (RCmpCase fc op args pd t f) =
    let (claimedT, t') = tryConsume nested target sc t
        (claimedF, f') = tryConsume nested target sc f
    in (claimedT || claimedF, RCmpCase fc op args pd t' f')
tryConsume nested target sc e =
    case tryClaim target sc e of
         Just e' => (True, e')
         Nothing => (False, RReleaseReuse emptyFC sc e)

||| Walk the whole tree bottom-up, resolving every eligible `RConCase`
||| alt's reuse offer (`RCmpCase`'s own two branches get the same
||| treatment, with no scrutinee of their own to offer). See
||| `doc/reuse-analysis.md`'s "Algorithm" for the full protocol.
export
resolveReuse : (nested : Bool) -> (imm : SortedSet RCLocal) -> RCExp -> RCExp
resolveReuse nested imm (RLet fc var rep value body) =
    RLet fc var rep (resolveReuse nested imm value) (resolveReuse nested imm body)
resolveReuse nested imm (RDup fc v extra body) = RDup fc v extra (resolveReuse nested imm body)
resolveReuse nested imm (RDrop fc vs body) = RDrop fc vs (resolveReuse nested imm body)
resolveReuse nested imm (RFree fc v body) = RFree fc v (resolveReuse nested imm body)
resolveReuse nested imm (RReleaseReuse fc v body) = RReleaseReuse fc v (resolveReuse nested imm body)
-- Without this, a memoized CAF body keeps `annotate`'s drops with none
-- of the field dups this pass owes them (doc/caf-memoization.md,
-- "Limitations").
resolveReuse nested imm (RMemoize fc n rep body) = RMemoize fc n rep (resolveReuse nested imm body)
resolveReuse nested imm (RConCase fc sc alts mDef) =
    RConCase fc sc (map (resolveAlt sc) alts) (map (resolveReuse nested imm) mDef)
  where
    ||| Eligible when `sc` dies in its own peeled drop list, its shape
    ||| isn't erased (NIL/NOTHING/ZERO/UNIT), and the body goes on to
    ||| build another constructor of the same name. See
    ||| `doc/reuse-analysis.md`'s "resolveAlt" and "Addendum:
    ||| dropOnUnique".
    resolveAlt : RCLocal -> RConAlt -> RConAlt
    resolveAlt sc (MkRConAlt name ci tag args body) =
        let body1 = resolveReuse nested imm body
            -- A field-less alternative has no cell worth reusing, and its
            -- scrutinee may not be a cell at all: a folded constant
            -- holds such a constructor as a tagged pointer (RCEmptyCon).
            erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT || null args
            (dropped, inner) = peelDrop body1
        in if not erased && elem sc dropped && contains name (usedConstructorsR inner)
              then let -- A dead offer (nothing claimed it anywhere)
                       -- keeps its branch -- the unique path genuinely
                       -- avoids dup/drop-ing the surviving fields, and
                       -- collapsing it to the shared path unconditionally
                       -- was measured to *add* refcount traffic. What it
                       -- doesn't need is `tryConsume`'s own
                       -- `RReleaseReuse` on every leaf path: release it
                       -- immediately instead, so the shell goes back to
                       -- the allocator at once rather than at whichever
                       -- leaf runs, and `reuseVarName sc`'s own C local
                       -- stops spanning the whole body.
                       inner' = case tryConsume nested name sc inner of
                                     (True, consumed) => consumed
                                     (False, _) => RReleaseReuse emptyFC sc inner
                       dropped' = dropped \\ [sc]
                       -- An always-unboxed field (`typedConstScrutinees`) needs no
                       -- dup/drop on either path: left out of the three lists below.
                       conArgsRC = filter (\l => not (contains l imm)) (map RCLoc args)
                       -- Surviving destructured fields need their own
                       -- dup on the "turned out shared" path; fields
                       -- already in `dropped'` ride `sc`'s own
                       -- recursive drop for free instead.
                       dupOnShared = conArgsRC \\ dropped'
                       outerDrop = dropped' \\ map RCLoc args
                       -- Never-referenced destructured fields: free on
                       -- the not-unique path (sc's own recursive
                       -- drop), but need an explicit drop on the
                       -- unique path, where sc itself is never dropped
                       -- (EmitUtil.emitReuseOffer).
                       dropOnUnique = conArgsRC \\ dupOnShared
                   in MkRConAlt name ci tag args
                        (rewrapDrop outerDrop (RReuseOffer emptyFC sc dupOnShared dropOnUnique inner'))
              else let conArgsRC = filter (\l => not (contains l imm)) (map RCLoc args)
                       -- Same "destructured via aliasing" rule as
                       -- `dupOnShared` above, just with no reuse offer
                       -- to carry it.
                       dupOnSurvive = conArgsRC \\ dropped
                       outerDrop = dropped \\ map RCLoc args
                   in MkRConAlt name ci tag args
                        (foldr (\v, acc => RDup emptyFC v 0 acc) (rewrapDrop outerDrop inner) dupOnSurvive)
resolveReuse nested imm (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map resolveConstAlt alts) (map (resolveReuse nested imm) mDef)
  where
    resolveConstAlt : RConstAlt -> RConstAlt
    resolveConstAlt (MkRConstAlt c body) = MkRConstAlt c (resolveReuse nested imm body)
resolveReuse nested imm (RCmpCase fc op args pd t f) =
    RCmpCase fc op args pd (resolveReuse nested imm t) (resolveReuse nested imm f)
resolveReuse _ _ e = e

||| Re-resolve offers that `resolveReuse` released up front because an
||| inner offer had already claimed the only same-name constructor, and
||| whose inner claim a later pass then removed (`DualABI`'s struct
||| return turns an offer on a `Ret` struct into a plain `drop`, see
||| `doc/reuse-analysis.md`, "Re-checking dead offers after DualABI").
||| Walks bottom-up (so an inner offer that still claims keeps its
||| constructor); at an offer in the exact shape `resolveAlt` makes of a
||| dead one -- `reuseOffer sc; releaseReuse sc; inner` -- runs
||| `tryConsume` on `inner`, and when some path now claims, keeps its
||| result in place of the up-front release. `env` maps each enclosing
||| case scrutinee to the constructor name of the alt we are in.
export
recheckReuse : (nested : Bool) -> RCExp -> RCExp
recheckReuse nested = go []
  where
    go : List (RCLocal, Name) -> RCExp -> RCExp
    go env (RConCase fc sc alts mDef) =
        RConCase fc sc
          (map (\(MkRConAlt n ci tag as b) => MkRConAlt n ci tag as (go ((sc, n) :: env) b)) alts)
          (map (go env) mDef)
    go env (RReuseOffer fc sc ds us k) =
        case go env k of
             k'@(RReleaseReuse _ sc' inner) =>
                 case (sc' == sc, lookup sc env) of
                      (True, Just name) =>
                          case tryConsume nested name sc inner of
                               (True, consumed) => RReuseOffer fc sc ds us consumed
                               (False, _) => RReuseOffer fc sc ds us k'
                      _ => RReuseOffer fc sc ds us k'
             k' => RReuseOffer fc sc ds us k'
    go env e = mapChildren (go env) e

||| `recheckReuse` over one definition's body.
export
recheckReuseDef : (nested : Bool) -> RCDef -> RCDef
recheckReuseDef nested (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (recheckReuse nested body)
recheckReuseDef nested (MkRCError body) = MkRCError (recheckReuse nested body)
recheckReuseDef _ d = d
