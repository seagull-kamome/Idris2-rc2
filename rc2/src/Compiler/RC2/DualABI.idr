module Compiler.RC2.DualABI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Dual calling convention: optimizes function signatures by promoting
-- parameters and return types to native (unboxed) representations
-- where statically eligible. Both eligibility analyses are purely
-- *local* to one function's own body -- no whole-program fixed point
-- is needed (see `rc2/doc/dual-abi.md`'s design section for why).
--
-- Tail-position calls are a deliberate, permanent scope boundary, not
-- a later stage: rewriting one into a direct, non-deferred call could
-- reintroduce unbounded C stack growth that the current closure-
-- deferral scheme bounds, and telling which call sites would be safe
-- to rewrite would need real interprocedural analysis -- exactly the
-- whole-program fixed point this effort otherwise avoids needing. A
-- tail call to an FFI worker is the one exception: a `%foreign`
-- callee is a leaf as far as this scheme is concerned (it can never
-- itself extend an otherwise-unknown-depth chain of further deferred
-- tail calls), so it's rewritten in tail position too -- see
-- `applyCallSiteRewriteBody`'s own tail-position clause (Stage 4).
--
-- See `rc2/doc/dual-abi.md` for the full design, the Stage 2
-- verification results against the test/benchmark suite, and the
-- documented interaction with `Compiler.RC2.MutualLoop`-produced
-- merged functions (which Stage 3 must exclude from worker synthesis
-- explicitly -- see that doc's "Bugs found" section).

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop
import Compiler.RC2.EmitUtil
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

||| Find an `RLoop` reachable through a prefix of ordinary `RLet`s
||| (`Compiler.RC2.Loop.applyLoop`'s own invariant-loop-param elision
||| wraps an `RLoop` in exactly this shape now -- a native-shadow-
||| eligible parameter that turned out loop-invariant gets hoisted into
||| a one-time `RLet` ahead of the loop rather than staying loop-
||| carried, see that function's own doc comment), collecting every id
||| bound along the way. `Nothing` if no `RLoop` is reachable this way
||| at all (an ordinary non-looping function, the common case).
findLoopThroughLets : SortedMap Int Rep -> RCExp -> Maybe (SortedMap Int Rep, List (Int, Rep))
findLoopThroughLets acc (RLet _ var rep _ body) = findLoopThroughLets (insert var rep acc) body
findLoopThroughLets acc (RLoop _ loopParams _ _ _) = Just (acc, loopParams)
findLoopThroughLets _ _ = Nothing

||| Every top-level parameter's own native eligibility: `Just ty` at the
||| position(s) `Compiler.RC2.Loop`'s `nativeArgType` (or, for an
||| already-`RLoop`-wrapped body, `loopParams` together with any
||| invariant-parameter `RLet`s wrapping it, see `findLoopThroughLets`)
||| finds eligible, `Nothing` otherwise. Reads `Compiler.RC2.Loop`'s own
||| decision directly when present rather than re-deriving it, via an id
||| lookup rather than a positional `zip` against `argIds` -- since
||| `applyLoop`'s own invariant-parameter elision, `loopParams` can now
||| be a strict subset of the function's own top-level parameters (with
||| the rest either needing no entry at all -- an eliminated Boxed
||| parameter's own id is still, and remains, the enclosing function's
||| own argument -- or captured by one of the wrapping `RLet`s instead);
||| an id missing from both simply means `Nothing` here, which is
||| correct either way (an eliminated Boxed parameter was never native
||| to begin with).
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

||| One line per `MkRCFun` def, reporting `paramEligibility`/
||| `returnEligibility`'s own results -- a debugging aid only, written
||| to `<outfile>.dualabi` whenever `--directive dumpdualabi` is passed
||| (see `RC2.idr`'s `compileExpr`), mirroring `Compiler.RC2.Pretty`'s
||| own `.rcexpr` dump. Stage 2's own verification tool: nothing in the
||| main pipeline reads this back, and nothing here is synthesized or
||| rewritten yet -- see the module note.
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

||| A fresh name for `original`'s own worker: `pfx` (the caller's own
||| prefix, e.g. `"idris2rc2_worker_"` for an ordinary `MkRCFun` worker,
||| `"idris2rc2_ffiworker_"` for an FFI one) plus `original`'s own
||| mangled C name (`Compiler.RC2.EmitUtil`'s `cName`, reused directly --
||| the exact same mangling the wrapper's own, unchanged C name already
||| uses, so the two read as visibly related) plus a disambiguating
||| counter (defends against, e.g., two originals whose own mangled
||| names happen to collide after `cCleanString`'s own character
||| sanitisation -- not expected in practice, kept only so this is
||| provably total either way). The prefix itself makes a worker's own
||| C name identifiable on sight, both as *generated* (matching this
||| project's own `idris2rc2_`-prefix convention for every runtime-owned
||| C symbol, `CLAUDE.md`) and as *whichever pass* produced it (nothing
||| else in the compiler ever produces either of the two prefixes above),
||| rather than the opaque `rc2_dualABI_N` counter this used to be.
freshName : {auto r : Ref FreshId Int} -> (pfx : String) -> SortedSet Name -> Name -> Core Name
freshName pfx existing original = do
    i <- freshId
    let cand = MN (pfx ++ cName original) i
    if contains cand existing then freshName pfx existing original else pure cand

-- `isMutualLoopMerged` itself now lives in `Compiler.RC2.Util` (see its
-- own doc comment there) -- reused as-is here via the existing `Util`
-- import above.

||| For one top-level function eligible for at least one native
||| parameter and/or a native return: synthesise its own worker (fresh
||| name; each parameter promoted to `RNative` at the eligible
||| positions, `RBoxed` at every other; `retRep` promoted to `RNative`
||| when `retEligible` found one, otherwise left as `wrapperRetRep`
||| unchanged; body is the original's own body verbatim, minus the
||| promoted parameters' now-stale ownership bookkeeping, via
||| `Compiler.RC2.Loop`'s own `stripOwnership` -- no id renaming needed
||| at all: the worker reuses every original parameter's own id
||| directly, safe because it's a brand-new C function with no existing
||| declaration under that name to collide with, unlike that module's
||| own use of `stripOwnership` for a loop's shadow ids within the
||| *same* function), and rewrite the original into a thin wrapper:
||| unchanged signature (`wrapperRetRep`, always `RBoxed` in practice --
||| every existing caller anywhere else in the program keeps working
||| unmodified), unchanged id, body is a single `RAppNameRep` call into
||| the worker, one argument per original parameter rendered per the
||| worker's own decided `Rep` there, and the *call's* own `retRep`
||| naming the worker's own (possibly native) return -- `Compiler.RC2.Emit`'s
||| own dedicated `RAppNameRep` renderer boxes that back up via
||| `nativeMk` before it becomes this wrapper's own (always-Boxed) tail
||| value, see its own module note. Every wrapper argument rendered
||| natively (an eligible position) is passed as `RAppNameRep`'s own
||| `postDrop`: the wrapper's own top-level parameters are always
||| `RBoxed` by construction, so any of them read natively by the call
||| (via `rcVarToNativeC`, which never dups/drops on its own -- see
||| `RAppNameRep`'s own doc comment in RCExp.idr) is left alive and
||| genuinely needs this explicit drop once the call has read it.
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

||| Whole-program pass: for every `MkRCFun` with at least one
||| parameter-eligible position and/or an eligible return
||| (`Compiler.RC2.MutualLoop`-produced merged functions excluded, see
||| `isMutualLoopMerged`), synthesises a worker (native at whichever of
||| its own parameters/return turned out eligible) and rewrites the
||| original into a thin wrapper -- see the module note for the full
||| Stage 3a+3b design. Every other definition (a function with nothing
||| eligible at all, or any non-`MkRCFun` def) passes through
||| completely unchanged.
|||
||| No width limit on the worker's own parameter count, unlike an
||| earlier version of this pass: a worker is only ever reachable via a
||| direct, statically-named `RAppNameRep` call (from its own wrapper's
||| body, or Stage 4's own call-site rewriting), never stored in a
||| `Closure` and so never dispatched through
||| `support/rc2/runtime.c`'s `idris2rc2_dispatchClosure` -- unlike an
||| ordinary function or this pass's own wrapper (both of which keep
||| the always-Boxed, closure-dispatch-compatible calling convention,
||| and so DO still need `Compiler.RC2.Emit`'s `createCFunctions` to
||| fall back to a `var_arglist[]`-style declaration past
||| `MaxExtractFunArgs` parameters -- see that function's own doc
||| comment). `MkRCFun`'s `isWorker` field is exactly this distinction,
||| baked onto the IR node itself rather than re-derived: `True` only
||| for a worker `synthesizeWorker` itself produces, `False` for its
||| own wrapper and everywhere else. See rc2/doc/dual-abi.md's "Bugs
||| found and fixed" #7-9 for why this exemption exists (a real,
||| externally-sourced package's own wide lambda-lifted helper) and how
||| far it was carried (closure-dispatch typedefs up to arity 20, the
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
-- always-Boxed C stub (`Compiler.RC2.Emit`'s `createCFunctions`) is
-- untouched by this pass entirely, wrapper and all. This only builds
-- the worker *table* Stage 4 needs; `Compiler.RC2.Emit` is the one
-- that actually emits a worker C function for each entry, reading this
-- exact table back via its own `FFIWorkers` ref (`RC2.idr`'s pipeline
-- threads the same `SortedMap` to both).

||| `ret`'s own peeled type -- `CFIORes t`'s payload `t`, or `ret`
||| itself for a non-IO (pure) `%foreign` declaration.
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

||| Every `MkRCForeign` def's own worker-table entry, if its own
||| `fargs`/`ret` have at least one `cfTypeNative`-eligible position.
||| No `paramEligibility`/`returnEligibility` needed here at all -- a
||| `%foreign` declaration's own `CFType`s already commit to a fixed C
||| ABI, so eligibility is decided by the type alone, unconditionally,
||| with no function body to analyse (see `Compiler.RC2.Types`'
||| `cfTypeNative` own doc comment for why it's a narrower set than
||| `nativeEligible`). `CFIORes`'s own payload type is what gets asked,
||| not `CFIORes` itself; a `CFWorld` trailing argument (IO's own dummy
||| world token) is never eligible either way, so it needs no special
||| peeling on the parameter side -- it just stays `RBoxed`, identically
||| to today, like every other non-eligible position.
|||
||| Returns two maps built from the same single traversal: the first,
||| keyed by the *original* `%foreign` name, is `Compiler.RC2.RC2`'s own
||| unmodified input to `applyCallSiteRewrite` below (Stage 4 itself is
||| untouched by this module's later FFI-inline addition -- see this
||| module's own header note); the second, keyed by the *worker's own*
||| synthesized name instead, is `inlineFFIWorkers`'s own input (Stage
||| 5, below Stage 4's section) -- it needs to recognise a Stage-4-
||| produced `RAppNameRep` by the worker name Stage 4 already put on
||| it, not the original function's name, which no longer appears
||| anywhere on that node.
|||
||| The first map's own entries carry a trailing `Bool`, always `True`
||| here -- "safe to rewrite even in tail position" (see
||| `applyCallSiteRewriteBody`'s own tail-position clause below for why
||| an FFI worker specifically is safe there, unlike an ordinary
||| `Compiler.RC2.DualABI` worker, which `workerTable` tags `False`):
||| a `%foreign` declaration's own callee is a leaf as far as this
||| module's own tail-call-deferral scheme is concerned -- it can never
||| itself extend an otherwise-unknown-depth chain of further deferred
||| Idris tail calls the way an ordinary RC2 function might, so the
||| stack-growth risk that scope boundary exists to avoid simply
||| doesn't apply here.
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
        in if not (any anyNative argReps) && not (anyNative retRep)
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

||| The worker (if any) `n` -- an *original*, user-visible function
||| name -- was rewritten to call: `(workerName, argReps, retRep)`,
||| read directly off the wrapper's own body. `synthesizeWorker`'s own
||| construction guarantees a wrapper's *entire* body is always exactly
||| one bare `RAppNameRep` call into its own worker, nothing else (see
||| its own doc comment) -- so scanning for that exact shape recovers
||| the table without `applyDualABI` itself needing to thread a
||| separate one out alongside its own `List (Name, RCDef)` result.
||| Tagged `False` (unlike `ffiWorkerTable`'s own entries) -- an
||| ordinary RC2 function's worker genuinely can chain into further
||| deferred tail calls, so `applyCallSiteRewriteBody`'s tail-position
||| clause must still leave a call through this table alone.
workerTable : List (Name, RCDef) -> SortedMap Name (Name, List Rep, Rep, Bool)
workerTable defs = fromList (mapMaybe workerEntry defs)
  where
    workerEntry : (Name, RCDef) -> Maybe (Name, (Name, List Rep, Rep, Bool))
    workerEntry (n, MkRCFun _ _ _ (RAppNameRep _ workerName argReps retRep _ _)) =
        Just (n, (workerName, argReps, retRep, False))
    workerEntry _ = Nothing

||| Which of `args` (rendered per the worker's own `argReps`, same
||| order) need an explicit drop once this call has been embedded in
||| its own statement: exactly the positions the worker reads
||| *natively* whose own source, per `reps`, is still genuinely
||| `RBoxed` -- see `RAppNameRep`'s own `postDrop` doc comment in
||| RCExp.idr for why this field exists at all (a real reference leak,
||| found via `valgrind`, in `Compiler.RC2.DualABI`'s own earlier
||| worker/wrapper synthesis before it did). No liveness analysis of
||| this pass's own is needed to get this right: `Compiler.RC2.RC`'s
||| own `annotate` already decided, for the *original* (still-
||| `RAppName`) call this replaces, that passing a Boxed argument to a
||| call consumes exactly one reference (dup'ing beforehand if that
||| argument's own local is still needed after this point, transferring
||| without a dup if this was already its last use) -- reading it
||| natively instead and dropping it right here pays the exact same net
||| cost, just explicitly rather than via ordinary Boxed hand-off, so
||| whatever `annotate` already arranged around this call site (an
||| earlier `RDup`, or none) still balances correctly either way.
postDropFor : SortedMap Int Rep -> List Rep -> List RCLocal -> List RCLocal
postDropFor reps argReps args =
    mapMaybe (\(r, a) => case r of
                              RBoxed => Nothing
                              _ => case localRepIn reps a of
                                        RBoxed => Just a
                                        _ => Nothing) (zip argReps args)

||| `e`'s own ultimate tail expression, peeling through every `RLet`'s
||| own `body` and every `RDup`/`RDrop`/`RFree`/`RReleaseReuse`/
||| `RReuseOffer`'s own `cont` -- the same peeling
||| `Compiler.RC2.Emit`'s `tryEmitLoopContinue`/`Compiler.RC2.EmitUtil`'s
||| `peelDrop` already do,
||| just walking all the way to the very end instead of stopping at the
||| first interesting shape. Used only to *inspect* what a value
||| position (an `RLet`'s own, possibly deeply nested, `value` -- see
||| `applyCallSiteRewriteBody`'s own doc comment for why that can
||| itself be a further `RLet` chain, not always a flat leaf) ultimately
||| evaluates to, never to rewrite anything itself.
ultimateTail : RCExp -> RCExp
ultimateTail (RLet _ _ _ _ body) = ultimateTail body
ultimateTail (RDup _ _ cont) = ultimateTail cont
ultimateTail (RDrop _ _ cont) = ultimateTail cont
ultimateTail (RFree _ _ cont) = ultimateTail cont
ultimateTail (RReleaseReuse _ _ cont) = ultimateTail cont
ultimateTail (RReuseOffer _ _ _ _ cont) = ultimateTail cont
ultimateTail e = e

||| `var`'s own native `PrimType` if `e`'s own *ultimate* tail
||| (peeling exactly as `ultimateTail` above does) is a bare (not
||| further `RLet`-bound) `ROp` reading `var` as one of its own
||| operands -- the one shape `Compiler.RC2.Loop`'s own `nativeArgTypes`
||| deliberately doesn't cover, and correctly so *for that pass's own
||| callers* (see its own doc comment: true when it runs, strictly
||| before any function's own return eligibility is decided, that a
||| bare tail is always Boxed regardless) -- but no longer true by the
||| time *this* stage runs: `fib`'s own worker is the concrete case this
||| exists for -- `let v3 = fib(n-1) in let v5 = fib(n-2) in v3 + v5`,
||| where `v3 + v5` is *itself* the worker's own bare tail, rendered
||| natively (`Compiler.RC2.Emit`'s own `emitNativeReturn`, Stage 3b)
||| precisely because the worker's own `retRep` already is -- without
||| this, neither `v3` nor `v5` would ever look like a worthwhile
||| promotion, and `fib` itself -- the flagship motivating case for this
||| entire effort -- would keep boxing every recursive call's own result
||| only to immediately unbox it again.
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
||| saturated call argument somewhere in `e`, at a position `workers`'
||| own table says its callee reads natively -- the same "skip the
||| box-then-immediately-unbox round trip" idea `nativeArgTypes`/
||| `bareTailNativeReads` already apply to an `ROp`/comparison operand
||| or a bare tail read, now extended to a *call* consuming the value
||| (`ffiCall2 (ffiCall1 x) y`-shaped chains, not just
||| `fib(n-1) + fib(n-2)`-shaped ones). Walks the whole tree, the same
||| way `nativeArgTypes` does -- a use can appear anywhere in `e`, not
||| just its tail. Looks only at bare `RAppName` nodes, since `e` is
||| always the *not-yet-Stage-4-rewritten* `body` at the point this is
||| called (see `applyCallSiteRewriteBody`'s own RLet clause: the
||| promotion decision for `var` happens before `body` itself is
||| walked). Whether `workers`' own entry for a callee is tagged `True`
||| (FFI) or `False` (ordinary) doesn't matter here -- both kinds are
||| always rewritten to read a native argument directly in *non-tail*
||| position (Stage 4's own non-tail clause ignores the tag too), and
||| an occurrence that instead sits in a tail-position call to an
||| ordinary (non-FFI) worker -- one Stage 4 leaves deferred via a
||| boxed closure, see the module's own header note -- still renders
||| correctly either way: closure slots only ever hold
||| `IDRIS2RC2_Value *`, so `var` gets reboxed on the way in exactly
||| like any other still-Boxed-context use elsewhere in `body` (see
||| this function's own caller, `nativePromotionFor`, for that same
||| "reboxed on demand, still correct" reasoning) -- promoting `var` in
||| that case just doesn't buy anything, it doesn't cost anything
||| either.
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
callArgNativeReads workers var (RDup _ _ cont) = callArgNativeReads workers var cont
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

||| Whether `body` justifies promoting an `RLet`-bound worker-call
||| result (currently `RBoxed`) all the way to `RNative ty` instead of
||| just rewriting the call itself and boxing its result back up on the
||| way out -- the difference between "native arguments into an
||| otherwise-still-boxed call" and the actual point of this whole
||| stage: skipping the box-then-immediately-unbox round trip entirely
||| (`fib(n-1) + fib(n-2)` staying in `int64_t` throughout, not
||| materialising a heap value for either recursive call's own result).
|||
||| Unions `Compiler.RC2.Loop`'s own (now exported) `nativeArgTypes`
||| with `bareTailNativeReads` and `callArgNativeReads` above, then asks
||| the *exact* same question `nativeArgType` itself asks about a whole
||| function's own top-level parameter, over that combined set: does
||| `body` (everything after this `RLet`) read `var` as a native-context
||| operand, consistently, at `ty`? Any *other*, still-Boxed-context use
||| of `var` elsewhere in `body` (e.g. stored into a constructor field)
||| keeps working correctly regardless of whether this promotes --
||| `rcVarToBoxedC`'s own on-demand reboxing of a native value handles
||| it, as a fresh allocation instead of sharing the one this call
||| *used* to produce, invisible to any Idris-level program (a scalar
||| has no observable identity) -- see `stripOwnership`'s own doc
||| comment for this exact case, already relied on by this same reuse.
nativePromotionFor : SortedMap Name (Name, List Rep, Rep, Bool) -> Int -> PrimType -> RCExp -> Maybe PrimType
nativePromotionFor workers var ty body =
    let found = (nativeArgTypes var body `union` bareTailNativeReads var body) `union` callArgNativeReads workers var body
    in case Prelude.toList found of
            [ty'] => if ty' == ty then Just ty else Nothing
            _ => Nothing

||| Rewrite every direct, saturated, non-tail-position call in `e`
||| targeting a function `workers` has a worker for. `reps` threads
||| this walk's own "which locals are already known native" state,
||| exactly the same seeding/extension `paramEligibility`/
||| `tailValueReps` (Stage 2, above) already use: a function's own
||| top-level parameters start it off (`applyCallSiteRewrite`'s own
||| entry point), each `RLet`'s own already-decided `Rep` extends it,
||| and `RLoop`'s own `loopParams` extends it across a loop's own body.
||| `inTail` tracks whether the point currently being visited is
||| genuinely the *whole function's* own tail position (only ever
||| `True` at the top-level entry point, and everywhere `RLet`'s own
||| `body`/`RCmpCase`/`RConCase`/`RConstCase`/`RLoop`'s own branches/
||| every wrapper node's own `cont` thread it straight through
||| unchanged) -- a bare `RAppName` reached there is left alone
||| (deliberately out of scope, see the module's own header note); one
||| reached with `inTail = False` is always safe to rewrite.
|||
||| Critically, `inTail` is *always* `False` while walking an `RLet`'s
||| own `value` (see this function's own first clause) -- and `value`
||| is *not* always the flat leaf (`ROp`/`RAppName`/`RCon`/etc.) it
||| might look like at first: Phase 1's own ANF normalisation of a call
||| *argument* expression (e.g. `fib (n - 2)`) nests a further `RLet`
||| *inside* the outer one's own value (`let v5 = (let v6 = n - 2 in
||| fib v6) in ...`), so the actual call can sit arbitrarily deep in a
||| chain of further `RLet`s, never directly as `value` itself. This
||| function's own first clause handles that correctly by *recursing*
||| into `value` (in non-tail mode, so any `RAppName` at *its* own
||| ultimate tail -- reached via this same function's own catch-all
||| below -- gets rewritten too) *before* deciding whether the
||| resulting `value1`'s own `ultimateTail` (peeling through exactly
||| that same kind of nested-`RLet` chain) is now a promotion
||| candidate.
applyCallSiteRewriteBody : SortedMap Name (Name, List Rep, Rep, Bool) -> SortedMap Int Rep -> Bool -> RCExp -> RCExp
applyCallSiteRewriteBody workers reps inTail (RLet fc var rep value body) =
    let value1 = applyCallSiteRewriteBody workers reps False value
        -- Promotion candidate iff `var` was still genuinely `RBoxed`
        -- and `value1`'s own ultimate tail is now a worker call with a
        -- native `retRep` -- see `nativePromotionFor`'s own doc
        -- comment for the actual eligibility question asked about
        -- `body`.
        promotedTy : Maybe PrimType
        promotedTy = case rep of
                          RBoxed => case ultimateTail value1 of
                                         RAppNameRep _ _ _ (RNative ty) _ _ => nativePromotionFor workers var ty body
                                         RAppNameRep _ _ _ (RInlineNative ty) _ _ => nativePromotionFor workers var ty body
                                         _ => Nothing
                          _ => Nothing
    in case promotedTy of
            Just ty =>
                -- stripOwnership needs no id renaming here, same
                -- reasoning as Compiler.RC2.DualABI's own Stage 3a use:
                -- `var` is a fresh RLet binding, not retrofitting a
                -- representation onto an already-declared C variable.
                let body' = stripOwnership (SortedSet.fromList [var]) body
                in RLet fc var (RNative ty) value1 (applyCallSiteRewriteBody workers (insert var (RNative ty) reps) inTail body')
            Nothing =>
                RLet fc var rep value1 (applyCallSiteRewriteBody workers (insert var rep reps) inTail body)
applyCallSiteRewriteBody workers reps inTail (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (applyCallSiteRewriteBody workers reps inTail t) (applyCallSiteRewriteBody workers reps inTail f)
applyCallSiteRewriteBody workers reps inTail (RConCase fc sc alts mDef) =
    RConCase fc sc (map rewriteConAlt alts) (map (applyCallSiteRewriteBody workers reps inTail) mDef)
  where
    rewriteConAlt : RConAlt -> RConAlt
    rewriteConAlt (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (applyCallSiteRewriteBody workers reps inTail body)
applyCallSiteRewriteBody workers reps inTail (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map rewriteConstAlt alts) (map (applyCallSiteRewriteBody workers reps inTail) mDef)
  where
    rewriteConstAlt : RConstAlt -> RConstAlt
    rewriteConstAlt (MkRConstAlt c body) = MkRConstAlt c (applyCallSiteRewriteBody workers reps inTail body)
applyCallSiteRewriteBody workers reps inTail (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (applyCallSiteRewriteBody workers (foldl (\m, (i, r) => insert i r m) reps loopParams) inTail body)
applyCallSiteRewriteBody workers reps inTail (RDup fc v cont) = RDup fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RDrop fc vs cont) = RDrop fc vs (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RFree fc v cont) = RFree fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RReleaseReuse fc v cont) = RReleaseReuse fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RReuseOffer fc sc dupOnShared dropOnUnique cont) = RReuseOffer fc sc dupOnShared dropOnUnique (applyCallSiteRewriteBody workers reps inTail cont)
-- The main case that rewrites a call: a bare RAppName reached with
-- inTail = False (never anyone's RLet-bound value, by this point --
-- the RLet clause above already peeled through those -- so this is
-- the ultimate tail of *some* value-computation chain, not the whole
-- function's own true tail position). Rewrites through either kind of
-- table entry (ordinary worker or FFI worker) alike -- the `Bool` tag
-- only matters for the tail-position clause just below.
applyCallSiteRewriteBody workers reps False value@(RAppName fc _ n args) =
    case lookup n workers of
         Nothing => value
         Just (workerName, argReps, workerRetRep, _) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
-- A bare RAppName reached with inTail = True -- the whole function's
-- own true tail position. Left alone for an ordinary worker (tagged
-- `False`, see `workerTable`'s own doc comment: it can chain into
-- further deferred tail calls of unknown depth, so
-- `tryBuildClosureInto`'s closure-deferral scheme must still handle
-- it) -- but rewritten just the same as the non-tail case for an FFI
-- worker (tagged `True`, see `ffiWorkerTable`'s own doc comment: a
-- `%foreign` callee is a leaf, never itself another link in a
-- deferred tail-call chain, so the risk that scope boundary exists to
-- avoid doesn't apply). `Compiler.RC2.Emit`'s `emitAppFFIInlineInto`
-- already renders a `SinkReturn` correctly (return-with-drop-before-
-- return ordering, same as any other tail value), so no Emit-side
-- change is needed for this to work once Stage 5 below turns the
-- resulting `RAppNameRep` into an `RAppFFIInline`.
applyCallSiteRewriteBody workers reps True value@(RAppName fc _ n args) =
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
applyCallSiteRewriteBody _ _ _ e = e

||| Whole-program pass: Stage 4 itself. Every direct, saturated,
||| non-tail-position call anywhere in the program targeting a function
||| Stage 3a/3b gave a worker to gets redirected straight to that
||| worker, native arguments/return where the call site already has (or
||| can be promoted to have) them on hand -- see the module's own header
||| note and `applyCallSiteRewriteBody`'s own doc comment for the full
||| design. A direct, saturated, *tail*-position call gets the same
||| treatment too, but only when it targets an FFI worker specifically
||| (`ffiWorkers`'s own entries are tagged `True`; `workerTable`'s own
||| are tagged `False`) -- see `applyCallSiteRewriteBody`'s own
||| tail-position clause for why that distinction is safe. Runs after
||| `applyDualABI` (needs its own worker table already built); every
||| definition (wrapper, worker, or untouched) passes through the same
||| rewrite uniformly -- nothing here needs to know which of those
||| three a given definition is, since a wrapper's own trivial
||| single-call body and an ordinary function's body are rewritten by
||| exactly the same logic. Each definition's own top-level body starts
||| `inTail = True` -- that's genuinely where the function's own real
||| tail position is. `ffiWorkers` (Stage 3c's own table) is unioned in
||| alongside the `MkRCFun`-derived `workerTable` -- their keys are
||| always disjoint (a `MkRCFun`/`MkRCForeign` name can never be both),
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
        (n, MkRCFun args retRep isWorker (applyCallSiteRewriteBody workers (fromList args) True body))
    rewriteDef _ (n, d) = (n, d)

------------------------------------------------------------------------
-- Stage 5: fold each Stage-4-produced FFI worker call directly into
-- its own marshalling logic, eliminating the standalone worker
-- function `ffiWorkerTable` above still synthesizes a name for. A
-- separate pass placed strictly after Stage 4 (rather than folded
-- into `applyCallSiteRewriteBody` itself), for the same reason
-- `Compiler.RC2.Inline` is its own pass rather than folded into
-- `Compiler.RC2.RC`: Stage 4's own `RAppName`/`RLet` rewriting logic
-- is already involved enough without also needing to know about
-- FFI-specific marshalling concerns. By the time this runs, Stage 4
-- has already made every ownership/promotion decision (`RAppNameRep`'s
-- own `postDrop`, and any enclosing `RLet`'s own native `Rep`
-- promotion) purely in terms of "is this call's own `retRep` native",
-- a question `RAppNameRep`'s `retRep` field already answers
-- identically whether the callee turns out to be an ordinary
-- `Compiler.RC2.DualABI` worker or (as only this pass knows) an FFI
-- one -- so this pass only ever needs to swap the node shape itself,
-- never re-derive or revisit any of those decisions.

||| Structural, whole-tree rewrite: every `RAppNameRep` naming a worker
||| `ffiInline` has an entry for becomes `RAppFFIInline`, `postDrop`/
||| `args` carried over completely unchanged -- see `RAppFFIInline`'s
||| own doc comment in RCExp.idr for why this is always safe
||| (`argReps = map repOf fargs` is invariant between the two node
||| shapes, so whatever Stage 4 already decided stays correct). Every
||| other node shape just recurses through -- no Rep-inference,
||| ownership, or tail-position logic of its own, unlike Stage 4
||| itself; much like `Loop.idr`'s own `renameRCExp` or
||| `ConstFold.idr`'s own tree-walkers.
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
inlineFFIWorkersExp ffiInline (RDup fc v cont) = RDup fc v (inlineFFIWorkersExp ffiInline cont)
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
