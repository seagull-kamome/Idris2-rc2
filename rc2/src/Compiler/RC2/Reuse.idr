module Compiler.RC2.Reuse

-- Constructor-reuse-in-place: a dedicated pass that runs on the fully
-- Phase-1+2'd RCExp tree (Compiler.RC2.RC's normalize+annotate already
-- done), after which Compiler.RC2.Emit lowers the whole thing to C
-- purely mechanically. This used to be an Emit.idr-level, stateful
-- analysis (a name-keyed ReuseMap threaded through C emission); this
-- module makes the same decision instead, as data on the IR itself
-- (RConAlt's `offersReuse`, RCon's `reuseFrom`, and the new
-- `RReleaseReuse` node -- see their own doc comments in RCExp.idr),
-- leaving Emit.idr nothing to decide.
--
-- The protocol, per RConCase alt (`resolveAlt`):
--   1. An alt is *eligible* when its own scrutinee `sc` is about to be
--      dropped right here (i.e. `sc` is in the alt's own peeled leading
--      RDrop list -- see `peelDrop`, mirroring RC.idr's `branchBody`,
--      the sole producer of that shape) *and* the alt's body goes on to
--      build another constructor of the exact same name somewhere
--      (`usedConstructorsR`).
--   2. If eligible: `sc` is pulled out of the flat drop list (its fate
--      becomes the offer instead of an unconditional drop) and
--      `offersReuse` is set to `Just sc`; `tryConsume` then walks the
--      body looking for the first reachable (per execution path)
--      not-yet-claimed RCon of the matching name to mark
--      `reuseFrom = Just sc`, inserting `RReleaseReuse fc sc` on every
--      path that doesn't reach one, so the reservation is never lost.
--   3. Ineligible alts, and the default branch (no known scrutinee
--      shape to reuse), are left with `offersReuse = Nothing` --
--      Emit.idr just does an ordinary drop for whatever's in their flat
--      list.
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
    tryConsumeAlt target sc (MkRConAlt name ci tag args body offersReuse) =
        MkRConAlt name ci tag args (tryConsume target sc body) offersReuse

    tryConsumeConstAlt : Name -> RCLocal -> RConstAlt -> RConstAlt
    tryConsumeConstAlt target sc (MkRConstAlt c body) = MkRConstAlt c (tryConsume target sc body)

mutual
    ||| Walk the whole tree bottom-up, resolving every eligible RConCase
    ||| alt's reuse offer along the way (RCmpCase's own two branches get
    ||| the same treatment as RConCase's alts, just with no scrutinee of
    ||| their own to ever offer). Nodes with no nested RCExp of their own
    ||| (RV, RAppName, RUnderApp, RApp, RCon, ROp, RExtPrim, RPrimVal,
    ||| RErased, RCrash) have nothing to recurse into.
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
    resolveAlt sc (MkRConAlt name ci tag args body _) =
        let body1 = resolveReuse body
            erased = ci == NIL || ci == NOTHING || ci == ZERO || ci == UNIT
            (dropped, inner) = peelDrop body1
        in if not erased && elem sc dropped && contains name (usedConstructorsR inner)
              then let inner' = tryConsume name sc inner
                       dropped' = dropped \\ [sc]
                   in MkRConAlt name ci tag args (rewrapDrop dropped' inner') (Just sc)
              else MkRConAlt name ci tag args body1 Nothing
