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
||| `RReleaseReuse` instead. See `doc/reuse-analysis.md`'s "tryConsume
||| / tryClaim" and "Ordering: bottom-up, not top-down".
tryConsume : Name -> RCLocal -> RCExp -> RCExp
tryConsume target sc (RLet fc var rep value body) =
    case tryClaim target sc value of
         Just value' => RLet fc var rep value' body
         Nothing     => RLet fc var rep value (tryConsume target sc body)
tryConsume target sc (RDup fc v extra body) = RDup fc v extra (tryConsume target sc body)
tryConsume target sc (RDrop fc vs body) = RDrop fc vs (tryConsume target sc body)
tryConsume target sc (RFree fc v body) = RFree fc v (tryConsume target sc body)
-- Not actually produced yet at the point this pass runs -- kept total
-- rather than assumed unreachable.
tryConsume target sc (RReleaseReuse fc v body) = RReleaseReuse fc v (tryConsume target sc body)
tryConsume target sc (RReuseOffer fc sc2 dupOnShared dropOnUnique body) =
    RReuseOffer fc sc2 dupOnShared dropOnUnique (tryConsume target sc body)
tryConsume target sc (RConCase fc sc2 alts mDef) =
    RConCase fc sc2 (map (tryConsumeAlt target sc) alts) (map (tryConsume target sc) mDef)
  where
    tryConsumeAlt : Name -> RCLocal -> RConAlt -> RConAlt
    tryConsumeAlt target sc (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (tryConsume target sc body)
tryConsume target sc (RConstCase fc sc2 alts mDef) =
    RConstCase fc sc2 (map (tryConsumeConstAlt target sc) alts) (map (tryConsume target sc) mDef)
  where
    tryConsumeConstAlt : Name -> RCLocal -> RConstAlt -> RConstAlt
    tryConsumeConstAlt target sc (MkRConstAlt c body) = MkRConstAlt c (tryConsume target sc body)
tryConsume target sc (RCmpCase fc op args pd t f) =
    RCmpCase fc op args pd (tryConsume target sc t) (tryConsume target sc f)
tryConsume target sc e =
    case tryClaim target sc e of
         Just e' => e'
         Nothing => RReleaseReuse emptyFC sc e

||| Walk the whole tree bottom-up, resolving every eligible `RConCase`
||| alt's reuse offer (`RCmpCase`'s own two branches get the same
||| treatment, with no scrutinee of their own to offer). See
||| `doc/reuse-analysis.md`'s "Algorithm" for the full protocol.
export
resolveReuse : RCExp -> RCExp
resolveReuse (RLet fc var rep value body) =
    RLet fc var rep (resolveReuse value) (resolveReuse body)
resolveReuse (RDup fc v extra body) = RDup fc v extra (resolveReuse body)
resolveReuse (RDrop fc vs body) = RDrop fc vs (resolveReuse body)
resolveReuse (RFree fc v body) = RFree fc v (resolveReuse body)
resolveReuse (RReleaseReuse fc v body) = RReleaseReuse fc v (resolveReuse body)
resolveReuse (RConCase fc sc alts mDef) =
    RConCase fc sc (map (resolveAlt sc) alts) (map resolveReuse mDef)
  where
    ||| Eligible when `sc` dies in its own peeled drop list, its shape
    ||| isn't erased (NIL/NOTHING/ZERO/UNIT), and the body goes on to
    ||| build another constructor of the same name. See
    ||| `doc/reuse-analysis.md`'s "resolveAlt" and "Addendum:
    ||| dropOnUnique".
    resolveAlt : RCLocal -> RConAlt -> RConAlt
    resolveAlt sc (MkRConAlt name ci tag args body) =
        let body1 = resolveReuse body
            erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
            (dropped, inner) = peelDrop body1
        in if not erased && elem sc dropped && contains name (usedConstructorsR inner)
              then let inner' = tryConsume name sc inner
                       dropped' = dropped \\ [sc]
                       conArgsRC = map RCLoc args
                       -- Surviving destructured fields need their own
                       -- dup on the "turned out shared" path; fields
                       -- already in `dropped'` ride `sc`'s own
                       -- recursive drop for free instead.
                       dupOnShared = conArgsRC \\ dropped'
                       outerDrop = dropped' \\ conArgsRC
                       -- Never-referenced destructured fields: free on
                       -- the not-unique path (sc's own recursive
                       -- drop), but need an explicit drop on the
                       -- unique path, where sc itself is never dropped
                       -- (EmitUtil.emitReuseOffer).
                       dropOnUnique = conArgsRC \\ dupOnShared
                   in MkRConAlt name ci tag args
                        (rewrapDrop outerDrop (RReuseOffer emptyFC sc dupOnShared dropOnUnique inner'))
              else let conArgsRC = map RCLoc args
                       -- Same "destructured via aliasing" rule as
                       -- `dupOnShared` above, just with no reuse offer
                       -- to carry it.
                       dupOnSurvive = conArgsRC \\ dropped
                       outerDrop = dropped \\ conArgsRC
                   in MkRConAlt name ci tag args
                        (foldr (\v, acc => RDup emptyFC v 0 acc) (rewrapDrop outerDrop inner) dupOnSurvive)
resolveReuse (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map resolveConstAlt alts) (map resolveReuse mDef)
  where
    resolveConstAlt : RConstAlt -> RConstAlt
    resolveConstAlt (MkRConstAlt c body) = MkRConstAlt c (resolveReuse body)
resolveReuse (RCmpCase fc op args pd t f) =
    RCmpCase fc op args pd (resolveReuse t) (resolveReuse f)
resolveReuse e = e
