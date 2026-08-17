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
-- whole-program fixed point this effort otherwise avoids needing.
--
-- See `rc2/doc/dual-abi.md` for the full design, the Stage 2
-- verification results against the test/benchmark suite, and the
-- documented interaction with `Compiler.RC2.MutualLoop`-produced
-- merged functions (which Stage 3 must exclude from worker synthesis
-- explicitly -- see that doc's "Bugs found" section).

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Loop
import Compiler.RC2.Emit

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
paramEligibility argIds (RLoop _ loopParams _ _ _) =
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
tailValueReps reps (RLoop _ loopParams _ _ body) =
    tailValueReps (foldl (\m, (i, r) => insert i r m) reps loopParams) body
tailValueReps _ (RLoopContinue _ _ _) = []
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
||| own `.rcexpr` dump. Stage 2's own verification tool: nothing in the
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

------------------------------------------------------------------------
-- Stage 3a: worker synthesis (parameters only) + wrapper rewrite.

data FreshId : Type where

freshId : {auto r : Ref FreshId Int} -> Core Int
freshId = do i <- get FreshId; put FreshId (i + 1); pure i

||| A fresh name for `original`'s own worker: `idris2rc2_worker_` plus
||| `original`'s own mangled C name (`Compiler.RC2.Emit`'s `cName`,
||| reused directly -- the exact same mangling the wrapper's own,
||| unchanged C name already uses, so the two read as visibly related)
||| plus a disambiguating counter (defends against, e.g., two
||| originals whose own mangled names happen to collide after
||| `cCleanString`'s own character sanitisation -- not expected in
||| practice, kept only so this is provably total either way). The
||| `idris2rc2_worker_` prefix itself makes a worker's own C name
||| identifiable on sight, both as *generated* (matching this project's
||| own `idris2rc2_`-prefix convention for every runtime-owned C symbol,
||| `CLAUDE.md`) and as *this specific pass's* own output (nothing else
||| in the compiler ever produces this prefix), rather than the opaque
||| `rc2_dualABI_N` counter this used to be.
freshName : {auto r : Ref FreshId Int} -> SortedSet Name -> Name -> Core Name
freshName existing original = do
    i <- freshId
    let cand = MN ("idris2rc2_worker_" ++ cName original) i
    if contains cand existing then freshName existing original else pure cand

||| True for a name `Compiler.RC2.MutualLoop` itself synthesised (its
||| own merged function -- sharing one slot per position across
||| multiple original members, potentially with different arities/
||| native-eligibility needs -- see this module's own header note's
||| "finding" from Stage 2's verification). These must never get a
||| dual-ABI worker of their own: a slot that's genuinely native for
||| one member can receive a literal `RCNull` from a smaller-arity
||| member's own caller, and `Compiler.RC2.Loop`'s own native-shadow
||| promotion already had to work around exactly this once (two real
||| crashes, see `doc/loop-conversion.md`'s "Bugs found" #4) for the
||| *loop-carried* case -- giving the merged function's own *external*
||| signature a native worker too would reopen the same hazard at a
||| different boundary. `MutualLoop`'s own per-member *wrapper*
||| functions don't need this special-casing -- their own body is
||| always just a forwarding call, so `paramEligibility`/
||| `returnEligibility` already correctly find nothing eligible there
||| on their own (confirmed directly in Stage 2's own verification).
isMutualLoopMerged : Name -> Bool
isMutualLoopMerged (MN "rc2_mutualLoop" _) = True
isMutualLoopMerged _ = False

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
    workerName <- freshName existingNames original
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
        workerDef = MkRCFun workerArgs workerRetRep workerBody
        wrapperArgIds : List Int
        wrapperArgIds = map fst args
        wrapperPostDrop : List RCLocal
        wrapperPostDrop = map RCLoc (map fst eligible)
        wrapperBody : RCExp
        wrapperBody = RAppNameRep emptyFC workerName (map snd workerArgs) workerRetRep wrapperPostDrop (map RCLoc wrapperArgIds)
        wrapperDef : RCDef
        wrapperDef = MkRCFun args wrapperRetRep wrapperBody
    pure (workerName, wrapperDef, workerDef)

||| Whole-program pass: for every `MkRCFun` with at least one
||| parameter-eligible position and/or an eligible return
||| (`Compiler.RC2.MutualLoop`-produced merged functions excluded, see
||| `isMutualLoopMerged`; a function with more than `MaxExtractFunArgs`
||| own top-level parameters also excluded unconditionally, regardless
||| of what eligibility it would otherwise have -- see this function's
||| own inline note), synthesises a worker (native at whichever of its
||| own parameters/return turned out eligible) and rewrites the
||| original into a thin wrapper -- see the module note for the full
||| Stage 3a+3b design. Every other definition (a function with nothing
||| eligible at all, or any non-`MkRCFun` def) passes through
||| completely unchanged.
export
applyDualABI : List (Name, RCDef) -> Core (List (Name, RCDef))
applyDualABI defs = do
    _ <- newRef FreshId 0
    let existingNames = SortedSet.fromList (map fst defs)
    concat <$> traverse (synthesizeIfEligible existingNames) defs
  where
    synthesizeIfEligible : {auto r : Ref FreshId Int} -> SortedSet Name -> (Name, RCDef) -> Core (List (Name, RCDef))
    synthesizeIfEligible existingNames (n, d@(MkRCFun args retRep body)) =
        -- `RAppNameRep`'s own emission (`Compiler.RC2.Emit`'s
        -- `emitAppNameRepInto`/`emitNativeValue`) has no `var_arglist[]`
        -- -style extraction fallback for more than `MaxExtractFunArgs`
        -- arguments the way an ordinary, always-Boxed many-argument
        -- function's own `createCFunctions` path does -- every
        -- `RAppNameRep` call this pass (or Stage 4's own call-site
        -- rewriting) ever produces throws `InternalError` past that
        -- limit. A real, externally-sourced package (not covered by
        -- this project's own test suite, which has no function this
        -- wide) hit exactly this: some of its own lambda-lifted
        -- internal helpers carry 9+ parameters (free variables
        -- captured from an enclosing scope), and at least one of those
        -- parameters was otherwise genuinely native-eligible. Rather
        -- than building that extraction fallback (real work, and this
        -- shape is expected to stay rare), simply exclude any function
        -- this wide from dual-ABI eligibility entirely, unconditionally
        -- -- regardless of what `paramEligibility`/`returnEligibility`
        -- would otherwise decide -- so no `RAppNameRep` is ever
        -- constructed for it in the first place. Correct, if
        -- conservative: such a function just keeps its own ordinary,
        -- always-Boxed calling convention, same as before this whole
        -- effort existed.
        if isMutualLoopMerged n || length args > MaxExtractFunArgs
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
-- Stage 4: call-site rewriting (non-tail positions only -- see the
-- module's own header note for why tail-position delegating calls are
-- a deliberate, permanent scope boundary, not a later stage).

||| The worker (if any) `n` -- an *original*, user-visible function
||| name -- was rewritten to call: `(workerName, argReps, retRep)`,
||| read directly off the wrapper's own body. `synthesizeWorker`'s own
||| construction guarantees a wrapper's *entire* body is always exactly
||| one bare `RAppNameRep` call into its own worker, nothing else (see
||| its own doc comment) -- so scanning for that exact shape recovers
||| the table without `applyDualABI` itself needing to thread a
||| separate one out alongside its own `List (Name, RCDef)` result.
workerTable : List (Name, RCDef) -> SortedMap Name (Name, List Rep, Rep)
workerTable defs = fromList (mapMaybe workerEntry defs)
  where
    workerEntry : (Name, RCDef) -> Maybe (Name, (Name, List Rep, Rep))
    workerEntry (n, MkRCFun _ _ (RAppNameRep _ workerName argReps retRep _ _)) =
        Just (n, (workerName, argReps, retRep))
    workerEntry _ = Nothing

||| `l`'s own currently-known `Rep` in `reps` (seeded from a function's
||| own top-level parameters, extended by every `RLet`/`RLoop` this
||| walk has already passed through by the time it asks) -- the same
||| lookup `Compiler.RC2.Emit`'s own (`Core`-monadic, `RepMap`-backed)
||| `repOfLocal` performs at emission time, just written as a pure
||| function here since this pass has no `Core` context of its own to
||| thread a ref through.
localRepIn : SortedMap Int Rep -> RCLocal -> Rep
localRepIn _ RCNull = RBoxed
localRepIn reps (RCLoc i) = fromMaybe RBoxed (lookup i reps)
localRepIn _ (RCConst c) = fromMaybe RBoxed (RNative <$> litRep c)
localRepIn _ (RCEmptyCon {}) = RBoxed

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
||| `tryEmitLoopContinue`/`peelDrop` (`Compiler.RC2.Emit`) already do,
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
ultimateTail (RReuseOffer _ _ _ cont) = ultimateTail cont
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
||| with `bareTailNativeReads` above, then asks the *exact* same
||| question `nativeArgType` itself asks about a whole function's own
||| top-level parameter, over that combined set: does `body`
||| (everything after this `RLet`) read `var` as a native-context
||| operand, consistently, at `ty`? Any *other*, still-Boxed-context use
||| of `var` elsewhere in `body` (e.g. stored into a constructor field)
||| keeps working correctly regardless of whether this promotes --
||| `rcVarToBoxedC`'s own on-demand reboxing of a native value handles
||| it, as a fresh allocation instead of sharing the one this call
||| *used* to produce, invisible to any Idris-level program (a scalar
||| has no observable identity) -- see `stripOwnership`'s own doc
||| comment for this exact case, already relied on by this same reuse.
nativePromotionFor : Int -> PrimType -> RCExp -> Maybe PrimType
nativePromotionFor var ty body =
    let found = nativeArgTypes var body `union` bareTailNativeReads var body
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
applyCallSiteRewriteBody : SortedMap Name (Name, List Rep, Rep) -> SortedMap Int Rep -> Bool -> RCExp -> RCExp
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
                                         RAppNameRep _ _ _ (RNative ty) _ _ => nativePromotionFor var ty body
                                         RAppNameRep _ _ _ (RInlineNative ty) _ _ => nativePromotionFor var ty body
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
    RConCase fc sc (map (rewriteConAlt workers reps inTail) alts) (map (applyCallSiteRewriteBody workers reps inTail) mDef)
  where
    rewriteConAlt : SortedMap Name (Name, List Rep, Rep) -> SortedMap Int Rep -> Bool -> RConAlt -> RConAlt
    rewriteConAlt workers reps inTail (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (applyCallSiteRewriteBody workers reps inTail body)
applyCallSiteRewriteBody workers reps inTail (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (rewriteConstAlt workers reps inTail) alts) (map (applyCallSiteRewriteBody workers reps inTail) mDef)
  where
    rewriteConstAlt : SortedMap Name (Name, List Rep, Rep) -> SortedMap Int Rep -> Bool -> RConstAlt -> RConstAlt
    rewriteConstAlt workers reps inTail (MkRConstAlt c body) = MkRConstAlt c (applyCallSiteRewriteBody workers reps inTail body)
applyCallSiteRewriteBody workers reps inTail (RLoop fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (applyCallSiteRewriteBody workers (foldl (\m, (i, r) => insert i r m) reps loopParams) inTail body)
applyCallSiteRewriteBody workers reps inTail (RDup fc v cont) = RDup fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RDrop fc vs cont) = RDrop fc vs (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RFree fc v cont) = RFree fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RReleaseReuse fc v cont) = RReleaseReuse fc v (applyCallSiteRewriteBody workers reps inTail cont)
applyCallSiteRewriteBody workers reps inTail (RReuseOffer fc sc dupOnShared cont) = RReuseOffer fc sc dupOnShared (applyCallSiteRewriteBody workers reps inTail cont)
-- The only case that ever actually rewrites a call: a bare RAppName
-- reached with inTail = False (never anyone's RLet-bound value, by
-- this point -- the RLet clause above already peeled through those --
-- so this is the ultimate tail of *some* value-computation chain, not
-- the whole function's own true tail position).
applyCallSiteRewriteBody workers reps False value@(RAppName fc _ n args) =
    case lookup n workers of
         Nothing => value
         Just (workerName, argReps, workerRetRep) =>
             if length args /= length argReps
                then value
                else RAppNameRep fc workerName argReps workerRetRep (postDropFor reps argReps args) args
-- Every other shape (including a bare RAppName reached with
-- inTail = True -- the whole function's own true tail position,
-- deliberately left alone, see this function's own doc comment):
-- RV, RAppNameRep, RUnderApp, RApp, RCon, RExtPrim, RPrimVal, RErased,
-- RCrash, RLoopContinue -- none hold a further RLet-bound-value
-- position of their own for this pass to inspect.
applyCallSiteRewriteBody _ _ _ e = e

||| Whole-program pass: Stage 4 itself. Every direct, saturated,
||| non-tail-position call anywhere in the program targeting a function
||| Stage 3a/3b gave a worker to gets redirected straight to that
||| worker, native arguments/return where the call site already has (or
||| can be promoted to have) them on hand -- see the module's own header
||| note and `applyCallSiteRewriteBody`'s own doc comment for the full
||| design. Runs after `applyDualABI` (needs its own worker table
||| already built); every definition (wrapper, worker, or untouched)
||| passes through the same rewrite uniformly -- nothing here needs to
||| know which of those three a given definition is, since a wrapper's
||| own trivial single-call body and an ordinary function's body are
||| rewritten by exactly the same logic. Each definition's own
||| top-level body starts `inTail = True` -- that's genuinely where the
||| function's own real tail position is.
export
applyCallSiteRewrite : List (Name, RCDef) -> List (Name, RCDef)
applyCallSiteRewrite defs =
    let workers = workerTable defs
    in map (rewriteDef workers) defs
  where
    rewriteDef : SortedMap Name (Name, List Rep, Rep) -> (Name, RCDef) -> (Name, RCDef)
    rewriteDef workers (n, MkRCFun args retRep body) =
        (n, MkRCFun args retRep (applyCallSiteRewriteBody workers (fromList args) True body))
    rewriteDef _ (n, d) = (n, d)
