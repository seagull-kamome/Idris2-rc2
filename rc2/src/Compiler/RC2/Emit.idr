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
import Compiler.RC2.Util

%default covering

||| The auto-implicit `Ref`s nearly every function in this module
||| threads through -- see each `Ref`'s own tag type (`ArgCounter`,
||| `OutfileText`, etc.) for what it tracks. `EmitDeps retTy` stands in
||| for the 9-line `{auto ...} -> ... -> {auto ...} ->` block a plain
||| function signature would otherwise repeat verbatim at every one of
||| this module's own definitions.
0 EmitDeps : Type -> Type
EmitDeps retTy = {auto a : Ref ArgCounter Nat}
              -> {auto oft : Ref OutfileText Output}
              -> {auto il : Ref IndentLevel Nat}
              -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
              -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
              -> {auto r : Ref RepMap (SortedMap Int Rep)}
              -> {auto lm : Ref InlineMap (SortedMap Int (String, List String))}
              -> {auto fa : Ref LoopParams (List (Int, Rep))}
              -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
              -> retTy

getArgsNrList : List ty -> Nat -> List Nat
getArgsNrList [] _ = []
getArgsNrList (x :: xs) k = k :: getArgsNrList xs (S k)

varNamesFromList : List ty -> Nat -> List String
varNamesFromList str k = map (("var_" ++) . show) (getArgsNrList str k)

discardLastArgument : List ty -> List ty
discardLastArgument [] = []
discardLastArgument xs@(_ :: _) = init xs

||| `CFChar`-only cast a native argument needs at a `%foreign` call
||| site: `nativeCType CharType` (this backend's own `uint32_t` native
||| Char representation) disagrees with `cTypeOfCFType CFChar`
||| (`char`), the one `CFType` where those two differ.
nativeCharArgExpr : String -> String
nativeCharArgExpr vn = "(char)" ++ vn

||| Widens a `CFChar`-returning `%foreign` call's own `char` result
||| back up to this backend's own native `uint32_t` Char
||| representation. Goes through `unsigned char` first, not a direct
||| `(uint32_t)` cast, so a `char` whose top bit is set zero-extends
||| instead of sign-extending into three bogus `0xff` bytes -- the same
||| `(unsigned char)` step every other `Char`-producing site in this
||| runtime already takes (e.g. `idris2rc2_strings.c`'s
||| `idris2rc2_mkChar((unsigned char)s[idx])`).
nativeCharRetExpr : String -> String
nativeCharRetExpr retVar = "(uint32_t)(unsigned char)" ++ retVar

||| `ret`'s own peeled type -- `CFIORes t`'s payload `t`, or `ret`
||| itself for a non-IO (pure) `%foreign` declaration. Mirrors
||| `Compiler.RC2.DualABI`'s own `peelIORes` -- kept as its own tiny
||| re-derivation here rather than shared across modules, same
||| reasoning as `RAppFFIInline`'s own doc comment in RCExp.idr gives
||| for not storing this on the IR node itself: cheap enough to
||| re-derive per use, including per module.
peelIORes : CFType -> CFType
peelIORes (CFIORes t) = t
peelIORes t = t

||| `(cLang, fctName)` for a `%foreign` declaration's own `ccs` tag
||| list. Shared by `emitGenericForeignWrapper` (which additionally
||| consults the same `parseCC` result for the library/header options
||| `extLibOpts` carries, and the always-Boxed wrapper's own emission)
||| and the new `emitAppFFIInlineInto`/`emitNativeValue`'s own
||| `RAppFFIInline` case below, which need only the resolved call
||| target itself -- no header/library registration of their own,
||| since the wrapper for the same declaration already did that once,
||| regardless of how many inline call sites end up calling this same
||| target.
resolveForeignTarget : List String -> Core (CLang, Name)
resolveForeignTarget ccs =
    case parseCC ffiTags ccs of
         Just (lang, fctForeignName :: _) =>
             pure ( if lang == "RefC" || lang == "RC2" then CLangRefC else CLangC
                  , UN $ Basic $ fctForeignName)
         _ => throw $ InternalError "[rc2] FFI not found for foreign declaration"

||| Marshal every one of `fargs`'s own positions, call `fctName`, and
||| produce the raw (un-packed, un-widened) C return-value expression
||| text -- `""` for a `CFIORes CFUnit` declaration, whose call is
||| emitted here as its own statement instead (C forbids a
||| `void`-returning call as a subexpression; `packCFType CFUnit`
||| ignores its own argument regardless, so an empty placeholder is
||| always safe to feed it). Shared by `emitAppFFIInlineInto` (wants
||| this value Boxed, via `packCFType`) and `emitNativeValue`'s own
||| `RAppFFIInline` case (wants it left native, via a plain
||| `CFChar`-aware widen) -- both then finish it off differently, so
||| this only carries the part identical either way, avoiding
||| triplicating the marshalling logic.
|||
||| Also returns every genuinely-`RBoxed`-typed argument position
||| (`CFWorld`'s own trailing slot on a `CFIORes`-returning declaration
||| included), already rendered to its own drop-ready C expression text
||| (`marshalArg`'s own doc comment) -- mirrors the old
||| `emitFFIWorker`'s own unconditional `removeVars boxedVars`, now paid
||| at the call site directly since no worker function exists any more
||| to pay it internally (see `emitAppFFIInlineInto`'s own doc comment
||| for the ownership hazard this closes). `discardLastArgument` only
||| ever trims the text actually passed to `fctName(...)` -- the
||| trailing `CFWorld` slot still contributes to this drop set
||| regardless, since it's still an ordinarily-owned Idris-level
||| reference even though the raw C function itself takes one fewer
||| parameter.
ffiRawCall : {auto a : Ref ArgCounter Nat}
          -> {auto oft : Ref OutfileText Output}
          -> {auto il : Ref IndentLevel Nat}
          -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
          -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
          -> {auto r : Ref RepMap (SortedMap Int Rep)}
          -> {auto lm : Ref InlineMap (SortedMap Int (String, List String))}
          -> CLang -> Name -> List CFType -> CFType -> List RCLocal -> Core (String, List String)
ffiRawCall cLang fctName fargs ret args = do
    let paramsInfo = zip fargs args
    marshalled <- traverse (uncurry marshalArg) paramsInfo
    let argExprs = map fst marshalled
        boxedArgDrop = concatMap snd marshalled
    let callWith : List String -> String
        callWith es = "\{cName fctName}(\{showSep ", " es})"
    -- `Compiler.RC2.EmitUtil`'s own `packCFType` CFInteger case doc
    -- comment has the full rationale: allocate a fresh
    -- `IDRIS2RC2_Integer` *before* the call, pass its own `->v` as an
    -- extra *leading* argument the callee writes its result into --
    -- GMP's own out-parameter idiom, `rop` always first
    -- (`mpz_add(rop, op1, op2)`, `mpz_set_str(rop, str, base)`, etc.),
    -- not merely "an out-param somewhere" -- so a declaration can bind
    -- directly to a real GMP function's own signature with no wrapper
    -- of its own needed. Emit the call as a bare statement (its real C
    -- return type is `void`), and hand the fresh Integer back as this
    -- call's own "result" -- already fully formed, no further packing
    -- needed (`packCFType CFInteger` is a bare passthrough for exactly
    -- this reason).
    let ffiIntegerOutParam : List String -> Core String
        ffiIntegerOutParam es = do
            retVar <- getNewVarThatWillNotBeFreedAtEndOfBlock
            emit emptyFC "IDRIS2RC2_Integer *\{retVar} = idris2rc2_mkInteger();"
            emit emptyFC "\{callWith ("\{retVar}->v" :: es)};"
            pure retVar
    rawExpr <- case ret of
         CFIORes CFUnit    => do
             emit emptyFC "\{callWith (discardLastArgument argExprs)};"
             pure ""
         CFIORes CFInteger => ffiIntegerOutParam (discardLastArgument argExprs)
         CFInteger         => ffiIntegerOutParam argExprs
         CFIORes _ => pure $ callWith (discardLastArgument argExprs)
         _          => pure $ callWith argExprs
    pure (rawExpr, boxedArgDrop)
  where
    ||| One argument, marshalled per its own `CFType` (mirrors the old
    ||| `emitFFIWorker`'s own `argExprFor`): `CFChar` needs
    ||| `nativeCharArgExpr`'s own narrow cast; any other native-eligible
    ||| type reads directly via `rcVarToNativeC`; anything else is
    ||| genuinely Boxed, read via `rcVarToBoxedC` then narrowed via
    ||| `extractValue`. Also hands back its own drop target (folded
    ||| into `pending`) -- unlike an ordinary `postDrop` entry, a raw
    ||| FFI argument can itself be a literal `RCConst` with no enclosing
    ||| `let`, needing this same constant-staging-aware rendering to
    ||| drop correctly.
    marshalArg : CFType -> RCLocal -> Core (String, List String)
    marshalArg CFChar v = do
        (e, pending) <- rcVarToNativeC CharType v
        pure (nativeCharArgExpr e, pending)
    marshalArg farg v = case cfTypeNative farg of
        Just ty => rcVarToNativeC ty v
        Nothing => do
            (boxedExpr, pending) <- rcVarToBoxedC v
            pure (extractValue cLang farg boxedExpr, boxedExpr :: pending)

-- emitAppNameRepInto/emitAppFFIInlineInto/emitRC are each called from
-- within the mutual block below (emitInto's own dispatch) but never
-- call back into it themselves -- forward-declared here and defined
-- after the block instead, the same technique RCExp.idr uses for
-- RCLocal/IsAnyConstLocal, so they don't need to be bundled in with
-- the other functions that genuinely are mutually recursive.
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
emitAppNameRepInto : EmitDeps (Sink -> TailPositionStatus -> FC -> Name -> List Rep -> Rep -> List RCLocal -> List RCLocal -> Core ())
||| Render a leftover `RAppFFIInline` (a direct, self-contained call
||| to a `%foreign` declaration's own raw C function, see its own
||| doc comment in RCExp.idr) into `sink` -- always produces a
||| *Boxed* value string, mirroring `emitAppNameRepInto`'s own
||| contract exactly (`emitNativeValue`'s own separate
||| `RAppFFIInline` case is the native-context counterpart, used
||| instead whenever `Compiler.RC2.DualABI`'s own `RLet` promotion
||| already decided this call's own result stays unboxed).
|||
||| Every genuinely-`RBoxed`-typed argument position
||| (`ffiRawCall`'s own drop set) needs an unconditional drop here,
||| *in addition to* `postDrop` -- the two are disjoint by
||| construction (`postDrop` only ever names a position whose own
||| argument representation is native; this only ever names a
||| position whose own argument representation is `RBoxed`) but
||| need exactly the same "after the value has been embedded in a
||| statement" discharge timing, so they're combined into one list
||| and handled by the same postDrop-capture-then-drop machinery
||| `emitAppNameRepInto` above already has. Get this backwards (miss
||| this drop entirely, or double it up with `postDrop`) and every
||| FFI call with a genuinely Boxed argument leaks or double-frees
||| -- see `ffiRawCall`'s own doc comment for the full rationale.
emitAppFFIInlineInto : EmitDeps (Sink -> TailPositionStatus -> FC -> List String -> List CFType -> CFType -> List RCLocal -> List RCLocal -> Core ())
||| Canonical statement of the `postDrop` read-before-drop rule every
||| other `postDrop`-consuming site in this file points back to here:
||| `postDrop` (`Compiler.RC2.RC`'s `annotate`) already lists exactly
||| which Boxed operand/argument locals need dropping once whichever
||| statement actually reads them has been emitted -- just lower it in
||| place, right after that statement, never re-deriving which locals
||| need it. Get the ordering backwards (drop before the read is
||| actually emitted) and it's a use-after-free.
|||
||| Takes `sink` and discharges it internally (via
||| `finalizeSinkWithDrop`) instead of just returning a Boxed expression
||| string, unlike an older version of this function -- a leaf case that
||| itself reads an InlineMap'd operand (`rcVarToBoxedC`/`rcVarToNativeC`,
||| see their own doc comments) gets back a pending drop that has to be
||| discharged only *after* the value is actually embedded in a
||| statement; since this function is the only place that statement gets
||| emitted (`finalizeSinkWithDrop` below), it also has to be the one
||| that discharges the pending drop -- returning a bare string to a
||| caller that might build it into a larger expression before ever
||| emitting anything (as several cases below used to, e.g. RApp/RCon)
||| would leave nowhere correct to put it.
emitRC : EmitDeps (Sink -> RCExp -> TailPositionStatus -> Core ())

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
    declareLet : EmitDeps (FC -> Int -> Rep -> RCExp -> Core ())
    declareLet fc var rep value = do
        update RepMap (insert var rep)
        case (rep, value) of
             (RNative _, RPrimVal _ c) => update InlineMap (insert var (nativeLitExpr c, []))
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
    tryEmitLoopContinue : EmitDeps (RCExp -> Core (Maybe RCExp))
    tryEmitLoopContinue (RDup fc v extra cont) = do
        dupVarExtra (varName v) extra
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
            (cty, valStr, pending) <- the (Core (String, String, List String)) $ case rep of
                 RBoxed => (\(s, p) => ("IDRIS2RC2_Value *", s, p)) <$> rcVarToBoxedC v
                 RNative ty => (\(s, p) => (nativeCType ty ++ " ", s, p)) <$> rcVarToNativeC ty v
                 RInlineNative ty => (\(s, p) => (nativeCType ty ++ " ", s, p)) <$> rcVarToNativeC ty v
            emit fc "\{cty}\{t} = \{valStr};"
            removeVars pending
            pure (paramId, t)) (zip newArgs loopParams)
        -- `postDrop` (see emitRC's own doc comment for the rule):
        -- every still-Boxed argument just read *natively* above (a
        -- `Native`/`RInlineNative` loop param slot fed by a Boxed
        -- source -- e.g. a `case`-valued let, which `Types.repOf`
        -- never promotes to Native even when every branch is
        -- native-eligible) needs its own source dropped now, since
        -- there's no separate statement position to hang an ordinary
        -- wrapping `drop` around a native-context read. See
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
    ||| second time. See `KNOWN-BUGS.md`'s "Fixed: Compiler.RC2.Emit's
    ||| tryBuildClosureInto used to double-emit a peeled wrapper's own
    ||| side effect" for why this return shape matters.
    tryBuildClosureInto : EmitDeps (Sink -> TailPositionStatus -> RCExp -> Core (Maybe RCExp))
    tryBuildClosureInto sink tailPosition (RDup fc v extra cont) = do
        dupVarExtra (varName v) extra
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
    declareNative : EmitDeps (FC -> PrimType -> Int -> RCExp -> Core ())
    declareNative fc ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        emit fc $ "\{nativeCType ty} var_\{show var} = \{valStr};"
        removeVars pending

    ||| As `declareNative`, but for an `RInlineNative` local: no C
    ||| variable ever declared, its rendered expression goes straight
    ||| into InlineMap instead (see `Rep.RInlineNative`'s own doc
    ||| comment). Also shared by `emitRC`'s and `emitNativeValue`'s own
    ||| RLet cases.
    |||
    ||| `pending` (any Boxed operand `value`'s own tail op read but
    ||| doesn't own a further use of) is stashed into InlineMap alongside
    ||| `valStr` itself, NOT dropped here -- `var`'s own single deferred
    ||| use is what actually embeds `valStr` in a statement, at some
    ||| later point this function has no visibility into, so dropping
    ||| `pending` here would be exactly the "drop before the read is
    ||| actually emitted" use-after-free `emitRC`'s own doc comment warns
    ||| about. `rcVarToBoxedC`/`rcVarToNativeC` (the only readers of an
    ||| InlineMap entry) hand `pending` back to their own caller instead,
    ||| which is what finally discharges it.
    inlineNative : EmitDeps (PrimType -> Int -> RCExp -> Core ())
    inlineNative ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        update InlineMap (insert var (valStr, pending))

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
    emitNativeReturn : EmitDeps (FC -> PrimType -> RCExp -> Core ())
    emitNativeReturn fc ty value = do
        (valStr, pending) <- emitNativeValue ty value
        case pending of
             [] => emit fc "return \{valStr};"
             _  => do
                 tmp <- getNewVarThatWillNotBeFreedAtEndOfBlock
                 emit fc "\{nativeCType ty} \{tmp} = \{valStr};"
                 removeVars pending
                 emit fc "return \{tmp};"

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
    emitInto : EmitDeps (FC -> Sink -> TailPositionStatus -> RCExp -> Core ())
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
                     -- Same reasoning as the RAppNameRep case just
                     -- above -- always routed to its own dedicated
                     -- renderer, regardless of `sink`.
                     RAppFFIInline fc' ccs fargs ret postDrop args =>
                         emitAppFFIInlineInto sink tailPosition fc' ccs fargs ret postDrop args
                     -- A native SinkReturn (Compiler.RC2.DualABI's own
                     -- Stage 3b) skips emitRC entirely: emitRC's own
                     -- contract is "always render a Boxed expression
                     -- string", which is exactly wrong here, and can't
                     -- discharge a pending Boxed-operand drop safely in
                     -- front of a `return` in the first place (see
                     -- emitNativeReturn's own doc comment). Every other
                     -- Sink still goes through emitRC directly, which
                     -- discharges `sink` (and any pending drop) itself.
                     _ => case sink of
                              SinkReturn (RNative ty) => emitNativeReturn fc ty remaining
                              SinkReturn (RInlineNative ty) => emitNativeReturn fc ty remaining
                              _ => emitRC sink remaining tailPosition

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
    branchBody : EmitDeps (Sink -> RCExp -> TailPositionStatus -> Core ())
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
    emitConAltBody : EmitDeps (Sink -> TailPositionStatus -> RCLocal -> RConAlt -> Core ())
    emitConAltBody sink tailPosition sc (MkRConAlt name coninfo tag args body) = do
        let sc' = varName sc
        _ <- foldlC (\k, arg => do
            emit emptyFC "IDRIS2RC2_Value *var_\{show arg} = ((IDRIS2RC2_Constructor*)\{sc'})->args[\{show k}];"
            pure (S k) ) 0 args
        branchBody sink body tailPosition

    ||| Lower a fused comparison branch (see RCExp.idr's own doc comment
    ||| on RCmpCase and `nativeCmpExpr`): the comparison is evaluated once
    ||| into a raw C `int` (no heap allocation for the Bool it would
    ||| otherwise be), `postDrop` is lowered immediately after (see
    ||| emitRC's own doc comment for the rule) -- and then exactly one of the two
    ||| branches runs, each writing straight into `sink` (resolved once,
    ||| before either branch -- see `resolveSink`) instead of a throwaway
    ||| `switchReturnVar`. Under `SinkReturn`, `whenTrue` is guaranteed to
    ||| end in `return`/`goto` (see `chainsWithElse`'s own doc comment),
    ||| so `whenFalse` needs neither an `else` to guard it nor its own
    ||| `{ }` scope -- it's already the last thing in whatever C block
    ||| contains this whole comparison, so it can just continue right
    ||| after `whenTrue`'s closing `}`, at the same indentation.
    emitCmpCaseInto : EmitDeps (Sink -> TailPositionStatus -> FC -> PrimFn 2 -> Vect 2 RCLocal
                    -> List RCLocal -> RCExp -> RCExp -> Core ())
    emitCmpCaseInto sink tailPosition fc op args postDrop whenTrue whenFalse = do
        case cmpArgTy op of
             Nothing => throw $ InternalError "[rc2] RCmpCase: not a comparison op"
             Just ty => do
                 argsWithPending <- rc2traverseVect (rcVarToNativeC ty) args
                 let argStrs = map fst argsWithPending
                 let condVar = "cmp_" ++ !(getNextCounter)
                 emit fc $ "int " ++ condVar ++ " = " ++ nativeCmpExpr op argStrs ++ ";"
                 removeVars $ concatMap snd (toList argsWithPending)
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
    emitConCaseInto : EmitDeps (Sink -> TailPositionStatus -> FC -> RCLocal -> List RConAlt -> Maybe RCExp -> Core ())
    emitConCaseInto sink tailPosition fc sc alts mDef = do
        let sc' = varName sc
        resolvedSink <- resolveSink fc sink
        emitAltChain resolvedSink
            (\alt => (\s => (s, [])) <$> conAltCondExpr sc' alt)
            (emitConAltBody resolvedSink tailPosition sc)
            (map (\body => branchBody resolvedSink body tailPosition) mDef)
            alts

    ||| Lower a constant/tag switch: same "each alt writes straight into
    ||| the once-resolved `sink`, via `emitAltChain`'s shared `if`-chain
    ||| shape" as `emitConCaseInto`, just over `RConstCase`'s own two
    ||| dispatch strategies (a fast integer switch via `extractIntExpr`,
    ||| or the string/double equality chain).
    emitConstCaseInto : EmitDeps (Sink -> TailPositionStatus -> FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> Core ())
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
                (extractExpr, pending) <- the (Core (String, List String)) $ case scRep of
                     RNative ty => rcVarToNativeC ty sc
                     RInlineNative ty => rcVarToNativeC ty sc
                     RBoxed => pure (case alts of
                                           (MkRConstAlt c0 _ :: _) => extractIntExpr c0 sc'
                                           [] => "idris2rc2_extractInt(\{sc'})", [])
                emit emptyFC "int64_t \{tmpint} = \{extractExpr};"
                removeVars pending
                emitAltChain resolvedSink
                    (\(MkRConstAlt c _) => pure ("\{tmpint} == \{const2Integer c 0}", []))
                    (\(MkRConstAlt _ body) => branchBody resolvedSink body tailPosition)
                    defaultAction
                    alts

            False =>
                emitAltChain resolvedSink
                    (\(MkRConstAlt c _) => case c of
                        Str x => pure ("! strcmp(\{cStringQuoted x}, ((IDRIS2RC2_String *)\{sc'})->str)", [])
                        Db  x => case scRep of
                                      RNative DoubleType => (\(e, p) => ("\{e} == \{show x}", p)) <$> rcVarToNativeC DoubleType sc
                                      RInlineNative DoubleType => (\(e, p) => ("\{e} == \{show x}", p)) <$> rcVarToNativeC DoubleType sc
                                      _ => pure ("((IDRIS2RC2_Double *)\{sc'})->v == \{show x}", [])
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
    |||   exclude this case from eligibility. A worker-promoted parameter
    |||   is never actually NULL either (an `int64_t` argument, not a
    |||   padded pointer slot), so the guard is scoped to `inPrologueDrop`
    |||   only -- see `rc2/doc/loop-conversion.md`'s "Bugs found and
    |||   fixed" #4 (Site 2) and `rc2/doc/dual-abi.md`'s #2 for the crash
    |||   and build failure this guard fixes.
    ||| * This is also the loop param's last use anywhere in the whole
    |||   function -- Compiler.RC2.Loop's own rewrite has already
    |||   redirected every other reference to the fresh shadow -- so
    |||   `initVal` is dropped right here, once, whenever `inPrologueDrop`
    |||   (its caller, `emitLoopInto`, discharges the full `prologueDrop`
    |||   list as one `removeVars` after every param's own declaration).
    declareLoopParam : EmitDeps ((inPrologueDrop : Bool) -> FC -> (paramId : Int) -> Rep -> (initVal : RCLocal) -> Core ())
    declareLoopParam _ fc paramId RBoxed initVal =
        if initVal == RCLoc paramId
           then update RepMap (insert paramId RBoxed)
           else declareLet fc paramId RBoxed (RV fc initVal)
    declareLoopParam inPrologueDrop fc paramId rep@(RNative ty) initVal = do
        update RepMap (insert paramId rep)
        (valStr, pending) <- rcVarToNativeC ty initVal
        if inPrologueDrop
           then do
               let initValName = varName initVal
               emit fc "\{nativeCType ty} var_\{show paramId} = (\{initValName} == NULL) ? 0 : (\{valStr});"
           else emit fc "\{nativeCType ty} var_\{show paramId} = \{valStr};"
        removeVars pending
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
    emitLoopInto : EmitDeps (Sink -> TailPositionStatus -> FC -> List (Int, Rep) -> List RCLocal -> (prologueDrop : List RCLocal) -> RCExp -> Core ())
    emitLoopInto sink tailPosition fc loopParams initial prologueDrop body = do
        traverse_ (\((paramId, rep), initVal) =>
                       declareLoopParam (elem initVal prologueDrop) fc paramId rep initVal) (zip loopParams initial)
        removeVars (varName <$> prologueDrop)
        emit fc "loop:;"
        put LoopParams loopParams
        emitInto emptyFC sink tailPosition body

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
    -- drop, and only *after* doing so. See KNOWN-BUGS.md's "Fixed:
    -- Compiler.RC2.Emit's emitNativeValue used to drop a native-read
    -- Boxed operand before the value was actually read" for what
    -- emitting it here unconditionally used to break.
    emitNativeValue : EmitDeps (PrimType -> RCExp -> Core (String, List String))
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
    emitNativeValue ty (RV fc v) = rcVarToNativeC ty v
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
        argsWithPending <- traverse (\(rep, v) => case rep of
                                 RNative t => rcVarToNativeC t v
                                 RInlineNative t => rcVarToNativeC t v
                                 RBoxed => rcVarToBoxedC v) (zip argReps args)
        let call = "\{cName n}(\{concat $ intersperse ", " (map fst argsWithPending)})"
        case retRep of
             RBoxed => throw $ InternalError "[rc2] emitNativeValue: RAppNameRep with Boxed retRep reached a native context"
             _ => pure (call, map varName postDrop ++ concatMap snd argsWithPending)
    -- A direct, self-contained call to a %foreign declaration's own
    -- raw C function (`RAppFFIInline`, `Compiler.RC2.DualABI`'s own
    -- Stage 5), reached here whenever an enclosing `RLet`'s own Rep
    -- was promoted to match this call's own implied native return --
    -- see the `RAppNameRep` case just above for the identical
    -- reasoning (this call's own `ret`, peeled through `CFIORes`, is
    -- expected to already be native-eligible; a Boxed one reaching
    -- here would mean that invariant broke somewhere upstream, an
    -- internal error rather than a case to render around). `postDrop`
    -- and `ffiRawCall`'s own genuinely-Boxed-argument drop set (already
    -- rendered to its own C expression text there -- unlike `postDrop`,
    -- a raw FFI call argument can genuinely be a literal `RCConst`, not
    -- only a plain declared variable, so it needs `rcVarToBoxedC`'s own
    -- constant-staging/InlineMap handling rather than a bare `varName`)
    -- are handed back combined, same reasoning as
    -- `emitAppFFIInlineInto`'s own doc comment -- our caller
    -- (declareNative/inlineNative/emitNativeReturn) hasn't emitted the
    -- statement that actually embeds this value yet, so it -- not this
    -- function -- is what must drop them, and only after doing so.
    emitNativeValue ty (RAppFFIInline fc ccs fargs ret postDrop args) = do
        (cLang, fctName) <- resolveForeignTarget ccs
        (rawExpr, boxedArgDrop) <- ffiRawCall cLang fctName fargs ret args
        case cfTypeNative (peelIORes ret) of
             Nothing => throw $ InternalError "[rc2] emitNativeValue: RAppFFIInline with Boxed ret reached a native context"
             Just _  =>
                 let retExpr = case peelIORes ret of
                                    CFChar => nativeCharRetExpr rawExpr
                                    _      => rawExpr
                 in pure (retExpr, map varName postDrop ++ boxedArgDrop)
    emitNativeValue ty (ROp fc _ op args postDrop) = do
        argsWithPending <- rc2traverseVect (\v => rcVarToNativeC (opArgTyFor ty op) v) args
        -- `postDrop` (same meaning as emitRC's boxed-ROp case, see its
        -- own doc comment) -- a native-result op still owes these
        -- operands the same cleanup, but can't drop them *here*: unlike
        -- emitRC, our caller hasn't necessarily emitted the statement
        -- that actually reads them yet (we only return an inline
        -- expression string). Hand `postDrop` back (folded in with any
        -- InlineMap'd pending drop each operand's own read already
        -- owed, see `rcVarToNativeC`'s own doc comment) so whoever
        -- *does* emit that statement can drop right after it.
        pure (nativeOpExpr op (map fst argsWithPending), map varName postDrop ++ concatMap snd (toList argsWithPending))
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
    emitNativeValue ty (RDup fc loc extra cont) = do
        dupVarExtra (varName loc) extra
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

emitAppNameRepInto sink tailPosition fc n argReps retRep postDrop args = do
    -- No `nargs` cap here: the call below is always a plain,
    -- positional, direct C call to a dual-ABI worker (`isWorker =
    -- True`, see `MkRCFun`'s own doc comment) -- never dispatched
    -- through `support/rc2/runtime.c`'s closure machinery, so
    -- `MaxExtractFunArgs` (which governs THAT convention) doesn't
    -- apply here.
    argsWithPending <- traverse (\(rep, v) => case rep of
                             RNative ty => rcVarToNativeC ty v
                             RInlineNative ty => rcVarToNativeC ty v
                             RBoxed => rcVarToBoxedC v) (zip argReps args)
    let argStrs = map fst argsWithPending
    let argPending = concatMap snd argsWithPending
    let call = "\{cName n}(\{concat $ intersperse ", " argStrs})"
    let valStr = case retRep of
                      RBoxed => case tailPosition of
                                     InTailPosition => call
                                     NotInTailPosition => "idris2rc2_trampoline(\{call})"
                      RNative ty => nativeMk ty call
                      RInlineNative ty => nativeMk ty call
    finalizeSinkWithDrop fc sink valStr (map varName postDrop ++ argPending)

emitAppFFIInlineInto sink tailPosition fc ccs fargs ret postDrop args = do
    (cLang, fctName) <- resolveForeignTarget ccs
    (rawExpr, boxedArgDrop) <- ffiRawCall cLang fctName fargs ret args
    -- The explicit cast matches `emitGenericForeignWrapper`'s own
    -- two analogous `packCFType` uses just below -- `packCFType`'s
    -- own "mk" functions don't all literally return
    -- `IDRIS2RC2_Value *` (e.g. `CFStruct`/`CFPtr`'s own
    -- `idris2rc2_mkPointer` returns `IDRIS2RC2_Pointer *`), so
    -- without it this fails to compile (`-Wincompatible-pointer-
    -- types` as an error) for any such declaration.
    let valStr = "(IDRIS2RC2_Value*)" ++ packCFType (peelIORes ret) rawExpr
    -- `postDrop` is always genuine-`RCLoc`-only (inherited verbatim
    -- from the `RAppNameRep` this replaced, see RCExp.idr's own doc
    -- comment), safe to render via a bare `varName`; `boxedArgDrop`
    -- is already-rendered text (see `ffiRawCall`'s own `marshalArg`
    -- doc comment for why it can't be a bare `varName` render).
    let allDrop = map varName postDrop ++ boxedArgDrop
    finalizeSinkWithDrop fc sink valStr allDrop

emitRC sink (RV fc v) _ = do
    (valStr, pending) <- rcVarToBoxedC v
    finalizeSinkWithDrop fc sink valStr pending
-- InTailPosition is unreachable here: emitInto's tryBuildClosureInto
-- always intercepts an InTailPosition RAppName itself, building the
-- closure straight into whichever Sink the caller handed down (see
-- buildClosureIntoSink) -- so emitRC only ever sees RAppName in
-- NotInTailPosition, where the call must actually be resolved
-- (trampolined) right here rather than deferred as a closure.
emitRC sink (RAppName fc _ n args) InTailPosition = throw $ InternalError "[rc2] RAppName (InTailPosition) reached emitRC directly (not intercepted by tryBuildClosureInto)"
emitRC sink (RAppName fc _ n args) NotInTailPosition = do
    let nargs = length args
    if nargs > MaxExtractFunArgs
       then finalizeSink fc sink "idris2rc2_trampoline(\{!(makeClosure fc n args 0)})"
       else do
           argsWithPending <- traverse rcVarToBoxedC args
           let valStr = "idris2rc2_trampoline(\{cName n}(\{concat $ intersperse ", " (map fst argsWithPending)}))"
           finalizeSinkWithDrop fc sink valStr (concatMap snd argsWithPending)

-- Unreachable: emitInto's own dispatch always intercepts a leftover
-- RAppNameRep itself (routing it to emitAppNameRepInto, which needs
-- to discharge its own postDrop -- something emitRC's own "always
-- discharge sink itself" contract has no room for -- before ever
-- falling back to a bare emitRC call). See emitAppNameRepInto's own
-- doc comment for the full rendering this case used to do directly.
emitRC sink (RAppNameRep fc n argReps retRep postDrop args) _ = throw $ InternalError "[rc2] RAppNameRep reached emitRC directly (not intercepted by emitInto)"

-- Unreachable: emitInto's own dispatch always intercepts a
-- leftover RAppFFIInline itself, same reasoning as RAppNameRep's
-- own case just above.
emitRC sink (RAppFFIInline fc ccs fargs ret postDrop args) _ = throw $ InternalError "[rc2] RAppFFIInline reached emitRC directly (not intercepted by emitInto)"

-- Unreachable: emitInto's tryBuildClosureInto always intercepts
-- RUnderApp itself, for any tailPosition -- a partial application is
-- always a closure build, tail position or not (see
-- buildClosureIntoSink).
emitRC sink (RUnderApp fc n missing args) _ = throw $ InternalError "[rc2] RUnderApp reached emitRC directly (not intercepted by tryBuildClosureInto)"
emitRC sink (RApp fc _ closure arg) tailPosition = do
   (closureStr, p1) <- rcVarToBoxedC closure
   (argStr, p2) <- rcVarToBoxedC arg
   let fnName = the String $ case tailPosition of
                     NotInTailPosition => "idris2rc2_applyClosure"
                     InTailPosition    => "idris2rc2_tailcallApplyClosure"
   finalizeSinkWithDrop fc sink "\{fnName}(\{closureStr}, \{argStr})" (p1 ++ p2)

-- Unreachable in practice, same reasoning as RLoopContinue's own
-- case below: emitInto's tryBuildClosureInto always peels an RLet
-- (declaring it via declareLet) before ever falling back to a bare
-- emitRC call, so this construct itself should never reach emitRC
-- directly. Failing loudly here (rather than silently re-declaring
-- `var` a second time, or worse, skipping its declaration) is the
-- safer choice.
emitRC sink (RLet fc var rep value body) _ = throw $ InternalError "[rc2] RLet reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

emitRC sink (RCon fc n coninfo tag args reuseFrom) _ = do
    if coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
        then finalizeSink fc sink "(NULL /* \{show n} */)"
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
                (vStr, pending) <- rcVarToBoxedC v
                emit EmptyFC $ "\{arglist}[\{show k}] = \{vStr};"
                removeVars pending
                pure (S k)) 0 args
            finalizeSink fc sink "(IDRIS2RC2_Value*)\{constr}"

emitRC sink (ROp fc _ op args postDrop) _ = do
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
    -- `postDrop`: see emitRC's own doc comment. Separately, any
    -- ephemeral box `boxOpArg` had to fabricate for a Native operand
    -- (folded into its own returned list alongside any InlineMap'd
    -- pending drop, see its own doc comment) is dropped too --
    -- `annotate` runs before `Compiler.RC2.Loop`'s native-shadow
    -- promotion ever decides a local is Native, so it can't have
    -- known about these.
    --
    -- `isReuseConsumingOp op` skips both: its own runtime primitive
    -- (rc2/support/rc2/numeric.h) now consumes and disposes of every
    -- operand handed to it itself, reusing a uniquely-referenced
    -- one's own heap allocation in place where possible -- see
    -- rc2/doc/rop-reuse.md.
    if isReuseConsumingOp op
       then pure ()
       else do
         removeVars $ map varName postDrop
         removeVars $ concatMap snd (toList argsWithFresh)
    finalizeSink fc sink resultVar

emitRC sink (RExtPrim fc _ p args postDrop) _ = do
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
    -- ext-prim args follow the same borrow/move contract as an
    -- ordinary ROp's operands (see RC.idr's own annotate RExtPrim
    -- case) -- box any that happen to be native locals first.
    argsWithPending <- traverse rcVarToBoxedC args
    -- Materialize the call into a fresh C variable (like the ROp
    -- case above) BEFORE dropping any postDrop argument -- args
    -- must still be alive while the call itself actually reads
    -- them; only after that's emitted is it safe to drop them.
    let resultVar = "extprimVar_" ++ !(getNextCounter)
    emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = idris2rc2_\{cName p}("++ showSep ", " (map fst argsWithPending) ++");"
    -- `postDrop`: see emitRC's own doc comment (same rule as the ROp
    -- case above) -- each argument's own InlineMap'd pending drop
    -- (`rcVarToBoxedC`'s own doc comment) needs exactly the same
    -- timing.
    removeVars $ map varName postDrop
    removeVars $ concatMap snd argsWithPending
    finalizeSink fc sink resultVar

-- Part D (doc/c-struct-support.md's "Design" section): resolve
-- structName/fieldName against StructDefs (Part B/C), then render
-- a plain C pointer dereference. Neither structVar (here) nor
-- value (RStructSet below) is ever duplicated to get here --
-- postDrop only ever means "this was this operand's own last use"
-- (Compiler.RC2.RC's dropIfLastUse), never "drop after a dup", so
-- this only ever discharges it, never inserts one.
emitRC sink (RStructGet fc structVar sn fn postDrop) _ = do
    structDefs <- get StructDefs
    let Just flds = lookup sn structDefs
        | Nothing => throw $ InternalError "[rc2] RStructGet: unknown struct \{sn}"
    let Just ty = lookup fn flds
        | Nothing => throw $ InternalError "[rc2] RStructGet: unknown field \{fn} of struct \{sn}"
    (ptrBoxed, pending) <- rcVarToBoxedC structVar
    let ptrC = extractValue CLangC CFPtr ptrBoxed
    let resultVar = "primVar_" ++ !(getNextCounter)
    emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = "
                ++ packCFType ty ("((\{sn}*)\{ptrC})->\{fn}") ++ ";"
    removeVars $ map varName postDrop
    removeVars pending
    finalizeSink fc sink resultVar

emitRC sink (RStructSet fc structVar sn fn value postDrop) _ = do
    structDefs <- get StructDefs
    let Just flds = lookup sn structDefs
        | Nothing => throw $ InternalError "[rc2] RStructSet: unknown struct \{sn}"
    let Just ty = lookup fn flds
        | Nothing => throw $ InternalError "[rc2] RStructSet: unknown field \{fn} of struct \{sn}"
    (ptrBoxed, p1) <- rcVarToBoxedC structVar
    let ptrC = extractValue CLangC CFPtr ptrBoxed
    (valBoxed, p2) <- rcVarToBoxedC value
    let valC = extractValue CLangC ty valBoxed
    emit fc $ "((\{sn}*)\{ptrC})->\{fn} = \{valC};"
    removeVars $ map varName postDrop
    removeVars (p1 ++ p2)
    finalizeSink fc sink "((IDRIS2RC2_Value *)NULL)"

-- Unreachable in practice, same reasoning as RLet's own case above:
-- emitInto's dispatch always intercepts a leftover RCmpCase/
-- RConCase/RConstCase itself (routing it to emitCmpCaseInto/
-- emitConCaseInto/emitConstCaseInto's Sink-aware handling) before
-- ever falling back to a bare emitRC call. Failing loudly here is
-- the safer choice: reaching this would mean every branch just
-- silently reverted to a throwaway switchReturnVar, undoing the
-- point of that dispatch without any other visible symptom.
emitRC sink (RCmpCase fc op args postDrop whenTrue whenFalse) _ = throw $ InternalError "[rc2] RCmpCase reached emitRC directly (not intercepted by emitInto)"
emitRC sink (RConCase fc sc alts mDef) _ = throw $ InternalError "[rc2] RConCase reached emitRC directly (not intercepted by emitInto)"
emitRC sink (RConstCase fc sc alts def) _ = throw $ InternalError "[rc2] RConstCase reached emitRC directly (not intercepted by emitInto)"

emitRC sink (RPrimVal fc (I x)) tailPosition = emitRC sink (RPrimVal fc (I64 $ cast x)) tailPosition
emitRC sink (RPrimVal fc c) _ = finalizeSink fc sink !(boxedConstExpr c)

emitRC sink (RErased fc) _ = finalizeSink fc sink "NULL"
emitRC sink (RCrash fc x) _ = finalizeSink fc sink "(NULL /* CRASH */)"
-- Unreachable in practice: emitInto always tries tryEmitLoopContinue
-- first, which intercepts every RLoopContinue (however deeply
-- RDup/RDrop/RFree/RLet-wrapped) before it could ever reach a bare
-- emitRC call -- see RLoopContinue's own doc comment. Unlike
-- varName's RCConst case, failing loudly here (rather than returning
-- some placeholder string) is the safer choice: reaching this would
-- mean the goto-loop was never emitted at all, silently turning a
-- loop into infinite recursion.
emitRC sink (RLoopContinue fc _ _) _ = throw $ InternalError "[rc2] RLoopContinue reached emitRC directly (not intercepted by tryEmitLoopContinue)"
-- Unreachable in practice, same reasoning as RCmpCase/RConCase/
-- RConstCase's own cases below: emitInto's dispatch always
-- intercepts a leftover RLoop itself (routing it to
-- emitLoopInto's Sink-aware handling) before ever falling back to
-- a bare emitRC call.
emitRC sink (RLoop fc loopParams initial prologueDrop body) _ = throw $ InternalError "[rc2] RLoop reached emitRC directly (not intercepted by emitInto)"
-- Unreachable in practice, same reasoning as RLet's own case above:
-- emitInto's tryBuildClosureInto always peels these wrapper nodes
-- (emitting their own dup/drop/free/reuse-release side effect) on
-- the way down before ever falling back to a bare emitRC call.
emitRC sink (RDrop fc locs cont) _ = throw $ InternalError "[rc2] RDrop reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
emitRC sink (RDup fc loc extra cont) _ = throw $ InternalError "[rc2] RDup reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
emitRC sink (RFree fc loc cont) _ = throw $ InternalError "[rc2] RFree reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
emitRC sink (RReleaseReuse fc loc cont) _ = throw $ InternalError "[rc2] RReleaseReuse reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
emitRC sink (RReuseOffer fc sc dupOnShared dropOnUnique cont) _ = throw $ InternalError "[rc2] RReuseOffer reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

addCommaToList : List String -> List String
addCommaToList [] = []
addCommaToList (x :: xs) = ("  " ++ x) :: map (", " ++) xs

||| The C signature line for a MkRCFun def -- shared by collectDeclarations
||| (needs it as a forward prototype before any body) and createCFunctions
||| (emits it as the definition's own head line).
fnSignature : {auto c : Ref Ctxt Defs}
           -> Name -> (args : List (Int, Rep)) -> (retRep : Rep) -> (isWorker : Bool)
           -> Core String
fnSignature n args retRep isWorker = do
    let nargs = length args
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
    -- `static`: a `MutualLoop`-merged dispatcher's own name
    -- (`MN "rc2_mutualLoop" i`, `isMutualLoopMerged`) numbers `i` from
    -- a fresh-per-compile counter (`Compiler.RC2.MutualLoop`'s own
    -- `FreshId`) -- unique across the whole compile in whole-program
    -- mode (one shared counter), but *not* across separate per-module
    -- incremental compiles, each starting its own counter at 0 again
    -- (`Compiler.RC2.RC2.incCompile`, rc2/doc/incremental-compile.md) --
    -- a real "multiple definition" link error once two such modules'
    -- own `.o`s both end up needed by the same program. `static`
    -- (safe unconditionally -- this dispatcher is never meant to be
    -- referenced from outside its own generated `.c` in the first
    -- place, whole-program or incremental) sidesteps the whole
    -- question: distinct per-TU internal linkage never collides no
    -- matter how the two counters happen to line up.
    let storageClass = if isMutualLoopMerged n then "static " else ""
    pure $ "\{storageClass}\{retTypeStr}\{cName !(getFullName n)}"
            ++ (if nargs == 0 then "(void)"
               else if useVarArglist then "(IDRIS2RC2_Value *var_arglist[\{show nargs}])"
               else ("\n(\n" ++ (showSep "\n" $ addCommaToList (map declareParam args))) ++ "\n)")

||| `Prelude.Types.fastPack`/`fastConcat` leak their own raw `malloc`'d
||| `char *` return through the generic `CFString`-return FFI wrapper
||| codegen (`emitGenericForeignWrapper`, `createCFunctions`'s own
||| `MkRCForeign` case) -- it copies into a fresh `IDRIS2RC2_String` via
||| `packCFType` and never frees the original -- correct for a real
||| external library's `char *` return, wrong for these two, which
||| `malloc` a buffer this project itself owns). `rc2/support/rc2/
||| idris2rc2_strings.c` already has leak-free replacements
||| (`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`, returning an already-fully-built
||| `IDRIS2RC2_Value*` directly, the same way any `CFUser` return is
||| already passed straight through with no copy). See `KNOWN-BUGS.md`
||| and `rc2/doc/fastpack-fix.md` for the full writeup, including why
||| this is intercepted here (at C-emission time, universally, for
||| every call site project-wide -- including ones already baked into
||| precompiled `network`/`base` code) rather than via upstream's own
||| `%transform` mechanism (which only ever rewrites a call site within
||| the rewriting definition's own elaboration/import scope, and so can
||| never reach a call site inside another package's own separately-
||| compiled `.ttc`).
|||
||| Checked by FULL namespace + base name (not just base name, unlike
||| `Compiler.RC2.ConstFold`'s own `constExtPrimValue`) precisely
||| so this never misfires on some unrelated future function that merely
||| happens to share the base name "fastPack"/"fastConcat" in a
||| different namespace. Every caller also checks this def's own
||| signature shape (`CFString`-returning, single `CFUser` argument) as
||| a second layer of defensive scoping. Shared by `createCFunctions`
||| (dispatch to `emitFastPackFixedWrapper`) and `collectDeclarations`
||| (must skip this def's own parseCC/HeaderFiles/ForeignLibs
||| registration exactly when `createCFunctions` will too).
fastPackFixedReplacement : Name -> Maybe String
fastPackFixedReplacement (NS ns (UN (Basic "fastPack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastPackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastConcat"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastConcatFixed" else Nothing
fastPackFixedReplacement _ = Nothing

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
    -- See `fnSignature`'s own identical computation -- kept in sync
    -- here only for `useVarArglist`, which this def's own body (just
    -- below) also needs to decide whether to unpack `var_arglist[]`.
    let useVarArglist = not isWorker && nargs > MaxExtractFunArgs
    fn <- fnSignature n args retRep isWorker

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
    _ <- newRef InlineMap (the (SortedMap Int (String, List String)) empty)
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
  emit EmptyFC "char const idris2rc2_constr_\{n'}[] = \{cStringQuoted $ show n};"
  pure ()

createCFunctions n (MkRCCon tag arity nt) = do
  emit EmptyFC $ ( "// \{show n} Constructor tag " ++ show tag ++ " arity " ++ show arity)

createCFunctions n (MkRCForeign ccs fargs ret) =
  -- `fastPackFixedReplacement`'s own doc comment has the full writeup.
  -- Both defensive checks (name via that function, signature shape
  -- here) must hold before diverting away from the generic FFI-wrapper
  -- codegen path every other `%foreign` declaration still goes through
  -- unconditionally.
  case (fastPackFixedReplacement n, ret, fargs) of
       (Just fixedFnName, CFString, [CFUser _ _]) => emitFastPackFixedWrapper fixedFnName
       _ => emitGenericForeignWrapper
  where
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

    ||| `Nothing` for an always-Boxed FFI wrapper argument whose own
    ||| `CFType` maps to `Types.alwaysUnboxed` (a tagged pointer at the
    ||| C level -- `idris2rc2_drop` on it is a guaranteed runtime no-op),
    ||| `Just` its own variable name otherwise. Filters `removeVars`'
    ||| own drop list so such an argument's drop call isn't generated at
    ||| all instead of merely being cheap once generated.
    alwaysUnboxedDropVar : (String, String, CFType) -> Maybe String
    alwaysUnboxedDropVar (_, varName, vt) =
        case cfTypeNative vt of
             Just ty => if alwaysUnboxed ty then Nothing else Just varName
             Nothing => Just varName

    additionalFFIStub : Name -> List CFType -> CFType -> String
    additionalFFIStub name argTypes (CFIORes retType) = additionalFFIStub name (discardLastArgument argTypes) retType
    -- A real C function returning `Integer` is actually declared `void`,
    -- taking an extra trailing `mpz_t` out-parameter instead (see
    -- `Compiler.RC2.EmitUtil`'s own `packCFType` CFInteger case) --
    -- `cTypeOfCFType CFInteger` ("mpz_t") is only ever valid in
    -- parameter position, never as a function(-pointer)'s own return
    -- type (illegal C: a function cannot return an array type), so this
    -- stub's declared shape has to match the real one, not the generic
    -- fallback below.
    additionalFFIStub name argTypes CFInteger =
        "void (*" ++ cName name ++ ")(" ++
        (concat $ intersperse ", " $ "mpz_t" :: map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"
    additionalFFIStub name argTypes retType =
        cTypeOfCFType retType ++
        " (*" ++ cName name ++ ")(" ++
        (concat $ intersperse ", " $ map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"

    ||| Same external name/declared signature `emitGenericForeignWrapper`
    ||| would have produced (so every existing call site anywhere --
    ||| including ones already baked into precompiled `network`/`base`
    ||| code -- keeps linking against the same symbol, unmodified), but
    ||| the body calls rc2's own leak-free `idris2rc2_fastPackFixed`/
    ||| `idris2rc2_fastConcatFixed` (`idris2rc2_strings.c`) instead of the leaking
    ||| `fastPack`/`fastConcat`, and returns its result directly --
    ||| skipping `packCFType`/`idris2rc2_mkString` entirely, the same
    ||| way a bare `CFUser` return is already passed straight through
    ||| with no copy (see `EmitUtil.idr`'s own `packCFType` `CFUser`
    ||| case) -- since `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` already return
    ||| a fully-formed, correctly-owned `IDRIS2RC2_Value*` themselves.
    emitFastPackFixedWrapper : String -> Core ()
    emitFastPackFixedWrapper fixedFnName = do
        typeVarNameArgList <- createFFIArgList fargs

        emitFDef n typeVarNameArgList
        emit EmptyFC "{"
        increaseIndentation
        emit EmptyFC $ " // rc2's own leak-free replacement for " ++ show n ++ " -- see KNOWN-BUGS.md / rc2/doc/fastpack-fix.md"
        let removeVarsArgList = removeVars (mapMaybe alwaysUnboxedDropVar typeVarNameArgList)
        emit EmptyFC $ "IDRIS2RC2_Value *retVal = " ++ fixedFnName
                    ++ "("
                    ++ showSep ", " (map (\(_, vn, vt) => extractValue CLangC vt vn) typeVarNameArgList)
                    ++ ");"
        removeVarsArgList
        emit EmptyFC "return retVal;"
        decreaseIndentation
        emit EmptyFC "}"

    emitGenericForeignWrapper : Core ()
    emitGenericForeignWrapper = do
      case parseCC ffiTags ccs of
          Just (lang, _ :: _) => do
              let isStandardFFI = elem lang ffiTags
              -- "RC2" (rc2-specific %foreign_impl patches, e.g.
              -- System.Concurrency.RC2/Data.Buffer.RC2) targets our own
              -- runtime exactly like "RefC" does -- both need
              -- CFBuffer's header-aware unwrap (EmitUtil.idr's
              -- `extractValue CLangRefC CFBuffer`), not the generic
              -- flat-data-pointer one "C" gets. Before this, every
              -- "RC2:"-tagged call fell into the `else` branch below
              -- and got the wrong (CLangC) unwrap for any CFBuffer
              -- argument -- never caught earlier because
              -- System.Concurrency.RC2's own patches never took one.
              (cLang, fctName) <- resolveForeignTarget ccs
              when (not isStandardFFI) $ emit EmptyFC $ additionalFFIStub fctName fargs ret
              typeVarNameArgList <- createFFIArgList fargs

              emitFDef n typeVarNameArgList
              emit EmptyFC "{"
              increaseIndentation
              emit EmptyFC $ " // ffi call to " ++ cName fctName
              let removeVarsArgList = removeVars (mapMaybe alwaysUnboxedDropVar typeVarNameArgList)
              case ret of
                  CFIORes CFUnit => do
                      emit EmptyFC $ cName fctName
                                  ++ "("
                                  ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                                  ++ ");"
                      removeVarsArgList
                      emit EmptyFC "return NULL;"
                  -- `Compiler.RC2.EmitUtil`'s own `packCFType` CFInteger
                  -- case has the full rationale: GMP's own `mpz_t` has
                  -- no "return by value" C shape, so a fresh
                  -- `IDRIS2RC2_Integer` is allocated *before* the call
                  -- and its own `->v` passed as an extra *leading*
                  -- argument (GMP's own `rop`-always-first
                  -- out-parameter idiom -- `mpz_add(rop, op1, op2)`,
                  -- etc. -- not merely "an out-param somewhere", so a
                  -- declaration can bind directly to a real GMP
                  -- function's own signature) the real C function
                  -- (declared `void`) writes its result into, rather
                  -- than assigning from the call's own (nonexistent)
                  -- return value.
                  CFIORes CFInteger => do
                      emit EmptyFC "IDRIS2RC2_Integer *retVal = idris2rc2_mkInteger();"
                      emit EmptyFC $ cName fctName
                                  ++ "("
                                  ++ showSep ", " ("retVal->v" :: map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                                  ++ ");"
                      emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType CFInteger "retVal" ++ ";"
                      removeVarsArgList
                      emit EmptyFC "return packedRet;"
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
                  -- Same reasoning as the CFIORes CFInteger branch above.
                  CFInteger => do
                      emit EmptyFC "IDRIS2RC2_Integer *retVal = idris2rc2_mkInteger();"
                      emit EmptyFC $ cName fctName
                                  ++ "("
                                  ++ showSep ", " ("retVal->v" :: map (\(_, vn, vt) => extractValue cLang vt vn) typeVarNameArgList)
                                  ++ ");"
                      emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType CFInteger "retVal" ++ ";"
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
          _ => throw $ InternalError "[rc2] FFI not found for \{cName n}"

createCFunctions n (MkRCError exp) = throw $ InternalError "[rc2] Error with expression"

||| Every untagged constructor `Name` a def's own generated C
||| dereferences via `->name = idris2rc2_constr_<name>` -- both a
||| dynamic `RCon` construction (this module's own `createCFunctions`
||| `RCon` case, `when (Nothing == tag) ...` above) and a `ConstFold`-
||| folded `RCConstCon` literal (`EmitUtil.boxedConstConExpr`'s own
||| `nameField`) set this field exactly when the constructor's own
||| `tag` is `Nothing`. Whole-program compilation never needs this --
||| every `MkRCCon` the program could possibly reference already sits
||| in the very same `defs` list `collectDeclarations` forward-declares
||| from below -- only matters once a module compiles against a strict
||| subset of the program (`Compiler.RC2.RC2`'s own `incCompile`, see
||| rc2/doc/incremental-compile.md), where the referenced constructor
||| may be owned by a module not present in `defs` at all. Found via a
||| real `--inc rc2` prelude rebuild: `Prelude.Basics` references
||| `Builtin.Void` this way with no declaration anywhere in its own
||| translation unit, a plain "undeclared identifier" C compile error.
||| A fresh, exhaustive walker mirroring `Compiler.RC2.DeadCode`'s own
||| `usedFunctionNamesR`/`usedFunctionNamesL` shape (see that module's
||| own doc comment for why this codebase writes a dedicated walker per
||| concern rather than reusing `RCExp.idr`'s generic ones).
untaggedConstructorRefsL : RCLocal -> SortedSet Name
untaggedConstructorRefsL (RCConstCon n _ Nothing args) = insert n (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsL (RCConstCon _ _ (Just _) args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsL (RCConstClosure _ _) = empty
untaggedConstructorRefsL (RCLoc _) = empty
untaggedConstructorRefsL RCNull = empty
untaggedConstructorRefsL (RCConst _) = empty
untaggedConstructorRefsL (RCEmptyCon {}) = empty

untaggedConstructorRefsR : RCExp -> SortedSet Name
untaggedConstructorRefsR (RV _ l) = untaggedConstructorRefsL l
untaggedConstructorRefsR (RAppName _ _ _ args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsR (RAppNameRep _ _ _ _ postDrop args) =
    union (concatMap untaggedConstructorRefsL postDrop) (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsR (RAppFFIInline _ _ _ _ postDrop args) =
    union (concatMap untaggedConstructorRefsL postDrop) (concatMap untaggedConstructorRefsL args)
untaggedConstructorRefsR (RUnderApp _ _ _ args) = concatMap untaggedConstructorRefsL args
untaggedConstructorRefsR (RApp _ _ c a) = union (untaggedConstructorRefsL c) (untaggedConstructorRefsL a)
untaggedConstructorRefsR (RLet _ _ _ value body) = union (untaggedConstructorRefsR value) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RCon _ n _ Nothing args reuseFrom) =
    insert n (union (concatMap untaggedConstructorRefsL args) (maybe empty untaggedConstructorRefsL reuseFrom))
untaggedConstructorRefsR (RCon _ _ _ (Just _) args reuseFrom) =
    union (concatMap untaggedConstructorRefsL args) (maybe empty untaggedConstructorRefsL reuseFrom)
untaggedConstructorRefsR (ROp _ _ _ args postDrop) =
    union (concatMap untaggedConstructorRefsL (toList args)) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RExtPrim _ _ _ args postDrop) =
    union (concatMap untaggedConstructorRefsL args) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RStructGet _ structVar _ _ postDrop) =
    union (untaggedConstructorRefsL structVar) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RStructSet _ structVar _ _ value postDrop) =
    union (untaggedConstructorRefsL structVar)
          (union (untaggedConstructorRefsL value) (concatMap untaggedConstructorRefsL postDrop))
untaggedConstructorRefsR (RCmpCase _ _ args postDrop t f) =
    union (concatMap untaggedConstructorRefsL (toList args))
          (union (concatMap untaggedConstructorRefsL postDrop)
                 (union (untaggedConstructorRefsR t) (untaggedConstructorRefsR f)))
untaggedConstructorRefsR (RConCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConAlt _ _ _ _ body) => untaggedConstructorRefsR body) alts
    in union (untaggedConstructorRefsL sc) (concat (maybe altsUsed (\d => untaggedConstructorRefsR d :: altsUsed) mDef))
untaggedConstructorRefsR (RConstCase _ sc alts mDef) =
    let altsUsed = map (\(MkRConstAlt _ body) => untaggedConstructorRefsR body) alts
    in union (untaggedConstructorRefsL sc) (concat (maybe altsUsed (\d => untaggedConstructorRefsR d :: altsUsed) mDef))
untaggedConstructorRefsR (RPrimVal _ _) = empty
untaggedConstructorRefsR (RErased _) = empty
untaggedConstructorRefsR (RCrash _ _) = empty
untaggedConstructorRefsR (RDup _ v _ body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RDrop _ vars body) = union (concatMap untaggedConstructorRefsL vars) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RFree _ v body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RReleaseReuse _ v body) = union (untaggedConstructorRefsL v) (untaggedConstructorRefsR body)
untaggedConstructorRefsR (RLoop _ _ initial prologueDrop body) =
    union (concatMap untaggedConstructorRefsL initial)
          (union (concatMap untaggedConstructorRefsL prologueDrop) (untaggedConstructorRefsR body))
untaggedConstructorRefsR (RLoopContinue _ args postDrop) =
    union (concatMap untaggedConstructorRefsL args) (concatMap untaggedConstructorRefsL postDrop)
untaggedConstructorRefsR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    union (untaggedConstructorRefsL sc)
          (union (concatMap untaggedConstructorRefsL dupOnShared)
                 (union (concatMap untaggedConstructorRefsL dropOnUnique) (untaggedConstructorRefsR body)))

||| Same idea as `untaggedConstructorRefsR`, lifted to a whole `RCDef`.
untaggedConstructorRefsD : RCDef -> SortedSet Name
untaggedConstructorRefsD (MkRCFun _ _ _ body) = untaggedConstructorRefsR body
untaggedConstructorRefsD (MkRCCon _ _ _) = empty
untaggedConstructorRefsD (MkRCForeign _ _ _) = empty
untaggedConstructorRefsD (MkRCError body) = untaggedConstructorRefsR body

||| Every function `Name` a def's own generated C references but might
||| not itself define -- a direct call (`RAppName`), a partial-
||| application closure build (`RUnderApp`), or a `ConstFold`-folded
||| zero-capture closure (`RCConstClosure`). Same story as
||| `untaggedConstructorRefsD` above: a no-op set in whole-program mode
||| (`collectDeclarations` already forward-declares every one of these
||| from that very same `defs` list), only populated once `defs` is a
||| single module's own subset (`Compiler.RC2.RC2`'s `incCompile`).
||| Confirmed for real via the same `--inc rc2` prelude rebuild that
||| found `untaggedConstructorRefsD`'s own gap: e.g. `Prelude.Num`
||| calls `Prelude.EqOrd`'s own comparison functions directly by name,
||| with nothing declaring them in `Prelude.Num`'s own translation
||| unit ("implicit declaration of function" C errors).
|||
||| Declared with the exact arity a real `RAppName` call site to it
||| already carries when one exists in `defs` (the true, authoritative
||| arity for a saturated direct call to it -- every plain, non-
||| `RAppNameRep` reference to another module's own top-level function
||| targets that function's Boxed-ABI wrapper entry point specifically:
||| a `RAppNameRep`/native-worker call can only ever target a function
||| `DualABI` proved eligible from *within the same module*
||| (rc2/doc/incremental-compile.md's "Which existing passes need to
||| change"), so it can never appear here -- so the wrapper is always
||| `IDRIS2RC2_Value *(...N boxed pointers...)` shaped, `N` = that call
||| site's own argument count), or arity 0 when it's referenced only as
||| a function-pointer *value* (`RUnderApp`/`RCConstClosure`, never
||| called with a fixed argument list directly) -- both already only
||| ever consumed through an explicit erased-signature cast anyway
||| (`EmitUtil`'s own `(IDRIS2RC2_Value *(*)())` closure-struct field,
||| the exact same cast a *locally*-declared, exact-arity closure
||| target already goes through too), so an arity-0 declaration is
||| harmless there. Trying a single K&R-style (empty-parens, no `void`)
||| declaration for every case first -- relying on it to mean
||| "unspecified arguments" the way traditional C does -- broke on this
||| toolchain's own C standard default (which treats bare `()` as `(void)`,
||| a real difference C23 introduced): a real 2-argument `RAppName`
||| call to a name declared that way is a hard "too many arguments" C
||| error, found the same way as `untaggedConstructorRefsD`'s own gap
||| (a real `--inc rc2` prelude rebuild -- `Prelude.Num` calls
||| `Prelude.EqOrd`'s own comparison functions directly by name).
|||
||| Returns `(Name, Nat)` pairs rather than a `SortedSet`/`SortedMap`
||| directly -- plain list concatenation at every recursive step avoids
||| any merge-order hazard between an arity-bearing `RAppName` sighting
||| and an arity-0 `RUnderApp`/`RCConstClosure` one for the very same
||| name (`generateCSourceFile`'s own call site resolves duplicates
||| with `max`, so whichever order they appear in this list, the real
||| arity always wins over the placeholder 0).
externalFunctionRefsL : RCLocal -> List (Name, Nat)
externalFunctionRefsL (RCConstClosure n _) = [(n, 0)]
externalFunctionRefsL (RCConstCon _ _ _ args) = concatMap externalFunctionRefsL args
externalFunctionRefsL (RCLoc _) = []
externalFunctionRefsL RCNull = []
externalFunctionRefsL (RCConst _) = []
externalFunctionRefsL (RCEmptyCon {}) = []

externalFunctionRefsR : RCExp -> List (Name, Nat)
externalFunctionRefsR (RV _ l) = externalFunctionRefsL l
externalFunctionRefsR (RAppName _ _ n args) = (n, length args) :: concatMap externalFunctionRefsL args
externalFunctionRefsR (RAppNameRep _ _ _ _ postDrop args) =
    concatMap externalFunctionRefsL postDrop ++ concatMap externalFunctionRefsL args
externalFunctionRefsR (RAppFFIInline _ _ _ _ postDrop args) =
    concatMap externalFunctionRefsL postDrop ++ concatMap externalFunctionRefsL args
externalFunctionRefsR (RUnderApp _ n _ args) = (n, 0) :: concatMap externalFunctionRefsL args
externalFunctionRefsR (RApp _ _ c a) = externalFunctionRefsL c ++ externalFunctionRefsL a
externalFunctionRefsR (RLet _ _ _ value body) = externalFunctionRefsR value ++ externalFunctionRefsR body
externalFunctionRefsR (RCon _ _ _ _ args reuseFrom) =
    concatMap externalFunctionRefsL args ++ maybe [] externalFunctionRefsL reuseFrom
externalFunctionRefsR (ROp _ _ _ args postDrop) =
    concatMap externalFunctionRefsL (toList args) ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RExtPrim _ _ _ args postDrop) =
    concatMap externalFunctionRefsL args ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RStructGet _ structVar _ _ postDrop) =
    externalFunctionRefsL structVar ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RStructSet _ structVar _ _ value postDrop) =
    externalFunctionRefsL structVar ++ externalFunctionRefsL value ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RCmpCase _ _ args postDrop t f) =
    concatMap externalFunctionRefsL (toList args) ++ concatMap externalFunctionRefsL postDrop
    ++ externalFunctionRefsR t ++ externalFunctionRefsR f
externalFunctionRefsR (RConCase _ sc alts mDef) =
    let altsUsed = concatMap (\(MkRConAlt _ _ _ _ body) => externalFunctionRefsR body) alts
    in externalFunctionRefsL sc ++ altsUsed ++ maybe [] externalFunctionRefsR mDef
externalFunctionRefsR (RConstCase _ sc alts mDef) =
    let altsUsed = concatMap (\(MkRConstAlt _ body) => externalFunctionRefsR body) alts
    in externalFunctionRefsL sc ++ altsUsed ++ maybe [] externalFunctionRefsR mDef
externalFunctionRefsR (RPrimVal _ _) = []
externalFunctionRefsR (RErased _) = []
externalFunctionRefsR (RCrash _ _) = []
externalFunctionRefsR (RDup _ v _ body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RDrop _ vars body) = concatMap externalFunctionRefsL vars ++ externalFunctionRefsR body
externalFunctionRefsR (RFree _ v body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RReleaseReuse _ v body) = externalFunctionRefsL v ++ externalFunctionRefsR body
externalFunctionRefsR (RLoop _ _ initial prologueDrop body) =
    concatMap externalFunctionRefsL initial ++ concatMap externalFunctionRefsL prologueDrop ++ externalFunctionRefsR body
externalFunctionRefsR (RLoopContinue _ args postDrop) =
    concatMap externalFunctionRefsL args ++ concatMap externalFunctionRefsL postDrop
externalFunctionRefsR (RReuseOffer _ sc dupOnShared dropOnUnique body) =
    externalFunctionRefsL sc ++ concatMap externalFunctionRefsL dupOnShared
    ++ concatMap externalFunctionRefsL dropOnUnique ++ externalFunctionRefsR body

||| Same idea as `externalFunctionRefsR`, lifted to a whole `RCDef`.
externalFunctionRefsD : RCDef -> List (Name, Nat)
externalFunctionRefsD (MkRCFun _ _ _ body) = externalFunctionRefsR body
externalFunctionRefsD (MkRCCon _ _ _) = []
externalFunctionRefsD (MkRCForeign _ _ _) = []
externalFunctionRefsD (MkRCError body) = externalFunctionRefsR body

||| Every file-scope declaration `def` contributes, derivable from its own
||| outer shape alone -- no RCExp recursion needed.
declarationsOf : {auto c : Ref Ctxt Defs} -> Name -> RCDef -> Core (List String)
declarationsOf n (MkRCFun args retRep isWorker _) = pure [ !(fnSignature n args retRep isWorker) ++ ";\n" ]
declarationsOf n (MkRCCon Nothing _ _) = pure [ "char const idris2rc2_constr_\{cName n}[];" ]
declarationsOf _ (MkRCCon _ _ _) = pure []
declarationsOf n (MkRCForeign _ fargs _) =
    pure [ "IDRIS2RC2_Value *\{cName n}(" ++ showSep ", " (replicate (length fargs) "IDRIS2RC2_Value *") ++ ");\n" ]
declarationsOf _ (MkRCError _) = pure []

||| Registers `n`'s own forward declaration(s) (`declarationsOf`) into
||| `FunctionDefinitions`, plus -- for a standard-FFI `MkRCForeign` not
||| diverted to rc2's own fastpack replacement (`fastPackFixedReplacement`,
||| same condition `createCFunctions`'s own `MkRCForeign` case dispatches
||| on) -- its own lib/header registration (`HeaderFiles`/`ForeignLibs`,
||| moved here verbatim from the old `emitGenericForeignWrapper`). Conses
||| each declaration onto the front of `FunctionDefinitions`, so run over
||| `defs` in its own original order (`generateCSourceFile`'s own
||| `traverse_`) this reproduces the exact reverse-`defs` order the old
||| direct-from-`createCFunctions` population left it in -- `header`
||| prints the list as-is, so the prototype section stays byte-identical
||| to before this pass was split out. Also the sole place `MkRCForeign`'s
||| own `parseCC` failure and `MkRCError` are detected -- both now surface
||| before `outn` is ever opened, same "no half-written .c on failure"
||| property the old single-pass design had.
collectDeclarations : {auto c : Ref Ctxt Defs} -> {auto f : Ref FunctionDefinitions (List String)}
                   -> {auto hf : Ref HeaderFiles (SortedSet String)} -> {auto fl : Ref ForeignLibs (SortedSet String)}
                   -> Name -> RCDef -> Core ()
collectDeclarations n (MkRCError exp) = throw $ InternalError "[rc2] Error with expression"
collectDeclarations n def@(MkRCForeign ccs fargs ret) = do
    decls <- declarationsOf n def
    update FunctionDefinitions $ \otherDefs => decls ++ otherDefs
    case (fastPackFixedReplacement n, ret, fargs) of
         (Just _, CFString, [CFUser _ _]) => pure ()
         _ => case parseCC ffiTags ccs of
                   Just (lang, _ :: extLibOpts) =>
                       when (elem lang ffiTags) $
                           case extLibOpts of
                                [lib, header] => do update HeaderFiles $ insert header
                                                    maybe (pure ()) (\l => update ForeignLibs $ insert l) (linkLibName lib)
                                [lib] => maybe (pure ()) (\l => update ForeignLibs $ insert l) (linkLibName lib)
                                _ => pure ()
                   _ => throw $ InternalError "[rc2] FFI not found for \{cName n}"
collectDeclarations n def = do
    decls <- declarationsOf n def
    update FunctionDefinitions $ \otherDefs => decls ++ otherDefs

||| Every declaration that has a whole-program forward-reference
||| requirement (`#include`s, struct typedefs, function prototypes --
||| see `collectDeclarations`'s own doc comment for why constants don't
||| belong here) -- returned as plain text lines instead of appended
||| into `OutfileText` directly, since `generateCSourceFile` now writes
||| this straight to `outn` before any def's own body-emission pass
||| runs, rather than threading it through the same accumulator every
||| def's own generated text passes through.
header : {auto f : Ref FunctionDefinitions (List String)}
      -> {auto h : Ref HeaderFiles (SortedSet String)}
      -> {auto sd : Ref StructDefs (SortedMap String (List (String, CFType)))}
      -> {auto ir : Ref InjectedRuntime String}
      -> Core (List String)
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
    pure $
        [initLines] ++
        map (\h => "#include <\{h}>\n") headerFiles ++
        (if injectedRuntime == ""
            then []
            else ["\n// %cg rc2 extraRuntime=<path> / inlineRuntime=<code>\n", injectedRuntime, "\n"]) ++
        ["\n// struct definitions"] ++
        map (uncurry genStructDef) (SortedMap.toList structDefs) ++
        ["\n// function definitions"] ++
        fns
  where
    genStructDef : String -> List (String, CFType) -> String
    genStructDef name flds =
      "typedef struct { "
        ++ concat (map (\(fn, ty) => cTypeOfCFType ty ++ " " ++ fn ++ "; ") flds)
        ++ "} \{name};\n"

||| Writes `ls` to `h`, throwing `FileErr outn err` on any failure --
||| unlike `System.File`'s own `HasIO`-polymorphic `fPutStrLn`, whose
||| `Either FileError ()` result the old single-shot write loop this
||| replaces discarded as a plain value inside an unconditional
||| `pure (Right ())`, via `coreLift_`'s own `ignore`: every failure,
||| including `openFile`'s own, used to vanish silently, leaving either
||| no `.c` at all or a stale one for the next compile stage to trip
||| over with a confusing gcc error instead. `Core.Core.FileErr` is an
||| existing `Error` constructor -- no new exception type needed.
putLines : (outn : String) -> File -> List String -> Core ()
putLines outn h = traverse_ $ \l =>
    coreLift (fPutStrLn h l) >>= \case
        Right () => pure ()
        Left err => throw $ FileErr outn err

||| Flushes this def's own already-generated body text (`OutfileText`,
||| reset to empty right before this def's own `createCFunctions` call)
||| to `h`, then clears it. `generateCSourceFile`'s own per-def loop
||| calls this right after `flushStagedDecls`, so a constant this def
||| just staged lands in the file before the def's own body text that
||| references it.
flushEmitBuffer : {auto oft : Ref OutfileText Output} -> (outn : String) -> File -> Core ()
flushEmitBuffer outn h = do
    buf <- get OutfileText
    put OutfileText DList.Nil
    putLines outn h (reify buf)

||| Flushes every constant `boxedConstExpr`/`boxedConstConExpr` staged
||| while lowering the def just processed (`ConstConDef`'s own pending
||| queue, see its doc comment) to `h`, then clears it -- always called
||| before `flushEmitBuffer` for the same def, so a constant a def
||| references is always declared earlier in the file than the def
||| itself, without needing any whole-program forward-reference pass.
flushStagedDecls : {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)} -> (outn : String) -> File -> Core ()
flushStagedDecls outn h = do
    (names, pending) <- get ConstConDef
    put ConstConDef (names, [])
    putLines outn h pending

||| The distinct link-library names (already "lib"-prefix-stripped,
||| see `linkLibName`) every `MkRCForeign` def in the program named via
||| its own standard-FFI `%foreign` lib field -- for `Compiler.RC2.CC`
||| to turn into `-l<name>` flags at link time, so an external library
||| a program's own FFI bindings depend on doesn't need `IDRIS2_LDLIBS`
||| set by hand.
||| The C wrapper synthesised for one validated `%export` declaration
||| (`Compiler.RC2.RC2.validateExport`'s own result): under the
||| user-given `exportedCName`, with native C parameter/return types,
||| boxing each argument, calling the original always-Boxed entry point
||| (`cName !(getFullName n)`, never itself touched/converted -- see
||| `rc2/doc/export-support.md`), then unboxing the trampolined result.
||| Never `static` -- nothing in generated C calls it; it exists purely
||| for an external caller, hand-written C included (see
||| `Test59Export/Test59Export.c`). A boxed `IDRIS2RC2_Value*` return is
||| explicitly `idris2rc2_drop`ped right after `extractValue` reads its
||| payload out (safe and a no-op for every already-unboxed scalar, see
||| `idris2rc2_drop`'s own `idris2rc2_is_unboxed` check) -- unlike
||| `main`'s own footer, which can get away with never dropping its
||| final result because the process exits immediately after, this
||| wrapper can be called arbitrarily many times from external C, so a
||| real heap-allocating return (`CFInt`/`CFInt64`/`CFUnsigned64`/
||| `CFDouble`) would otherwise leak on every call.
|||
||| Three argument/return positions can't use that generic pack-then-
||| call / call-then-extract-then-drop shape as-is, and are special-
||| cased below: a `CFInteger` argument (a raw incoming `mpz_t`, not
||| already an `IDRIS2RC2_Integer*` the way `packCFType`'s own identity-
||| passthrough CFInteger case assumes -- see its doc comment), a
||| `CFInteger` return (GMP's `mpz_t` has no by-value C return shape at
||| all, so the whole wrapper signature gains a leading `mpz_t out`
||| parameter and turns `void`, mirroring `emitGenericForeignWrapper`'s
||| own identical convention for a `%foreign` Integer return), and a
||| `CFString` return (`extractValue`'s own CFString case aliases the
||| Boxed value's own malloc'd buffer -- returning that pointer and
||| *then* dropping the Boxed value it came from would hand the C
||| caller a dangling pointer, so an independent copy is made first).
emitExportWrapper : {auto c : Ref Ctxt Defs}
                  -> {auto oft : Ref OutfileText Output}
                  -> {auto il : Ref IndentLevel Nat}
                  -> Name -> String -> List CFType -> CFType -> Core ()
emitExportWrapper n exportedCName fargs ret = do
    let ret' = peelIORes ret
    let isIntegerReturn = case ret' of CFInteger => True; _ => False
    let isStringReturn = case ret' of CFString => True; _ => False
    -- A `CFString` return is a plain, independently-`malloc`'d buffer the
    -- C caller must `free()` (see the CFString case below) -- declaring
    -- it `const char *` (the shared `cTypeOfCFType CFString` mapping,
    -- meant for %foreign's borrowed-immutable-view convention) would
    -- make that `free()` call discard a qualifier for no reason.
    let retC = the String (if isIntegerReturn then "void"
                            else if isStringReturn then "char *"
                            else cTypeOfCFType ret')
    let params = zip (getArgsNrList fargs 0) fargs
    let paramDecls = map (\(i, ty) => cTypeOfCFType ty ++ " p_\{show i}") params
    let allParamDecls = if isIntegerReturn then "mpz_t out" :: paramDecls else paramDecls
    let sig = "\{retC} \{exportedCName}("
            ++ (if isNil allParamDecls then "void" else showSep ", " allParamDecls)
            ++ ")"
    emit EmptyFC sig
    emit EmptyFC "{"
    increaseIndentation
    traverse_ (\(i, ty) => emit EmptyFC "IDRIS2RC2_Value *a_\{show i} = \{argPack ty i};") params
    -- `ret`'s own un-peeled shape: an `IO`/`IORes`-returning declaration's
    -- compiled entry point carries one extra trailing World parameter
    -- rc2's own `%export` validation (`Compiler.RC2.RC2.validateExport`)
    -- already confirmed is real, not erased -- see that doc comment and
    -- `rc2/doc/export-support.md`'s "World argument" note. `CFWorld`'s
    -- own boxed representation is always NULL, matching `packCFType`/
    -- `extractValue`'s existing CFWorld case exactly.
    let worldArg = case ret of CFIORes _ => ["(IDRIS2RC2_Value *)NULL"]; _ => []
    let boxedArgs = map (\(i, _) => "a_" ++ show i) params ++ worldArg
    fulln <- getFullName n
    let callExpr = "\{cName fulln}(\{showSep ", " boxedArgs})"
    let ranExpr = "idris2rc2_trampoline(\{callExpr})"
    case ret' of
         CFUnit => emit EmptyFC "(void)\{ranExpr};"
         CFInteger => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "mpz_init(out);"
             emit EmptyFC "mpz_set(out, \{extractValue CLangC CFInteger "r"});"
             emit EmptyFC "idris2rc2_drop(r);"
             emit EmptyFC "return;"
         CFString => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "const char *raw = \{extractValue CLangC CFString "r"};"
             emit EmptyFC "size_t len = strlen(raw) + 1;"
             emit EmptyFC "char *result = malloc(len);"
             emit EmptyFC "memcpy(result, raw, len);"
             emit EmptyFC "idris2rc2_drop(r);"
             -- `result` is a plain, independently-allocated buffer, not
             -- an IDRIS2RC2_String -- the C caller now owns it and must
             -- free() it themselves; never pass it to any idris2rc2_*
             -- function.
             emit EmptyFC "return result;"
         _ => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "\{retC} result = \{extractValue CLangC ret' "r"};"
             emit EmptyFC "idris2rc2_drop(r);"
             emit EmptyFC "return result;"
    decreaseIndentation
    emit EmptyFC "}"
  where
    -- `packCFType`'s own CFInteger case is a bare passthrough that
    -- assumes an `IDRIS2RC2_Integer*` was already built elsewhere (real
    -- for a `%foreign` call site's own out-parameter convention, see
    -- its doc comment) -- but here `p_i` is the raw incoming `mpz_t`
    -- itself, so a fresh, independently-owned `IDRIS2RC2_Integer` has
    -- to be copied in first.
    -- `(IDRIS2RC2_Value *)`-cast unconditionally: several `packCFType`
    -- cases (CFPtr/CFGCPtr/CFStruct) return an `IDRIS2RC2_Pointer*`/
    -- `IDRIS2RC2_GCPointer*`-typed call expression, not a bare
    -- `IDRIS2RC2_Value*` one -- every other call site in this module
    -- assigning a `packCFType` result already carries this same cast
    -- (e.g. `emitGenericForeignWrapper`'s own `packedRet` lines) for
    -- exactly this reason; this one just never had an argument-
    -- position CFPtr/CFGCPtr/CFStruct to expose the gap before.
    argPack : CFType -> Nat -> String
    argPack CFInteger i = "(IDRIS2RC2_Value *)idris2rc2_mkIntegerFromMpz(p_\{show i})"
    argPack ty i = "(IDRIS2RC2_Value *)" ++ packCFType ty ("p_" ++ show i)

||| A `%foreign` declaration rc2 can actually implement: either
||| diverted to rc2's own native `fastPack`/`fastConcat` replacement
||| (`fastPackFixedReplacement`, regardless of what its own `ccs` says
||| -- rc2 supplies a native body either way) or carrying a calling
||| convention `parseCC` actually recognizes (`"C:..."`/`"RefC:..."`/
||| `"RC2:..."`). A declaration with neither -- e.g.
||| `Prelude.IO.prim__threadWait`'s `%foreign "scheme:blodwen-thread-wait"`
||| only, no C-family convention at all since only Chez ever needed one
||| -- is a hard whole-program compile error today
||| (`collectDeclarations`'s own `MkRCForeign` case), unreachable in
||| practice since `DeadCode.pruneDeadDefs` already removes an unused
||| declaration like this before `collectDeclarations` ever sees it --
||| deliberately kept as a hard, immediately-attributable error for
||| whole-program mode (naming the exact Idris function) rather than
||| softened into a link-time failure too: if it's ever genuinely
||| reachable there, something in the program truly calls a function
||| rc2 has no way to implement, and that's worth surfacing immediately
||| and unambiguously, not as a mystery "undefined reference" to a
||| mangled C name. Incremental mode, in contrast, deliberately never
||| runs `DeadCode` at all (see rc2/doc/incremental-compile.md's "What
||| actually needs to change") -- every module's *entire* `toIR`, used
||| or not, real convention or not, reaches `collectDeclarations`
||| regardless of whether anything anywhere ever actually calls it, so
||| the same hard error would trip on every unused-in-this-module
||| declaration like this one across the whole standard library. Only
||| there (`dropUnimplementableForeign = True`, `Compiler.RC2.RC2`'s
||| own `incCompile`) is a declaration like this dropped from `defs`
||| silently instead, before this module owns anything to declare --
||| see rc2/doc/incremental-compile.md's "Bugs found while implementing"
||| #3 for the full reasoning and the deliberate whole-program/
||| incremental split. Any real caller (if one exists) still gets a
||| plain `extern` prototype via `externalFunctionRefsD` below, since a
||| dropped name is indistinguishable from an ordinary externally-
||| defined one at that point -- the failure becomes a link-time
||| "undefined reference" there instead of either a compile-time stop
||| or a runtime crash.
hasUsableForeignImpl : (Name, RCDef) -> Bool
hasUsableForeignImpl (n, MkRCForeign ccs fargs ret) =
    case (fastPackFixedReplacement n, ret, fargs) of
         (Just _, CFString, [CFUser _ _]) => True
         _ => isJust (parseCC ffiTags ccs)
hasUsableForeignImpl _ = True

||| `noMain`: `--directive nomain` / `%cg rc2 nomain`, read by
||| `Compiler.RC2.RC2.compileExpr` -- when `True`, `footer` (the C
||| `main()` emitter) is skipped entirely, so the generated `.c` can be
||| linked as a library alongside a caller-supplied `main` (e.g. a
||| companion `.c` driving an `%export`ed symbol directly -- see
||| `rc2/doc/export-support.md`'s own "Linking as a library" section
||| and worked example) without a duplicate-symbol link error.
|||
||| `dropUnimplementableForeign`: see `hasUsableForeignImpl`'s own doc
||| comment -- `False` (whole-program `compileExprWhole`) keeps
||| today's hard compile-time error for a `%foreign` declaration with
||| no rc2-usable convention; `True` (incremental `incCompile`) drops
||| it silently instead, deferring to a link-time error only if
||| something actually calls it.
|||
||| `directEntryPoint`: `Nothing` keeps today's whole-program footer,
||| calling the `ClosedTerm`-synthesized `__mainExpression_0()`
||| (`Compiler.Common.getCompileDataWith`'s own `unsafePerformIO`/
||| `%MkWorld`/closure-`apply` chain, folded down to a single call by
||| the time whole-program `Inline`/`ConstFold` are done with it).
||| `Just call` (`Compiler.RC2.RC2.incCompile`'s own `Main`-module case
||| only) splices `call` -- a complete C call expression, already
||| built by the caller, e.g. `"Main_main(idris2rc2_freshWorld())"` or
||| arity-0 `"Main_main()"` -- verbatim instead. This function itself
||| deliberately knows nothing about `Main.main`'s own real arity or
||| how to build a `%World` token; `incCompile` does, since only it can
||| see `Main.main`'s own actual compiled `MkRCFun` shape in `defs`
||| (observed to vary -- a bare `putStrLn` compiles `Main.main` at
||| arity 1 with a real `%World` token, a multi-statement `do` block
||| calling pure functions at arity 0, folded to a CAF -- hardcoding
||| either one broke the other). `__mainExpression_0` itself is never
||| actually a member of any module's own `toIR`
||| (`Compiler.Common.getIncCompileData`'s own `toIR`-only fetch never
||| produces it, unlike whole-program's `getCompileDataWith`, which
||| synthesizes it fresh from the real `ClosedTerm` every time -- see
||| rc2/doc/incremental-compile.md's "Bugs found while implementing")
||| -- undefined reference otherwise. Never `Just` at the same time as
||| `noMain = True` (mutually exclusive: no footer at all vs. a
||| specific direct-call one).
export
generateCSourceFile : {auto c : Ref Ctxt Defs}
                   -> List (Name, RCDef)
                   -> (exports : List (Name, String, List CFType, CFType))
                   -> (noMain : Bool)
                   -> (directEntryPoint : Maybe String)
                   -> (dropUnimplementableForeign : Bool)
                   -> (injectedRuntime : String)
                   -> (outn : String)
                   -> Core (List String)
generateCSourceFile defs0 exports noMain directEntryPoint dropUnimplementableForeign injectedRuntime outn =
  do let defs = if dropUnimplementableForeign then filter hasUsableForeignImpl defs0 else defs0
     _ <- newRef ArgCounter 0
     _ <- newRef FunctionDefinitions []
     _ <- newRef ConstDef Data.SortedMap.empty
     _ <- newRef ConstConDef (Data.SortedMap.empty, [])
     _ <- newRef OutfileText DList.Nil
     _ <- newRef HeaderFiles empty
     _ <- newRef ForeignLibs empty
     _ <- newRef IndentLevel 0
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
     -- Pass 1: every declaration with a whole-program forward-reference
     -- requirement (function prototypes, plus the header/lib metadata
     -- and early parseCC/MkRCError error detection that ride along --
     -- see `collectDeclarations`'s own doc comment), derived from each
     -- def's own signature alone, no body traversal.
     traverse_ (uncurry collectDeclarations) defs
     -- Forward-declare (as `extern`) every untagged constructor `defs`
     -- itself references but doesn't own -- a no-op set whenever `defs`
     -- really is the whole program (every such constructor is already
     -- declared by the loop just above), but not whenever it's a
     -- single module's own subset (`Compiler.RC2.RC2`'s `incCompile`)
     -- -- see `untaggedConstructorRefsD`'s own doc comment.
     let locallyOwnedCons = SortedSet.fromList $ mapMaybe (\(n, d) => case d of MkRCCon _ _ _ => Just n; _ => Nothing) defs
     let externalCons = foldl (\acc, (_, d) => union acc (untaggedConstructorRefsD d)) Data.SortedSet.empty defs
     let externCons = filter (\n => not (contains n locallyOwnedCons)) (Prelude.toList externalCons)
     update FunctionDefinitions (map (\n => "extern char const idris2rc2_constr_\{cName n}[];") externCons ++)
     -- Same idea, for function names (`externalFunctionRefsD`'s own doc
     -- comment) -- a module-local function is already forward-declared
     -- (exact arity/`Rep`s) by the loop above, so only names outside
     -- that set need this generic fallback declaration. `max` resolves
     -- an arity-bearing `RAppName` sighting against an arity-0
     -- `RUnderApp`/`RCConstClosure` one for the same name in favour of
     -- the real arity, regardless of which order they were seen in.
     let locallyOwnedFns = SortedSet.fromList $ mapMaybe (\(n, d) => case d of MkRCFun{} => Just n; MkRCForeign{} => Just n; _ => Nothing) defs
     let externalFnArity = foldl (\acc, (n, ar) => insertWith max n ar acc) Data.SortedMap.empty (concatMap (externalFunctionRefsD . snd) defs)
     let externFns = filter (\(n, _) => not (contains n locallyOwnedFns)) (SortedMap.toList externalFnArity)
     update FunctionDefinitions (map (\(n, ar) => "extern IDRIS2RC2_Value *\{cName n}(" ++ showSep ", " (replicate ar "IDRIS2RC2_Value *") ++ ");\n") externFns ++)
     -- `withFile`'s own continuation runs in a `HasIO io`-polymorphic
     -- type, and `Core` has no `HasIO` instance -- `createCFunctions`
     -- (which needs `Core`, for e.g. `Ref Ctxt Defs`) can't run inside
     -- it. `openFile`/`closeFile` are driven directly instead, the same
     -- `coreLift` idiom `Core.Core.writeFile` already uses.
     Right h <- coreLift $ openFile outn WriteTruncate
       | Left err => throw $ FileErr outn err
     putLines outn h !header
     -- Pass 2: def-at-a-time body lowering (`createCFunctions`, totally
     -- unchanged, still exactly once per def) into a small per-def
     -- `OutfileText` scratch buffer, flushed straight to `h` before
     -- moving to the next def instead of accumulating in memory for the
     -- whole program -- constants this def staged while lowering
     -- (`flushStagedDecls`) always go out first, so they're declared
     -- before the def's own body text that references them.
     traverse_ (\(n, d) => do
         put OutfileText DList.Nil
         createCFunctions n d
         flushStagedDecls outn h
         flushEmitBuffer outn h) defs
     -- `%export` wrappers: additive, generated after every ordinary def
     -- (Pass 2 above) so the original always-Boxed entry point each one
     -- calls is already emitted -- though C doesn't actually require
     -- that ordering here, since Pass 1's own `collectDeclarations` already
     -- forward-declared every def's own prototype before Pass 2 even started.
     traverse_ (\(n, exportedCName, fargs, ret) => do
         put OutfileText DList.Nil
         emitExportWrapper n exportedCName fargs ret
         flushEmitBuffer outn h) exports
     -- The process entry point: boxes nothing further, just calls the
     -- entry point then trampolines its result. Skipped when `noMain`
     -- (see this function's own doc comment above for why) so a
     -- `%export`ed program can link this `.c` as a library alongside a
     -- caller-supplied `main` instead. `directEntryPoint`'s own doc
     -- comment above has the full story on the two shapes `entryCall`
     -- can take.
     --
     -- `idris2rc2_rtInit()` / `idris2rc2_rtFinish()` (support/rc2/
     -- runtime.c) bracket the whole run: rtInit adopts the environment
     -- locale (`setlocale(LC_ALL, "")`, LC_NUMERIC pinned back to "C")
     -- before any Idris code runs, rtFinish flushes stdio after. A
     -- `noMain` build gets no `main()` here, so its hand-written driver
     -- (doc/export-support.md) is responsible for calling both.
     let entryCall : String = fromMaybe "__mainExpression_0()" directEntryPoint
     when (not noMain) $ emit EmptyFC """

       // main function
       int main(int argc, char *argv[])
       {
           idris2rc2_rtInit();
           \{ ifThenElse (contains "idris_support.h" !(get HeaderFiles))
                         "idris2_setArgs(argc, argv);"
                         ""
           }
           IDRIS2RC2_Value *mainExprVal = \{entryCall};
           idris2rc2_trampoline(mainExprVal);
           idris2rc2_rtFinish();
           return 0;
       }
       """
     flushEmitBuffer outn h
     coreLift $ closeFile h
     log "compiler.refc" 10 $ "Generated C file " ++ outn
     pure (Prelude.toList !(get ForeignLibs))
