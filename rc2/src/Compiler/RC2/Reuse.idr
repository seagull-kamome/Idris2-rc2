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
||| "Ordering: bottom-up, not top-down".
tryConsume : Name -> RCLocal -> RCExp -> (Bool, RCExp)
tryConsume target sc (RLet fc var rep value body) =
    case tryClaim target sc value of
         Just value' => (True, RLet fc var rep value' body)
         Nothing     => let (claimed, body') = tryConsume target sc body
                        in (claimed, RLet fc var rep value body')
tryConsume target sc (RDup fc v extra body) =
    let (claimed, body') = tryConsume target sc body in (claimed, RDup fc v extra body')
tryConsume target sc (RDrop fc vs body) =
    let (claimed, body') = tryConsume target sc body in (claimed, RDrop fc vs body')
tryConsume target sc (RFree fc v body) =
    let (claimed, body') = tryConsume target sc body in (claimed, RFree fc v body')
-- Not actually produced yet at the point this pass runs -- kept total
-- rather than assumed unreachable.
tryConsume target sc (RReleaseReuse fc v body) =
    let (claimed, body') = tryConsume target sc body in (claimed, RReleaseReuse fc v body')
tryConsume target sc (RReuseOffer fc sc2 dupOnShared dropOnUnique body) =
    let (claimed, body') = tryConsume target sc body
    in (claimed, RReuseOffer fc sc2 dupOnShared dropOnUnique body')
tryConsume target sc (RConCase fc sc2 alts mDef) =
    let altResults = map (tryConsumeAlt target sc) alts
        defResult = map (tryConsume target sc) mDef
    in (any fst altResults || maybe False fst defResult,
        RConCase fc sc2 (map snd altResults) (map snd defResult))
  where
    tryConsumeAlt : Name -> RCLocal -> RConAlt -> (Bool, RConAlt)
    tryConsumeAlt target sc (MkRConAlt name ci tag args body) =
        let (claimed, body') = tryConsume target sc body
        in (claimed, MkRConAlt name ci tag args body')
tryConsume target sc (RConstCase fc sc2 alts mDef) =
    let altResults = map (tryConsumeConstAlt target sc) alts
        defResult = map (tryConsume target sc) mDef
    in (any fst altResults || maybe False fst defResult,
        RConstCase fc sc2 (map snd altResults) (map snd defResult))
  where
    tryConsumeConstAlt : Name -> RCLocal -> RConstAlt -> (Bool, RConstAlt)
    tryConsumeConstAlt target sc (MkRConstAlt c body) =
        let (claimed, body') = tryConsume target sc body in (claimed, MkRConstAlt c body')
tryConsume target sc (RCmpCase fc op args pd t f) =
    let (claimedT, t') = tryConsume target sc t
        (claimedF, f') = tryConsume target sc f
    in (claimedT || claimedF, RCmpCase fc op args pd t' f')
tryConsume target sc e =
    case tryClaim target sc e of
         Just e' => (True, e')
         Nothing => (False, RReleaseReuse emptyFC sc e)

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
                       inner' = case tryConsume name sc inner of
                                     (True, consumed) => consumed
                                     (False, _) => RReleaseReuse emptyFC sc inner
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
