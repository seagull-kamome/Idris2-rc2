||| Pipeline orchestration, in broad strokes (`toRCDefs` and
||| `compileExprWhole` have the exact order and the stages each
||| `--directive noXXX` turns off):
||| 1. On the case trees, before lifting: `Delay` CAFs (`LazyCaf`),
|||    inlining (`InlineCExp`), dead arguments (`DeadArgs`), world arity
|||    raising (`ArityRaiseCExp`)
||| 2. Lambda lifting + normalization into RCExp (`Compiler.RC2.RC`)
||| 3. Constant folding (`ConstFold`), case into tails (`PushCon`),
|||    closure/constant-constructor specialization (`SpecClosure`),
|||    early inline (`LateInline`)
||| 4. Nested comparison merge (`CmpMerge`), single-force lazy values
|||    (`LazyFold`), world arity raising again
|||    (`ArityRaise`), TRMC (`Trmc`), difference lists (`ClosureCtx`),
|||    CAF memoization (`insertMemoize`)
||| 5. RC annotation, constructor reuse, native shadow caching (`RC`,
|||    `Reuse`, `ConAltNative`)
||| 6. Loop/tail call conversion (`MutualLoop`, `Loop`)
||| 7. Late inline (`LateInline`), applied-closure folding (`ArityRaise`),
|||    post-RC case into tails (`PushCon`)
||| 8. Branch-local sinking (`Sink`), dual ABI, null parameters and struct
|||    return (`DualABI`, `NullParams`), reuse re-check (`Reuse`)
||| 9. Dead-code elimination (`DeadCode`), dup/drop push-down (`PushDown`),
|||    dup merging (`DupMerge`), leaf tail calls (`LeafTail`), dead variable
|||    erasure (`DeadVars`), function dedup (`FunDedup`, whole program only)
||| 10. C generation (`Emit`) and C compiler invocation (`CC`)
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.RC2

import Compiler.RC2.ArityRaise
import Compiler.RC2.ArityRaiseCExp
import Compiler.RC2.ClosureCtx
import Compiler.RC2.DeadArgs
import Compiler.RC2.Trmc
import Compiler.RC2.CC
import Compiler.RC2.CmpMerge
import Compiler.RC2.ConAltNative
import Compiler.RC2.ConstFold
import Compiler.RC2.DeadCode
import Compiler.RC2.DualABI
import Compiler.RC2.DeadVars
import Compiler.RC2.DupMerge
import Compiler.RC2.LeafTail
import Compiler.RC2.FunDedup
import Compiler.RC2.PushDown
import Compiler.RC2.Emit
import Compiler.RC2.Emit.Util
import Compiler.RC2.InlineCExp
import Compiler.RC2.Pretty
import Compiler.RC2.PushCon
import Compiler.RC2.RC
import Compiler.RC2.RCExp
import Compiler.RC2.Reuse
import Compiler.RC2.SpecClosure
import Compiler.RC2.LateInline
import Compiler.RC2.LazyCaf
import Compiler.RC2.LazyFold
import Compiler.RC2.MutualLoop
import Compiler.RC2.NullParams
import Compiler.RC2.CalleeTable
import Compiler.RC2.Loop
import Compiler.RC2.Sink
import Compiler.RC2.Types
import Compiler.RC2.Util

import Compiler.Common

import Core.CompileExpr
import Core.Directory
import Core.Env
import Core.Value

import Data.DPair
import Data.SortedMap
import Data.SortedSet
import Data.String as String

import Idris.Syntax

import System
import System.File

import Libraries.Utils.Path

%default covering

||| The locals `Types.typedConstScrutinees` finds, when the field rule
||| (`--directive noboolfield`) is on: `Reuse` and `ConAltNative` then leave a
||| constructor field in that set out of their own dup/drop/offer lists.
immOf : Bool -> RCExp -> SortedSet RCLocal
immOf on body = if on then typedConstScrutinees body else empty

||| Compiler.RC2.Reuse's pass runs after Compiler.RC2.RC's normalize+
||| annotate are both fully done (it relies on `annotate`'s own RDrop
||| lists -- see its own module note), on each definition's body
||| independently -- reuse offers never cross a function boundary.
applyReuse : (nested : Bool) -> (fieldCase : Bool) -> RCDef -> RCDef
applyReuse nested fc (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (resolveReuse nested (immOf fc body) body)
applyReuse nested fc (MkRCError body) = MkRCError (resolveReuse nested (immOf fc body) body)
applyReuse _ _ d@(MkRCCon _ _ _) = d
applyReuse _ _ d@(MkRCForeign _ _ _) = d

||| Iteration cap for `foldConstProgram`'s fixpoint loop. Hitting it only
||| leaves some CAFs un-inlined (a missed optimisation), never an incorrect
||| fold. Why 8 and not 4: rc2/doc/const-caf-fold.md, "CAF boundary crossing".
maxConstFoldIterations : Nat
maxConstFoldIterations = 8

||| Nanosecond threshold for `toRCDefs`'s own per-definition
||| `logTimeOver` diagnostic around `Compiler.RC2.Loop.applyLoop` (500ms)
||| -- see that call site's own comment.
slowApplyLoopThresholdNs : Integer
slowApplyLoopThresholdNs = 500000000

||| TEMP DIAGNOSTIC: a rough structural node count, purely for the
||| `slowApplyLoopThresholdNs` message below -- not calibrated against
||| anything, just enough to tell "how big is this body, and how many
||| top-level parameters does it have" apart for whichever definitions
||| `logTimeOver` flags.
rcSizeOf : RCExp -> Nat
rcSizeConAlt : RConAlt -> Nat
rcSizeConstAlt : RConstAlt -> Nat

rcSizeOf (RV _ _) = 1
rcSizeOf (RAppName _ _ _ _) = 1
rcSizeOf (RAppNameRep _ _ _ _ _ _) = 1
rcSizeOf (RAppFFIInline _ _ _ _ _ _) = 1
rcSizeOf (RUnderApp _ _ _ _) = 1
rcSizeOf (RApp _ _ _ _) = 1
rcSizeOf (RLet _ _ _ value body) = 1 + rcSizeOf value + rcSizeOf body
rcSizeOf (RCon _ _ _ _ _ _) = 1
rcSizeOf (RRetPack _ _ _ _) = 1
rcSizeOf (ROp _ _ _ _ _) = 1
rcSizeOf (RExtPrim _ _ _ _ _) = 1
rcSizeOf (RStructGet _ _ _ _) = 1
rcSizeOf (RStructSet _ _ _ _ _) = 1
rcSizeOf (RFill _ _ _ _ _) = 1
rcSizeOf (RCmpCase _ _ _ _ t f) = 1 + rcSizeOf t + rcSizeOf f
rcSizeOf (RConCase _ _ alts mDef) = 1 + sum (map rcSizeConAlt alts) + maybe 0 rcSizeOf mDef
rcSizeOf (RConstCase _ _ alts mDef) = 1 + sum (map rcSizeConstAlt alts) + maybe 0 rcSizeOf mDef
rcSizeOf (RPrimVal _ _) = 1
rcSizeOf (RErased _) = 1
rcSizeOf (RCrash _ _) = 1
rcSizeOf (RDup _ _ _ cont) = 1 + rcSizeOf cont
rcSizeOf (RDrop _ _ cont) = 1 + rcSizeOf cont
rcSizeOf (RFree _ _ cont) = 1 + rcSizeOf cont
rcSizeOf (RReleaseReuse _ _ cont) = 1 + rcSizeOf cont
rcSizeOf (RLoop _ _ _ _ body) = 1 + rcSizeOf body
rcSizeOf (RLoopContinue _ _ _) = 1
rcSizeOf (RReuseOffer _ _ _ _ cont) = 1 + rcSizeOf cont
rcSizeOf (RMemoize _ _ _ body) = 1 + rcSizeOf body
rcSizeOf (RDelay _ _ _ _) = 1
rcSizeOf (RForce _ _ _ _) = 1

rcSizeConAlt (MkRConAlt _ _ _ _ body) = rcSizeOf body
rcSizeConstAlt (MkRConstAlt _ body) = rcSizeOf body

||| Runs `Compiler.RC2.ConstFold.foldConstDef` over every definition in
||| `defs0` (Phase 1 output from `Compiler.RC2.RC.normalizeProgram`),
||| rebuilding `CafTable` after each pass and looping while its key count
||| still grows, up to `maxConstFoldIterations`; see
||| rc2/doc/const-caf-fold.md. Each round is `logTime`d at level 3 as
||| `round n/m` (`n` reaching `m` means the cap bound it). Per-round times
||| are only indicative (laziness; cf. `Compiler.RC2.LateInline.applyLateInline`),
||| the round count is exact.
|||
||| `knownCons`: `False` under `--directive noknowncon`, turning off
||| `ConstFold`'s known-constructor fold here (the clones
||| `Compiler.RC2.SpecClosure` folds itself keep it).
foldConstProgram : {auto c : Ref Ctxt Defs} -> (knownCons : Bool) -> List (Name, RCDef) -> Core (List (Name, RCDef))
foldConstProgram knownCons defs0 = go 1 maxConstFoldIterations empty 0 defs0
  where
    -- Threads the table's own key count alongside it instead of
    -- re-deriving it via `length (SortedMap.toList table)` (O(n log n))
    -- on every one of up to `maxConstFoldIterations` rounds -- a key
    -- only ever contributes to this count the first time it's seen,
    -- since re-inserting an already-present key overwrites its value
    -- without growing the table.
    rebuildTable : List (Name, RCDef) -> (CafTable, Nat)
    rebuildTable = foldl step (empty, 0)
      where
        step : (CafTable, Nat) -> (Name, RCDef) -> (CafTable, Nat)
        step (tbl, cnt) (n, d) =
            case cafValueOf d of
                 Nothing => (tbl, cnt)
                 Just v => case lookup n tbl of
                                Just _  => (insert n v tbl, cnt)
                                Nothing => (insert n v tbl, cnt + 1)

    go : Nat -> Nat -> CafTable -> Nat -> List (Name, RCDef) -> Core (List (Name, RCDef))
    go _ Z _ _ defs = pure defs
    go round (S fuel) table count defs = do
        (folded, table', count') <-
            logTime 3 "rc2: ConstFold (round \{show round}/\{show maxConstFoldIterations}, \{show count} CAFs in)" $
              -- Only round 1 folds known constructors: later rounds
              -- differ only by CAF substitution, which seldom leaves a
              -- constructor newly non-escaping -- not worth a use walk
              -- per round (rc2/doc/constructor-escape-analysis.md).
              -- `pure $ let ...`, not `let` statements in a `do`: those run
              -- before `logTime` starts its clock (code-style-Idris2.md).
              pure $ let folded = map (\(n, d) => (n, foldConstDef (knownCons && round == 1) table d)) defs
                         (table', count') = rebuildTable folded
                     in (folded, table', count')
        if count' == count
           then pure folded
           else go (S round) fuel table' count' folded

||| Wraps every remaining non-constant top-level 0-argument
||| definition's own body in `RMemoize` (`doc/caf-memoization.md`) --
||| run once, right after `foldConstProgram` above has already reduced
||| every CAF `ConstFold` can prove constant down to a bare reference.
||| Reuses `cafValueOf` unchanged (exactly the same "is this already a
||| bare reference to a compile-time constant" question ConstFold's own
||| whole-program fixpoint asks) to decide which CAFs to skip -- nothing
||| to guard for one of those; runtime-side memoization is only for
||| whatever's left, either a real effect or a computation `ConstFold`'s
||| own analysis couldn't fully resolve.
insertMemoize : (thunks : SortedSet Name) -> List (Name, RCDef) -> List (Name, RCDef)
insertMemoize thunks = map wrap
  where
    wrapCaf : (Name, RCDef) -> (Name, RCDef)
    wrapCaf (n, d@(MkRCFun [] retRep isWorker body)) =
        case cafValueOf d of
             Just _  => (n, d)
             Nothing => (n, MkRCFun [] retRep isWorker (RMemoize EmptyFC n retRep body))
    wrapCaf nd = nd

    wrap : (Name, RCDef) -> (Name, RCDef)
    -- A `Delay`'s thunk with no captures is 0-ary too, but its lazy cell
    -- already memoizes it, per cell and freed with the cell; a CAF would
    -- keep the value for the whole run (doc/lazy-memoization.md).
    wrap nd@(n, _) = if contains n thunks then nd else wrapCaf nd


isDelay : LiftOrigin -> Bool
isDelay (FromDelay _) = True
isDelay FromLambda = False

||| Arity raising before lifting (doc/world-arity-raising.md).
raiseNamed : {auto c : Ref Ctxt Defs} -> List String -> Maybe NamedCExp -> List (Name, FC, NamedDef) -> Core (Maybe NamedCExp, List (Name, FC, NamedDef))
raiseNamed disabled main defs =
    if "noarityraise" `elem` disabled then pure (main, defs)
    else logTime 2 "rc2: Arity raise" $ applyArityRaiseCExp main defs

||| rc2's inlining (`noinline` turns it off with the case-of-case
||| collapse), before lifting.
inlineNamed : {auto c : Ref Ctxt Defs} -> List String -> Maybe (SortedSet Name) -> Maybe NamedCExp -> List (Name, FC, NamedDef) -> Core (Maybe NamedCExp, List (Name, FC, NamedDef))
inlineNamed disabled keep main defs =
    if "noinline" `elem` disabled then pure (main, defs)
    else logTime 2 "rc2: Inline (before lifting)" $ inlineCExp keep main defs

||| The stage names `--directive noXXX`/`%cg rc2 noXXX` can disable
||| (`rc2/doc/directives.md`) -- factored out so whole-program
||| `compileExprWhole` and per-module `incCompile`
||| (rc2/doc/incremental-compile.md) derive their own `disabled` list
||| from the very same set instead of two literals that could drift
||| apart.
disableableStageNames : List String
disableableStageNames =
    ["noinline", "nodeadargs", "noarityraise", "noapplyfold", "notrmc", "noctx", "noconstfold", "noknowncon", "nopushcon", "nospecclosure", "nospecconstcon", "noconaltnative", "nomutualloop", "noloop", "noearlyinline", "nolateinline", "nosink", "nocmpmerge", "nodualabi", "noboolret", "noboolcase", "noboolfield", "nonullparams", "nostructreturn", "nomutualstruct", "nodeadcode", "nopushdown", "nodupmerge", "nodeadvars", "noleaftail", "nofundedup", "noreusenested", "noreuserecheck"]

||| Stages that are off unless asked for with `--directive <name>`. They
||| travel to `toRCDefs` in the same list as the disables above.
optInStageNames : List String
optInStageNames = ["latepushcon"]

||| Every directive `toRCDefs` consults: the disables and the opt-ins.
stageDirectiveNames : List String
stageDirectiveNames = disableableStageNames ++ optInStageNames

||| Optional pipeline-stage disabling via `--directive no<stagename>`,
||| for A/B regression isolation without editing `toRCDefs` itself and
||| rebuilding `idris2-rc2`. See `rc2/doc/directives.md` for the full
||| stage list, why `noreuse` isn't (and can't safely be) among them,
||| and why `nomain` is a real directive but not a stage disable.
|||
||| `roots`: names `Compiler.RC2.DeadCode.pruneDeadDefs` must never drop
||| regardless of reachability -- `main`'s own well-known entry name
||| (`MN "__mainExpression" 0`, `Compiler.Common`) plus the `%export`ed
||| names (rc2/doc/export-support.md), both supplied by `compileExpr`'s
||| own call site. An incremental compile (`incCompile`) passes `[]`.
|||
||| `incremental`: the module is compiled on its own (rc2/doc/incremental-
||| compile.md), seeing only its own definitions, so the whole-program
||| `FunDedup` is skipped. (The one definition kind that cannot be
||| compiled on its own, a `getField`/`setField` whose struct and field
||| names are not literals, is dropped earlier, by `normalizeProgram`.)
toRCDefs : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> List String -> (incremental : Bool) -> (roots : List Name)
        -> (thunks : SortedSet Name) -> List (Name, RCDef) -> Core (List (Name, RCDef))
toRCDefs directives incremental roots thunks preFolded = do
    folded <- if "noconstfold" `elem` directives
                 then pure preFolded
                 else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ foldConstProgram (not ("noknowncon" `elem` directives)) preFolded
    -- doc/constructor-escape-analysis.md's "Rewrite B": after ConstFold,
    -- whose known-constructor fold it relies on to finish each push, and
    -- before the specialization passes, so their clones start pushed.
    pushed <- if ("nopushcon" `elem` directives) || ("noconstfold" `elem` directives)
                 then pure folded
                 else logTime 2 "rc2: Push case into tails" $ applyPushCon folded
    -- doc/speculative-closure-specialization.md: strictly after
    -- ConstFold (so RUnderApp targets it already resolved are visible)
    -- and strictly before insertMemoize/Phase 2 below -- a kept clone
    -- is just one more plain MkRCFun by the time either of those see
    -- it, needing no special-casing of its own from either.
    -- doc/constant-constructor-specialization.md: the same pipeline
    -- position and the same three steps as the closure case above, for
    -- the argument shape it cannot see -- a dictionary that gets
    -- destructured rather than applied. It consumes the pass above's
    -- own clones (a clone is an ordinary MkRCFun by now) and its own
    -- clones are likewise ordinary by the time insertMemoize/Phase 2
    -- see them.
    dictSpecialized <- if ("nospecclosure" `elem` directives) && ("nospecconstcon" `elem` directives)
                          then pure pushed
                          else logTime 2 "rc2: Speculative specialization (closure + constant-constructor rounds)" $
                                 applySpecRounds (not ("nospecclosure" `elem` directives)) (not ("nospecconstcon" `elem` directives)) pushed
    -- doc/constructor-escape-analysis.md's "The shapes `LateInline`
    -- creates": LateInline's single-caller splicing, run once already
    -- here, before RC annotation, so ConstFold's folds and PushCon see
    -- what it exposes. No callee in a call cycle (it may still need Loop
    -- conversion) and no CAF (not memoized yet) qualifies this early. The splices are refolded and re-pushed here;
    -- the later LateInline stage handles whatever is left.
    earlyInlined <- if ("noearlyinline" `elem` directives) || ("nolateinline" `elem` directives) || ("noconstfold" `elem` directives)
                       then pure dictSpecialized
                       else logTime 2 "rc2: Early inline" $ do
                              spliced <- applyLateInline "Early inline" True roots dictSpecialized
                              refolded <- logTime 3 "rc2: Early inline (refold)" $ pure $ map (\(n, d) => (n, foldConstDef True empty d)) spliced
                              if "nopushcon" `elem` directives then pure refolded else logTime 3 "rc2: Early inline (PushCon)" $ applyPushCon refolded
    -- doc/caf-memoization.md: right after ConstFold (and the
    -- specialization pass above, whose own clones are never 0-arg CAFs
    -- regardless) and strictly before Phase 2 (toRCDefPostFold's own
    -- annotateDef needs to see RMemoize already in place -- see RC.idr's
    -- own `annotate` case for it).
    -- Once more: the passes since expose sites the first run could not
    -- see (an inlined `bind`, say), and a function raised then is a
    -- bare wrapper, whose sites call its raised version directly.
    -- A local lazy value forced once becomes a call, once inlining has
    -- brought delays and forces together (doc/lazy-memoization.md).
    cmpMerged <- if "nocmpmerge" `elem` directives
                    then pure earlyInlined
                    else logTime 2 "rc2: Merge nested comparisons" $ pure $ map (\(n, d) => (n, mergeCmpDef d)) earlyInlined
    lazyFolded <- logTime 2 "rc2: Lazy fold" $ pure $ map (\(n, d) => (n, foldSingleForceDef d)) cmpMerged
    reraised <- if "noarityraise" `elem` directives
                   then pure lazyFolded
                   else logTime 2 "rc2: Arity raise (after early inline)" $ applyArityRaise lazyFolded
    trmced <- if "notrmc" `elem` directives
                 then pure reraised
                 else logTime 2 "rc2: TRMC" $ applyTrmc reraised
    ctxed <- if "noctx" `elem` directives
                then pure trmced
                else logTime 2 "rc2: Closure contexts" $ applyClosureCtx trmced
    memoized <- logTime 2 "rc2: CAF memoization" $ pure (insertMemoize thunks ctxed)
    reused <- logTime 2 "rc2: RC annotate + Reuse + ConAltNative" $
                traverse (\(n, d) => do
                  d1 <- toRCDefPostFold (not ("noboolcase" `elem` directives)) d
                  let fieldCase = not ("noboolcase" `elem` directives) && not ("noboolfield" `elem` directives)
                  let d2 = applyReuse (not ("noreusenested" `elem` directives)) fieldCase d1
                  d3 <- if "noconaltnative" `elem` directives then pure d2 else applyConAltNative fieldCase d2
                  pure (n, d3)) memoized
    (merged, noPromotes) <- if "nomutualloop" `elem` directives then pure (reused, SortedMap.empty) else logTime 2 "rc2: Mutual loop" $ applyMutualLoop reused
    looped <- if "noloop" `elem` directives
                 then pure merged
                 else logTime 2 "rc2: Loop conversion" $ do
                        calleeTable <- logTime 3 "rc2: Loop conversion (build callee table)" $ pure (buildCalleeTable merged)
                        -- `logTimeOver` (unconditional, not gated behind
                        -- `--timing`) rather than one `logTime` call per
                        -- definition -- this stage's own cost turned out
                        -- to concentrate in a handful of pathologically
                        -- large individual bodies rather than being
                        -- spread evenly (see `rc2/doc/loop-conversion.md`'s
                        -- "Bugs found and fixed" #7), so a per-definition
                        -- threshold naming *which* one is slow is more
                        -- useful here than one more aggregate number.
                        logTime 3 "rc2: Loop conversion (apply)" $
                          traverse (\(n, d) =>
                                      let stats = case d of
                                                       MkRCFun args _ _ dbody =>
                                                           " (P=" ++ show (length args) ++ " B=" ++ show (rcSizeOf dbody) ++ ")"
                                                       _ => ""
                                      in logTimeOver slowApplyLoopThresholdNs
                                           (pure ("rc2: Loop conversion (apply) slow definition: " ++ show n ++ stats))
                                           (do d' <- applyLoop calleeTable (fromMaybe SortedSet.empty (lookup n noPromotes)) n d; pure (n, d'))) merged
    -- rc2/doc/inlining.md's "Criterion B, revisited": strictly after
    -- Loop/MutualLoop conversion, so a self- or mutually-tail-recursive
    -- candidate's own recursion has already collapsed into RLoop/
    -- RLoopContinue -- not a further RAppName call this pass would
    -- otherwise have to refuse to inline. Strictly before DualABI, so
    -- this pass only ever sees a callee's own original (always RBoxed)
    -- top-level params, never a dual-ABI worker/wrapper split.
    inlined <- if "nolateinline" `elem` directives
                  then pure looped
                  else logTime 2 "rc2: Late inline" $ applyLateInline "Late inline" False roots looped
    -- doc/world-arity-raising.md's "Post-RC fold": a closure LateInline
    -- left built and applied at once becomes a call.
    applyFolded <- if "noapplyfold" `elem` directives
                      then pure inlined
                      else logTime 2 "rc2: Fold applied closures" $ pure (applyFoldApplied inlined)
    -- doc/constructor-escape-analysis.md's "What is left after Early
    -- inline, and the RC-aware fold": PushCon's push again, for what
    -- LateInline has created, with each known tail folded by hand
    -- as ownership is explicit. Before Sink and DualABI, so both
    -- still see the result.
    -- Off by default (`--directive latepushcon` turns it on): on
    -- idris2-lsp it folds 243 tails yet leaves the static constructor
    -- count unchanged (constructor-escape-analysis.md).
    latePushed <- if not ("latepushcon" `elem` directives) || ("nopushcon" `elem` directives)
                     then pure applyFolded
                     else logTime 2 "rc2: Push case into tails (post-RC)" $ applyPushConRC applyFolded
    sunk <- if "nosink" `elem` directives
               then pure latePushed
               else logTime 2 "rc2: Sink" $ pure (map (\(n, d) => (n, applySink d)) latePushed)
    dualABId <- if "nodualabi" `elem` directives
       then pure sunk
       else logTime 2 "rc2: DualABI" $ do
           let nullParams := if "nonullparams" `elem` directives then SortedMap.empty else nullParamTable roots sunk
           withNative <- logTime 3 "rc2: DualABI (workers)" $ applyDualABI (not ("noboolret" `elem` directives)) nullParams sunk
           -- doc/struct-return.md
           withWorkers <- if "nostructreturn" `elem` directives
                             then pure withNative
                             else logTime 3 "rc2: DualABI (struct return)" $ applyStructReturn (not ("nomutualstruct" `elem` directives)) withNative
           (ffiWorkers, ffiInlineMap) <- logTime 3 "rc2: DualABI (FFI worker table)" $ ffiWorkerTable sunk
           rewritten0 <- logTime 3 "rc2: DualABI (call-site rewrite)" $ pure $ applyCallSiteRewrite (not ("noboolcase" `elem` directives)) ffiWorkers withWorkers
           -- doc/dual-abi.md, "Bool return"
           rewritten <- if "noboolret" `elem` directives
                           then pure rewritten0
                           else logTime 3 "rc2: DualABI (Bool return tail calls)" $ pure $ applyBoolReturnTails rewritten0
           logTime 3 "rc2: DualABI (FFI inline)" $ pure $ inlineFFIWorkers ffiInlineMap rewritten
    -- doc/reuse-analysis.md, "Re-checking dead offers after DualABI": before
    -- Dead code, PushDown, DupMerge and DeadVars, which then still see the result.
    rechecked <- if "noreuserecheck" `elem` directives
                    then pure dualABId
                    else logTime 2 "rc2: Reuse re-check" $
                           pure (map (\(n, d) => (n, recheckReuseDef (not ("noreusenested" `elem` directives)) d)) dualABId)
    pruned <- if "nodeadcode" `elem` directives
                 then pure rechecked
                 else logTime 2 "rc2: Dead code elimination" $ pure (pruneDeadDefs roots rechecked)
    -- rc2/doc/pushdown.md: a dup/drop run in front of a case moves into the arms.
    pushedDown <- if "nopushdown" `elem` directives
                     then pure pruned
                     else logTime 2 "rc2: Dup/drop push-down" $ pure (map (\(n, d) => (n, applyPushDown d)) pruned)
    dupMerged <- if "nodupmerge" `elem` directives
                    then pure pushedDown
                    else logTime 2 "rc2: Dup merge" $ pure (map (\(n, d) => (n, applyDupMerge d)) pushedDown)
    -- rc2/doc/leaf-tail-calls.md: before Dead variable erasure, which reserves id 0.
    leafTailed <- if "noleaftail" `elem` directives
                     then pure dupMerged
                     else logTime 2 "rc2: Leaf tail calls" $ applyLeafTail dupMerged
    erased <- if "nodeadvars" `elem` directives
                 then pure leafTailed
                 else logTime 2 "rc2: Dead variable erasure" $ pure (map (\(n, d) => (n, applyDeadVars d)) leafTailed)
    -- Erasing a dead `RLet` can leave a `dup` and a `drop` of the same
    -- local adjacent that weren't when Dup merge ran, so its own
    -- cancellation peephole gets one more sweep here -- no re-merge,
    -- and gated by the same directive.
    cancelled <- if "nodupmerge" `elem` directives
                    then pure erased
                    else logTime 2 "rc2: Dup/drop cancel (post dead-vars)" $
                           pure (map (\(n, d) => (n, applyCancelDupDrop d)) erased)
    -- rc2/doc/fun-dedup.md: functions with equal bodies become one. Not in
    -- incremental mode, where a module only sees its own definitions.
    if ("nofundedup" `elem` directives) || incremental
       then pure cancelled
       else logTime 2 "rc2: Function dedup" $ pure (dedupFuns roots cancelled)

||| `%cg rc2 inlineRuntime=<code>` companion to upstream's own
||| file-path-based `Compiler.Common.getExtraRuntime` -- splices the
||| value as literal C text directly instead of reading it from a file.
||| MUST stay on one line and MUST NOT end with a literal `}` -- see
||| `rc2/doc/directives.md` for why (both landmines are inherent to
||| Idris2's own `%cg` lexer/parser, not this function).
getInlineRuntime : List String -> String
getInlineRuntime directives = concat $ intersperse "\n" $ nub $ mapMaybe getArg $ reverse directives
  where
    getArg : String -> Maybe String
    getArg directive =
      let (k, v) = String.break (== '=') directive
      in if trim k == "inlineRuntime"
            then Just $ trim $ substr 1 (length v) v
            else Nothing

||| `%cg rc2 externStruct=<name>`, repeatable -- names of `Struct`
||| types `Emit.idr`'s `header` must not emit its own `typedef struct`
||| for, because `name` is already `typedef`'d by some included system/
||| library header instead. See `rc2/doc/directives.md` for the design
||| (in particular why the Idris-side field list stays purely nominal
||| for a name in this set) and `rc2/doc/c-struct-support.md`.
getExternStructs : List String -> SortedSet String
getExternStructs directives = SortedSet.fromList $ mapMaybe getArg directives
  where
    getArg : String -> Maybe String
    getArg directive =
      let (k, v) = String.break (== '=') directive
      in if trim k == "externStruct"
            then Just $ trim $ substr 1 (length v) v
            else Nothing

||| Names of top-level definitions whose upstream CExp body is exactly
||| `Delay e` (`MkNmFun [] (NmDelay _ _ _)`) -- the same shape
||| `Compiler.Scheme.Common`'s own `schDef` special-cases for a
||| memoized top-level lazy definition on the Chez backend (see
||| doc/lazy-memoization.md). rc2 memoizes such a definition too, once
||| `Compiler.RC2.LazyCaf` takes its `Delay` off (`RMemoize`); the
||| detection here only marks it in the dump, and is free: `CompileData.namedDefs` is populated unconditionally
||| by `getCompileDataWith` regardless of the requested `UsePhase`, so
||| no extra compilation pass is needed to build this set purely for
||| `dumprcexpr`'s own benefit (`Compiler.RC2.Pretty.prettyDef`'s
||| `lazyCAFs` parameter).
collectLazyCAFs : List (Name, FC, NamedDef) -> SortedSet Name
collectLazyCAFs = SortedSet.fromList . mapMaybe isLazyCAF
  where
    isLazyCAF : (Name, FC, NamedDef) -> Maybe Name
    isLazyCAF (n, _, MkNmFun [] (NmDelay _ _ _)) = Just n
    isLazyCAF _ = Nothing

||| Recognizes every CFType %export's own scope supports -- scalars,
||| Ptr/AnyPtr, GCPtr/GCAnyPtr (argument-position only; validateExport
||| itself rejects a GCPtr return, see its own doc comment), Integer,
||| String, and any Struct (by pointer, same marshalling as Ptr --
||| Emit/Util.idr's own cTypeOfCFType/extractValue/packCFType CFStruct cases
||| already alias CFPtr's verbatim) -- plus the PrimIO IO/IORes wrapper
||| (peeled to CFIORes so Compiler.RC2.Util's own peelIORes applies
||| uniformly afterward). Still nothing for Buffer/ForeignObj/CFUser/
||| CFFun -- deliberately out of %export's own scope (Buffer is a
||| known, separately-tracked gap; ForeignObj/CFUser/CFFun have no
||| %export-side marshalling story at all). Unlike %foreign's own
||| Compiler.CompileExpr.nfToCFType/getCFTypes (not reused here, since
||| those also accept CFFun/CFUser/CFBuffer/CFForeignObj), Ptr/GCPtr/
||| Struct are recognized by bare type-constructor name only (ignoring
||| namespace), mirroring upstream's own `getNArgs` precedent
||| (Compiler.CompileExpr) rather than requiring a specific namespace
||| the way the PrimIO IO/IORes case below still does.
exportNfToCFType : {auto c : Ref Ctxt Defs} -> Defs -> NF [] -> Core (Maybe CFType)
exportNfToCFType defs (NPrimVal _ (PrT ty)) = pure $ case ty of
    IntType => Just CFInt;  Int8Type => Just CFInt8;  Int16Type => Just CFInt16
    Int32Type => Just CFInt32; Int64Type => Just CFInt64
    Bits8Type => Just CFUnsigned8; Bits16Type => Just CFUnsigned16
    Bits32Type => Just CFUnsigned32; Bits64Type => Just CFUnsigned64
    DoubleType => Just CFDouble; CharType => Just CFChar
    IntegerType => Just CFInteger; StringType => Just CFString
    WorldType => Just CFWorld
-- `NS (mkNamespace "PrimIO") (UN (Basic "IO"))` confirmed empirically
-- (a temporary `coreLift $ putStrLn "DEBUG NTCon: \{show fn}"` here,
-- compiling a probe `%export`ed `IO Int`-returning function and
-- observing "DEBUG NTCon: PrimIO.IO") rather than trusted from source
-- reading alone -- `IO`/`IORes` are both genuine `data` types
-- (`libs/prelude/PrimIO.idr`), so their `NTCon` name is exactly their
-- own declaration site's full name, no further unmangling needed.
exportNfToCFType defs (NTCon _ n _ args) = do
    fn <- toFullNames n
    case fn of
         NS ns (UN (Basic nm)) => case (nm, map snd args) of
             ("IO", [arg]) =>
                 if ns == mkNamespace "PrimIO"
                    then map CFIORes <$> (exportNfToCFType defs !(evalClosure defs arg))
                    else pure Nothing
             ("IORes", [arg]) =>
                 if ns == mkNamespace "PrimIO"
                    then map CFIORes <$> (exportNfToCFType defs !(evalClosure defs arg))
                    else pure Nothing
             ("Ptr", [_])     => pure $ Just CFPtr
             ("AnyPtr", [])   => pure $ Just CFPtr
             ("GCPtr", [_])   => pure $ Just CFGCPtr
             ("GCAnyPtr", []) => pure $ Just CFGCPtr
             -- Field list (the Struct type's own second argument)
             -- deliberately unread -- CFStruct's fields are only ever
             -- consulted for generating a C typedef ahead of a
             -- getField/setField site (Emit/Util.idr's collectStructDefs,
             -- populated solely from %foreign defs), never for
             -- %export's own marshalling (cTypeOfCFType/extractValue/
             -- packCFType's CFStruct cases already ignore them,
             -- aliasing CFPtr verbatim) -- so an empty field list here
             -- is not a shortcut, it's the whole story.
             ("Struct", [nArg, _]) => do
                 NPrimVal _ (Str sname) <- evalClosure defs nArg
                     | _ => pure Nothing
                 pure $ Just (CFStruct sname [])
             _ => pure Nothing
         _ => pure Nothing
exportNfToCFType _ _ = pure Nothing

||| Peels every leading `Pi` off a normalized closed type, `Nothing` at
||| each position `exportNfToCFType` doesn't recognize -- mirrors
||| upstream's own `Compiler.CompileExpr.getCFTypes`, narrowed to
||| %export's own scalar-only vocabulary.
exportCFSignature : {auto c : Ref Ctxt Defs} -> NF [] -> Core (List (Maybe CFType), Maybe CFType)
exportCFSignature (NBind fc _ (Pi _ _ _ ty) sc) = do
    defs <- get Ctxt
    aty <- exportNfToCFType defs !(evalClosure defs ty)
    sc' <- sc defs (toClosure defaultOpts Env.empty (Erased fc Placeholder))
    (rest, ret) <- exportCFSignature sc'
    pure (aty :: rest, ret)
exportCFSignature t = do
    defs <- get Ctxt
    pure ([], !(exportNfToCFType defs t))

isCFWorld : CFType -> Bool
isCFWorld CFWorld = True
isCFWorld _ = False

||| %export's own allowlist -- distinct from `Compiler.RC2.Types`'s
||| `cfTypeNative` (a much narrower, purely-scalar predicate several
||| other codegen stages share for native/boxed Rep selection, and not
||| widened here to avoid changing any of their behaviour): Ptr, GCPtr,
||| Integer, String, and any Struct all have a real, already-working
||| %export marshalling path (`Emit/Util.idr`'s `packCFType`/`extractValue`)
||| that has nothing to do with Rep selection.
isExportableCFType : CFType -> Bool
isExportableCFType CFPtr          = True
isExportableCFType CFGCPtr        = True
isExportableCFType CFInteger      = True
isExportableCFType CFString       = True
isExportableCFType (CFStruct _ _) = True
isExportableCFType ty = case cfTypeNative ty of
    Just _  => True
    Nothing => False

exportSupportedTypesDesc : String
exportSupportedTypesDesc =
    "scalar (Int/Int8/Int16/Int32/Int64/Bits8/Bits16/Bits32/Bits64/Double/Char), Ptr, GCPtr, Integer, String, or struct (Struct)"

||| Phase 1 (lambda lifting and normalisation, `Compiler.RC2.RC`) and
||| every later stage, under one `VarId` counter for the whole compile
||| (`Compiler.RC2.Util`'s `VarId`; it starts at 1 because
||| `Compiler.RC2.DeadVars` reserves 0), with the struct table the
||| program's `%foreign` signatures declare.
lowerProgram : {auto c : Ref Ctxt Defs} -> List String -> (incremental : Bool) -> (roots : List Name) ->
               Maybe NamedCExp -> List (Name, FC, NamedDef) -> Core (List (Name, RCDef), SortedMap Name LiftInfo)
lowerProgram disabled incremental roots main defs = do
    _ <- newRef VarId 1
    structs <- logTime 3 "rc2: struct table" $ pure $
           foldl (\acc, (_, _, d) => case d of
                                        MkNmForeign _ fargs ret => foldl (flip collectStructDefs) (collectStructDefs ret acc) fargs
                                        _ => acc)
                 SortedMap.empty defs
    _ <- newRef StructTable structs
    (preFolded, infos) <- logTime 2 "rc2: Lambda lift + RC normalize" $ normalizeProgram incremental main defs
    -- `Delay` thunks, which their lazy cells memoize (`insertMemoize`).
    let thunks = SortedSet.fromList [n | (n, i) <- SortedMap.toList infos, isDelay i.origin]
    rc <- toRCDefs disabled incremental roots thunks preFolded
    pure (rc, infos)

||| Validates one %export'ed name against its own real elaborated
||| type, deriving the native CFType signature the wrapper needs.
||| Throws a clear, attributable GenericMsg for any unsupported shape
||| (an argument/return type outside `isExportableCFType`'s own
||| allowlist, a GCPtr return specifically, arity mismatch from an
||| implicit/auto-implicit argument) -- same philosophy as the CFFun-
||| %foreign-return-type fix (`checkForeignReturn`, Compiler.RC2.RC):
||| fail immediately and attributably at the one point that still has
||| the declaration's own Name, not via a downstream mystery.
|||
||| `exported cdata`'s own Name is `Resolved` (Compiler.Common's
||| `getExports` calls `resolved`, not `toFullNames`), while
||| the definitions' keys are already full names -- `getFullName`
||| bridges the two so the `SortedMap Name NamedDef` lookup below
||| actually finds the def instead of silently missing it.
validateExport : {auto c : Ref Ctxt Defs} -> SortedMap Name NamedDef -> (Name, String) -> Core (Name, String, List CFType, CFType)
validateExport byName (n, exportedName) = do
    defs <- get Ctxt
    n' <- getFullName n
    Just ty <- lookupTyExact n (gamma defs)
        | Nothing => throw $ InternalError "[rc2] %export \{exportedName}: no type for \{show n'}"
    (argsRaw, retRaw) <- exportCFSignature !(nf defs [] ty)
    let badPositions = mapMaybe (\(i, mt) => if isNothing mt then Just i else Nothing) (zip [0 .. length argsRaw] argsRaw)
    when (not (isNil badPositions)) $
        throw $ GenericMsg EmptyFC
            "[rc2] %export declaration \{exportedName} (\{show n'})'s own argument(s) \{show badPositions} own type isn't a type %export supports -- %export supports \{exportSupportedTypesDesc} arguments"
    ret <- case retRaw of
        Just r => pure r
        Nothing => throw $ GenericMsg EmptyFC
            "[rc2] %export declaration \{exportedName} (\{show n'})'s own return type isn't a type %export supports -- %export supports \{exportSupportedTypesDesc} (or IO-wrapped, or IO ()) return types"
    let args = mapMaybe id argsRaw
    let realArgs = filter (not . isCFWorld) args
    let retPeeled = peelIORes ret
    case retPeeled of
         CFUnit => pure ()
         -- Unlike every other exportable type, a GCPtr can carry a
         -- finalizer (`Compiler.RC2.Emit.Util`'s own `packCFType
         -- CFGCPtr` note) -- `emitExportWrapper`'s own unconditional
         -- drop-after-return step (rc2/doc/export-support.md's
         -- "Memory" section) could invoke it before the C caller ever
         -- reads the returned pointer, a use-after-free the argument
         -- position never risks (its own GCPtr is never dropped by the
         -- wrapper at all). Same fail-fast-and-attributable philosophy
         -- as `Compiler.RC2.RC`'s own `checkForeignReturn`.
         CFGCPtr => throw $ GenericMsg EmptyFC
             "[rc2] %export declaration \{exportedName} (\{show n'})'s own return type is a GC-managed pointer (GCPtr/GCAnyPtr) -- returning one via %export isn't supported: the wrapper's own drop-after-return step could invoke the pointer's finalizer (if one is attached) before the C caller ever sees the value"
         _ => if isExportableCFType retPeeled
                 then pure ()
                 else throw $ GenericMsg EmptyFC "[rc2] %export declaration \{exportedName} (\{show n'})'s own return type \{show retPeeled} isn't a type %export supports -- %export supports \{exportSupportedTypesDesc} return types"
    for_ (zip [0 .. length realArgs] realArgs) $ \(i, a) =>
        if isExportableCFType a
           then pure ()
           else throw $ GenericMsg EmptyFC "[rc2] %export declaration \{exportedName} (\{show n'})'s own argument \{show i} (\{show a}) isn't a type %export supports -- %export supports \{exportSupportedTypesDesc} arguments"
    when (length realArgs > 20) $
        throw $ GenericMsg EmptyFC
            "[rc2] %export declaration \{exportedName} (\{show n'}) declares \{show (length realArgs)} argument(s) -- %export doesn't support more than 20"
    let Just ld = lookup n' byName
        | Nothing => throw $ InternalError "[rc2] %export \{exportedName}: \{show n'} has no definition"
    ldArgs <- the (Core (List Name)) $ case ld of
                   MkNmFun largs _ => pure largs
                   _ => throw $ GenericMsg EmptyFC "[rc2] %export declaration \{exportedName} (\{show n'}) isn't an ordinary function (foreign/constructor?)"
    -- An `IO`/`IORes`-returning declaration's own compiled arity is one
    -- more than its own source-level argument count: unlike `main`
    -- (whose `%MkWorld` token is already applied at the very top of the
    -- whole program, before lambda lifting, giving `__mainExpression`
    -- its own well-known arity-0 shape), an ordinary `%export`ed
    -- function still carries a real, un-erased trailing World
    -- parameter (quantity 1, not 0) all the way through Lifted -- see
    -- `rc2/doc/export-support.md`'s own "World argument" note, found by
    -- empirically probing this exact shape (a naive `length realArgs
    -- == length ldArgs` comparison throws a spurious arity-mismatch
    -- error on every IO-returning export otherwise). `emitExportWrapper`
    -- supplies this same slot as a boxed NULL constant when calling in,
    -- mirroring `packCFType`/`extractValue`'s own existing `CFWorld`
    -- convention.
    let retIsIO = case ret of CFIORes _ => True; _ => False
    let expectedArity = length realArgs + (if retIsIO then 1 else 0)
    when (expectedArity /= Prelude.List.length ldArgs) $
        throw $ GenericMsg EmptyFC
            "[rc2] %export declaration \{exportedName} (\{show n'}) declares \{show (length realArgs)} scalar argument(s) but its compiled definition has arity \{show (Prelude.List.length ldArgs)} -- likely an implicit/auto-implicit argument in its own type signature, which %export doesn't support"
    pure (n', exportedName, realArgs, ret)

||| Whole-program compilation -- generates C for every reachable
||| definition in the program (found from `tm`, the real `main`
||| `ClosedTerm`) and links it into a single executable in one shot.
||| `compileExpr` (below) dispatches here whenever incremental mode
||| isn't active, and also falls back here from `compileExprInc` when
||| some import lacks incremental compile data for `rc2` -- see
||| rc2/doc/incremental-compile.md.
compileExprWhole : Ref Ctxt Defs
           -> Ref Syn SyntaxInfo
           -> (tmpDir : String)
           -> (outputDir : String)
           -> ClosedTerm
           -> (outfile : String)
           -> Core (Maybe String)
compileExprWhole c s _ outputDir tm outfile =
  do let outn = outputDir </> outfile ++ ".c"
     let outobj = outputDir </> outfile ++ ".o"
     let outexec = outputDir </> outfile

     coreLift_ $ mkdirAll outputDir

     -- All directives share this one `directiveList` (CLI `--directive`
     -- union `%cg rc2 <directive>` source pragmas) -- see
     -- rc2/doc/directives.md for the mechanism and full directive list.
     -- Fetched once, up front, since `toRCDefs`'s own stage disabling
     -- needs it before `toRCDefs` runs.
     directiveList <- getDirectives (Other "rc2")
     let disabledStages = filter (`elem` directiveList) stageDirectiveNames
     -- `nomain`: not a stage disable, only controls whether `Emit.idr`'s
     -- `footer` emits a C `main()` -- see rc2/doc/directives.md and
     -- rc2/doc/export-support.md's "Linking as a library" section.
     let noMain = "nomain" `elem` directiveList
     cdata <- getCompileDataWith ["RC2", "RefC", "C"] False Cases tm
     exportNames <- traverse (\(n, _) => getFullName n) (exported cdata)
     -- Top-level `Delay` definitions onto CAF memoization; whole program
     -- only, since another module's references are out of sight
     -- (doc/lazy-memoization.md).
     let (mainLz, namedLz) = applyLazyCaf (Just (forget (mainExpr cdata))) (namedDefs cdata)
     (mainInl, namedInl) <- inlineNamed disabledStages (Just (SortedSet.fromList exportNames)) mainLz namedLz
     -- Signatures change, so not in `incCompile`: another module's calls
     -- are out of sight (doc/dead-args.md).
     (mainIn, namedIn) <- if "nodeadargs" `elem` disabledStages
                             then pure (mainInl, namedInl)
                             else logTime 2 "rc2: Dead arguments" $
                                    applyDeadArgs (MN "__mainExpression" 0 :: exportNames) mainInl namedInl
     (mainR, namedR) <- raiseNamed disabledStages mainIn namedIn
     exportedSigs <- traverse (validateExport (SortedMap.fromList (map (\(n, _, d) => (n, d)) namedR))) (exported cdata)
     -- `exported cdata`'s own Name is `Resolved` (Compiler.Common's
     -- `getExports` calls `resolved`, not `toFullNames`), but every
     -- entry in `defs`/`lifted` is keyed by full name --
     -- `Compiler.RC2.DeadCode.pruneDeadDefs`'s own reachability is a
     -- structural `Name` set-membership check, so a root given as a
     -- `Resolved` name would silently never match anything and get
     -- pruned as unreachable regardless of this list's own intent.
     -- `exportedSigs`'s own first component (`validateExport`'s
     -- `getFullName`-resolved `n'`) is reused here rather than
     -- re-deriving it a second time from `exported cdata` directly.
     let roots = MN "__mainExpression" 0 :: map (\(n, _, _, _) => n) exportedSigs
     (defs, liftInfos) <- lowerProgram disabledStages False roots mainR namedR

     -- `dumprcexpr`: dump the final RCExp to a `.rcexpr` file -- see
     -- rc2/doc/reading-the-ir.md for the format, rc2/doc/directives.md
     -- for the directive. `directiveText`, wrapped in a `-- ` line
     -- (`Language.RCExpr.Parser`'s own comment convention), records
     -- the exact directive set active for this compile, so a dump
     -- found later says which optimization stages ran without
     -- re-running the build to find out.
     when ("dumprcexpr" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".rcexpr")
             ("-- " ++ directiveText directiveList ++ "\n" ++
              prettyProgram (collectLazyCAFs (namedDefs cdata)) defs)

     -- `dumpdualabi`: dump Stage 2's own eligibility analysis -- see
     -- rc2/doc/dual-abi.md, rc2/doc/directives.md.
     when ("dumpdualabi" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".dualabi") (dumpDualABI defs)

     -- `dumplifts`: where each lifted definition came from -- see
     -- rc2/doc/lambda-lifting.md.
     when ("dumplifts" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".lifts") (dumpLifts liftInfos)

     -- `dumpcc`: print the C compile/link command(s) to stdout -- see
     -- rc2/doc/directives.md.
     let dumpCC = "dumpcc" `elem` directiveList

     -- `extraRuntime=<path>` / `inlineRuntime=<code>`: splice C straight
     -- into the generated output -- see rc2/doc/directives.md for the
     -- mechanism, the `inlineRuntime` landmines, and the natural
     -- `%foreign "C:funcName"` pairing.
     extraRuntimeFiles <- getExtraRuntime directiveList
     let inlineRuntime = getInlineRuntime directiveList
     let injectedRuntime = extraRuntimeFiles ++ (if inlineRuntime == "" then "" else "\n" ++ inlineRuntime)

     -- `externStruct=<name>`: suppress `header`'s own `typedef struct`
     -- for a name already `typedef`'d by an included header -- see
     -- rc2/doc/directives.md.
     let externStructs = getExternStructs directiveList

     foreignLibs <- logTime 2 "rc2: C generation" $ generateCSourceFile defs exportedSigs noMain Nothing False injectedRuntime externStructs directiveList outn
     Just _ <- logTime 2 "rc2: C compile" $ compileCObjectFile outn outobj dumpCC
       | Nothing => pure Nothing
     logTime 2 "rc2: C link" $ compileCFile [outobj] outexec foreignLibs dumpCC

||| Resolves a per-module incremental object filename -- as returned by
||| `incCompile` below and accumulated into `allIncData` (always a
||| relative name, since it may belong to a different, already-
||| installed package rather than this project's own build directory)
||| -- to a real path: try this project's own ttc build directory
||| first, then every dependency package's own installed directory.
||| Mirrors `Compiler.Scheme.Chez.loadSO`'s identical search order for
||| the exact same purpose (there, a per-module `.so`; here, `.o`).
||| The `""` case mirrors `loadSO appdir ""`'s own short-circuit --
||| `incCompile`'s own "this module compiled to no code at all" result
||| (`rc2/doc/incremental-compile.md`).
resolveIncObj : {auto c : Ref Ctxt Defs} -> String -> Core String
resolveIncObj "" = pure ""
resolveIncObj mod = do
    bdir <- ttcBuildDirectory
    extraDirs <- extraSearchDirectories
    let candidates = map (</> mod) (bdir :: extraDirs)
    Just fname <- firstAvailable candidates
        | Nothing => throw (InternalError "[rc2] incremental compile: missing object file \{mod}")
    pure fname

||| Final incremental-mode link (`rc2/doc/incremental-compile.md`): no
||| C codegen at all here -- every module's own `incCompile` call
||| already produced its own `.o` (the `Main` module's own `.o` already
||| contains `main()`, see that doc's own "no root-term recompile step"
||| section), so this just resolves and links every accumulated
||| per-module object plus their combined `%foreign` library list.
||| Falls back to `compileExprWhole` (same as Chez's own
||| `compileExprInc`) if `allIncData` has no entry for `rc2` -- some
||| import lacks incremental compile data for this codegen, most likely
||| because `prelude`/`base`/`contrib`/`network` haven't themselves
||| been rebuilt with `--inc rc2` yet (see the doc's own "practical
||| prerequisite" section).
compileExprInc : Ref Ctxt Defs
              -> Ref Syn SyntaxInfo
              -> (tmpDir : String)
              -> (outputDir : String)
              -> ClosedTerm
              -> (outfile : String)
              -> Core (Maybe String)
compileExprInc c s tmpDir outputDir tm outfile = do
    defs <- get Ctxt
    let Just (mods, libs) = lookup (Other "rc2") (allIncData defs)
        | Nothing => do
            coreLift $ putStrLn "Missing incremental compile data, reverting to whole program compilation"
            compileExprWhole c s tmpDir outputDir tm outfile
    directiveList <- getDirectives (Other "rc2")
    let dumpCC = "dumpcc" `elem` directiveList
    objs <- traverse resolveIncObj (nub mods)
    let outexec = outputDir </> outfile
    coreLift_ $ mkdirAll outputDir
    -- Archived, not linked directly (`archiveObjectFiles`'s own doc
    -- comment, `CC.idr`) -- a module whose own code is never reached
    -- from `main` (including one that only exists to dangle a
    -- reference to something incremental mode deliberately dropped,
    -- e.g. `Prelude.IO`'s own `threadWait`) must not be linked in at
    -- all, which a bare `.o` on the command line can't express but an
    -- unreferenced archive member naturally is.
    let outar = outputDir </> outfile ++ ".a"
    Just _ <- logTime 2 "rc2: incremental archive" $
        archiveObjectFiles (filter (/= "") objs) outar dumpCC
      | Nothing => pure Nothing
    logTime 2 "rc2: incremental link" $
        compileCFile [outar] outexec (nub libs) dumpCC

export
compileExpr : Ref Ctxt Defs
           -> Ref Syn SyntaxInfo
           -> (tmpDir : String)
           -> (outputDir : String)
           -> ClosedTerm
           -> (outfile : String)
           -> Core (Maybe String)
compileExpr c s tmpDir outputDir tm outfile = do
    sesh <- getSession
    if not (wholeProgram sesh) && ((Other "rc2") `elem` incrementalCGs sesh)
       then compileExprInc c s tmpDir outputDir tm outfile
       else compileExprWhole c s tmpDir outputDir tm outfile

||| `Compiler.Common.Codegen`'s own `incCompileFile` hook -- called
||| once per module by `Idris.ProcessIdr.process`, right after that
||| module finishes elaborating, with exactly the definitions that
||| module itself introduced (`getIncCompileData`'s own `toIR` scope).
||| See rc2/doc/incremental-compile.md for the full design: why
||| ConstFold/MutualLoop/Loop/DualABI need no change to run correctly
||| against this narrower def list, why DeadCode must always be
||| skipped here (`"nodeadcode"`, forced regardless of any user
||| `--directive` setting), and why `noMain` alone (already built for
||| the `%export`-as-library case) is enough to decide whether this
||| particular module's own `.c` needs the C `main()` entry point --
||| true only for the module literally named `Main`, which needs no
||| special handling here beyond that flag: its own `Main.main` is
||| just another definition already in `toIR` like everything else.
incCompile : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
             (sourceFile : String) -> Core (Maybe (String, List String))
incCompile c s sourceFile = do
    cdata <- getIncCompileData False Cases
    let ndefs = namedDefs cdata
    if isNil ndefs
       then pure (Just ("", []))
            -- No code to generate, but still record that the module
            -- was incrementally compiled (mirrors Chez's own
            -- `incCompile` -- `missingIncremental`'s later check needs
            -- *some* entry to exist, not necessarily a nonempty one).
       else do
         -- `ctxtPathToNS sourceFile` would derive the namespace from the
         -- *file path* (e.g. "Hello" for a file named Hello.idr) -- wrong
         -- here, since Idris2 lets a file's own `module Main` declaration
         -- differ from its filename precisely for the entry-point case
         -- (the same special-case `Idris.ProcessIdr.processMod`'s own
         -- `ns /= nsAsModuleIdent mainNS` check guards against). What
         -- `noMain` actually needs is the module's own *declared*
         -- namespace, already recorded on `Ctxt` by the time `incCompile`
         -- runs (elaboration of this module has already finished).
         coreDefs <- get Ctxt
         let noMain = currentNS coreDefs /= mainNS
         directiveList <- getDirectives (Other "rc2")
         let disabledStages = nub ("nodeadcode" :: filter (`elem` directiveList) stageDirectiveNames)
         (_, namedInl) <- inlineNamed disabledStages Nothing Nothing (namedDefs cdata)
         (_, namedIn) <- raiseNamed disabledStages Nothing namedInl
         (defs, _) <- lowerProgram disabledStages True [] Nothing namedIn
         -- `Main.main`'s compiled arity is 0 or 1 (a CAF still waiting for the
         -- world, vs. a function taking it), so the entry call is built from
         -- the real `MkRCFun` arity, never hardcoded. Arity 0 must go through
         -- `idris2rc2_applyClosure`: a bare call only builds the closure and
         -- runs nothing. See rc2/doc/incremental-compile.md, "Bugs found while
         -- implementing" item 4.
         let mainMainName = NS mainNS (UN (Basic "main"))
         directEntryPoint <- the (Core (Maybe String)) $
             if noMain
                then pure Nothing
                else case lookup mainMainName defs of
                          Just (MkRCFun [] _ _ _) => pure (Just "idris2rc2_applyClosure(\{cName mainMainName}(), NULL)")
                          Just (MkRCFun _ _ _ _) => pure (Just "\{cName mainMainName}(NULL)")
                          _ => throw $ InternalError "[rc2] incremental compile: Main module has no Main.main function"
         when ("dumprcexpr" `elem` directiveList) $ do
             rcexprFile <- getTTCFileName sourceFile "rcexpr"
             coreLift_ $ writeFile rcexprFile
                 ("-- " ++ directiveText directiveList ++ "\n" ++
                  prettyProgram (collectLazyCAFs (namedDefs cdata)) defs)
         extraRuntimeFiles <- getExtraRuntime directiveList
         let inlineRuntime = getInlineRuntime directiveList
         let injectedRuntime = extraRuntimeFiles ++ (if inlineRuntime == "" then "" else "\n" ++ inlineRuntime)
         let externStructs = getExternStructs directiveList
         outC <- getTTCFileName sourceFile "c"
         outO <- getTTCFileName sourceFile "o"
         objRel <- getObjFileName sourceFile "o"
         foreignLibs <- logTime 2 "rc2: incremental C generation" $
             generateCSourceFile defs [] noMain directEntryPoint True injectedRuntime externStructs directiveList outC
         Just _ <- logTime 2 "rc2: incremental C compile" $
             compileCObjectFile outC outO ("dumpcc" `elem` directiveList)
           | Nothing => pure Nothing
         pure (Just (objRel, foreignLibs))

export
executeExpr : Ref Ctxt Defs -> Ref Syn SyntaxInfo ->
              (execDir : String) -> ClosedTerm -> Core ()
executeExpr c s tmpDir tm = do
  do let outfile = "_tmp_rc2"
     Just _ <- compileExpr c s tmpDir tmpDir tm outfile
       | Nothing => do coreLift_ $ putStrLn "Error: failed to compile"
     coreLift_ $ system (tmpDir </> outfile)

export
codegenRC2 : Codegen
codegenRC2 = MkCG compileExpr executeExpr (Just incCompile) (Just "o")
