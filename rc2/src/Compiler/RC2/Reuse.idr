module Compiler.RC2.Reuse

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Performs constructor-reuse-in-place optimization to recycle storage
-- of dying values for new constructors of the same shape.
-- This pass makes and encodes reuse decisions directly into the IR,
-- eliminating the need for `Emit.idr` to perform runtime uniqueness checks.
--
-- The protocol, per RConCase alt (`resolveAlt`):
--   1. An alt is *eligible* when its own scrutinee `sc` is about to be
--      dropped right here (i.e. `sc` is in the alt's own peeled leading
--      RDrop list -- see `peelDrop`, mirroring RC.idr's `branchBody`,
--      the sole producer of that shape) *and* the alt's body goes on to
--      build another constructor of the exact same name somewhere
--      (`usedConstructorsR`).
--   2. If eligible: `sc` is pulled out of the flat drop list (its fate
--      becomes the offer instead of an unconditional drop), and the
--      alt's own body is rewritten to `RReuseOffer sc dupOnShared
--      inner'` (wrapped, if anything else is still due to be dropped
--      unconditionally alongside it, in an ordinary leading `RDrop`) --
--      `dupOnShared` is exactly the alt's own destructured fields that
--      survive past this point (they were read straight out of `sc`'s
--      own storage, so anything still live needs an explicit reference
--      of its own before `sc`'s potential recursive teardown frees them
--      out from under it -- same "destructured via aliasing" rule
--      RC.idr's own `branchBody`-adjacent analysis already applies to
--      an *ordinary* matched alt, just precomputed here instead of
--      re-derived at emission time). `tryConsume` then walks `inner'`
--      looking for the first reachable (per execution path)
--      not-yet-claimed RCon of the matching name to mark
--      `reuseFrom = Just sc`, inserting `RReleaseReuse fc sc` on every
--      path that doesn't reach one, so the reservation is never lost.
--   3. Ineligible alts get no `RReuseOffer` -- an ordinary flat drop
--      list -- but still get an explicit `RDup` for any of their own
--      destructured fields that survive past it, same "destructured via
--      aliasing" reasoning as `dupOnShared` above (see `resolveAlt`'s
--      own `else` branch). The default branch (no known scrutinee shape
--      to reuse, so no destructured fields of its own either) is left
--      entirely alone.
--
-- Resolution proceeds bottom-up (`resolveReuse` recurses into a body
-- *before* deciding the enclosing alt's own eligibility), so by the
-- time an outer alt is considered, every nested opportunity has already
-- claimed whatever it was going to claim -- an outer offer's own
-- `tryConsume` search can only ever find RCon nodes nested processing
-- left unclaimed, never double-claim one out from under an inner offer.
--
-- `tryConsume` fully resolves any nested RConCase/RConstCase it walks
-- through while searching (independently, for *every* alt/default of
-- that nested case, since either branch could be the one actually taken
-- at runtime) -- a nested case's own resolution therefore never reports
-- back "still searching" to its caller, every one of its own branches
-- ends up either consuming the offer or releasing it.

import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.FC
import Core.Name.Scoped

import Data.List
import Data.SortedSet

%default covering

||| Peel a single leading RDrop, mirroring RC.idr's `branchBody` -- the
||| only producer of RConAlt/RConstAlt/default bodies -- which always
||| wraps its result in at most one such node (a single list, never a
||| chain of several).
peelDrop : RCExp -> (List RCLocal, RCExp)
peelDrop (RDrop _ locs cont) = (locs, cont)
peelDrop e = ([], e)

||| Inverse of `peelDrop`.
rewrapDrop : List RCLocal -> RCExp -> RCExp
rewrapDrop [] cont = cont
rewrapDrop locs cont = RDrop emptyFC locs cont

||| Try to claim `target`'s construction within a value/tail-position
||| expression that might be a (possibly RDup-wrapped -- see `annotate`'s
||| `wrapDups`) RCon of the right name and not already claimed by some
||| other offer. `Nothing` means this expression definitely isn't (and
||| doesn't wrap) such a construction -- not a verdict on the search as a
||| whole, just this one position.
tryClaim : Name -> RCLocal -> RCExp -> Maybe RCExp
tryClaim target sc (RDup fc v inner) = RDup fc v <$> tryClaim target sc inner
tryClaim target sc (RCon fc n ci tag args Nothing) =
    if n == target then Just (RCon fc n ci tag args (Just sc)) else Nothing
tryClaim target sc _ = Nothing

mutual
    ||| Search `e` (a value already known to be reached on *this*
    ||| execution path) for the first reachable, not-yet-claimed RCon of
    ||| `target`'s name, claiming it for `sc`; every path that doesn't
    ||| reach one gets an `RReleaseReuse` instead, so the reservation is
    ||| always resolved one way or the other by the time this returns.
    tryConsume : Name -> RCLocal -> RCExp -> RCExp
    tryConsume target sc (RLet fc var rep value body) =
        -- `value` is evaluated (and might itself be the construction we
        -- want) before `body` -- there is exactly one execution path
        -- through an RLet, so if `value` claims the offer, `body` (already
        -- otherwise resolved by the bottom-up walk) is left untouched; if
        -- it doesn't, the search continues into `body`.
        case tryClaim target sc value of
             Just value' => RLet fc var rep value' body
             Nothing     => RLet fc var rep value (tryConsume target sc body)
    tryConsume target sc (RDup fc v body) = RDup fc v (tryConsume target sc body)
    tryConsume target sc (RDrop fc vs body) = RDrop fc vs (tryConsume target sc body)
    tryConsume target sc (RFree fc v body) = RFree fc v (tryConsume target sc body)
    -- Not actually produced yet at the point this pass runs (nothing
    -- upstream inserts it) -- kept total rather than assumed unreachable.
    tryConsume target sc (RReleaseReuse fc v body) = RReleaseReuse fc v (tryConsume target sc body)
    -- *Is* genuinely reachable here, unlike RReleaseReuse above:
    -- resolution proceeds bottom-up (see the module note), so `inner`
    -- may already contain an RReuseOffer a nested alt's own eligibility
    -- check produced during the recursive `resolveReuse body` call that
    -- ran before this search ever started.
    tryConsume target sc (RReuseOffer fc sc2 dupOnShared dropOnUnique body) =
        RReuseOffer fc sc2 dupOnShared dropOnUnique (tryConsume target sc body)
    tryConsume target sc (RConCase fc sc2 alts mDef) =
        RConCase fc sc2 (map (tryConsumeAlt target sc) alts) (map (tryConsume target sc) mDef)
    tryConsume target sc (RConstCase fc sc2 alts mDef) =
        RConstCase fc sc2 (map (tryConsumeConstAlt target sc) alts) (map (tryConsume target sc) mDef)
    -- A fused comparison branch (RCExp.idr's own RCmpCase) is exactly a
    -- two-way case in every way this search cares about -- the search
    -- continues into *both* whenTrue/whenFalse independently, same as
    -- RConCase's own alts above.
    tryConsume target sc (RCmpCase fc op args pd t f) =
        RCmpCase fc op args pd (tryConsume target sc t) (tryConsume target sc f)
    tryConsume target sc e =
        -- A genuine terminal (RV/RAppName/RApp/RUnderApp/ROp/RExtPrim/
        -- RPrimVal/RErased/RCrash, or a bare tail-position RCon): claim it
        -- directly if it's our target, else this path definitely doesn't
        -- build it -- release here. In particular a call (RAppName/RApp/
        -- RUnderApp) is always a dead end for this purely local,
        -- intraprocedural search: whatever the callee does is invisible
        -- here.
        case tryClaim target sc e of
             Just e' => e'
             Nothing => RReleaseReuse emptyFC sc e

    tryConsumeAlt : Name -> RCLocal -> RConAlt -> RConAlt
    tryConsumeAlt target sc (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (tryConsume target sc body)

    tryConsumeConstAlt : Name -> RCLocal -> RConstAlt -> RConstAlt
    tryConsumeConstAlt target sc (MkRConstAlt c body) = MkRConstAlt c (tryConsume target sc body)

mutual
    ||| Walk the whole tree bottom-up, resolving every eligible RConCase
    ||| alt's reuse offer along the way (RCmpCase's own two branches get
    ||| the same treatment as RConCase's alts, just with no scrutinee of
    ||| their own to ever offer). Nodes with no nested RCExp of their own
    ||| (RV, RAppName, RUnderApp, RApp, RCon, ROp, RExtPrim, RPrimVal,
    ||| RErased, RCrash, RStructGet, RStructSet) have nothing to
    ||| recurse into.
    export
    resolveReuse : RCExp -> RCExp
    resolveReuse (RLet fc var rep value body) =
        RLet fc var rep (resolveReuse value) (resolveReuse body)
    resolveReuse (RDup fc v body) = RDup fc v (resolveReuse body)
    resolveReuse (RDrop fc vs body) = RDrop fc vs (resolveReuse body)
    resolveReuse (RFree fc v body) = RFree fc v (resolveReuse body)
    resolveReuse (RReleaseReuse fc v body) = RReleaseReuse fc v (resolveReuse body)
    resolveReuse (RConCase fc sc alts mDef) =
        RConCase fc sc (map (resolveAlt sc) alts) (map resolveReuse mDef)
    resolveReuse (RConstCase fc sc alts mDef) =
        RConstCase fc sc (map resolveConstAlt alts) (map resolveReuse mDef)
    resolveReuse (RCmpCase fc op args pd t f) =
        RCmpCase fc op args pd (resolveReuse t) (resolveReuse f)
    resolveReuse e = e

    resolveConstAlt : RConstAlt -> RConstAlt
    resolveConstAlt (MkRConstAlt c body) = MkRConstAlt c (resolveReuse body)

    resolveAlt : RCLocal -> RConAlt -> RConAlt
    resolveAlt sc (MkRConAlt name ci tag args body) =
        let body1 = resolveReuse body
            erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
            (dropped, inner) = peelDrop body1
        in if not erased && elem sc dropped && contains name (usedConstructorsR inner)
              then let inner' = tryConsume name sc inner
                       -- `sc`'s own fate is now the offer, not an
                       -- unconditional drop -- pulled out of the flat
                       -- list either way.
                       dropped' = dropped \\ [sc]
                       conArgsRC = map RCLoc args
                       -- Surviving destructured fields need their own
                       -- dup on the "turned out shared" path (see
                       -- RReuseOffer's own doc comment); fields already
                       -- in `dropped'` don't -- their release comes free
                       -- from `sc`'s own recursive drop there.
                       dupOnShared = conArgsRC \\ dropped'
                       -- Everything else in `dropped'` (unrelated to the
                       -- destructured fields) still needs an ordinary,
                       -- unconditional drop regardless of which way the
                       -- uniqueness check goes.
                       outerDrop = dropped' \\ conArgsRC
                       -- The destructured fields *not* in `dupOnShared`
                       -- (i.e. never referenced in `inner`, so `dropped'`
                       -- already claims them) -- on the not-unique path
                       -- these ride `sc`'s own recursive drop for free,
                       -- but on the unique path `sc` itself is never
                       -- dropped (its storage is reserved for reuse
                       -- instead), so that free ride never happens.
                       -- `EmitUtil.emitReuseOffer` emits an explicit drop
                       -- for each of these, unique branch only -- see
                       -- `RReuseOffer`'s own doc comment.
                       dropOnUnique = conArgsRC \\ dupOnShared
                   in MkRConAlt name ci tag args
                        (rewrapDrop outerDrop (RReuseOffer emptyFC sc dupOnShared dropOnUnique inner'))
              else let conArgsRC = map RCLoc args
                       -- Same "destructured via aliasing" rule as
                       -- `dupOnShared` above, just with no reuse offer
                       -- to carry it: a field read straight out of
                       -- `sc`'s own storage that's still live past this
                       -- point needs its own reference before `sc`'s
                       -- own (ordinary, unconditional) drop below
                       -- potentially frees/repurposes the storage it
                       -- points into. Applies regardless of whether
                       -- `sc` itself actually ends up dropped here --
                       -- mirrors `Compiler.RC2.Emit`'s own `branchBody`,
                       -- which used to re-derive this very same
                       -- decision at emission time via a `conArgs \\
                       -- shouldDrop` list difference; precomputed here
                       -- instead, same as `dupOnShared`.
                       dupOnSurvive = conArgsRC \\ dropped
                       -- A `dropped` entry that's *also* one of this
                       -- alt's own destructured fields is one that's
                       -- already dying -- deliberately left out of the
                       -- flat drop list here too, same as `outerDrop`
                       -- above: its release comes for free from however
                       -- `sc` itself gets torn down (an ordinary,
                       -- unconditional drop, unlike the reuse-eligible
                       -- case's own conditional one), so dropping it a
                       -- second time here would double-free.
                       outerDrop = dropped \\ conArgsRC
                   in MkRConAlt name ci tag args
                        (foldr (RDup emptyFC) (rewrapDrop outerDrop inner) dupOnSurvive)
