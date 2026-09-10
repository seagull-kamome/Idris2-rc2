module Compiler.RC2.DualABI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Dual calling convention: promotes eligible function parameters/
-- return values to native (unboxed) representations across an
-- *ordinary* call boundary, not just a self-tail-call loop's own
-- `goto` (`Compiler.RC2.Loop`). Both eligibility analyses are purely
-- local to one function's own body -- see `rc2/doc/dual-abi.md`'s "Why
-- no whole-program fixed point is needed".
--
-- Tail-position calls to an ordinary worker are a deliberate,
-- permanent scope boundary (unbounded C-stack-growth risk if
-- rewritten -- see the doc's "Scope: non-tail-position calls only,
-- permanently" under "Stage 4"); a tail call to an FFI worker is the
-- one exception (see the doc's "Stage 4b"), handled in
-- `applyCallSiteRewriteBody`'s own tail-position clause below.
--
-- See `rc2/doc/dual-abi.md` for the full design and the
-- `Compiler.RC2.MutualLoop`-merged-function exclusion Stage 3 needs
-- (that doc's "A finding that changed Stage 3's own plan").

import Compiler.Common
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop
import Compiler.RC2.Emit.Util
import Compiler.RC2.Util

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Find an `RLoop` reachable through a prefix of ordinary `RLet`s --
||| `applyLoop`'s own loop-invariant-parameter elision wraps an `RLoop`
||| in exactly this shape (`doc/loop-conversion.md`'s "Loop-invariant
||| parameter elision") -- collecting every id bound along the way.
||| `Nothing` if no `RLoop` is reachable at all (the common, non-looping
||| case).
findLoopThroughLets : SortedMap Int Rep -> RCExp -> Maybe (SortedMap Int Rep, List (Int, Rep))
findLoopThroughLets acc (RLet _ var rep _ body) = findLoopThroughLets (insert var rep acc) body
findLoopThroughLets acc (RLoop _ loopParams _ _ _) = Just (acc, loopParams)
findLoopThroughLets _ _ = Nothing

||| Every top-level parameter's own native eligibility: `Just ty` where
||| `Compiler.RC2.Loop`'s `nativeArgType` (or, for an `RLoop`-wrapped
||| body, `loopParams`/its wrapping `RLet`s via `findLoopThroughLets`)
||| finds it eligible, `Nothing` otherwise -- an id lookup rather than a
||| positional `zip`, since loop-invariant-parameter elision can leave
||| `loopParams` a strict subset of the top-level parameters (see
||| `doc/loop-conversion.md`'s "Loop-invariant parameter elision", its
||| own "DualABI interaction").
export
paramEligibility : List Int -> RCExp -> List (Int, Maybe PrimType)
paramEligibility argIds body =
    case findLoopThroughLets empty body of
         Just (letReps, loopParams) =>
             let m = foldl (\mp, (i, r) => insert i r mp) letReps loopParams
             in map (\p => (p, case lookup p m of
                                     Just (RNative ty) => Just ty
                                     Just (RInlineNative ty) => Just ty
                                     _ => Nothing)) argIds
         Nothing => map (\p => (p, nativeArgType p body)) argIds

||| Every `Rep` a genuine (non-`RLoopContinue`) tail-position value of
||| `e` would have, given `reps` (natives known so far, seeded from
||| `paramEligibility`, extended through `RLet`/`RLoop` bindings) --
||| `Nothing` for a leaf never native regardless of context (a call,
||| closure, constructor, extprim, erasure, crash), which is what makes
||| the whole return ineligible the moment any exit can't be native.
||| See `doc/dual-abi.md`'s "returnEligibility / tailValueReps".
||| `RLoopContinue` contributes nothing (never a real exit).
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
tailValueReps reps (RDup _ _ _ cont) = tailValueReps reps cont
tailValueReps reps (RDrop _ _ cont) = tailValueReps reps cont
tailValueReps reps (RFree _ _ cont) = tailValueReps reps cont
tailValueReps reps (RReleaseReuse _ _ cont) = tailValueReps reps cont
tailValueReps reps (RReuseOffer _ _ _ _ cont) = tailValueReps reps cont
tailValueReps reps (RCmpCase _ _ _ _ t f) = tailValueReps reps t ++ tailValueReps reps f
tailValueReps reps (RConCase _ _ alts mDef) =
    concatMap (\(MkRConAlt _ _ _ _ body) => tailValueReps reps body) alts
      ++ maybe [] (tailValueReps reps) mDef
tailValueReps reps (RConstCase _ _ alts mDef) =
    concatMap (\(MkRConstAlt _ body) => tailValueReps reps body) alts
      ++ maybe [] (tailValueReps reps) mDef
tailValueReps reps (RLoop _ loopParams _ _ body) =
    tailValueReps (foldl (\m, (i, r) => insert i r m) reps loopParams) body
tailValueReps _ (RLoopContinue _ _ _) = []
-- RAppName, RUnderApp, RApp, RCon, RExtPrim, RErased, RCrash,
-- RStructGet, RStructSet: never a native value regardless of context --
-- a call/closure/constructor result is always Boxed today (no callee is
-- known to return native yet -- see the module note's "pure tail-call
-- delegation" limitation); RStructGet/RStructSet's own packCFType
-- (doc/c-struct-support.md's Part D) always renders a Boxed
-- IDRIS2RC2_Value* too, same reasoning.
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

||| One line per `MkRCFun` def: `paramEligibility`/`returnEligibility`'s
||| own results, written to `<outfile>.dualabi` by `--directive
||| dumpdualabi` -- Stage 2's own verification tool
||| (`doc/dual-abi.md`'s "Stage 2: eligibility analysis"), nothing in
||| the main pipeline reads it back.
export
describeEligibility : Name -> RCDef -> Maybe String
describeEligibility n (MkRCFun args _ _ body) =
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

------------------------------------------------------------------------
-- Stage 3a: worker synthesis (parameters only) + wrapper rewrite.

data FreshId : Type where

freshId : {auto r : Ref FreshId Int} -> Core Int
freshId = do i <- get FreshId; put FreshId (i + 1); pure i

||| A fresh name for `original`'s own worker: `pfx` (`"idris2rc2_worker_"`
||| for an ordinary `MkRCFun` worker, `"idris2rc2_ffiworker_"` for an FFI
||| one) plus `original`'s own mangled C name (`cName`, `export`ed for
||| this reuse) plus a disambiguating counter -- see `doc/dual-abi.md`'s
||| "Stage 3a" step 1 for the full naming-scheme rationale.
freshName : {auto r : Ref FreshId Int} -> (pfx : String) -> SortedSet Name -> Name -> Core Name
freshName pfx existing original = do
    i <- freshId
    let cand = MN (pfx ++ cName original) i
    if contains cand existing then freshName pfx existing original else pure cand

-- `isMutualLoopMerged` itself now lives in `Compiler.RC2.Util` (see its
-- own doc comment there) -- reused as-is here via the existing `Util`
-- import above.

||| Synthesise `original`'s own worker (each parameter promoted to
||| `RNative` at its eligible position, `RBoxed` elsewhere; `retRep`
||| promoted when `retEligible` found one; body is the original's own
||| body, ownership-stripped for the promoted ids via `stripOwnership`
||| -- no id renaming needed, unlike `Compiler.RC2.Loop`'s own use of it
||| for a loop's shadow ids: a worker is a brand-new C function with
||| nothing existing to collide with) and rewrite `original` into a thin
||| wrapper (unchanged signature/id; body a single `RAppNameRep` call
||| into the worker, each natively-rendered argument explicitly
||| `postDrop`'d since the wrapper's own params stay `RBoxed`). See
||| `doc/dual-abi.md`'s "Stage 3a" for the full six-step design this
||| implements.
synthesizeWorker : {auto r : Ref FreshId Int}
                 -> SortedSet Name -> Name -> List (Int, PrimType) -> Maybe PrimType -> List (Int, Rep) -> Rep -> RCExp
                 -> Core (Name, RCDef, RCDef)
synthesizeWorker existingNames original eligible retEligible args wrapperRetRep body = do
    workerName <- freshName "idris2rc2_worker_" existingNames original
    let eligibleOf : Int -> Maybe PrimType
        eligibleOf p = Data.SortedMap.lookup p (Data.SortedMap.fromList eligible)
        workerArgs : List (Int, Rep)
        workerArgs = map (\(p, _) => case eligibleOf p of
                                           Just ty => (p, RNative ty)
                                           Nothing => (p, RBoxed)) args
        promotedIds : SortedSet Int
        promotedIds = fromList (map fst eligible)
        workerBody : RCExp
        workerBody = stripOwnership promotedIds body
        workerRetRep : Rep
        workerRetRep = maybe wrapperRetRep RNative retEligible
        workerDef : RCDef
        workerDef = MkRCFun workerArgs workerRetRep True workerBody
        wrapperArgIds : List Int
        wrapperArgIds = map fst args
        wrapperPostDrop : List RCLocal
        wrapperPostDrop = map RCLoc (mapMaybe (\(p, ty) => if alwaysUnboxed ty then Nothing else Just p) eligible)
        wrapperBody : RCExp
        wrapperBody = RAppNameRep emptyFC workerName (map snd workerArgs) workerRetRep wrapperPostDrop (map RCLoc wrapperArgIds)
        wrapperDef : RCDef
        wrapperDef = MkRCFun args wrapperRetRep False wrapperBody
    pure (workerName, wrapperDef, workerDef)

||| Whole-program pass: synthesises a worker + thin wrapper for every
||| eligible `MkRCFun` (`Compiler.RC2.MutualLoop`-merged functions
||| excluded, see `isMutualLoopMerged`); everything else passes through
||| unchanged.
|||
||| No width limit on a worker's own parameter count: a worker is only
||| ever reached via a direct, statically-named `RAppNameRep` call,
||| never dispatched through a `Closure` the way its own always-Boxed
||| wrapper still can be -- `MkRCFun`'s `isWorker` field is exactly this
||| distinction, telling `createCFunctions` whether to fall back to
||| `var_arglist[]` past `MaxExtractFunArgs`. See `doc/dual-abi.md`'s
||| "Bugs found and fixed" #6-9 for the crash this fixes and how far the
||| exemption was carried (closure-dispatch typedefs to arity 20, the
||| FFI worker path too).
export
applyDualABI : List (Name, RCDef) -> Core (List (Name, RCDef))
applyDualABI defs = do
    _ <- newRef FreshId 0
    let existingNames = SortedSet.fromList (map fst defs)
    concat <$> traverse (synthesizeIfEligible existingNames) defs
  where
    synthesizeIfEligible : {auto r : Ref FreshId Int} -> SortedSet Name -> (Name, RCDef) -> Core (List (Name, RCDef))
    synthesizeIfEligible existingNames (n, d@(MkRCFun args retRep _ body)) =
        if isMutualLoopMerged n
           then pure [(n, d)]
           else do
             let argIds = map fst args
                 params = paramEligibility argIds body
                 eligible = mapMaybe (\(p, mty) => map (\ty => (p, ty)) mty) params
                 retEligible = returnEligibility params body
             if null eligible && isNothing retEligible
                then pure [(n, d)]
                else do
                  (workerName, wrapperDef, workerDef) <- synthesizeWorker existingNames n eligible retEligible args retRep body
                  pure [(n, wrapperDef), (workerName, workerDef)]
    synthesizeIfEligible _ (n, d) = pure [(n, d)]

------------------------------------------------------------------------
-- Stage 3c: FFI worker synthesis. Unlike Stage 3a, there is no
-- `RCExp` body to rewrite into a thin wrapper -- a `MkRCForeign`'s own
-- always-Boxed C stub is untouched by this pass entirely. Only builds
-- the worker *table* Stage 4 rewrites call sites against; Stage 5
-- below splices each worker's own marshalling logic directly into the
-- call site instead of ever emitting a standalone worker C function --
-- see `doc/dual-abi.md`'s "Stage 3c"/"Stage 5".

||| `ret`'s own peeled type -- `CFIORes t`'s payload `t`, or `ret`
||| itself for a non-IO (pure) `%foreign` declaration.
export
peelIORes : CFType -> CFType
peelIORes (CFIORes t) = t
peelIORes t = t

||| A `CFType`'s own intrinsic `Rep` -- a pure, non-analytical fact of
||| the type alone (`Compiler.RC2.Types.cfTypeNative`), unlike a
||| `MkRCFun` parameter's eligibility (`paramEligibility`/
||| `returnEligibility` above), which genuinely depends on how a whole
||| function body uses it.
repOf : CFType -> Rep
repOf ty = maybe RBoxed RNative (cfTypeNative ty)

anyNative : Rep -> Bool
anyNative RBoxed = False
anyNative _ = True

||| Every `MkRCForeign` def's own worker-table entry, if `fargs`/`ret`
||| have at least one `cfTypeNative`-eligible position -- eligibility is
||| decided by the type alone, no function body to analyse (see
||| `doc/dual-abi.md`'s "Stage 3c": "Eligibility needs no analysis") --
||| *and* `ccs` actually carries a convention rc2 can use (`parseCC
||| ffiTags ccs`). The second condition doesn't come up in whole-
||| program compilation today (nothing calling such a declaration would
||| still be present in `defs` at all by this point -- `defs` here is
||| already upstream's own reachable-from-`main` set), but incremental
||| compilation's own `toIR`-scoped `defs` (`Compiler.RC2.RC2.incCompile`)
||| carries every declaration a module makes regardless of whether
||| anything actually calls it, real convention or not -- see
||| rc2/doc/incremental-compile.md's "Bugs found while implementing" for
||| the concrete case (`Prelude.IO.prim__threadWait`, Chez/Scheme-only)
||| this excludes. Skipping it here (rather than only in `Emit.idr`,
||| where the same declaration's own dropped-if-unusable handling
||| lives) matters because eligibility here runs *before* any call-site
||| rewriting (Stage 4/5) -- without this check, a native-eligible-
||| shaped call to a no-convention declaration would already have been
||| rewritten into an `RAppFFIInline` node by the time `Emit.idr` ever
||| sees it, which `Emit.idr`'s own per-declaration drop can no longer
||| undo (that call site's own `resolveForeignTarget` would still try,
||| and fail, to resolve a convention that was never there). Excluding
||| it here instead means the call falls back to an ordinary `RAppName`/
||| `RAppNameRep`, whose own callee resolution in `Emit.idr` already
||| does the right thing in either mode: whole-program's own
||| `collectDeclarations` still throws its usual immediately-
||| attributable compile-time error if such a call is ever genuinely
||| reachable (unaffected by this change, since that path was never
||| about FFI-inlining specifically); incremental's own dropped-
||| declaration/`externalFunctionRefsD` combination turns it into a
||| link-time "undefined reference" instead, per that same doc.
|||
||| Returns two maps from one traversal: keyed by the *original* name
||| (`applyCallSiteRewrite`'s own input, unchanged from Stage 4) and
||| keyed by the *worker's own* synthesized name (`inlineFFIWorkers`'s
||| own input, Stage 5 -- see the doc's "Stage 5" for why the two
||| keyings differ). The first map's trailing `Bool` is always `True`
||| here -- safe to rewrite even in tail position, since a `%foreign`
||| callee is always a leaf (see the doc's "Stage 4b: tail-position FFI
||| calls").
export
ffiWorkerTable : List (Name, RCDef)
              -> Core (SortedMap Name (Name, List Rep, Rep, Bool),
                       SortedMap Name (List String, List CFType, CFType))
ffiWorkerTable defs = do
    _ <- newRef FreshId 0
    let existingNames = SortedSet.fromList (map fst defs)
    entries <- traverse (ffiEntry existingNames) defs
    pure (fromList (concatMap fst entries), fromList (concatMap snd entries))
  where
    ffiEntry : {auto r : Ref FreshId Int} -> SortedSet Name -> (Name, RCDef)
            -> Core (List (Name, (Name, List Rep, Rep, Bool)), List (Name, (List String, List CFType, CFType)))
    ffiEntry existingNames (n, MkRCForeign ccs fargs ret) =
        let argReps = map repOf fargs
            retRep = repOf (peelIORes ret)
        in if (not (any anyNative argReps) && not (anyNative retRep)) || not (isJust (parseCC ffiTags ccs))
              then pure ([], [])
              else do
                workerName <- freshName "idris2rc2_ffiworker_" existingNames n
                pure ([(n, (workerName, argReps, retRep, True))], [(workerName, (ccs, fargs, ret))])
    ffiEntry _ (_, _) = pure ([], [])

------------------------------------------------------------------------
-- Stage 4: call-site rewriting (non-tail positions, plus tail-position
-- calls to an FFI worker specifically -- see the module's own header
-- note for why an ordinary function's tail-position delegating calls are
-- a deliberate, permanent scope boundary, not a later stage).

||| The worker (if any) `n` was rewritten to call, recovered by
||| scanning for the exact shape `synthesizeWorker` always produces for
||| a wrapper's body (a bare `RAppNameRep` into its own worker, nothing
||| else) -- see `doc/dual-abi.md`'s "The worker table" (Stage 4).
||| Tagged `False` (unlike `ffiWorkerTable`'s entries): an ordinary
||| worker can chain into further deferred tail calls, so
||| `applyCallSiteRewriteBody`'s tail-position clause must still leave
||| it alone.
workerTable : List (Name, RCDef) -> SortedMap Name (Name, List Rep, Rep, Bool)
workerTable defs = fromList (mapMaybe workerEntry defs)
  where
    workerEntry : (Name, RCDef) -> Maybe (Name, (Name, List Rep, Rep, Bool))
    workerEntry (n, MkRCFun _ _ _ (RAppNameRep _ workerName argReps retRep _ _)) =
        Just (n, (workerName, argReps, retRep, False))
    workerEntry _ = Nothing

||| Which of `args` need an explicit drop once embedded in its own
||| statement: positions the worker reads *natively* whose source, per
||| `reps`, is still `RBoxed` -- `RAppNameRep`'s `postDrop` field exists
||| specifically for this, added to fix a real reference leak (see
||| `doc/dual-abi.md`'s "Bugs found and fixed" #3). No liveness analysis
||| needed: `Compiler.RC2.RC`'s own `annotate` already decided the
||| original (still-`RAppName`) call consumes exactly one reference per
||| Boxed argument -- reading it natively and dropping it here instead
||| pays the exact same net cost.
postDropFor : SortedMap Int Rep -> List Rep -> List RCLocal -> List RCLocal
postDropFor reps argReps args =
    mapMaybe (\(r, a) => case r of
                              RBoxed => Nothing
                              _ => case localRepIn reps a of
                                        RBoxed => Just a
                                        _ => Nothing) (zip argReps args)

||| `e`'s own ultimate tail expression, peeling through every `RLet`'s
||| own `body` and every wrapper node's own `cont` -- the same peeling
||| `tryEmitLoopContinue`/`peelDrop` already do, just walking all the
||| way to the end instead of stopping at the first interesting shape.
||| Inspects only, never rewrites -- used on a (possibly deeply nested,
||| see `applyCallSiteRewriteBody`'s own doc comment) `RLet` value to
||| see what it ultimately evaluates to.
ultimateTail : RCExp -> RCExp
ultimateTail (RLet _ _ _ _ body) = ultimateTail body
ultimateTail (RDup _ _ _ cont) = ultimateTail cont
ultimateTail (RDrop _ _ cont) = ultimateTail cont
ultimateTail (RFree _ _ cont) = ultimateTail cont
ultimateTail (RReleaseReuse _ _ cont) = ultimateTail cont
ultimateTail (RReuseOffer _ _ _ _ cont) = ultimateTail cont
ultimateTail e = e

||| `var`'s own native `PrimType` if `e`'s own ultimate tail (peeling as
||| `ultimateTail` does) is a bare `ROp` reading `var` as an operand --
||| the one shape `Compiler.RC2.Loop`'s own `nativeArgTypes` correctly
||| doesn't cover for *its own* callers (a bare tail is always Boxed
||| when that pass runs), but no longer true by Stage 4's own point in
||| the pipeline. See `doc/dual-abi.md`'s "Bugs found and fixed" #5 for
||| the `fib`-worker `v3 + v5` case this exists to catch.
bareTailNativeReads : Int -> RCExp -> SortedSet PrimType
bareTailNativeReads var e =
    case ultimateTail e of
         ROp _ _ op args _ =>
             if vectElemRCLoc var args
                then maybe empty (\rty => SortedSet.fromList [opArgTyFor rty op]) (opResultRep op)
                else empty
         _ => empty
  where
    -- Plain recursive membership check, avoiding Data.Vect's own
    -- `toList`/`Foldable` -- both collide (name ambiguity with
    -- Data.SortedMap's own `fromList`/`lookup`, already used
    -- throughout this module) or fail to resolve (the `{0 arity :
    -- Nat}` erased implicit `ROp` carries its `Vect` length in blocks
    -- the usual `Foldable (Vect n)` search) when actually imported
    -- here.
    vectElemRCLoc : Int -> Vect n RCLocal -> Bool
    vectElemRCLoc _ [] = False
    vectElemRCLoc i (x :: xs) = x == RCLoc i || vectElemRCLoc i xs

||| Every native `PrimType` at which `var` is read as a direct,
||| saturated call argument somewhere in `e`, at a position `workers`
||| says its callee reads natively -- extends the same "skip the
||| box-then-unbox round trip" idea to a *call* consuming the value, not
||| just an `ROp`/bare tail (`ffiCall2 (ffiCall1 x) y`-shaped chains).
||| Walks the whole tree like `nativeArgTypes`; looks only at bare
||| `RAppName` (`e` is always pre-Stage-4-rewrite here). Whether the
||| callee's own tag is FFI or ordinary doesn't matter -- an occurrence
||| in a still-deferred tail-position call to an ordinary worker just
||| gets reboxed on the way in, same "reboxed on demand" reasoning
||| `nativePromotionFor` relies on. See `doc/dual-abi.md`'s "Extending
||| the promotion to call-argument chains".
callArgNativeReads : SortedMap Name (Name, List Rep, Rep, Bool) -> Int -> RCExp -> SortedSet PrimType
callArgNativeReads workers var (RLet _ _ _ value body) =
    callArgNativeReads workers var value `union` callArgNativeReads workers var body
callArgNativeReads workers var (RCmpCase _ _ _ _ t f) =
    callArgNativeReads workers var t `union` callArgNativeReads workers var f
callArgNativeReads workers var (RConCase _ _ alts mDef) =
    concat (map (\(MkRConAlt _ _ _ _ body) => callArgNativeReads workers var body) alts)
      `union` maybe empty (callArgNativeReads workers var) mDef
callArgNativeReads workers var (RConstCase _ _ alts mDef) =
    concat (map (\(MkRConstAlt _ body) => callArgNativeReads workers var body) alts)
      `union` maybe empty (callArgNativeReads workers var) mDef
callArgNativeReads workers var (RLoop _ _ _ _ body) = callArgNativeReads workers var body
callArgNativeReads workers var (RDup _ _ _ cont) = callArgNativeReads workers var cont
callArgNativeReads workers var (RDrop _ _ cont) = callArgNativeReads workers var cont
callArgNativeReads workers var (RFree _ _ cont) = callArgNativeReads workers var cont
callArgNativeReads workers var (RReleaseReuse _ _ cont) = callArgNativeReads workers var cont
callArgNativeReads workers var (RReuseOffer _ _ _ _ cont) = callArgNativeReads workers var cont
callArgNativeReads workers var (RAppName _ _ n args) =
    case lookup n workers of
         Nothing => empty
         Just (_, argReps, _, _) =>
             if length args /= length argReps
                then empty
                else fromList $ mapMaybe (\(a, r) => if a == RCLoc var
                                                          then case r of
                                                                    RNative ty => Just ty
                                                                    RInlineNative ty => Just ty
                                                                    RBoxed => Nothing
                                                          else Nothing)
                                          (zip args argReps)
-- Every other shape (RV, RAppNameRep, RUnderApp, RApp, RCon, a bare
-- ROp/RExtPrim, RPrimVal, RErased, RCrash, RLoopContinue, RStructGet,
-- RStructSet): no call-argument position of its own to inspect, and
-- none hold a further RCExp to recurse into beyond what
-- RLet/RCmpCase/RConCase/RConstCase/RLoop above already visit.
callArgNativeReads _ _ _ = empty

||| Every native `PrimType` at which `var` is fed as the enclosing
||| `RLoop`'s own next value for an already native-shadowed loop-carried
||| parameter, via a bare `RLoopContinue` reachable in `e` -- the
||| loop-carried analogue of `callArgNativeReads` (there: a *named*
||| worker call's argument; here: the implicit self-call every
||| `RLoopContinue` represents). `loopParams` is the exact, already-
||| aligned list `applyLoop` attaches to the enclosing `RLoop` -- see
||| `doc/loop-conversion.md`'s "Known limitation: native-shadow
||| eligibility stops at bare top-level scalars" for why this exists
||| and how it closes the round trip. Walks only the tail-preserving
||| spine `fillLoopContinuePostDrop` uses (never an `RLet`'s own
||| `value`) -- an `RLoopContinue` can only ever sit there. No `RLoop`
||| case needed: one `RLoop` per function, so `e` never nests a second.
loopContinueNativeReads : List (Int, Rep) -> Int -> RCExp -> SortedSet PrimType
loopContinueNativeReads loopParams var (RLet _ _ _ _ body) = loopContinueNativeReads loopParams var body
loopContinueNativeReads loopParams var (RCmpCase _ _ _ _ t f) =
    loopContinueNativeReads loopParams var t `union` loopContinueNativeReads loopParams var f
loopContinueNativeReads loopParams var (RConCase _ _ alts mDef) =
    concat (map (\(MkRConAlt _ _ _ _ body) => loopContinueNativeReads loopParams var body) alts)
      `union` maybe empty (loopContinueNativeReads loopParams var) mDef
loopContinueNativeReads loopParams var (RConstCase _ _ alts mDef) =
    concat (map (\(MkRConstAlt _ body) => loopContinueNativeReads loopParams var body) alts)
      `union` maybe empty (loopContinueNativeReads loopParams var) mDef
loopContinueNativeReads loopParams var (RDup _ _ _ cont) = loopContinueNativeReads loopParams var cont
loopContinueNativeReads loopParams var (RDrop _ _ cont) = loopContinueNativeReads loopParams var cont
loopContinueNativeReads loopParams var (RFree _ _ cont) = loopContinueNativeReads loopParams var cont
loopContinueNativeReads loopParams var (RReleaseReuse _ _ cont) = loopContinueNativeReads loopParams var cont
loopContinueNativeReads loopParams var (RReuseOffer _ _ _ _ cont) = loopContinueNativeReads loopParams var cont
loopContinueNativeReads loopParams var (RLoopContinue _ args _) =
    fromList $ mapMaybe (\((_, paramRep), arg) =>
                              if arg == RCLoc var
                                 then case paramRep of
                                           RNative ty => Just ty
                                           RInlineNative ty => Just ty
                                           RBoxed => Nothing
                                 else Nothing)
                         (zip loopParams args)
-- Every other shape (RV, RAppName, RAppNameRep, RUnderApp, RApp, RCon,
-- a bare ROp/RExtPrim, RPrimVal, RErased, RCrash, RStructGet,
-- RStructSet -- and RLoop, never actually reachable here, see this
-- function's own doc comment): no RLoopContinue reachable through any
-- of these beyond what the cases above already cover.
loopContinueNativeReads _ _ _ = empty

||| Whether `body` justifies promoting an `RLet`-bound worker-call
||| result from `RBoxed` all the way to `RNative ty`, instead of just
||| rewriting the call and boxing its result back up -- the actual point
||| of Stage 4: skipping the box-then-unbox round trip entirely.
||| Unions `nativeArgTypes`/`bareTailNativeReads`/`callArgNativeReads`
||| (plus, inside a loop, `loopContinueNativeReads` via `mLoopParams`),
||| then asks `nativeArgType`'s own eligibility question over that
||| combined set. Any other, still-Boxed-context use of `var` elsewhere
||| keeps working via `rcVarToBoxedC`'s own on-demand reboxing (a scalar
||| has no observable identity, see `stripOwnership`'s own doc comment).
||| See `doc/dual-abi.md`'s "The promotion: `nativePromotionFor`".
nativePromotionFor : SortedMap Name (Name, List Rep, Rep, Bool) -> Maybe (List (Int, Rep)) -> Int -> PrimType -> RCExp -> Maybe PrimType
nativePromotionFor workers mLoopParams var ty body =
    let fromLoop = maybe empty (\loopParams => loopContinueNativeReads loopParams var body) mLoopParams
        found = ((nativeArgTypes var body `union` bareTailNativeReads var body)
                  `union` callArgNativeReads workers var body)
                  `union` fromLoop
    in case Prelude.toList found of
            [ty'] => if ty' == ty then Just ty else Nothing
            _ => Nothing

||| Rewrite every direct, saturated, non-tail-position call in `e`
||| targeting a function `workers` has a worker for. `reps` threads the
||| same known-native seeding/extension Stage 2 uses; `inTail` tracks
||| whether the current point is genuinely the whole function's own
||| tail position (`True` only at the top-level entry, threaded through
||| unchanged everywhere else, always `False` descending into an
||| `RLet`'s own `value`) -- a bare `RAppName` reached with `inTail`
||| still `True` is the deliberate scope boundary (module header note);
||| every other one is safe to rewrite.
|||
||| The one genuine subtlety -- an `RLet`'s own `value` can itself be a
||| further, arbitrarily deep `RLet` chain from Phase 1's own ANF
||| normalisation of a call argument, never a flat leaf -- is handled by
||| recursing into `value` first, then inspecting the rewritten
||| `value1`'s own `ultimateTail`. See `doc/dual-abi.md`'s "The rewrite:
||| `applyCallSiteRewriteBody`" for the full `let v3 = (let v4 = n - 1
||| in fib v4) in ...` worked example.
applyCallSiteRewriteBody : SortedMap Name (Name, List Rep, Rep, Bool)
                        -> SortedMap Int Rep
                        -> Maybe (List (Int, Rep))
                        -> Bool -> RCExp -> RCExp
applyCallSiteRewriteBody workers reps mLoopParams inTail (RLet fc var rep value body) =
    let value1 = applyCallSiteRewriteBody workers reps mLoopParams False value
        -- Promotion candidate iff `var` was still genuinely `RBoxed`
        -- and `value1`'s own ultimate tail is now a worker call with a
        -- native `retRep` -- see `nativePromotionFor`'s own doc
        -- comment for the actual eligibility question asked about
        -- `body`.
        promotedTy : Maybe PrimType
        promotedTy = case rep of
                          RBoxed => case ultimateTail value1 of
                                         RAppNameRep _ _ _ (RNative ty) _ _ => nativePromotionFor workers mLoopParams var ty body
                                         RAppNameRep _ _ _ (RInlineNative ty) _ _ => nativePromotionFor workers mLoopParams var ty body
                                         _ => Nothing
                          _ => Nothing
    in case promotedTy of
            Just ty =>
                -- stripOwnership needs no id renaming here, same
                -- reasoning as Compiler.RC2.DualABI's own Stage 3a use:
                -- `var` is a fresh RLet binding, not retrofitting a
                -- representation onto an already-declared C variable.
                let body' = stripOwnership (SortedSet.fromList [var]) body
                in RLet fc var (RNative ty) value1 (applyCallSiteRewriteBody workers (insert var (RNative ty) reps) mLoopParams inTail body')
            Nothing =>
                RLet fc var rep value1 (applyCallSiteRewriteBody workers (insert var rep reps) mLoopParams inTail body)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (applyCallSiteRewriteBody workers reps mLoopParams inTail t) (applyCallSiteRewriteBody workers reps mLoopParams inTail f)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RConCase fc sc alts mDef) =
    RConCase fc sc (map rewriteConAlt alts) (map (applyCallSiteRewriteBody workers reps mLoopParams inTail) mDef)
  where
    rewriteConAlt : RConAlt -> RConAlt
    rewriteConAlt (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (applyCallSiteRewriteBody workers reps mLoopParams inTail body)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map rewriteConstAlt alts) (map (applyCallSiteRewriteBody workers reps mLoopParams inTail) mDef)
  where
    rewriteConstAlt : RConstAlt -> RConstAlt
    rewriteConstAlt (MkRConstAlt c body) = MkRConstAlt c (applyCallSiteRewriteBody workers reps mLoopParams inTail body)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (applyCallSiteRewriteBody workers (foldl (\m, (i, r) => insert i r m) reps loopParams) (Just loopParams) inTail body)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RDup fc v extra cont) = RDup fc v extra (applyCallSiteRewriteBody workers reps mLoopParams inTail cont)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RDrop fc vs cont) = RDrop fc vs (applyCallSiteRewriteBody workers reps mLoopParams inTail cont)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RFree fc v cont) = RFree fc v (applyCallSiteRewriteBody workers reps mLoopParams inTail cont)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RReleaseReuse fc v cont) = RReleaseReuse fc v (applyCallSiteRewriteBody workers reps mLoopParams inTail cont)
applyCallSiteRewriteBody workers reps mLoopParams inTail (RReuseOffer fc sc dupOnShared dropOnUnique cont) = RReuseOffer fc sc dupOnShared dropOnUnique (applyCallSiteRewriteBody workers reps mLoopParams inTail cont)
-- The main rewrite: a bare RAppName reached with inTail = False is
-- always the ultimate tail of some value-computation chain (the RLet
-- clause above already peeled through any RLet-bound value), never
-- the whole function's own true tail -- safe to rewrite through either
-- table entry alike; the Bool tag only matters below.
applyCallSiteRewriteBody workers reps _ False value@(RAppName fc _ n args) =
    case lookup n workers of
         Nothing => value
         Just (workerName, argReps, workerRetRep, _) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
-- A bare RAppName reached with inTail = True -- the whole function's
-- own true tail position. Left alone for an ordinary worker (tag
-- `False`: can still chain into further deferred tail calls, see
-- workerTable's own doc comment); rewritten just like the non-tail
-- case for an FFI worker (tag `True`: always a leaf, see
-- ffiWorkerTable's own doc comment) -- see doc/dual-abi.md's "Stage
-- 4b" for the full design; no Emit-side change was needed for this.
applyCallSiteRewriteBody workers reps _ True value@(RAppName fc _ n args) =
    case lookup n workers of
         Just (workerName, argReps, workerRetRep, True) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
         _ => value
-- Every other shape: RV, RAppNameRep, RUnderApp, RApp, RCon, RExtPrim,
-- RPrimVal, RErased, RCrash, RLoopContinue, RStructGet, RStructSet --
-- none hold a further RLet-bound-value position of their own for this
-- pass to inspect.
applyCallSiteRewriteBody _ _ _ _ e = e

||| Whole-program pass: Stage 4 itself. Every direct, saturated,
||| non-tail-position call targeting a worker (Stage 3a/3c) gets
||| redirected straight to it; a tail-position call only when the
||| target is an FFI worker (`ffiWorkers`'s entries tagged `True`,
||| `workerTable`'s tagged `False`) -- see `applyCallSiteRewriteBody`'s
||| own doc comment for the design, `doc/dual-abi.md`'s "Stage 4"/
||| "Stage 4b" for why the tag distinction is safe. Runs after
||| `applyDualABI`; every definition passes through the same rewrite
||| uniformly, starting `inTail = True` at its own top-level body.
||| `ffiWorkers` and the `MkRCFun`-derived `workerTable` always have
||| disjoint keys (a name is never both `MkRCFun` and `MkRCForeign`),
||| so `mergeWith`'s own conflict-resolution function is never actually
||| exercised.
export
applyCallSiteRewrite : SortedMap Name (Name, List Rep, Rep, Bool) -> List (Name, RCDef) -> List (Name, RCDef)
applyCallSiteRewrite ffiWorkers defs =
    let workers = mergeWith const (workerTable defs) ffiWorkers
    in map (rewriteDef workers) defs
  where
    rewriteDef : SortedMap Name (Name, List Rep, Rep, Bool) -> (Name, RCDef) -> (Name, RCDef)
    rewriteDef workers (n, MkRCFun args retRep isWorker body) =
        (n, MkRCFun args retRep isWorker (applyCallSiteRewriteBody workers (fromList args) Nothing True body))
    rewriteDef _ (n, d) = (n, d)

------------------------------------------------------------------------
-- Stage 5: fold each Stage-4-produced FFI worker call directly into
-- its own marshalling logic, eliminating the standalone worker
-- function `ffiWorkerTable` synthesizes a name for. A separate pass
-- placed strictly after Stage 4, for the same reason
-- `Compiler.RC2.Inline` is its own pass rather than folded into
-- `Compiler.RC2.RC` -- see `doc/dual-abi.md`'s "Stage 5" for the full
-- design and why this pass only ever needs to swap the node shape,
-- never revisit Stage 4's own ownership/promotion decisions.

||| Structural, whole-tree rewrite: every `RAppNameRep` naming a worker
||| `ffiInline` has an entry for becomes `RAppFFIInline`, `postDrop`/
||| `args` unchanged -- always safe since `argReps = map repOf fargs` is
||| invariant between the two shapes (`RAppFFIInline`'s own doc comment
||| in RCExp.idr). Every other node just recurses through -- no
||| Rep-inference/ownership/tail-position logic of its own, unlike
||| Stage 4 -- much like `Loop.idr`'s own `renameRCExp`.
inlineFFIWorkersExp : SortedMap Name (List String, List CFType, CFType) -> RCExp -> RCExp
inlineFFIWorkersExp ffiInline (RAppNameRep fc workerName argReps retRep postDrop args) =
    case lookup workerName ffiInline of
         Just (ccs, fargs, ret) => RAppFFIInline fc ccs fargs ret postDrop args
         Nothing => RAppNameRep fc workerName argReps retRep postDrop args
inlineFFIWorkersExp ffiInline (RLet fc var rep value body) =
    RLet fc var rep (inlineFFIWorkersExp ffiInline value) (inlineFFIWorkersExp ffiInline body)
inlineFFIWorkersExp ffiInline (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (inlineFFIWorkersExp ffiInline t) (inlineFFIWorkersExp ffiInline f)
inlineFFIWorkersExp ffiInline (RConCase fc sc alts mDef) =
    RConCase fc sc (map rewriteAlt alts) (map (inlineFFIWorkersExp ffiInline) mDef)
  where
    rewriteAlt : RConAlt -> RConAlt
    rewriteAlt (MkRConAlt name ci tag args body) = MkRConAlt name ci tag args (inlineFFIWorkersExp ffiInline body)
inlineFFIWorkersExp ffiInline (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map rewriteAlt alts) (map (inlineFFIWorkersExp ffiInline) mDef)
  where
    rewriteAlt : RConstAlt -> RConstAlt
    rewriteAlt (MkRConstAlt c body) = MkRConstAlt c (inlineFFIWorkersExp ffiInline body)
inlineFFIWorkersExp ffiInline (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (inlineFFIWorkersExp ffiInline body)
inlineFFIWorkersExp ffiInline (RDup fc v extra cont) = RDup fc v extra (inlineFFIWorkersExp ffiInline cont)
inlineFFIWorkersExp ffiInline (RDrop fc vs cont) = RDrop fc vs (inlineFFIWorkersExp ffiInline cont)
inlineFFIWorkersExp ffiInline (RFree fc v cont) = RFree fc v (inlineFFIWorkersExp ffiInline cont)
inlineFFIWorkersExp ffiInline (RReleaseReuse fc v cont) = RReleaseReuse fc v (inlineFFIWorkersExp ffiInline cont)
inlineFFIWorkersExp ffiInline (RReuseOffer fc sc dupOnShared dropOnUnique cont) =
    RReuseOffer fc sc dupOnShared dropOnUnique (inlineFFIWorkersExp ffiInline cont)
inlineFFIWorkersExp _ e = e

||| Whole-program pass: Stage 5 itself. See `inlineFFIWorkersExp`'s own
||| doc comment -- every definition (wrapper, ordinary worker, FFI
||| wrapper, or untouched) passes through the same rewrite uniformly,
||| same reasoning as `applyCallSiteRewrite` above.
export
inlineFFIWorkers : SortedMap Name (List String, List CFType, CFType) -> List (Name, RCDef) -> List (Name, RCDef)
inlineFFIWorkers ffiInline defs = map (rewriteDef ffiInline) defs
  where
    rewriteDef : SortedMap Name (List String, List CFType, CFType) -> (Name, RCDef) -> (Name, RCDef)
    rewriteDef ffiInline' (n, MkRCFun args retRep isWorker body) =
        (n, MkRCFun args retRep isWorker (inlineFFIWorkersExp ffiInline' body))
    rewriteDef _ (n, d) = (n, d)
