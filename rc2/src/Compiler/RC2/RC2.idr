module Compiler.RC2.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Pipeline orchestration:
-- 1. Lifted -> RCExp (`Compiler.RC2.RC`)
-- 2. Constructor reuse (`Compiler.RC2.Reuse`)
-- 3. Native shadow caching (`Compiler.RC2.ConAltNative`)
-- 4. Loop/Tail call conversion (`Compiler.RC2.MutualLoop`, `Compiler.RC2.Loop`)
-- 5. Branch-local sinking (`Compiler.RC2.Sink`)
-- 6. Dual ABI synthesis (`Compiler.RC2.DualABI`)
-- 7. Dead-code elimination (`Compiler.RC2.DeadCode`)
-- 8. Dup merging (`Compiler.RC2.DupMerge`)
-- 9. C generation (`Compiler.RC2.Emit`)
-- 10. C compiler invocation (`Compiler.RC2.CC`)

import Compiler.RC2.CC
import Compiler.RC2.ConAltNative
import Compiler.RC2.ConstFold
import Compiler.RC2.DeadCode
import Compiler.RC2.DualABI
import Compiler.RC2.DupMerge
import Compiler.RC2.Emit
import Compiler.RC2.Emit.Util
import Compiler.RC2.Inline
import Compiler.RC2.Pretty
import Compiler.RC2.RC
import Compiler.RC2.RCExp
import Compiler.RC2.Reuse
import Compiler.RC2.MutualLoop
import Compiler.RC2.Loop
import Compiler.RC2.Sink
import Compiler.RC2.Types

import Compiler.Common
import Compiler.LambdaLift

import Core.CompileExpr
import Core.Context
import Core.Directory
import Core.Env
import Core.Name.Namespace
import Core.Normalise
import Core.Options
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

||| Compiler.RC2.Reuse's pass runs after Compiler.RC2.RC's normalize+
||| annotate are both fully done (it relies on `annotate`'s own RDrop
||| lists -- see its own module note), on each definition's body
||| independently -- reuse offers never cross a function boundary.
applyReuse : RCDef -> RCDef
applyReuse (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (resolveReuse body)
applyReuse (MkRCError body) = MkRCError (resolveReuse body)
applyReuse d@(MkRCCon _ _ _) = d
applyReuse d@(MkRCForeign _ _ _) = d

||| Optional pipeline-stage disabling via `--directive no<stagename>`,
||| for A/B regression isolation without editing `toRCDefs` itself and
||| rebuilding `idris2-rc2`. See `rc2/doc/directives.md` for the full
||| stage list, why `noreuse` isn't (and can't safely be) among them,
||| and why `nomain` is a real directive but not a stage disable.
|||
||| `roots`: names `Compiler.RC2.DeadCode.pruneDeadDefs` must never drop
||| regardless of reachability -- `main`'s own well-known entry name
||| (`MN "__mainExpression" 0`, `Compiler.Common`) plus any `%export`ed
||| names, both supplied by `compileExpr`'s own call site (the latter is
||| currently always `[]` in practice -- rc2 doesn't otherwise implement
||| `%export`, but including it costs nothing and avoids a latent trap
||| if that ever changes).
||| Iteration cap for `foldConstProgram`'s own whole-program fixpoint
||| loop, chosen the same way GHC picks `-fmax-simplifier-iterations`'s
||| default (4): monotonicity (a CAF only ever transitions from "not
||| yet known foldable" to "foldable", never back) means the loop would
||| naturally halt on its own once `CafTable` stops growing, bounded by
||| the total number of 0-arg top-level definitions in the program --
||| but a fixed cap on top guards against a pathological input still
||| taking unboundedly many iterations to reach that point. Hitting the
||| cap only leaves some CAFs un-inlined across a call boundary (a
||| missed optimisation), never an incorrect fold -- see Test76's own
||| module note for the mutual-recursion case this exists for.
maxConstFoldIterations : Nat
maxConstFoldIterations = 4

||| Runs `Compiler.RC2.ConstFold.foldConstDef` over every definition in
||| `defs0` (Phase 1 output, pre-`ConstFold`, from `toRCDefPreFold`),
||| rebuilding `CafTable` after each pass via `cafValueOf` and looping
||| again as long as the table's own key count is still growing (a CAF
||| newly proven foldable this round might be exactly what unblocks
||| another CAF -- or an ordinary `RAppName` call site -- next round),
||| up to `maxConstFoldIterations`.
foldConstProgram : List (Name, RCDef) -> List (Name, RCDef)
foldConstProgram defs0 = go maxConstFoldIterations empty defs0
  where
    rebuildTable : List (Name, RCDef) -> CafTable
    rebuildTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    go : Nat -> CafTable -> List (Name, RCDef) -> List (Name, RCDef)
    go Z _ defs = defs
    go (S fuel) table defs =
        let folded = map (\(n, d) => (n, foldConstDef table d)) defs
            table' = rebuildTable folded
        in if length (SortedMap.toList table') == length (SortedMap.toList table)
              then folded
              else go fuel table' folded

||| The stage names `--directive noXXX`/`%cg rc2 noXXX` can disable
||| (`rc2/doc/directives.md`) -- factored out so whole-program
||| `compileExprWhole` and per-module `incCompile`
||| (rc2/doc/incremental-compile.md) derive their own `disabled` list
||| from the very same set instead of two literals that could drift
||| apart.
disableableStageNames : List String
disableableStageNames =
    ["noinline", "noconstfold", "noconaltnative", "nomutualloop", "noloop", "nosink", "nodualabi", "nodeadcode", "nodupmerge"]

||| `incremental`: `Compiler.RC2.RC.toRCDefPreFold` throws (tagged
||| `notInlinedStructFieldMarker`) for a definition like
||| `System.FFI.getField` itself -- one that only works once its own
||| caller inlines it down to a literal struct/field name, never as a
||| standalone compiled function (rc2/doc/incremental-compile.md's "no
||| C struct support under --inc rc2"). Whole-program compilation
||| (`incremental = False`) never actually throws this in practice
||| (such a definition's own un-inlined form was already excluded by
||| upstream's own reachable-from-`main` fetch before `toRCDefs` ever
||| sees it) -- `False` here preserves that exactly, an uncaught
||| `InternalError` if it's ever somehow reached. Incremental mode's
||| own `toIR`-scoped `defs` has no such luxury (every definition a
||| module makes is compiled for real, reachable or not) -- `True`
||| catches exactly that one marker and drops the offending definition
||| from the result instead of aborting the whole module's compile,
||| same "unimplementable, fails at link time instead" treatment
||| `Emit.idr`'s own `hasUsableForeignImpl` gives an unusable `%foreign`
||| declaration.
toRCDefs : {auto c : Ref Ctxt Defs} -> List String -> (incremental : Bool) -> (roots : List Name) -> List (Name, LiftedDef) -> Core (List (Name, RCDef))
toRCDefs disabled incremental roots lds0 = do
    lds <- if "noinline" `elem` disabled then pure lds0 else logTime 2 "rc2: Inline" $ applyInlineLifted lds0
    preFolded <- logTime 2 "rc2: RC normalize" $
                   if not incremental
                      then traverse (\(n, ld) => do d <- toRCDefPreFold n ld; pure (n, d)) lds
                      else do
                        results <- traverse (\(n, ld) =>
                            catch (map (\d => Just (n, d)) (toRCDefPreFold n ld))
                                  (\err => case err of
                                                InternalError msg =>
                                                    if isInfixOf notInlinedStructFieldMarker msg
                                                       then pure Nothing
                                                       else throw err
                                                _ => throw err))
                            lds
                        pure (mapMaybe id results)
    folded <- if "noconstfold" `elem` disabled
                 then pure preFolded
                 else logTime 2 "rc2: ConstFold (whole-program fixpoint)" $ pure (foldConstProgram preFolded)
    reused <- logTime 2 "rc2: RC annotate + Reuse + ConAltNative" $
                traverse (\(n, d) => do
                  d1 <- toRCDefPostFold d
                  let d2 = applyReuse d1
                  let d3 = if "noconaltnative" `elem` disabled then d2 else applyConAltNative d2
                  pure (n, d3)) folded
    merged <- if "nomutualloop" `elem` disabled then pure reused else logTime 2 "rc2: Mutual loop" $ applyMutualLoop reused
    looped <- if "noloop" `elem` disabled
                 then pure merged
                 else logTime 2 "rc2: Loop conversion" $
                        let calleeTable = buildCalleeTable merged
                        in pure (map (\(n, d) => (n, applyLoop calleeTable n d)) merged)
    sunk <- if "nosink" `elem` disabled
               then pure looped
               else logTime 2 "rc2: Sink" $ pure (map (\(n, d) => (n, applySink d)) looped)
    dualABId <- if "nodualabi" `elem` disabled
       then pure sunk
       else logTime 2 "rc2: DualABI" $ do
           withWorkers <- applyDualABI sunk
           (ffiWorkers, ffiInlineMap) <- ffiWorkerTable sunk
           let rewritten = applyCallSiteRewrite ffiWorkers withWorkers
           pure (inlineFFIWorkers ffiInlineMap rewritten)
    pruned <- if "nodeadcode" `elem` disabled
                 then pure dualABId
                 else logTime 2 "rc2: Dead code elimination" $ pure (pruneDeadDefs roots dualABId)
    if "nodupmerge" `elem` disabled
       then pure pruned
       else logTime 2 "rc2: Dup merge" $ pure (map (\(n, d) => (n, applyDupMerge d)) pruned)

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
||| `TODO.md`'s "Semantics: `Lazy`/`Force`..." entry). rc2 doesn't
||| implement that memoization (see the same TODO.md entry's own
||| follow-up for why it's more than a small fix), but the detection
||| itself is free: `CompileData.namedDefs` is populated unconditionally
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
||| EmitUtil's own cTypeOfCFType/extractValue/packCFType CFStruct cases
||| already alias CFPtr's verbatim) -- plus the PrimIO IO/IORes wrapper
||| (peeled to CFIORes so Compiler.RC2.DualABI's own peelIORes applies
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
             -- getField/setField site (EmitUtil's collectStructDefs,
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
||| %export marshalling path (`EmitUtil`'s `packCFType`/`extractValue`)
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
||| `lambdaLifted cdata`'s keys are already full names -- `getFullName`
||| bridges the two so the `SortedMap Name LiftedDef` lookup below
||| actually finds the def instead of silently missing it.
validateExport : {auto c : Ref Ctxt Defs} -> SortedMap Name LiftedDef -> (Name, String) -> Core (Name, String, List CFType, CFType)
validateExport liftedByName (n, exportedName) = do
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
    let Just ld = lookup n' liftedByName
        | Nothing => throw $ InternalError "[rc2] %export \{exportedName}: \{show n'} has no Lifted def"
    ldArgs <- the (Core (List Name)) $ case ld of
                   MkLFun largs _ _ => pure largs
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
     let disabledStages = filter (`elem` directiveList) disableableStageNames
     -- `nomain`: not a stage disable, only controls whether `Emit.idr`'s
     -- `footer` emits a C `main()` -- see rc2/doc/directives.md and
     -- rc2/doc/export-support.md's "Linking as a library" section.
     let noMain = "nomain" `elem` directiveList
     cdata <- getCompileDataWith ["RC2", "RefC", "C"] False Lifted tm
     let liftedByName = SortedMap.fromList (lambdaLifted cdata)
     exportedSigs <- traverse (validateExport liftedByName) (exported cdata)
     -- `exported cdata`'s own Name is `Resolved` (Compiler.Common's
     -- `getExports` calls `resolved`, not `toFullNames`), but every
     -- entry in `defs`/`lambdaLifted cdata` is keyed by full name --
     -- `Compiler.RC2.DeadCode.pruneDeadDefs`'s own reachability is a
     -- structural `Name` set-membership check, so a root given as a
     -- `Resolved` name would silently never match anything and get
     -- pruned as unreachable regardless of this list's own intent.
     -- `exportedSigs`'s own first component (`validateExport`'s
     -- `getFullName`-resolved `n'`) is reused here rather than
     -- re-deriving it a second time from `exported cdata` directly.
     let roots = MN "__mainExpression" 0 :: map (\(n, _, _, _) => n) exportedSigs
     defs <- toRCDefs disabledStages False roots (lambdaLifted cdata)

     -- `dumprcexpr`: dump the final RCExp to a `.rcexpr` file -- see
     -- rc2/doc/reading-the-ir.md for the format, rc2/doc/directives.md
     -- for the directive.
     when ("dumprcexpr" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".rcexpr")
             (prettyProgram (collectLazyCAFs (namedDefs cdata)) defs)

     -- `dumpdualabi`: dump Stage 2's own eligibility analysis -- see
     -- rc2/doc/dual-abi.md, rc2/doc/directives.md.
     when ("dumpdualabi" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".dualabi") (dumpDualABI defs)

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

     foreignLibs <- logTime 2 "rc2: C generation" $ generateCSourceFile defs exportedSigs noMain Nothing False injectedRuntime externStructs outn
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
    cdata <- getIncCompileData False Lifted
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
         let disabledStages = nub ("nodeadcode" :: filter (`elem` directiveList) disableableStageNames)
         defs <- toRCDefs disabledStages True [] (lambdaLifted cdata)
         -- `Main.main`'s own *compiled* arity isn't a fixed 0-or-1 --
         -- observed both across two small test programs (a bare
         -- `putStrLn`: arity 1, a real `%World` token; a multi-
         -- statement `do` block calling `sort`/`SortedMap` operations:
         -- arity 0, folded to a CAF) -- so `directEntryPoint`'s own
         -- call expression is built from whatever `defs` (after the
         -- very `toRCDefs` call above, so post-ConstFold/-Inline) says
         -- `Main.main`'s real `MkRCFun` arity actually is, never
         -- hardcoded. `__mainExpression_0` is never a member of any
         -- module's own `toIR` at all (`Emit.idr`'s `directEntryPoint`
         -- doc comment has the full story on why the Main module's own
         -- footer must call `Main.main` directly instead), so
         -- `Nothing` here would be a straight undefined-reference bug,
         -- not a graceful fallback -- hence the `assert_total`-style
         -- `InternalError` (not a quiet `Nothing`) if `Main.main`
         -- somehow isn't a `MkRCFun` in `defs` at all.
         --
         -- Arity 0 is *not* "already a ready-to-run action, just call
         -- it" -- confirmed wrong the hard way (a `Hello2.idr` with
         -- pure `let`-bindings ahead of its own first real IO action
         -- built a valid executable that silently did nothing at all:
         -- `--directive dumprcexpr` showed `Main.main`'s own body
         -- building its own `let`-bound values, then ending in
         -- `partial Main.{main:31} missing=1 [v0]` -- i.e. calling
         -- `Main_main()` with no args only *builds a closure* still
         -- missing the `%World` argument, exactly the same
         -- under-application `RUnderApp` compiles to anywhere else; it
         -- never runs anything on its own). So arity 0 needs the exact
         -- same closure-`apply` step whole-program mode's own
         -- `PrimIO.unsafeCreateWorld` body (`apply v0 v1`) already
         -- does for this identical reason -- `idris2rc2_applyClosure`,
         -- the general-purpose runtime function every other
         -- under-applied closure in the entire program is *always*
         -- fed through, not something specific to this footer. Arity
         -- >=1 needs no such thing: `Main.main` itself already *is*
         -- the real C function taking the `%World` token as one of
         -- its own genuine parameters, so a direct call already does
         -- the equivalent of that same `apply` for free.
         let mainMainName = NS mainNS (UN (Basic "main"))
         directEntryPoint <- the (Core (Maybe String)) $
             if noMain
                then pure Nothing
                else case lookup mainMainName defs of
                          Just (MkRCFun [] _ _ _) => pure (Just "idris2rc2_applyClosure(\{cName mainMainName}(), idris2rc2_freshWorld())")
                          Just (MkRCFun _ _ _ _) => pure (Just "\{cName mainMainName}(idris2rc2_freshWorld())")
                          _ => throw $ InternalError "[rc2] incremental compile: Main module has no Main.main function"
         when ("dumprcexpr" `elem` directiveList) $ do
             rcexprFile <- getTTCFileName sourceFile "rcexpr"
             coreLift_ $ writeFile rcexprFile
                 (prettyProgram (collectLazyCAFs (namedDefs cdata)) defs)
         extraRuntimeFiles <- getExtraRuntime directiveList
         let inlineRuntime = getInlineRuntime directiveList
         let injectedRuntime = extraRuntimeFiles ++ (if inlineRuntime == "" then "" else "\n" ++ inlineRuntime)
         let externStructs = getExternStructs directiveList
         outC <- getTTCFileName sourceFile "c"
         outO <- getTTCFileName sourceFile "o"
         objRel <- getObjFileName sourceFile "o"
         foreignLibs <- logTime 2 "rc2: incremental C generation" $
             generateCSourceFile defs [] noMain directEntryPoint True injectedRuntime externStructs outC
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
