module Compiler.RC2.DualABI

-- Dual calling convention, Stage 2: read-only eligibility analysis.
-- Decides, for each top-level function, which of its own parameters
-- and whether its own return value could be given a native (unboxed)
-- representation *at the function's own external C signature* --
-- Compiler.RC2.Loop's own native-shadow promotion (see doc/loop-
-- conversion.md) already does the analogous thing for a *loop's own*
-- carried parameters; this is the same idea widened to an ordinary
-- function's own calling convention, the biggest remaining item in
-- TODO.md's "Performance" section.
--
-- This module deliberately does not (yet) synthesize anything or
-- rewrite any call site -- see the project's own staged plan (branch
-- `dual-abi`). Nothing in the main pipeline (RC2.idr's toRCDefs) calls
-- into this module yet.
--
-- Both analyses below are purely *local* to one function's own body --
-- no whole-program fixed point is needed, for a reason worth spelling
-- out since it's not obvious up front:
--
--   * A parameter's own eligibility only depends on how *this*
--     function's own body reads it (Compiler.RC2.Loop's existing
--     `nativeArgType`, or, if the body is already `RLoop`-wrapped by
--     that same pass, its own `loopParams`' Rep directly) -- nothing
--     about any other function is relevant.
--   * A tail-position `ROp`/`RCmpCase`-shaped return value's own Rep
--     comes from the *operator's own* type tag (`Types.opResultRep`),
--     which never depends on where its operands came from -- so
--     `fib(n-1) + fib(n-2)` is already a native-Rep'd `Add`, right now,
--     regardless of whether `fib` itself is known to return natively.
--     The one case this deliberately leaves on the table is a *pure*
--     tail-call delegation with no arithmetic of its own (`g x = h
--     x`) -- whether `g`'s own return could be native then genuinely
--     depends on `h`'s, a real cross-function fixed point. Left as
--     ineligible for now (a real but acceptable v1 limitation).
--
-- Stage 2 verification (`--directive dumpdualabi`, see RC2.idr) against
-- the existing test/benchmark suite confirmed the design holds up:
-- `Main.fib` (tests/BenchFib.idr) -> params=[Int] ret=Int, the marquee
-- non-tail-recursive target this whole effort exists for;
-- `Main.sumTo` (tests/BenchLoop.idr) -> params=[Int, Int] ret=Int,
-- correctly read straight off `Compiler.RC2.Loop`'s own `RLoop`
-- decision; `Main.countDown`/`Main.collatzLike`
-- (tests/Test9SelfTailLoop.idr) -> correct *mixed* eligibility (one
-- native param, one Boxed) in the same function; `Main.swapLoop` and
-- every `Compiler.RC2.MutualLoop`-produced per-member wrapper
-- (`Main.isEvenM`/`isOddM`/`stepA`/`stepB` in the same file) -> nothing
-- eligible, correctly (no `ROp`/`RCmpCase` use of their own params at
-- all -- a wrapper's own body is just a forwarding call).
--
-- One finding that changes a later stage's own plan, not this one:
-- `MutualLoop`'s own *merged* function (`{rc2_mutualLoop:N}`, as
-- opposed to the per-member wrappers above) can show real eligibility
-- for a shared slot some member reads natively, even though a
-- *different*, smaller-arity member only ever supplies `RCNull` there
-- (confirmed directly against `tests/Test10MutualLoop.idr`'s own
-- `stepA`/`stepB` group, the exact shape that already caused two real
-- crashes during the loop-conversion work's own native-shadow-
-- promotion, see `doc/loop-conversion.md`'s "Bugs found" #4). Stage 3
-- must exclude every `MutualLoop`-produced merged function from worker
-- synthesis explicitly -- this can't be left to "no eligibility found,
-- nothing to do" the way the wrappers' own exclusion falls out for
-- free, since the merged function's *own* body can genuinely contain
-- real native-context reads of a slot that isn't safe to treat that
-- way unconditionally.

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap

%default covering

||| Every top-level parameter's own native eligibility: `Just ty` at the
||| position(s) `Compiler.RC2.Loop`'s `nativeArgType` (or, for an
||| already-`RLoop`-wrapped body, the corresponding `loopParams` entry)
||| finds eligible, `Nothing` otherwise. Reads `Compiler.RC2.Loop`'s own
||| decision directly when present rather than re-deriving it: an
||| `RLoop`'s own `initial` always reads each loop param's starting
||| value from the *same-position* top-level argument, unconditionally,
||| by construction (`Compiler.RC2.Loop.applyLoop`'s own `initial =
||| map RCLoc argIds`) -- so `loopParams`'s own entries line up
||| positionally with `argIds` here, with nothing further to check.
export
paramEligibility : List Int -> RCExp -> List (Int, Maybe PrimType)
paramEligibility argIds (RLoop _ loopParams _ _) =
    zip argIds (map (\(_, r) => case r of
                                      RNative ty => Just ty
                                      RInlineNative ty => Just ty
                                      RBoxed => Nothing) loopParams)
paramEligibility argIds body = map (\p => (p, nativeArgType p body)) argIds

||| Every `Rep` a genuine (non-`RLoopContinue`) tail-position value of
||| `e` would have, given `reps` (every local already known to be
||| native by this point -- seeded from `paramEligibility`'s own result
||| for the function's own parameters, extended as the walk passes
||| through `RLet`/`RLoop`'s own bindings). `Nothing` for a tail leaf
||| whose value is never native regardless of context (a call, closure,
||| constructor, extprim, erasure, crash) -- this is what makes a
||| function's return ineligible the moment *any* exit path can't be
||| native. `RLoopContinue` contributes nothing at all (never a real
||| exit -- it jumps back to the loop's own top, someone else's tail
||| position handles the eventual real exit).
tailValueReps : SortedMap Int Rep -> RCExp -> List (Maybe PrimType)
tailValueReps reps (RV _ (RCLoc i)) =
    [ case lookup i reps of
           Just (RNative ty) => Just ty
           Just (RInlineNative ty) => Just ty
           _ => Nothing ]
tailValueReps _ (RV _ (RCConst c)) = [litRep c]
tailValueReps _ (RV _ _) = [Nothing]
tailValueReps _ (ROp _ _ op _ _) = [opResultRep op]
tailValueReps _ (RPrimVal _ c) = [litRep c]
tailValueReps reps (RLet _ var rep value body) = tailValueReps (insert var rep reps) body
tailValueReps reps (RDup _ _ cont) = tailValueReps reps cont
tailValueReps reps (RDrop _ _ cont) = tailValueReps reps cont
tailValueReps reps (RFree _ _ cont) = tailValueReps reps cont
tailValueReps reps (RReleaseReuse _ _ cont) = tailValueReps reps cont
tailValueReps reps (RReuseOffer _ _ _ cont) = tailValueReps reps cont
tailValueReps reps (RCmpCase _ _ _ _ t f) = tailValueReps reps t ++ tailValueReps reps f
tailValueReps reps (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ _ body) => tailValueReps reps body) alts
      ++ maybe [] (tailValueReps reps) mDef
tailValueReps reps (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => tailValueReps reps body) alts
      ++ maybe [] (tailValueReps reps) mDef
tailValueReps reps (RLoop _ loopParams _ body) =
    tailValueReps (foldl (\m, (i, r) => insert i r m) reps loopParams) body
tailValueReps _ (RLoopContinue _ _) = []
-- RAppName, RUnderApp, RApp, RCon, RExtPrim, RErased, RCrash: never a
-- native value regardless of context -- a call/closure/constructor
-- result is always Boxed today (no callee is known to return native
-- yet -- see the module note's "pure tail-call delegation" limitation).
tailValueReps _ _ = [Nothing]

||| `Just ty` iff `xs` is non-empty and every element is `Just ty` for
||| the *same* `ty` -- the same "consistent single type, else give up"
||| shape `Compiler.RC2.Loop`'s own `nativeArgType` uses.
allJustSame : List (Maybe PrimType) -> Maybe PrimType
allJustSame [] = Nothing
allJustSame (Just ty :: rest) = if all (== Just ty) rest then Just ty else Nothing
allJustSame (Nothing :: _) = Nothing

||| The function's own return-value eligibility: `Just ty` iff *every*
||| genuine tail-position value is native at the same `ty`, given the
||| already-decided `params` (so a bare tail return of an eligible
||| parameter counts as native too, not just a locally-computed one).
export
returnEligibility : List (Int, Maybe PrimType) -> RCExp -> Maybe PrimType
returnEligibility params body =
    let seeded = fromList $ mapMaybe (\(p, mty) => map (\ty => (p, RNative ty)) mty) params
    in allJustSame (tailValueReps seeded body)

||| One line per `MkRCFun` def, reporting `paramEligibility`/
||| `returnEligibility`'s own results -- a debugging aid only, written
||| to `<outfile>.dualabi` whenever `--directive dumpdualabi` is passed
||| (see `RC2.idr`'s `compileExpr`), mirroring `Compiler.RC2.Pretty`'s
||| own `.crexpr` dump. Stage 2's own verification tool: nothing in the
||| main pipeline reads this back, and nothing here is synthesized or
||| rewritten yet -- see the module note.
export
describeEligibility : Name -> RCDef -> Maybe String
describeEligibility n (MkRCFun args _ body) =
    let argIds = map fst args
        params = paramEligibility argIds body
        ret = returnEligibility params body
    in Just $ show n ++ ": params=" ++
         show (map (\(p, mty) => "\{show p}:\{maybe "Boxed" show mty}") params) ++
         " ret=" ++ maybe "Boxed" show ret
describeEligibility _ _ = Nothing

export
dumpDualABI : List (Name, RCDef) -> String
dumpDualABI defs = fastConcat $ map (++ "\n") $ mapMaybe (uncurry describeEligibility) defs
