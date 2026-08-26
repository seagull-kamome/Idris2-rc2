module Compiler.RC2.Emit

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- RCExp -> C. Mostly mechanical: every ownership decision (dup/drop/free,
-- and what to drop and when), every native-vs-boxed representation
-- decision, and the constructor-reuse-in-place decision were already made
-- by Compiler.RC2.RC/Compiler.RC2.Reuse and are baked into the tree as
-- data (explicit RDup/RDrop/RFree nodes, RLet's Rep field, RCon's
-- reuseFrom, RReuseOffer, RReleaseReuse). This module never
-- (re)analyses any of those; it just maintains a small incrementally-built
-- `RepMap` so that a *use* of a local (which only carries its RCLocal id)
-- can look back up the Rep its binding RLet already decided. Every local
-- variable use (RV, and every RCLocal appearing as a call/constructor/op
-- argument) is lowered as-is, with no per-use dup decision: any refcount
-- adjustment a use needs has already been made explicit as a wrapping
-- RDup/RDrop/RFree node earlier in the tree, which this module just
-- lowers to the matching runtime call.
--
-- In particular, an `RDrop`'s own var list never needs re-filtering
-- here: Compiler.RC2.RC's `Owned` set (the sole source of every
-- `RDrop` it produces, via `dropUnusedOwnedVars`'s set-difference) only
-- ever gains members at three sites (a function's own args, an RLet's
-- own bound var, an RConAlt's own destructured args), and all three
-- exclude `natives`-listed locals and only ever insert genuine `RCLoc`s
-- -- never `RCConst`/`RCEmptyCon`/`RCNull`. A `keepBoxedLocals`
-- Native/RCConst/RCEmptyCon/RCNull re-filter used to sit in front of
-- every `RDrop` lowering below as a defensive measure; removed once
-- this was confirmed airtight (see TODO.md's former "Architecture"
-- note on this exact question).
--
-- A few things this module still *does* decide, deliberately, not an
-- oversight:
--   * `tryBuildClosureInto`/`makeClosureInto`: which C statements a
--     closure build/partial-application ends up as. Purely a codegen-
--     shape optimisation (fewer statements, no throwaway `closure_N`
--     immediately copied into its real destination) with zero effect on
--     runtime semantics -- unlike the ownership/representation decisions
--     above, there's no *semantic* fact for Compiler.RC2.RC's IR to carry
--     about this, only a syntactic one about how many C statements to
--     spend saying it.
--   * `RPrimVal`'s small-int cache / constant-staging (`dyngen`/
--     `orStagen`): a literal's own *value* decides whether it uses the
--     small-int cache or gets staged into a deduplicated top-level
--     constant. Left here on purpose, not elevated alongside the
--     decisions above: this is a runtime-representation detail (which
--     cache/table a given literal's storage lives in), not an
--     ownership/native-vs-boxed *fact* about the IR itself, and dedup
--     inherently spans the *whole compilation unit* rather than one
--     definition, so it doesn't fit the "decide once per node during
--     Lifted -> RCExp conversion" shape the elevations above use even
--     if moved.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Compiler.CompileExpr
import Compiler.Common
import Compiler.Generated

import Core.Directory
import Core.Context

import Idris.Syntax

import Libraries.Data.DList
import Data.List
import Data.List.Quantifiers
import Data.SortedSet
import Data.SortedMap
import Data.String
import Data.Vect

import Protocol.Hex
import Libraries.Utils.Path

import System
import System.File

import Compiler.RC2.EmitUtil

%default covering

mutual
    ||| Declare an `RLet`'s own binding: record its `Rep` (so later *uses*
    ||| of `var` can look it up), then either inline it (a literal, or an
    ||| `RInlineNative`), declare a plain native C scalar, or build/copy
    ||| its Boxed value into `var_N`. Shared by `emitRC`'s and
    ||| `emitNativeValue`'s own `RLet` cases (identical in both except
    ||| for what continues afterward, which each caller keeps to itself)
    ||| *and* `tryBuildClosureInto`'s own `RLet` case -- an `RLet`
    ||| standing between it and a closure-shaped tail expression still
    ||| needs its binding declared exactly as it would be anywhere else,
    ||| it just isn't the end of that search.
    declareLet : {auto a : Ref ArgCounter Nat}
               -> {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
               -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
               -> {auto r : Ref RepMap (SortedMap Int Rep)}
               -> {auto lm : Ref InlineMap (SortedMap Int String)}
               -> {auto fa : Ref LoopParams (List (Int, Rep))}
               -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
               -> FC -> Int -> Rep -> RCExp -> Core ()
    declareLet fc var rep value = do
        update RepMap (insert var rep)
        case (rep, value) of
             (RNative _, RPrimVal _ c) => update InlineMap (insert var (nativeLitExpr c))
             (RInlineNative ty, _) => inlineNative ty var value
             (RNative ty, _) => declareNative fc ty var value
             (RBoxed, _) => emitInto fc (SinkVar True "var_\{show var}") NotInTailPosition value

    ||| If `value` is a continue of the nearest enclosing loop
    ||| (`RLoopContinue`, see its own doc comment) -- possibly wrapped in
    ||| leading RDup/RDrop/RFree/RLet, same as `tryBuildClosureInto` --
    ||| emit the loop-back: snapshot every new value into a fresh
    ||| temporary first (a plain simultaneous-assignment safeguard
    ||| against aliasing, e.g. `f x y = f y x` -- nothing here is an
    ||| ownership decision, `annotate` (Phase 2) already decided every
    ||| argument's dup/move before Compiler.RC2.Loop ever ran, see
    ||| `RLoopContinue`'s own doc comment), reassign each loop param
    ||| variable from its own temporary -- boxed or native, per that
    ||| param's own `Rep` (from `LoopParams`) -- then `goto loop;`.
    |||
    ||| Returns `Nothing` if the loop-back was emitted (nothing left for
    ||| the caller to assign or return -- control already left via the
    ||| `goto`), or `Just leftover` using the same leftover protocol as
    ||| `tryBuildClosureInto`, for the same reason (a peeled wrapper's
    ||| side effect must not be emitted twice).
    tryEmitLoopContinue : {auto a : Ref ArgCounter Nat}
                        -> {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                        -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                        -> {auto r : Ref RepMap (SortedMap Int Rep)}
                        -> {auto lm : Ref InlineMap (SortedMap Int String)}
                        -> {auto fa : Ref LoopParams (List (Int, Rep))}
                        -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                        -> RCExp -> Core (Maybe RCExp)
    tryEmitLoopContinue (RDup fc v cont) = do
        dupVars [varName v]
        tryEmitLoopContinue cont
    tryEmitLoopContinue (RDrop fc vs cont) = do
        -- `vs` is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> vs)
        tryEmitLoopContinue cont
    tryEmitLoopContinue (RFree fc v cont) = do
        freeVars [varName v]
        tryEmitLoopContinue cont
    tryEmitLoopContinue (RLet fc var rep value body) = do
        declareLet fc var rep value
        tryEmitLoopContinue body
    tryEmitLoopContinue (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        tryEmitLoopContinue cont
    tryEmitLoopContinue (RReuseOffer fc sc dupOnShared dropOnUnique cont) = do
        emitReuseOffer sc dupOnShared dropOnUnique
        tryEmitLoopContinue cont
    tryEmitLoopContinue (RLoopContinue fc newArgs postDrop) = do
        loopParams <- get LoopParams
        temps <- traverse (\(v, (paramId, rep)) => do
            t <- getNewVarThatWillNotBeFreedAtEndOfBlock
            (cty, valStr) <- the (Core (String, String)) $ case rep of
                 RBoxed => (\s => ("IDRIS2RC2_Value *", s)) <$> rcVarToBoxedC v
                 RNative ty => (\s => (nativeCType ty ++ " ", s)) <$> rcVarToNativeC ty v
                 RInlineNative ty => (\s => (nativeCType ty ++ " ", s)) <$> rcVarToNativeC ty v
            emit fc "\{cty}\{t} = \{valStr};"
            pure (paramId, t)) (zip newArgs loopParams)
        -- `postDrop`: every still-Boxed argument that was just read
        -- *natively* above (a `Native`/`RInlineNative` loop param slot,
        -- fed by a Boxed source -- e.g. a `case`-valued let, which
        -- `Types.repOf` never promotes to Native on its own even when
        -- every branch is native-eligible) needs its own Boxed source
        -- dropped now that it's been read, the same "read first, drop
        -- after" ordering `ROp`/`RCmpCase`'s own `postDrop` already
        -- follow -- there's no separate statement position to hang an
        -- ordinary wrapping `drop` around a native-context read. See
        -- `RLoopContinue`'s own doc comment (RCExp.idr) for the real
        -- leak this closes.
        removeVars (varName <$> postDrop)
        traverse_ (\(paramId, t) => emit fc "var_\{show paramId} = \{t};") temps
        emit fc "goto loop;"
        pure Nothing
    tryEmitLoopContinue e = pure (Just e)

    ||| If `value` is a partial application (RUnderApp), or an InTailPosition
    ||| tail call (RAppName -- see emitRC's own RAppName case, which only
    ||| ever produces a bare closure name in that tail position, never
    ||| otherwise) -- either possibly wrapped in leading RDup/RDrop/RFree for
    ||| their own operands' refcounting, or in one or more RLet bindings
    ||| that have nothing to do with the closure itself (both of which
    ||| `annotate`/Phase 1's own ANF normalisation can wrap around any
    ||| expression uniformly, without changing what the *tail* expression
    ||| actually is) -- lower those wrappers first, then build the closure
    ||| directly into `sink` (via `buildClosureIntoSink`/`makeClosureInto`)
    ||| instead of the throwaway `closure_N` a generic `emitRC value`
    ||| would produce (only to have the caller immediately copy it into
    ||| the real destination right after -- two statements for one).
    |||
    ||| Returns `Nothing` if the closure was built (nothing left for the
    ||| caller to do), or `Just leftover` if `value` wasn't shaped like
    ||| this at all -- `leftover` is *not* always `value` itself: peeling
    ||| an RDup/RDrop/RFree/RLet wrapper on the way down already emits
    ||| that wrapper's own side effect (a dup/drop/free call, or a let
    ||| declaration), so if the search dead-ends partway through, the
    ||| caller must resume from what's left (the innermost un-peeled
    ||| expression), not restart from `value` -- re-running `emitRC` on
    ||| the original `value` would emit every wrapper's side effect a
    ||| second time. (An earlier version returned a bare `Bool` and had
    ||| exactly this bug: any Boxed `RLet` whose value was e.g. an
    ||| RDup-wrapped non-tail-position `RAppName` -- an ordinary, common
    ||| shape, not exotic -- had its dup emitted twice, permanently
    ||| leaking one reference. Found via `Prelude.Types.foldr`.)
    tryBuildClosureInto : {auto a : Ref ArgCounter Nat}
                        -> {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                        -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                        -> {auto r : Ref RepMap (SortedMap Int Rep)}
                        -> {auto lm : Ref InlineMap (SortedMap Int String)}
                        -> {auto fa : Ref LoopParams (List (Int, Rep))}
                        -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                        -> Sink -> TailPositionStatus -> RCExp -> Core (Maybe RCExp)
    tryBuildClosureInto sink tailPosition (RDup fc v cont) = do
        dupVars [varName v]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RDrop fc vs cont) = do
        -- `vs` is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> vs)
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RFree fc v cont) = do
        freeVars [varName v]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RLet fc var rep value body) = do
        declareLet fc var rep value
        tryBuildClosureInto sink tailPosition body
    tryBuildClosureInto sink tailPosition (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RReuseOffer fc sc dupOnShared dropOnUnique cont) = do
        emitReuseOffer sc dupOnShared dropOnUnique
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink _ (RUnderApp fc n missing args) = do
        buildClosureIntoSink fc sink n args missing
        pure Nothing
    tryBuildClosureInto sink InTailPosition (RAppName fc _ n args) = do
        buildClosureIntoSink fc sink n args 0
        pure Nothing
    tryBuildClosureInto _ _ e = pure (Just e)

    ||| Render `value`'s native expression and declare it as a plain
    ||| `TYPE var_N = ...;` C scalar, discharging its own pending
    ||| Boxed-operand drop(s) immediately after (see `emitNativeValue`'s
    ||| own doc comment for why that ordering matters). Shared by
    ||| `emitRC`'s and `emitNativeValue`'s own RLet cases for a plain
    ||| (non-inlined) `RNative` local -- identical in both except for
    ||| what continues afterward, which each caller keeps to itself.
    declareNative : {auto a : Ref ArgCounter Nat}
                  -> {auto oft : Ref OutfileText Output}
                  -> {auto il : Ref IndentLevel Nat}
                  -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                  -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                  -> {auto r : Ref RepMap (SortedMap Int Rep)}
                  -> {auto lm : Ref InlineMap (SortedMap Int String)}
                  -> {auto fa : Ref LoopParams (List (Int, Rep))}
                  -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                  -> FC -> PrimType -> Int -> RCExp -> Core ()
    declareNative fc ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        emit fc $ "\{nativeCType ty} var_\{show var} = \{valStr};"
        removeVars $ map varName pending

    ||| As `declareNative`, but for an `RInlineNative` local: no C
    ||| variable ever declared, its rendered expression goes straight
    ||| into InlineMap instead (see `Rep.RInlineNative`'s own doc
    ||| comment). Also shared by `emitRC`'s and `emitNativeValue`'s own
    ||| RLet cases.
    inlineNative : {auto a : Ref ArgCounter Nat}
                 -> {auto oft : Ref OutfileText Output}
                 -> {auto il : Ref IndentLevel Nat}
                 -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                 -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                 -> {auto r : Ref RepMap (SortedMap Int Rep)}
                 -> {auto lm : Ref InlineMap (SortedMap Int String)}
                 -> {auto fa : Ref LoopParams (List (Int, Rep))}
                 -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                 -> PrimType -> Int -> RCExp -> Core ()
    inlineNative ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        update InlineMap (insert var valStr)
        removeVars $ map varName pending

    ||| As `declareNative`, but for a `SinkReturn (RNative ty)`/
    ||| `SinkReturn (RInlineNative ty)` tail position instead of an
    ||| `RLet` -- `Compiler.RC2.DualABI`'s own Stage 3b, see `Sink`'s own
    ||| doc comment. A `return` has no statement position *after* it for
    ||| a pending Boxed-operand drop to land in, unlike `declareNative`'s
    ||| `RLet` -- see `rc2/doc/dual-abi.md`'s "no statement position
    ||| after return" section for the full problem and the bug this
    ||| design avoids repeating. Nothing pending: plain `return valStr;`.
    ||| Something pending: capture the read into a scratch `tmp_N` (same
    ||| naming `makeClosure`'s own
    ||| `getNewVarThatWillNotBeFreedAtEndOfBlock` already uses) first,
    ||| drop, then return the scratch variable.
    emitNativeReturn : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> {auto fa : Ref LoopParams (List (Int, Rep))}
                     -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                     -> FC -> PrimType -> RCExp -> Core ()
    emitNativeReturn fc ty value = do
        (valStr, pending) <- emitNativeValue ty value
        case pending of
             [] => emit fc "return \{valStr};"
             _  => do
                 tmp <- getNewVarThatWillNotBeFreedAtEndOfBlock
                 emit fc "\{nativeCType ty} \{tmp} = \{valStr};"
                 removeVars $ map varName pending
                 emit fc "return \{tmp};"

    ||| Render a leftover `RAppNameRep` (a direct call to `name`'s own
    ||| dual-ABI worker, see its own doc comment in RCExp.idr) into
    ||| `sink`. Renders each argument per `argReps`' own position
    ||| (mirroring `tryEmitLoopContinue`'s own per-position rendering),
    ||| then always produces a *Boxed* value string -- `RBoxed` behaves
    ||| like an ordinary, never-closure-deferred `RAppName` call;
    ||| `RNative`/`RInlineNative` boxes the callee's raw native result via
    ||| `nativeMk`. See `rc2/doc/dual-abi.md`'s Stage 3a "Bugs found" #3
    ||| for why `postDrop` exists at all (a real reference leak, found via
    ||| `valgrind`), and its Stage 4 section for why a `SinkReturn` target
    ||| needs the same scratch-variable capture `emitNativeReturn` uses
    ||| (no statement position after a `return` for the drop to land in)
    ||| -- `SinkVar` always has one, so it just drops right after.
    emitAppNameRepInto : {auto a : Ref ArgCounter Nat}
                       -> {auto oft : Ref OutfileText Output}
                       -> {auto il : Ref IndentLevel Nat}
                       -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                       -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                       -> {auto r : Ref RepMap (SortedMap Int Rep)}
                       -> {auto lm : Ref InlineMap (SortedMap Int String)}
                       -> {auto fa : Ref LoopParams (List (Int, Rep))}
                       -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                       -> Sink -> TailPositionStatus -> FC -> Name -> List Rep -> Rep -> List RCLocal -> List RCLocal -> Core ()
    emitAppNameRepInto sink tailPosition fc n argReps retRep postDrop args = do
        -- No `nargs` cap here: the call below is always a plain,
        -- positional, direct C call to a dual-ABI worker (`isWorker =
        -- True`, see `MkRCFun`'s own doc comment) -- never dispatched
        -- through `support/rc2/runtime.c`'s closure machinery, so
        -- `MaxExtractFunArgs` (which governs THAT convention) doesn't
        -- apply here.
        argStrs <- traverse (\(rep, v) => case rep of
                                 RNative ty => rcVarToNativeC ty v
                                 RInlineNative ty => rcVarToNativeC ty v
                                 RBoxed => rcVarToBoxedC v) (zip argReps args)
        let call = "\{cName n}(\{concat $ intersperse ", " argStrs})"
        let valStr = case retRep of
                          RBoxed => case tailPosition of
                                         InTailPosition => call
                                         NotInTailPosition => "idris2rc2_trampoline(\{call})"
                          RNative ty => nativeMk ty call
                          RInlineNative ty => nativeMk ty call
        case postDrop of
             [] => finalizeSink fc sink valStr
             _  => case sink of
                        SinkReturn _ => do
                            tmp <- getNewVarThatWillNotBeFreedAtEndOfBlock
                            emit fc "IDRIS2RC2_Value * \{tmp} = \{valStr};"
                            removeVars $ map varName postDrop
                            emit fc "return \{tmp};"
                        _ => do
                            finalizeSink fc sink valStr
                            removeVars $ map varName postDrop

    ||| Evaluate `value` (in `tailPosition`) and dispose of its result per
    ||| `sink` -- either declaring/assigning a named C variable, or (only
    ||| ever while `tailPosition` is `InTailPosition`, since nothing after
    ||| a `return` would run) emitting a plain C `return` statement. Tries
    ||| `tryEmitLoopContinue` first (a self-tail-call has nothing to hand
    ||| any `Sink` at all -- control leaves via `goto` -- see its own doc
    ||| comment), then `tryBuildClosureInto` (skips a throwaway `closure_N`
    ||| when `value` is a closure build that can go straight into `sink`
    ||| -- see its own doc comment). A leftover `RCmpCase`/`RConCase`/
    ||| `RConstCase` is handled specially too (`emitCmpCaseInto`/
    ||| `emitConCaseInto`/`emitConstCaseInto`), so every branch writes
    ||| straight into the *caller's own* `sink` instead of a throwaway
    ||| `switchReturnVar` that then has to be copied into it -- the same
    ||| "build directly into the real destination" idea as
    ||| `tryBuildClosureInto`, applied to branching constructs (and,
    ||| in tail position, letting a whole chain of nested cases collapse
    ||| straight down to a `return` in each leaf branch, with no
    ||| intermediate variable anywhere along the way). Anything else (a
    ||| genuine single-expression leaf: `RV`, `RCon`, `ROp`, `RExtPrim`,
    ||| `RPrimVal`, `RErased`, `RCrash`, `RApp`, a non-tail `RAppName`)
    ||| falls back to the general `emitRC`-then-`finalizeSink` route --
    ||| unless `sink` is itself a native `SinkReturn` (`RNative`/
    ||| `RInlineNative`, Compiler.RC2.DualABI's own Stage 3b), in which
    ||| case `emitNativeReturn` handles it instead: `emitRC`'s own
    ||| contract is always-Boxed, exactly wrong for a function whose own
    ||| C return type is a native scalar -- see `emitNativeReturn`'s own
    ||| doc comment.
    ||| Every "evaluate this RCExp and store/return its result" site in
    ||| this module goes through here, so the choice between those routes
    ||| is only ever written once.
    emitInto : {auto a : Ref ArgCounter Nat}
             -> {auto oft : Ref OutfileText Output}
             -> {auto il : Ref IndentLevel Nat}
             -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
             -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
             -> {auto r : Ref RepMap (SortedMap Int Rep)}
             -> {auto lm : Ref InlineMap (SortedMap Int String)}
             -> {auto fa : Ref LoopParams (List (Int, Rep))}
             -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
             -> FC -> Sink -> TailPositionStatus -> RCExp -> Core ()
    emitInto fc sink tailPosition value = do
        -- Same "resume from the leftover, not the original value" care
        -- as tryBuildClosureInto's own doc comment explains, chained
        -- across every stage.
        afterSelfTail <- tryEmitLoopContinue value
        whenJust afterSelfTail $ \v1 => do
            leftover <- tryBuildClosureInto sink tailPosition v1
            whenJust leftover $ \remaining =>
                case remaining of
                     RCmpCase fc' op args postDrop whenTrue whenFalse =>
                         emitCmpCaseInto sink tailPosition fc' op args postDrop whenTrue whenFalse
                     RConCase fc' sc alts mDef =>
                         emitConCaseInto sink tailPosition fc' sc alts mDef
                     RConstCase fc' sc alts def =>
                         emitConstCaseInto sink tailPosition fc' sc alts def
                     RLoop fc' loopParams initial prologueDrop body =>
                         emitLoopInto sink tailPosition fc' loopParams initial prologueDrop body
                     -- Always routed to its own dedicated renderer,
                     -- regardless of `sink` -- emitRC's own contract
                     -- ("always render a Boxed expression string") has
                     -- no room to also discharge RAppNameRep's own
                     -- postDrop (see its own doc comment in RCExp.idr),
                     -- the same "can't discharge a pending Boxed-operand
                     -- drop safely in front of a `return`" problem
                     -- emitNativeReturn already solves for an ordinary
                     -- native tail value, generalised here to any Sink.
                     RAppNameRep fc' n argReps retRep postDrop args =>
                         emitAppNameRepInto sink tailPosition fc' n argReps retRep postDrop args
                     -- A native SinkReturn (Compiler.RC2.DualABI's own
                     -- Stage 3b) skips emitRC entirely: emitRC's own
                     -- contract is "always render a Boxed expression
                     -- string", which is exactly wrong here, and can't
                     -- discharge a pending Boxed-operand drop safely in
                     -- front of a `return` in the first place (see
                     -- emitNativeReturn's own doc comment). Every other
                     -- Sink still goes through the ordinary
                     -- emitRC-then-finalizeSink route, unchanged.
                     _ => case sink of
                              SinkReturn (RNative ty) => emitNativeReturn fc ty remaining
                              SinkReturn (RInlineNative ty) => emitNativeReturn fc ty remaining
                              _ => do
                                  valStr <- emitRC remaining tailPosition
                                  finalizeSink fc sink valStr

    ||| A case branch (or default): emit the drops RC.idr's `annotate`
    ||| already decided on (the peeled leading RDrop), then the body
    ||| itself (an `RReuseOffer`, if Compiler.RC2.Reuse left one on this
    ||| alt, is just part of that body now -- `emitInto`'s own peeling
    ||| chain lowers it mechanically like any other wrapper, nothing
    ||| special-cased here). Mirrors RC2/RefC's `concaseBody`.
    |||
    ||| For a matched-constructor alt, any of its own destructured
    ||| fields (read straight out of the scrutinee's own storage,
    ||| `sc->args[k]` -- plain pointer aliasing, not independently
    ||| reference-counted) that survive past this branch already carry
    ||| their own explicit leading `RDup` here -- `Compiler.RC2.Reuse`'s
    ||| own `resolveAlt` precomputes this (its own `else` branch for an
    ||| ordinary matched alt, `dupOnShared` for a reuse-eligible one),
    ||| the same "destructured via aliasing" rule either way, so this
    ||| function has nothing left to re-derive: whatever survivor-dups
    ||| a given alt's body needs are already part of `body` itself, laid
    ||| out exactly like any other RDup/RDrop/RReuseOffer wrapper
    ||| `emitInto`'s own peeling chain already lowers mechanically.
    branchBody : {auto a : Ref ArgCounter Nat}
               -> {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
               -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
               -> {auto r : Ref RepMap (SortedMap Int Rep)}
               -> {auto lm : Ref InlineMap (SortedMap Int String)}
               -> {auto fa : Ref LoopParams (List (Int, Rep))}
               -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
               -> Sink -> RCExp -> TailPositionStatus -> Core ()
    branchBody sink body tailPosition = do
        let (shouldDrop0, body') = peelDrop body
        -- shouldDrop0 is already guaranteed Boxed-only -- see the
        -- module note.
        let shouldDrop = varName <$> shouldDrop0
        removeVars shouldDrop
        -- `sink` is already fully resolved -- any variable it names was
        -- declared once by the enclosing RConCase/RConstCase/RCmpCase
        -- before any branch ran (see `resolveSink`), or it's `SinkReturn`
        -- and names nothing at all.
        emitInto emptyFC sink tailPosition body'

    ||| An `RConAlt`'s own destructuring (`var_N = sc->args[k]` for each
    ||| pattern-bound field) followed by its body via `branchBody` --
    ||| shared by every alt `emitConCaseInto`/`emitAltChain` render,
    ||| whether or not this particular alt ended up needing its own
    ||| condition check (the destructuring itself doesn't depend on
    ||| that).
    emitConAltBody : {auto a : Ref ArgCounter Nat}
                   -> {auto oft : Ref OutfileText Output}
                   -> {auto il : Ref IndentLevel Nat}
                   -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                   -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                   -> {auto r : Ref RepMap (SortedMap Int Rep)}
                   -> {auto lm : Ref InlineMap (SortedMap Int String)}
                   -> {auto fa : Ref LoopParams (List (Int, Rep))}
                   -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                   -> Sink -> TailPositionStatus -> RCLocal -> RConAlt -> Core ()
    emitConAltBody sink tailPosition sc (MkRConAlt name coninfo tag args body) = do
        let sc' = varName sc
        _ <- foldlC (\k, arg => do
            emit emptyFC "IDRIS2RC2_Value *var_\{show arg} = ((IDRIS2RC2_Constructor*)\{sc'})->args[\{show k}];"
            pure (S k) ) 0 args
        branchBody sink body tailPosition

    ||| Lower a fused comparison branch (see RCExp.idr's own doc comment
    ||| on RCmpCase and `nativeCmpExpr`): the comparison is evaluated once
    ||| into a raw C `int` (no heap allocation for the Bool it would
    ||| otherwise be), `postDrop` (Compiler.RC2.RC's `annotate`) is
    ||| lowered immediately after -- same ordering rule as ROp's own
    ||| postDrop, see its doc comment -- and then exactly one of the two
    ||| branches runs, each writing straight into `sink` (resolved once,
    ||| before either branch -- see `resolveSink`) instead of a throwaway
    ||| `switchReturnVar`. Under `SinkReturn`, `whenTrue` is guaranteed to
    ||| end in `return`/`goto` (see `chainsWithElse`'s own doc comment),
    ||| so `whenFalse` needs neither an `else` to guard it nor its own
    ||| `{ }` scope -- it's already the last thing in whatever C block
    ||| contains this whole comparison, so it can just continue right
    ||| after `whenTrue`'s closing `}`, at the same indentation.
    emitCmpCaseInto : {auto a : Ref ArgCounter Nat}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                    -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                    -> {auto r : Ref RepMap (SortedMap Int Rep)}
                    -> {auto lm : Ref InlineMap (SortedMap Int String)}
                    -> {auto fa : Ref LoopParams (List (Int, Rep))}
                    -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                    -> Sink -> TailPositionStatus -> FC -> PrimFn 2 -> Vect 2 RCLocal
                    -> List RCLocal -> RCExp -> RCExp -> Core ()
    emitCmpCaseInto sink tailPosition fc op args postDrop whenTrue whenFalse = do
        case cmpArgTy op of
             Nothing => throw $ InternalError "[rc2] RCmpCase: not a comparison op"
             Just ty => do
                 argStrs <- rc2traverseVect (rcVarToNativeC ty) args
                 let condVar = "cmp_" ++ !(getNextCounter)
                 emit fc $ "int " ++ condVar ++ " = " ++ nativeCmpExpr op argStrs ++ ";"
                 removeVars $ map varName postDrop
                 resolvedSink <- resolveSink fc sink
                 emit emptyFC "if (\{condVar}) {"
                 increaseIndentation
                 emitInto emptyFC resolvedSink tailPosition whenTrue
                 decreaseIndentation
                 if chainsWithElse resolvedSink
                    then do
                        emit emptyFC "} else {"
                        increaseIndentation
                        emitInto emptyFC resolvedSink tailPosition whenFalse
                        decreaseIndentation
                        emit emptyFC "}"
                    else do
                        emit emptyFC "}"
                        emitInto emptyFC resolvedSink tailPosition whenFalse

    ||| Lower a constructor-tag switch: each alt (and the default, if
    ||| any) writes straight into `sink` (resolved once, before any alt
    ||| -- see `resolveSink`) instead of a throwaway `switchReturnVar` --
    ||| see `emitAltChain`'s own doc comment for the `if`-chain shape.
    emitConCaseInto : {auto a : Ref ArgCounter Nat}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                    -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                    -> {auto r : Ref RepMap (SortedMap Int Rep)}
                    -> {auto lm : Ref InlineMap (SortedMap Int String)}
                    -> {auto fa : Ref LoopParams (List (Int, Rep))}
                    -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                    -> Sink -> TailPositionStatus -> FC -> RCLocal -> List RConAlt -> Maybe RCExp -> Core ()
    emitConCaseInto sink tailPosition fc sc alts mDef = do
        let sc' = varName sc
        resolvedSink <- resolveSink fc sink
        emitAltChain resolvedSink
            (conAltCondExpr sc')
            (emitConAltBody resolvedSink tailPosition sc)
            (map (\body => branchBody resolvedSink body tailPosition) mDef)
            alts

    ||| Lower a constant/tag switch: same "each alt writes straight into
    ||| the once-resolved `sink`, via `emitAltChain`'s shared `if`-chain
    ||| shape" as `emitConCaseInto`, just over `RConstCase`'s own two
    ||| dispatch strategies (a fast integer switch via `extractIntExpr`,
    ||| or the string/double equality chain).
    emitConstCaseInto : {auto a : Ref ArgCounter Nat}
                       -> {auto oft : Ref OutfileText Output}
                       -> {auto il : Ref IndentLevel Nat}
                       -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                       -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                       -> {auto r : Ref RepMap (SortedMap Int Rep)}
                       -> {auto lm : Ref InlineMap (SortedMap Int String)}
                       -> {auto fa : Ref LoopParams (List (Int, Rep))}
                       -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                       -> Sink -> TailPositionStatus -> FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> Core ()
    emitConstCaseInto sink tailPosition fc sc alts def = do
        let sc' = varName sc
        resolvedSink <- resolveSink fc sink
        let defaultAction = map (\body => branchBody resolvedSink body tailPosition) def
        -- `sc` is Boxed in every case Phase 1/2 ever produce on their
        -- own -- but Compiler.RC2.Loop's own native-shadow promotion
        -- (see its `applyLoop`) can redirect a loop param's *every*
        -- read, including here, to a fresh `RNative` shadow (a loop-
        -- carried numeric value pattern-matched against literal
        -- constants -- e.g. a countdown's own `0` check -- is exactly
        -- as native-shadow-eligible as one read by an `ROp`/`RCmpCase`
        -- operand). Both branches below must render `sc` per its own
        -- current `Rep`, not assume Boxed unconditionally.
        scRep <- repOfLocal sc
        case integerSwitch alts of
            True => do
                tmpint <- getNewVarThatWillNotBeFreedAtEndOfBlock
                extractExpr <- the (Core String) $ case scRep of
                     RNative ty => rcVarToNativeC ty sc
                     RInlineNative ty => rcVarToNativeC ty sc
                     RBoxed => pure $ case alts of
                                           (MkRConstAlt c0 _ :: _) => extractIntExpr c0 sc'
                                           [] => "idris2rc2_extractInt(\{sc'})"
                emit emptyFC "int64_t \{tmpint} = \{extractExpr};"
                emitAltChain resolvedSink
                    (\(MkRConstAlt c _) => pure "\{tmpint} == \{const2Integer c 0}")
                    (\(MkRConstAlt _ body) => branchBody resolvedSink body tailPosition)
                    defaultAction
                    alts

            False =>
                emitAltChain resolvedSink
                    (\(MkRConstAlt c _) => case c of
                        Str x => pure "! strcmp(\{cStringQuoted x}, ((IDRIS2RC2_String *)\{sc'})->str)"
                        Db  x => case scRep of
                                      RNative DoubleType => (\e => "\{e} == \{show x}") <$> rcVarToNativeC DoubleType sc
                                      RInlineNative DoubleType => (\e => "\{e} == \{show x}") <$> rcVarToNativeC DoubleType sc
                                      _ => pure "((IDRIS2RC2_Double *)\{sc'})->v == \{show x}"
                        x => throw $ InternalError "[rc2] RConstCase : unsupported type. \{show fc} \{show x}")
                    (\(MkRConstAlt _ body) => branchBody resolvedSink body tailPosition)
                    defaultAction
                    alts

    ||| Declare (and initialise) one `RLoop` loop param -- unless
    ||| `initVal` already directly *is* `paramId`'s own value, under its
    ||| own C name, with the matching `RBoxed` representation (the
    ||| common case for a loop whose params simply reuse the enclosing
    ||| function's own top-level args unchanged, see
    ||| `Compiler.RC2.Loop`'s own `applyLoop`) -- in which case there is
    ||| nothing to declare at all: `var_\{paramId}` already exists,
    ||| already holds exactly this value, as a C function parameter.
    ||| Redeclaring it under the same name would be a C redeclaration
    ||| error, not just wasted work. Either way, `paramId`'s own `Rep` is
    ||| recorded in `RepMap` so later reads (native or boxed) render
    ||| correctly.
    |||
    ||| A genuinely fresh loop param (a native shadow -- see
    ||| `Compiler.RC2.Loop`'s own `applyLoop`, the only other case this
    ||| ever arises) reads `initVal` -- always one of the enclosing
    ||| function's own top-level args -- directly via
    ||| `rcVarToNativeC`/`rcVarToBoxedC` rather than going through
    ||| `declareLet`/`declareNative`: those expect an ANF-shaped
    ||| computation recipe (`ROp`/`RPrimVal`/...) to evaluate, not a
    ||| bare existing-local read, which `emitNativeValue` has no case
    ||| for.
    |||
    ||| `inPrologueDrop`: whether `initVal` is a member of the enclosing
    ||| `RLoop`'s own `prologueDrop` (see its own doc comment in
    ||| RCExp.idr) -- `Compiler.RC2.Loop`'s own `applyLoop` already
    ||| decided, once, whether this exact shadowed param's own original
    ||| is genuinely Boxed here: true unless `Compiler.RC2.DualABI` later
    ||| promoted this very parameter at the enclosing worker's own
    ||| signature (see its own module note), in which case
    ||| `Compiler.RC2.Loop`'s own `stripOwnership` -- called by DualABI's
    ||| `synthesizeWorker` over the whole worker body -- already filtered
    ||| this `initVal` back out of `prologueDrop` for us. Membership here
    ||| now drives two things this function used to independently
    ||| re-derive via a `repOfLocal` lookup on every call:
    |||
    ||| * The native unboxing is guarded by a runtime NULL check on
    |||   `initVal`'s own variable, but only when `inPrologueDrop`: an
    |||   *ordinary* function's own native-eligible argument is never
    |||   actually NULL (Int/Int64/Bits64/Double always genuinely
    |||   allocate or hit the small-value cache, never a bare `NULL`),
    |||   but a top-level parameter of one of Compiler.RC2.MutualLoop's
    |||   own merged functions can be -- its unused trailing "slots" are
    |||   padded with `RCNull`/C `NULL` by callers that don't have that
    |||   many arguments of their own (see `buildGroup`'s own `padded`),
    |||   and this parameter can still end up native-shadowed if *some
    |||   other* member of the same merged group reads its own
    |||   same-position argument natively -- Compiler.RC2.Loop has no
    |||   visibility into MutualLoop's own padding at all, so it can't
    |||   exclude this case from eligibility; unboxing unconditionally
    |||   here would dereference that NULL through `nativeUnbox`'s
    |||   runtime accessor, a real crash this exact pattern used to hit
    |||   before this guard existed. A worker-promoted parameter is never
    |||   actually NULL either (an `int64_t` argument, not a padded
    |||   pointer slot) -- comparing it against C `NULL` would in fact be
    |||   a compile error (`comparison between pointer and integer`),
    |||   not just a wasted check -- this exact mistake was caught by a
    |||   real build failure in `Test1Basics.idr`'s own `Main.loop`
    |||   (self-tail-recursive *and* dual-ABI-eligible) the first time a
    |||   worker wrapped a native-shadowed loop.
    ||| * This is also the loop param's last use anywhere in the whole
    |||   function -- Compiler.RC2.Loop's own rewrite has already
    |||   redirected every other reference to the fresh shadow -- so
    |||   `initVal` is dropped right here, once, whenever `inPrologueDrop`
    |||   (its caller, `emitLoopInto`, discharges the full `prologueDrop`
    |||   list as one `removeVars` after every param's own declaration).
    declareLoopParam : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> {auto fa : Ref LoopParams (List (Int, Rep))}
                     -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                     -> (inPrologueDrop : Bool) -> FC -> (paramId : Int) -> Rep -> (initVal : RCLocal) -> Core ()
    declareLoopParam _ fc paramId RBoxed initVal =
        if initVal == RCLoc paramId
           then update RepMap (insert paramId RBoxed)
           else declareLet fc paramId RBoxed (RV fc initVal)
    declareLoopParam inPrologueDrop fc paramId rep@(RNative ty) initVal = do
        update RepMap (insert paramId rep)
        valStr <- rcVarToNativeC ty initVal
        if inPrologueDrop
           then do
               let initValName = varName initVal
               emit fc "\{nativeCType ty} var_\{show paramId} = (\{initValName} == NULL) ? 0 : (\{valStr});"
           else emit fc "\{nativeCType ty} var_\{show paramId} = \{valStr};"
    -- A loop param is read again every iteration, so it never has the
    -- single-use shape `RInlineNative` requires -- Compiler.RC2.Loop
    -- never actually constructs this case -- kept total (falling back
    -- to a plain native declaration) rather than assumed unreachable.
    declareLoopParam inPrologueDrop fc paramId (RInlineNative ty) initVal =
        declareLoopParam inPrologueDrop fc paramId (RNative ty) initVal

    ||| Lower an `RLoop` (see its own doc comment in RCExp.idr): declare
    ||| each loop param (`declareLoopParam`, a no-op for the common
    ||| "reuses the enclosing function's own args unchanged" case), a
    ||| `loop:;` label, then `body` itself -- writing straight into
    ||| `sink`, same as every other branching construct this module
    ||| lowers (an `RLoopContinue` reachable from `body` in tail position
    ||| is intercepted by `emitInto`'s own `tryEmitLoopContinue` call
    ||| before ever reaching here again, so `body`'s own tail-position
    ||| value(s), if any survive, are genuinely this whole loop's exit
    ||| value), after each declared param's own `prologueDrop` membership
    ||| (see `declareLoopParam`'s own doc comment) is discharged as one
    ||| `removeVars` -- `Compiler.RC2.RC`'s `annotate`-decided ownership
    ||| facts (`postDrop` etc.) are always discharged individually, at
    ||| their own node; this one's just as much a precomputed IR fact
    ||| (`Compiler.RC2.Loop`'s own `applyLoop`), simply batched here since
    ||| every member's own drop point is this same spot regardless.
    emitLoopInto : {auto a : Ref ArgCounter Nat}
                 -> {auto oft : Ref OutfileText Output}
                 -> {auto il : Ref IndentLevel Nat}
                 -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                 -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                 -> {auto r : Ref RepMap (SortedMap Int Rep)}
                 -> {auto lm : Ref InlineMap (SortedMap Int String)}
                 -> {auto fa : Ref LoopParams (List (Int, Rep))}
                 -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                 -> Sink -> TailPositionStatus -> FC -> List (Int, Rep) -> List RCLocal -> (prologueDrop : List RCLocal) -> RCExp -> Core ()
    emitLoopInto sink tailPosition fc loopParams initial prologueDrop body = do
        traverse_ (\((paramId, rep), initVal) =>
                       declareLoopParam (elem initVal prologueDrop) fc paramId rep initVal) (zip loopParams initial)
        removeVars (varName <$> prologueDrop)
        emit fc "loop:;"
        put LoopParams loopParams
        emitInto emptyFC sink tailPosition body

    emitRC : {auto a : Ref ArgCounter Nat}
           -> {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
           -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
           -> {auto r : Ref RepMap (SortedMap Int Rep)}
           -> {auto lm : Ref InlineMap (SortedMap Int String)}
           -> {auto fa : Ref LoopParams (List (Int, Rep))}
           -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
           -> RCExp
           -> TailPositionStatus
           -> Core String

    emitRC (RV fc v) _ = rcVarToBoxedC v
    -- InTailPosition is unreachable here: emitInto's tryBuildClosureInto
    -- always intercepts an InTailPosition RAppName itself, building the
    -- closure straight into whichever Sink the caller handed down (see
    -- buildClosureIntoSink) -- so emitRC only ever sees RAppName in
    -- NotInTailPosition, where the call must actually be resolved
    -- (trampolined) right here rather than deferred as a closure.
    emitRC (RAppName fc _ n args) InTailPosition = throw $ InternalError "[rc2] RAppName (InTailPosition) reached emitRC directly (not intercepted by tryBuildClosureInto)"
    emitRC (RAppName fc _ n args) NotInTailPosition = do
        let nargs = length args
        if nargs > MaxExtractFunArgs
           then pure "idris2rc2_trampoline(\{!(makeClosure fc n args 0)})"
           else do
               argStrs <- traverse rcVarToBoxedC args
               pure "idris2rc2_trampoline(\{cName n}(\{concat $ intersperse ", " argStrs}))"

    -- Unreachable: emitInto's own dispatch always intercepts a leftover
    -- RAppNameRep itself (routing it to emitAppNameRepInto, which needs
    -- to discharge its own postDrop -- something emitRC's own "just
    -- return a Boxed expression string" contract has no room for --
    -- before ever falling back to a bare emitRC call). See
    -- emitAppNameRepInto's own doc comment for the full rendering this
    -- case used to do directly.
    emitRC (RAppNameRep fc n argReps retRep postDrop args) _ = throw $ InternalError "[rc2] RAppNameRep reached emitRC directly (not intercepted by emitInto)"

    -- Unreachable: emitInto's tryBuildClosureInto always intercepts
    -- RUnderApp itself, for any tailPosition -- a partial application is
    -- always a closure build, tail position or not (see
    -- buildClosureIntoSink).
    emitRC (RUnderApp fc n missing args) _ = throw $ InternalError "[rc2] RUnderApp reached emitRC directly (not intercepted by tryBuildClosureInto)"
    emitRC (RApp fc _ closure arg) tailPosition = do
       closureStr <- rcVarToBoxedC closure
       argStr <- rcVarToBoxedC arg
       pure $ (case tailPosition of
           NotInTailPosition => "idris2rc2_applyClosure"
           InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"

    -- Unreachable in practice, same reasoning as RLoopContinue's own
    -- case below: emitInto's tryBuildClosureInto always peels an RLet
    -- (declaring it via declareLet) before ever falling back to a bare
    -- emitRC call, so this construct itself should never reach emitRC
    -- directly. Failing loudly here (rather than silently re-declaring
    -- `var` a second time, or worse, skipping its declaration) is the
    -- safer choice.
    emitRC (RLet fc var rep value body) _ = throw $ InternalError "[rc2] RLet reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

    emitRC (RCon fc n coninfo tag args reuseFrom) _ = do
        if coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
            then pure "(NULL /* \{show n} */)"
            else do
                let createNewConstructor = " = idris2rc2_newConstructor("
                                 ++ (show (length args))
                                 ++ ", "  ++ maybe "-1" show tag  ++ ");"

                emit fc " // constructor \{show n}"
                -- `reuseFrom` (Compiler.RC2.Reuse) already decided
                -- whether this construction may claim an offered
                -- scrutinee's storage -- just lower it: reference the
                -- same deterministically-named reservation variable its
                -- offering RConAlt already declared (see reuseVarName),
                -- no lookup needed.
                constr <- the (Core String) $ case reuseFrom of
                    Just sc => do
                        let reuseVar = reuseVarName sc
                        emit fc "if (! \{reuseVar}) {"
                        increaseIndentation
                        emit fc $ reuseVar ++ createNewConstructor
                        decreaseIndentation
                        emit fc "}"
                        pure reuseVar
                    Nothing => do
                        let constr = "constructor_\{!(getNextCounter)}"
                        emit fc $ "IDRIS2RC2_Constructor* " ++ constr ++ createNewConstructor
                        when (Nothing == tag) $ emit fc "\{constr}->name = idris2rc2_constr_\{cName n};"
                        pure constr
                let arglist = "\{constr}->args"
                _ <- foldlC (\k, v => do
                    vStr <- rcVarToBoxedC v
                    emit EmptyFC $ "\{arglist}[\{show k}] = \{vStr};"
                    pure (S k)) 0 args
                pure "(IDRIS2RC2_Value*)\{constr}"

    emitRC (ROp fc _ op args postDrop) _ = do
        -- Reached only when Compiler.RC2.Types decided this op's result
        -- stays Boxed (comparisons, or a non-numeric op) -- operands may
        -- still individually be native locals (e.g. a comparison over an
        -- earlier native arithmetic chain), hence the Rep-aware boxing
        -- (boxOpArg, which also names and tracks any fresh box it has to
        -- fabricate for a Native operand, so it can be freed below).
        argsWithFresh <- rc2traverseVect (boxOpArg fc) args
        let argStrs = map fst argsWithFresh
        let resultVar = "primVar_" ++ !(getNextCounter)
        emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = " ++ cOp op argStrs ++ ";"
        -- `postDrop` (Compiler.RC2.RC's `annotate`) already lists exactly
        -- which *existing* Boxed operand locals need dropping now that
        -- this op is done reading them -- just lower it, no re-deriving
        -- here. Separately, any ephemeral box `boxOpArg` had to fabricate
        -- for a Native operand is dropped too -- `annotate` runs before
        -- `Compiler.RC2.Loop`'s native-shadow promotion ever decides a
        -- local is Native, so it can't have known about these.
        removeVars $ map varName postDrop
        removeVars $ mapMaybe snd (toList argsWithFresh)
        pure resultVar

    emitRC (RExtPrim fc _ p args) _ = do
        -- prim__getField/prim__setField never reach here -- Compiler.RC2.RC's
        -- own `normalize` (Phase 1) converts them straight into
        -- RStructGet/RStructSet, handled by their own cases below (see
        -- doc/c-struct-support.md's "Design" section for why).
        let prims : List String =
            ["prim__newIORef", "prim__readIORef", "prim__writeIORef", "prim__newArray",
             "prim__arrayGet", "prim__arraySet",
             "prim__os", "prim__codegen", "prim__onCollect", "prim__onCollectAny" ]
        case p of
            NS _ (UN (Basic pn)) =>
               unless (elem pn prims) $ throw $ InternalError $ "[rc2] Unknown primitive: " ++ cName p
            _ => throw $ InternalError $ "[rc2] Unknown primitive: " ++ cName p
        emit fc $ "// call to external primitive " ++ cName p
        -- ext-prim args are used owned/as-is (see RC.idr's module note on
        -- RExtPrim); box any that happen to be native locals first.
        argStrs <- traverse rcVarToBoxedC args
        pure $ "idris2rc2_\{cName p}("++ showSep ", " argStrs ++")"

    -- Part D (doc/c-struct-support.md's "Design" section): resolve
    -- structName/fieldName against StructDefs (Part B/C), then render
    -- a plain C pointer dereference. Neither structVar (here) nor
    -- value (RStructSet below) is ever duplicated to get here --
    -- postDrop only ever means "this was this operand's own last use"
    -- (Compiler.RC2.RC's dropIfLastUse), never "drop after a dup", so
    -- this only ever discharges it, never inserts one.
    emitRC (RStructGet fc structVar sn fn postDrop) _ = do
        structDefs <- get StructDefs
        let Just flds = lookup sn structDefs
            | Nothing => throw $ InternalError "[rc2] RStructGet: unknown struct \{sn}"
        let Just ty = lookup fn flds
            | Nothing => throw $ InternalError "[rc2] RStructGet: unknown field \{fn} of struct \{sn}"
        ptrBoxed <- rcVarToBoxedC structVar
        let ptrC = extractValue CLangC CFPtr ptrBoxed
        let resultVar = "primVar_" ++ !(getNextCounter)
        emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = "
                    ++ packCFType ty ("((\{sn}*)\{ptrC})->\{fn}") ++ ";"
        removeVars $ map varName postDrop
        pure resultVar

    emitRC (RStructSet fc structVar sn fn value postDrop) _ = do
        structDefs <- get StructDefs
        let Just flds = lookup sn structDefs
            | Nothing => throw $ InternalError "[rc2] RStructSet: unknown struct \{sn}"
        let Just ty = lookup fn flds
            | Nothing => throw $ InternalError "[rc2] RStructSet: unknown field \{fn} of struct \{sn}"
        ptrBoxed <- rcVarToBoxedC structVar
        let ptrC = extractValue CLangC CFPtr ptrBoxed
        valBoxed <- rcVarToBoxedC value
        let valC = extractValue CLangC ty valBoxed
        emit fc $ "((\{sn}*)\{ptrC})->\{fn} = \{valC};"
        removeVars $ map varName postDrop
        pure "((IDRIS2RC2_Value *)NULL)"

    -- Unreachable in practice, same reasoning as RLet's own case above:
    -- emitInto's dispatch always intercepts a leftover RCmpCase/
    -- RConCase/RConstCase itself (routing it to emitCmpCaseInto/
    -- emitConCaseInto/emitConstCaseInto's Sink-aware handling) before
    -- ever falling back to a bare emitRC call. Failing loudly here is
    -- the safer choice: reaching this would mean every branch just
    -- silently reverted to a throwaway switchReturnVar, undoing the
    -- point of that dispatch without any other visible symptom.
    emitRC (RCmpCase fc op args postDrop whenTrue whenFalse) _ = throw $ InternalError "[rc2] RCmpCase reached emitRC directly (not intercepted by emitInto)"
    emitRC (RConCase fc sc alts mDef) _ = throw $ InternalError "[rc2] RConCase reached emitRC directly (not intercepted by emitInto)"
    emitRC (RConstCase fc sc alts def) _ = throw $ InternalError "[rc2] RConstCase reached emitRC directly (not intercepted by emitInto)"

    emitRC (RPrimVal fc (I x)) tailPosition = emitRC (RPrimVal fc (I64 $ cast x)) tailPosition
    emitRC (RPrimVal fc c) _ = boxedConstExpr c

    emitRC (RErased fc) _ = pure "NULL"
    emitRC (RCrash fc x) _ = pure "(NULL /* CRASH */)"
    -- Unreachable in practice: emitInto always tries tryEmitLoopContinue
    -- first, which intercepts every RLoopContinue (however deeply
    -- RDup/RDrop/RFree/RLet-wrapped) before it could ever reach a bare
    -- emitRC call -- see RLoopContinue's own doc comment. Unlike
    -- varName's RCConst case, failing loudly here (rather than returning
    -- some placeholder string) is the safer choice: reaching this would
    -- mean the goto-loop was never emitted at all, silently turning a
    -- loop into infinite recursion.
    emitRC (RLoopContinue fc _ _) _ = throw $ InternalError "[rc2] RLoopContinue reached emitRC directly (not intercepted by tryEmitLoopContinue)"
    -- Unreachable in practice, same reasoning as RCmpCase/RConCase/
    -- RConstCase's own cases below: emitInto's dispatch always
    -- intercepts a leftover RLoop itself (routing it to
    -- emitLoopInto's Sink-aware handling) before ever falling back to
    -- a bare emitRC call.
    emitRC (RLoop fc loopParams initial prologueDrop body) _ = throw $ InternalError "[rc2] RLoop reached emitRC directly (not intercepted by emitInto)"
    -- Unreachable in practice, same reasoning as RLet's own case above:
    -- emitInto's tryBuildClosureInto always peels these wrapper nodes
    -- (emitting their own dup/drop/free/reuse-release side effect) on
    -- the way down before ever falling back to a bare emitRC call.
    emitRC (RDrop fc locs cont) _ = throw $ InternalError "[rc2] RDrop reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RDup fc loc cont) _ = throw $ InternalError "[rc2] RDup reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RFree fc loc cont) _ = throw $ InternalError "[rc2] RFree reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RReleaseReuse fc loc cont) _ = throw $ InternalError "[rc2] RReleaseReuse reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RReuseOffer fc sc dupOnShared dropOnUnique cont) _ = throw $ InternalError "[rc2] RReuseOffer reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

    ||| The raw C expression for a value Compiler.RC2.Types has decided is
    ||| Native ty -- an `RLet`'s own tail is always an `ROp`/`RPrimVal`
    ||| here (Phase 1's own ANF normalisation guarantees it); a bare
    ||| `RV` is reachable too, but only via `emitInto`'s own native-
    ||| `SinkReturn` dispatch (`Compiler.RC2.DualABI`'s own Stage 3b),
    ||| never via an `RLet`.
    -- Returns the native C expression for `e` together with any Boxed
    -- locals `e`'s own tail op reads but doesn't own a further use of --
    -- Compiler.RC2.RC's `annotate` already decided those are "consumed"
    -- here (see splitBorrows), so they need exactly one drop, but not
    -- before the expression string is actually *read* by whichever
    -- statement the caller embeds it in. The caller (either emitRC's
    -- RLet case below, or this function's own RLet case) is what emits
    -- that statement, so it -- not this function -- is what must emit the
    -- drop, and only *after* doing so: emitting it here unconditionally
    -- would run the drop before the value it reads from is ever used,
    -- freeing it out from under its own extraction (a real regression an
    -- earlier version of this fix hit for heap-allocated 64-bit types).
    emitNativeValue : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> {auto fa : Ref LoopParams (List (Int, Rep))}
                     -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                     -> PrimType -> RCExp -> Core (String, List RCLocal)
    -- A bare local read -- unreachable before Stage 3b (declareNative/
    -- inlineNative's own RLet callers only ever see an ROp/RPrimVal
    -- tail here, since Phase 1's own ANF normalisation binds every
    -- non-trivial operand to its own let). Compiler.RC2.DualABI's own
    -- native-return tail-value walk (`tailValueReps`) can genuinely
    -- find a bare `RV` at a real tail position instead -- e.g. a
    -- parameter, or an already-native intermediate, returned unchanged
    -- -- so this case is reachable now. No pending drop: `v`'s own Rep
    -- is already known native by construction here (see
    -- `tailValueReps`'s own seeding), so there's nothing Boxed being
    -- read at all, unlike the ROp case below.
    emitNativeValue ty (RV fc v) = do
        valStr <- rcVarToNativeC ty v
        pure (valStr, [])
    -- A direct worker call whose own result Compiler.RC2.DualABI's own
    -- Stage 4 promoted an enclosing RLet's Rep to match (see
    -- `applyCallSiteRewriteBody`'s own doc comment: "does the rest of
    -- this let's own scope read the call's result natively, skip the
    -- box-then-immediately-unbox round trip entirely"). `postDrop` here
    -- is exactly `RAppNameRep`'s own field (see its own doc comment in
    -- RCExp.idr) -- any Boxed-sourced *argument* this call reads
    -- natively, handed back for the same reason ROp's own postDrop
    -- above is: our caller (declareNative) hasn't emitted the statement
    -- that actually performs the read yet. `retRep` is expected to
    -- already be `RNative ty`/`RInlineNative ty` exactly -- Stage 4
    -- only ever promotes an RLet's own Rep when the worker being called
    -- already returns natively at this same `ty` (`nativePromotionFor`
    -- checks this before ever constructing this shape) -- a Boxed
    -- `retRep` reaching here would mean that invariant broke somewhere,
    -- so it's an internal error, not a case to render around.
    emitNativeValue ty (RAppNameRep fc n argReps retRep postDrop args) = do
        -- No `nargs` cap here -- same reasoning as `emitAppNameRepInto`'s
        -- own doc comment: always a plain, direct positional call to a
        -- dual-ABI worker, never dispatched through the closure
        -- machinery `MaxExtractFunArgs` governs.
        argStrs <- traverse (\(rep, v) => case rep of
                                 RNative t => rcVarToNativeC t v
                                 RInlineNative t => rcVarToNativeC t v
                                 RBoxed => rcVarToBoxedC v) (zip argReps args)
        let call = "\{cName n}(\{concat $ intersperse ", " argStrs})"
        case retRep of
             RBoxed => throw $ InternalError "[rc2] emitNativeValue: RAppNameRep with Boxed retRep reached a native context"
             RNative _ => pure (call, postDrop)
             RInlineNative _ => pure (call, postDrop)
    emitNativeValue ty (ROp fc _ op args postDrop) = do
        argStrs <- rc2traverseVect (\v => rcVarToNativeC (opArgTyFor ty op) v) args
        -- `postDrop` is exactly the Boxed operands this op needs dropped
        -- (Compiler.RC2.RC's `annotate` already decided this, same as
        -- emitRC's boxed-ROp case) -- a native-result op still reads
        -- them (via rcVarToNativeC's unboxing above) and owes them that
        -- same cleanup, we just can't emit it *here*: unlike emitRC, our
        -- caller hasn't necessarily emitted the statement that actually
        -- performs the read yet (we only return an inline expression
        -- string), so dropping now could run before that read happens.
        -- Hand `postDrop` back so whoever *does* emit that statement can
        -- drop right after it -- see this function's own doc comment.
        pure (nativeOpExpr op argStrs, postDrop)
    emitNativeValue ty (RPrimVal fc c) = pure (nativeLitExpr c, [])
    -- RC.idr's own ANF-normalisation wraps any non-trivial operand (e.g. a
    -- literal) in a synthetic RLet before the "real" ROp/RPrimVal --
    -- declare it (native or boxed, whichever Compiler.RC2.Types decided)
    -- and keep unwinding to find the tail expression. This synthetic
    -- let's own value gets its pending-drop list (if any) discharged
    -- right here, immediately after its own declaration statement; only
    -- `body`'s eventual tail-op pending list is returned onward.
    emitNativeValue ty (RLet fc var rep value body) = do
        declareLet fc var rep value
        emitNativeValue ty body
    -- A native-typed let's *value* can still legitimately be wrapped in
    -- RDup/RDrop/RFree: those govern its own boxed operands (e.g. `x + x`
    -- where `x` is a boxed parameter needs a dup before the add), which is
    -- an entirely separate concern from whether the op's *result* ends up
    -- native. Just lower the wrapper and keep unwinding.
    emitNativeValue ty (RDup fc loc cont) = do
        dupVars [varName loc]
        emitNativeValue ty cont
    emitNativeValue ty (RFree fc loc cont) = do
        freeVars [varName loc]
        emitNativeValue ty cont
    emitNativeValue ty (RDrop fc locs cont) = do
        -- locs is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> locs)
        emitNativeValue ty cont
    emitNativeValue ty (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        emitNativeValue ty cont
    emitNativeValue ty e = throw $ InternalError "[rc2] internal: expected a native-producing expression"

addCommaToList : List String -> List String
addCommaToList [] = []
addCommaToList (x :: xs) = ("  " ++ x) :: map (", " ++) xs

createCFunctions : {auto c : Ref Ctxt Defs}
                -> {auto a : Ref ArgCounter Nat}
                -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                -> {auto f : Ref FunctionDefinitions (List String)}
                -> {auto oft : Ref OutfileText Output}
                -> {auto il : Ref IndentLevel Nat}
                -> {auto h : Ref HeaderFiles (SortedSet String)}
                -> {auto fl : Ref ForeignLibs (SortedSet String)}
                -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
                -> {auto fw : Ref FFIWorkers (SortedMap Name (Name, List Rep, Rep))}
                -> Name
                -> RCDef
                -> Core ()
createCFunctions n (MkRCFun args retRep isWorker body) = do
    -- `args`/`retRep` are dual-ABI groundwork (see RCExp.idr's own doc
    -- comment on MkRCFun, and Compiler.RC2.DualABI's own module note).
    -- Both can now genuinely hold `RNative`/`RInlineNative` entries (a
    -- dual-ABI worker's own eligible parameters/return,
    -- Compiler.RC2.DualABI's own Stage 3a+3b), so both this function's
    -- own C declaration (its return type here, each parameter's own
    -- type just below) and RepMap registration (so *reads* within
    -- `body` render correctly -- rcVarToNativeC/rcVarToBoxedC are
    -- already fully Rep-aware, they just need this to actually find
    -- the Rep) must follow suit. `retRep` is threaded into `emitInto`
    -- below via `SinkReturn retRep`, not consulted directly here
    -- otherwise -- see `Sink`'s own doc comment for how that then
    -- reaches every tail leaf, including inside nested
    -- RCmpCase/RConCase/RConstCase/RLoop, uniformly.
    let argIds = map fst args
    let nargs = length argIds
    let declareParam : (Int, Rep) -> String
        declareParam (i, RBoxed) = "  IDRIS2RC2_Value * var_" ++ show i
        declareParam (i, RNative ty) = "  " ++ nativeCType ty ++ " var_" ++ show i
        declareParam (i, RInlineNative ty) = "  " ++ nativeCType ty ++ " var_" ++ show i
    let retTypeStr : String = case retRep of
                                    RBoxed => "IDRIS2RC2_Value *"
                                    RNative ty => nativeCType ty ++ " "
                                    RInlineNative ty => nativeCType ty ++ " "
    -- `MaxExtractFunArgs`'s own `var_arglist[]` fallback only exists to
    -- match `support/rc2/runtime.c`'s closure-dispatch function-pointer
    -- types (see that constant's own doc comment) -- a dual-ABI
    -- *worker* (`isWorker = True`) is never stored in a `Closure` and
    -- so never needs to satisfy that convention, regardless of its own
    -- argument count: it keeps individually-typed positional
    -- parameters (native where eligible) no matter how wide it is.
    let useVarArglist = not isWorker && nargs > MaxExtractFunArgs
    let fn = "\{retTypeStr}\{cName !(getFullName n)}"
            ++ (if nargs == 0 then "(void)"
               else if useVarArglist then "(IDRIS2RC2_Value *var_arglist[\{show nargs}])"
               else ("\n(\n" ++ (showSep "\n" $ addCommaToList (map declareParam args))) ++ "\n)")
    update FunctionDefinitions $ \otherDefs => (fn ++ ";\n") :: otherDefs

    emit EmptyFC fn
    emit EmptyFC "{"
    increaseIndentation
    when useVarArglist $ do
      _ <- foldlC (\i, j => do
         emit EmptyFC "IDRIS2RC2_Value *var_\{show j} = var_arglist[\{show i}];"
         pure $ i + 1) 0 argIds
      pure ()
    -- Seeded with this function's own top-level parameters (their Rep
    -- is already decided, on `args` itself); populated further,
    -- incrementally, as each RLet is emitted below (its Rep is
    -- already decided and stored on the node by Compiler.RC2.RC; this map
    -- just lets *use* sites, which only have a bare RCLocal id, look it
    -- back up).
    _ <- newRef RepMap (SortedMap.fromList args)
    -- Populated instead of RepMap+a declaration for any RLet whose value
    -- is a bare literal -- see InlineMap's own comment.
    _ <- newRef InlineMap (the (SortedMap Int String) empty)
    -- Empty until `body` actually contains an `RLoop` -- `emitLoopInto`
    -- overwrites this the moment it enters one; `RLoopContinue` can only
    -- ever be reachable *inside* an `RLoop`'s own body by construction
    -- (Compiler.RC2.Loop's own `applyLoop` never produces one without
    -- also wrapping the body in the matching `RLoop`), so it's never
    -- read while this is still empty.
    _ <- newRef LoopParams (the (List (Int, Rep)) [])
    -- emitInto's own tryEmitLoopContinue-first / RLoop-dispatch protocol
    -- handles a loop body correctly on its own (declare params, `loop:;`,
    -- goto, no return); for anything else, SinkReturn makes every
    -- reachable tail leaf -- including inside a nested RCmpCase/
    -- RConCase/RConstCase -- emit its own `return` directly, no
    -- intermediate switchReturnVar anywhere.
    emitInto EmptyFC (SinkReturn retRep) InTailPosition body
    decreaseIndentation
    emit EmptyFC  "}\n"
    emit EmptyFC  ""
    pure ()

createCFunctions n (MkRCCon Nothing _ _) = do
  let n' = cName n
  update FunctionDefinitions $ \otherDefs => "char const idris2rc2_constr_\{n'}[];" :: otherDefs
  emit EmptyFC "char const idris2rc2_constr_\{n'}[] = \{cStringQuoted $ show n};"
  pure ()

createCFunctions n (MkRCCon tag arity nt) = do
  emit EmptyFC $ ( "// \{show n} Constructor tag " ++ show tag ++ " arity " ++ show arity)

createCFunctions n (MkRCForeign ccs fargs ret) = do
  case parseCC ffiTags ccs of
      Just (lang, fctForeignName :: extLibOpts) => do
          let isStandardFFI = elem lang ffiTags
          let cLang = if lang == "RefC" then CLangRefC else CLangC
          let fctName = if isStandardFFI
                           then UN $ Basic $ fctForeignName
                           else NS (mkNamespace lang) n
          if isStandardFFI
             then case extLibOpts of
                      [lib, header] => do update HeaderFiles $ insert header
                                          maybe (pure ()) (\l => update ForeignLibs $ insert l) (linkLibName lib)
                      [lib] => maybe (pure ()) (\l => update ForeignLibs $ insert l) (linkLibName lib)
                      _ => pure ()
             else emit EmptyFC $ additionalFFIStub fctName fargs ret
          let fnDef = "IDRIS2RC2_Value *" ++ (cName n) ++ "(" ++ showSep ", " (replicate (length fargs) "IDRIS2RC2_Value *") ++ ");"
          update FunctionDefinitions $ \otherDefs => (fnDef ++ "\n") :: otherDefs
          typeVarNameArgList <- createFFIArgList fargs

          emitFDef n typeVarNameArgList
          emit EmptyFC "{"
          increaseIndentation
          emit EmptyFC $ " // ffi call to " ++ cName fctName
          let removeVarsArgList = removeVars ((\(_, varName, _) => varName) <$> typeVarNameArgList)
          case ret of
              CFIORes CFUnit => do
                  emit EmptyFC $ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC "return NULL;"
              CFIORes ret => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  -- Pack retVal before dropping the args: a CFString/CFBuffer
                  -- retVal may alias memory owned by one of those args (e.g.
                  -- a C function that just returns a pointer it was handed),
                  -- so packCFType must read through it while the arg (and
                  -- whatever finalizer freeing that memory) is still alive.
                  emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"
                  removeVarsArgList
                  emit EmptyFC "return packedRet;"
              _ => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) typeVarNameArgList)
                              ++ ");"
                  -- Same reasoning as the CFIORes ret branch above.
                  emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"
                  removeVarsArgList
                  emit EmptyFC "return packedRet;"

          decreaseIndentation
          emit EmptyFC "}"
          ffiWorkers <- get FFIWorkers
          case lookup n ffiWorkers of
               Nothing => pure ()
               Just (workerName, argReps, retRep) =>
                   emitFFIWorker cLang fctName workerName argReps retRep fargs ret
      _ => throw $ InternalError "[rc2] FFI not found for \{cName n}"
  where
    ||| Turn a `%foreign` lib field ("libcurl", "libc 6", ...) into the
    ||| bare name a linker's own `-l` flag needs: drop the "lib" prefix
    ||| (this project's own FFI convention -- matches how Chez's own
    ||| `loadLib` treats the same field) and any trailing " <version>"
    ||| hint (a Chez-only dynamic-load version pin, meaningless to a
    ||| static linker). `Nothing` for a lib field that doesn't start
    ||| with "lib" at all -- not expected in practice, left unlinked
    ||| rather than guessed at.
    linkLibName : String -> Maybe String
    linkLibName lib =
        let base = fst (Data.String.break isSpace lib)
        in if isPrefixOf "lib" base
              then Just (substr 3 (length base `minus` 3) base)
              else Nothing

    getArgsNrList : List ty -> Nat -> List Nat
    getArgsNrList [] _ = []
    getArgsNrList (x :: xs) k = k :: getArgsNrList xs (S k)

    varNamesFromList : List ty -> Nat -> List String
    varNamesFromList str k = map (("var_" ++) . show) (getArgsNrList str k)

    createFFIArgList : List CFType
                    -> Core $ List (String, String, CFType)
    createFFIArgList cftypeList = do
        let sList = map cTypeOfCFType cftypeList
        let varList = varNamesFromList cftypeList 1
        pure $ zip3 sList varList cftypeList

    emitFDef : (funcName:Name)
            -> (arglist:List (String, String, CFType))
            -> Core ()
    emitFDef funcName [] = emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName ++ "(void)"
    emitFDef funcName ((varType, varName, varCFType) :: xs) = do
        emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName
        emit EmptyFC "("
        increaseIndentation
        emit EmptyFC $ "  IDRIS2RC2_Value *" ++ varName
        traverse_ (\(varType, varName, varCFType) => emit EmptyFC $ ", IDRIS2RC2_Value *" ++ varName) xs
        decreaseIndentation
        emit EmptyFC ")"

    discardLastArgument : List ty -> List ty
    discardLastArgument [] = []
    discardLastArgument xs@(_ :: _) = init xs

    ||| `CFChar`-only cast a native argument needs at its `fctName` call
    ||| site: `nativeCType CharType` (this worker's own `uint32_t`
    ||| parameter) disagrees with `cTypeOfCFType CFChar` (`fctName`'s own
    ||| `char`), the one `CFType` where those two differ.
    nativeCharArgExpr : String -> String
    nativeCharArgExpr vn = "(char)" ++ vn

    ||| Widens a `CFChar`-returning `fctName`'s own `char` result back up
    ||| to this worker's own `uint32_t` return type. Goes through
    ||| `unsigned char` first, not a direct `(uint32_t)` cast, so a
    ||| `char` whose top bit is set zero-extends instead of sign-
    ||| extending into three bogus `0xff` bytes -- the same
    ||| `(unsigned char)` step every other `Char`-producing site in this
    ||| runtime already takes (e.g. `idris2rc2_strings.c`'s
    ||| `idris2rc2_mkChar((unsigned char)s[idx])`).
    nativeCharRetExpr : String -> String
    nativeCharRetExpr retVar = "(uint32_t)(unsigned char)" ++ retVar

    ||| The dual-ABI FFI worker itself (`Compiler.RC2.DualABI`'s Stage
    ||| 3c already decided `workerName`/`argReps`/`retRep`; this just
    ||| renders it) -- a second C function alongside the always-emitted,
    ||| always-Boxed wrapper above, one `Rep`-eligible position at a
    ||| time: a `RNative`/`RInlineNative` position's own declared C type
    ||| is already `nativeCType`, textually identical to `cTypeOfCFType`
    ||| for every `CFType` `Compiler.RC2.Types.cfTypeNative` ever maps to
    ||| one *except* `CFChar`, cast explicitly instead
    ||| (`nativeCharArgExpr`/`nativeCharRetExpr` above) -- same
    ||| narrowing/zero-extension the always-Boxed wrapper already gets
    ||| via `idris2rc2_to_char`/`idris2rc2_mkChar`, just paid as a
    ||| register-width cast here rather than a box/unbox round trip.
    ||| Every other position renders exactly like the wrapper's own
    ||| (`extractValue`/`packCFType`), so a mixed signature costs nothing
    ||| extra at the positions that were never eligible to begin with.
    emitFFIWorker : CLang -> Name -> Name -> List Rep -> Rep -> List CFType -> CFType -> Core ()
    emitFFIWorker cLang fctName workerName argReps retRep fargs ret = do
        let varNames = varNamesFromList fargs 1
            paramsInfo = zip3 argReps varNames fargs
            declareParam : (Rep, String, CFType) -> String
            declareParam (RBoxed, vn, _) = "  IDRIS2RC2_Value *" ++ vn
            declareParam (RNative ty, vn, _) = "  " ++ nativeCType ty ++ " " ++ vn
            declareParam (RInlineNative ty, vn, _) = "  " ++ nativeCType ty ++ " " ++ vn
            retTypeStr : String
            retTypeStr = case retRep of
                              RBoxed => "IDRIS2RC2_Value *"
                              RNative ty => nativeCType ty ++ " "
                              RInlineNative ty => nativeCType ty ++ " "
            wfn = "\{retTypeStr}\{cName workerName}"
                    ++ (if null paramsInfo then "(void)"
                       else ("\n(\n" ++ (showSep "\n" $ addCommaToList (map declareParam paramsInfo))) ++ "\n)")
        update FunctionDefinitions $ \otherDefs => (wfn ++ ";\n") :: otherDefs
        emit EmptyFC wfn
        emit EmptyFC "{"
        increaseIndentation
        emit EmptyFC $ " // dual-ABI FFI worker for " ++ cName fctName
        let argExprFor : (Rep, String, CFType) -> String
            argExprFor (RBoxed, vn, vt) = extractValue cLang vt vn
            argExprFor (RNative _, vn, CFChar) = nativeCharArgExpr vn
            argExprFor (RInlineNative _, vn, CFChar) = nativeCharArgExpr vn
            argExprFor (RNative _, vn, _) = vn
            argExprFor (RInlineNative _, vn, _) = vn
            boxedVars : List String
            boxedVars = mapMaybe (\(r, vn, _) => case r of RBoxed => Just vn; _ => Nothing) paramsInfo
            finishNative : String -> Core ()
            finishNative retVar = do
                removeVars boxedVars
                emit EmptyFC "return \{retVar};"
            nativeRetExprFor : CFType -> String -> String
            nativeRetExprFor CFChar retVar = nativeCharRetExpr retVar
            nativeRetExprFor _      retVar = retVar
        case ret of
            CFIORes CFUnit => do
                emit EmptyFC $ cName fctName ++ "(" ++ showSep ", " (map argExprFor (discardLastArgument paramsInfo)) ++ ");"
                removeVars boxedVars
                emit EmptyFC "return NULL;"
            CFIORes ret' => do
                emit EmptyFC $ cTypeOfCFType ret' ++ " retVal = " ++ cName fctName
                            ++ "(" ++ showSep ", " (map argExprFor (discardLastArgument paramsInfo)) ++ ");"
                case retRep of
                     RBoxed => do
                         emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType ret' "retVal" ++ ";"
                         removeVars boxedVars
                         emit EmptyFC "return packedRet;"
                     _ => finishNative (nativeRetExprFor ret' "retVal")
            _ => do
                emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                            ++ "(" ++ showSep ", " (map argExprFor paramsInfo) ++ ");"
                case retRep of
                     RBoxed => do
                         emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"
                         removeVars boxedVars
                         emit EmptyFC "return packedRet;"
                     _ => finishNative (nativeRetExprFor ret "retVal")
        decreaseIndentation
        emit EmptyFC "}"

    additionalFFIStub : Name -> List CFType -> CFType -> String
    additionalFFIStub name argTypes (CFIORes retType) = additionalFFIStub name (discardLastArgument argTypes) retType
    additionalFFIStub name argTypes retType =
        cTypeOfCFType retType ++
        " (*" ++ cName name ++ ")(" ++
        (concat $ intersperse ", " $ map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"

createCFunctions n (MkRCError exp) = throw $ InternalError "[rc2] Error with expression"

header : {auto f : Ref FunctionDefinitions (List String)}
      -> {auto o : Ref OutfileText Output}
      -> {auto il : Ref IndentLevel Nat}
      -> {auto h : Ref HeaderFiles (SortedSet String)}
      -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
      -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
      -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
      -> {auto ir : Ref InjectedRuntime String}
      -> Core ()
header = do
    let initLines = """
      #include <idris2rc2_runtime.h>
      /* \{ generatedString "rc2" } */

      """
    let headerFiles = Prelude.toList !(get HeaderFiles)
    fns <- get FunctionDefinitions
    -- Part C (doc/c-struct-support.md's "Design" section): one real C
    -- `typedef struct` per entry in `StructDefs` (Part B), so
    -- RStructGet/RStructSet's own `((name*)ptr)->field` rendering
    -- (Part D) has something to compile against -- emitted here,
    -- ahead of every function definition, since C needs the type
    -- declared before any use.
    structDefs <- get StructDefs
    injectedRuntime <- get InjectedRuntime
    update OutfileText $ appendL $
        [initLines] ++
        map (\h => "#include <\{h}>\n") headerFiles ++
        (if injectedRuntime == ""
            then []
            else ["\n// %cg rc2 extraRuntime=<path> / inlineRuntime=<code>\n", injectedRuntime, "\n"]) ++
        ["\n// struct definitions"] ++
        map (uncurry genStructDef) (SortedMap.toList structDefs) ++
        ["\n// function definitions"] ++
        fns ++
        ["\n// constant value definitions"] ++
        map (uncurry genConstant) (SortedMap.toList !(get ConstDef)) ++
        ["\n// constant constructor value definitions"] ++
        snd !(get ConstConDef)
  where
    go : ConstDef -> String -> String -> String -> String
    go cdef ty tag v =
      "static IDRIS2RC2_\{ty} const \{constantName cdef}"
        ++ " = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_\{tag}), \{v} };"
    genConstant : Constant -> ConstDef -> String
    genConstant c cdef = case c of
      I x   => go cdef "Int64" "INT64" (showIntMin x)
      I64 x => go cdef "Int64" "INT64" (showInt64Min x)
      B64 x => go cdef "Bits64" "BITS64" "UINT64_C(\{show x})"
      Db x  => go cdef "Double" "DOUBLE" (show x)
      Str x => go cdef "String" "STRING" (cStringQuoted x)
      _ => "/* bad constant */"
    genStructDef : String -> List (String, CFType) -> String
    genStructDef name flds =
      "typedef struct { "
        ++ concat (map (\(fn, ty) => cTypeOfCFType ty ++ " " ++ fn ++ "; ") flds)
        ++ "} \{name};\n"

footer : {auto il : Ref IndentLevel Nat}
      -> {auto f : Ref OutfileText Output}
      -> {auto h : Ref HeaderFiles (SortedSet String)}
      -> Core ()
footer = do
    emit EmptyFC """

      // main function
      int main(int argc, char *argv[])
      {
          \{ ifThenElse (contains "idris_support.h" !(get HeaderFiles))
                        "idris2_setArgs(argc, argv);"
                        ""
          }
          IDRIS2RC2_Value *mainExprVal = __mainExpression_0();
          idris2rc2_trampoline(mainExprVal);
          return 0;
      }
      """

||| The distinct link-library names (already "lib"-prefix-stripped,
||| see `linkLibName`) every `MkRCForeign` def in the program named via
||| its own standard-FFI `%foreign` lib field -- for `Compiler.RC2.CC`
||| to turn into `-l<name>` flags at link time, so an external library
||| a program's own FFI bindings depend on doesn't need `IDRIS2_LDLIBS`
||| set by hand.
export
generateCSourceFile : {auto c : Ref Ctxt Defs}
                   -> SortedMap Name (Name, List Rep, Rep)
                   -> List (Name, RCDef)
                   -> (injectedRuntime : String)
                   -> (outn : String)
                   -> Core (List String)
generateCSourceFile ffiWorkers defs injectedRuntime outn =
  do _ <- newRef ArgCounter 0
     _ <- newRef FunctionDefinitions []
     _ <- newRef ConstDef Data.SortedMap.empty
     _ <- newRef ConstConDef (Data.SortedMap.empty, [])
     _ <- newRef OutfileText DList.Nil
     _ <- newRef HeaderFiles empty
     _ <- newRef ForeignLibs empty
     _ <- newRef IndentLevel 0
     _ <- newRef FFIWorkers ffiWorkers
     _ <- newRef InjectedRuntime injectedRuntime
     -- Part B (doc/c-struct-support.md's "Design" section): collect
     -- every CFStruct reachable from any MkRCForeign's own argument/
     -- return types, once, before any def is lowered -- so a
     -- getField/setField call site anywhere in the program can resolve
     -- its own struct name against a table that already knows about
     -- every struct declared anywhere, regardless of definition order.
     let structDefs = foldl (\acc, (_, d) => case d of
                                  MkRCForeign _ fargs ret =>
                                      foldl (flip collectStructDefs) (collectStructDefs ret acc) fargs
                                  _ => acc)
                             Data.SortedMap.empty defs
     _ <- newRef StructDefs structDefs
     traverse_ (uncurry createCFunctions) defs
     header
     footer
     fileContent <- get OutfileText
     -- Streams each already-generated line straight to a buffered file
     -- handle instead of first fastConcat-ing the whole file into one
     -- in-memory String (the old `writeFile outn code` above) -- avoids
     -- holding both the List String and its full concatenation in
     -- memory at once for large generated .c files.
     coreLift_ $ withFile outn WriteTruncate pure $ \h => do
         traverse_ (fPutStrLn h) (reify fileContent)
         pure (Right ())
     log "compiler.refc" 10 $ "Generated C file " ++ outn
     pure (Prelude.toList !(get ForeignLibs))
