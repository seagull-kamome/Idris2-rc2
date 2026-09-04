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
-- 8. C generation (`Compiler.RC2.Emit`)
-- 9. C compiler invocation (`Compiler.RC2.CC`)

import Compiler.RC2.CC
import Compiler.RC2.ConAltNative
import Compiler.RC2.ConstFold
import Compiler.RC2.DeadCode
import Compiler.RC2.DualABI
import Compiler.RC2.Emit
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

||| Optional pipeline-stage disabling, via `--directive
||| no<stagename>`, for A/B regression isolation (e.g. "does this
||| observed difference/leak trace back to one specific pass") without
||| editing `toRCDefs` itself and rebuilding `idris2-rc2` (this
||| A/B-isolation need is exactly what rc2/doc/con-alt-native.md's
||| "Bugs found and fixed" #1-2 describe hitting by hand, before this
||| mechanism existed). Recognised
||| directives: `noinline`, `noconstfold` (disables
||| `Compiler.RC2.ConstFold`'s own whole-program fixpoint fold --
||| `Compiler.RC2.ConstExtPrim`'s own fold, run unconditionally inside
||| `toRCDefPreFold`, is unaffected), `noconaltnative`, `nomutualloop`,
||| `noloop`, `nosink`, `nodualabi` (disables both `DualABI`'s own
||| worker/wrapper synthesis *and* its own call-site rewriting together
||| -- the rewrite needs the worker table the synthesis step builds, so
||| splitting them wouldn't be meaningful), `nodeadcode` (disables
||| `Compiler.RC2.DeadCode`'s own pruning -- see that module's own
||| header note for what it removes and why). Each stage is still purely
||| additive/optional in the sense that skipping any of them should
||| still produce *correct*
||| (if less optimised, and possibly no longer byte-for-byte matching
||| real `idris2 --cg refc`'s own output shape) C -- none of
||| `Compiler.RC2.Inline`/`ConAltNative`/`MutualLoop`/`Loop`/
||| `Sink`/`DualABI`/`DeadCode` is required by anything downstream of it
||| for correctness, only for the optimisation it itself provides. "Not
||| perfectly complete" by design: a coarse, whole-stage on/off switch,
||| not fine-grained per-function/per-node control.
|||
||| `noreuse` is deliberately not in this list -- retired, not merely
||| undocumented. See `KNOWN-BUGS.md`'s "Retired: `--directive noreuse`
||| no longer exists" for why: it was never actually safely
||| independent/disableable, and the ability to disable `Reuse` this
||| way was removed entirely -- `applyReuse` now always runs,
||| unconditionally.
|||
||| `nomain` is also not in this list, for the opposite reason: it's a
||| real, currently-supported directive, just not a pipeline-stage
||| disable -- it's read as its own plain `Bool` directly in
||| `compileExpr` (not threaded through `toRCDefs`/`disabled` at all)
||| and only affects whether `Emit.idr`'s `footer` emits a C `main()`.
||| See `compileExpr`'s own `noMain` binding for what it's for.
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

toRCDefs : {auto c : Ref Ctxt Defs} -> List String -> (roots : List Name) -> List (Name, LiftedDef) -> Core (List (Name, RCDef))
toRCDefs disabled roots lds0 = do
    lds <- if "noinline" `elem` disabled then pure lds0 else logTime 2 "rc2: Inline" $ applyInlineLifted lds0
    preFolded <- logTime 2 "rc2: RC normalize" $
                   traverse (\(n, ld) => do d <- toRCDefPreFold n ld; pure (n, d)) lds
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
    if "nodeadcode" `elem` disabled
       then pure dualABId
       else logTime 2 "rc2: Dead code elimination" $ pure (pruneDeadDefs roots dualABId)

||| `%cg rc2 inlineRuntime=<code>` companion to upstream's own
||| file-path-based `Compiler.Common.getExtraRuntime` (no inline-text
||| equivalent exists there) -- same `key=value` directive shape,
||| except the value is spliced as literal C text directly instead of
||| being read from a file. MUST stay on one line: Idris2's own `%cg`
||| lexer (`Parser.Lexer.Source`'s `cgDirective`) has a braced `{ ... }`
||| form that stops at the *first* literal `}`, with no nesting support
||| -- real C (any function body) always has a closing `}`, so that
||| form would silently truncate. The plain, unbraced form it falls
||| back to instead just consumes the rest of the line verbatim with no
||| brace-balancing at all, which is what `inlineRuntime=` (starting
||| with `i`, never `{`) always hits.
|||
||| A second, sharper landmine: the code MUST NOT end with a literal
||| `}` after trimming. `Idris.Parser`'s `stripBraces` unconditionally
||| strips one trailing `}` (and one leading `{`) from a %cg directive's
||| captured text no matter which lexer alternative produced it -- it
||| has no way to tell "this `}` is the real, load-bearing end of a C
||| function body" from "this `}` is the braced form's own delimiter".
||| Since any C function definition ends in `}`, this WILL silently eat
||| it, and the resulting mangled C won't fail until gcc chokes on it
||| much later with a confusing error far from the actual cause. Ending
||| the directive with a trailing `;` (a harmless empty top-level C
||| declaration) after the function's own `}` sidesteps this, since
||| that `;` -- not the `}` before it -- becomes the new last character.
||| See the README's own "%cg rc2 directives" section for the
||| user-facing version of both notes.
getInlineRuntime : List String -> String
getInlineRuntime directives = concat $ intersperse "\n" $ nub $ mapMaybe getArg $ reverse directives
  where
    getArg : String -> Maybe String
    getArg directive =
      let (k, v) = String.break (== '=') directive
      in if trim k == "inlineRuntime"
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
         -- finalizer (`Compiler.RC2.EmitUtil`'s own `packCFType
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

export
compileExpr : Ref Ctxt Defs
           -> Ref Syn SyntaxInfo
           -> (tmpDir : String)
           -> (outputDir : String)
           -> ClosedTerm
           -> (outfile : String)
           -> Core (Maybe String)
compileExpr c s _ outputDir tm outfile =
  do let outn = outputDir </> outfile ++ ".c"
     let outobj = outputDir </> outfile ++ ".o"
     let outexec = outputDir </> outfile

     coreLift_ $ mkdirAll outputDir

     -- `--directive dumprcexpr`/`dumpdualabi`/`no<stagename>` all share
     -- this one `directiveList` -- upstream idris2's own generic
     -- per-invocation string passthrough (see Compiler.ES.Codegen's own
     -- "minimal"/"compact" directives for precedent), so none of this
     -- needs any changes to idris2-src itself. `getDirectives (Other
     -- "rc2")` (rc2's own registered codegen name, `Main.idr`) unions
     -- CLI `--directive` flags with any `%cg rc2 <directive>` pragma
     -- written directly in Idris2 source -- also fully generic upstream
     -- machinery (`Core.Context.addDirective`/`cgdirectives`, aggregated
     -- across transitive imports, persisted in TTC); rc2 previously only
     -- read the CLI half via `getSession`, silently ignoring any source
     -- `%cg rc2 ...` pragma. Fetched once, up front, since `toRCDefs`'s
     -- own pipeline-stage disabling (see its own doc comment) needs it
     -- before `toRCDefs` runs, not just after like `dumprcexpr`/
     -- `dumpdualabi` (which only ever inspect its *output*).
     directiveList <- getDirectives (Other "rc2")
     let disabledStages = filter (`elem` directiveList)
                             ["noinline", "noconstfold", "noconaltnative", "nomutualloop", "noloop", "nosink", "nodualabi", "nodeadcode"]
     -- `--directive nomain` / `%cg rc2 nomain`: NOT a pipeline-stage
     -- disable (unlike `disabledStages` above) -- it only controls
     -- whether `Emit.idr`'s `footer` emits a C `main()` at all, so it's
     -- read as its own plain `Bool` instead of being folded into that
     -- list. Exists so a `%export`ed program can be linked as a library
     -- into a hand-written C driver that supplies its own `main`,
     -- without a duplicate-symbol link error -- see
     -- rc2/doc/export-support.md's "Linking as a library" section and
     -- worked example for the end-to-end scenario this fixes.
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
     defs <- toRCDefs disabledStages roots (lambdaLifted cdata)

     -- `--directive dumprcexpr` / `%cg rc2 dumprcexpr`: dump the final
     -- RCExp -- this exact `defs`, after every non-disabled stage above
     -- has run, i.e. precisely what generateCSourceFile is about to
     -- consume -- to a human-readable `.crexpr` file next to the `.c`
     -- output. Purely a debugging aid (see Pretty.idr's own module
     -- note); idris2-src's own generic `--dumplifted`/`--dumpanf`/etc.
     -- hooks (wired entirely inside Compiler.Common.getCompileDataWith,
     -- already used above via getCompileData) don't reach this far --
     -- RCExp only exists after rc2's own toRCDefs runs.
     when ("dumprcexpr" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".rcexpr")
             (prettyProgram (collectLazyCAFs (namedDefs cdata)) defs)

     -- `--directive dumpdualabi` / `%cg rc2 dumpdualabi`: Stage 2's own
     -- verification tool for the (not yet wired into this pipeline)
     -- dual-calling-convention eligibility analysis -- see
     -- Compiler.RC2.DualABI's own module note and doc/loop-conversion.md-
     -- style follow-up notes once this lands. Same directive mechanism
     -- as dumprcexpr above.
     when ("dumpdualabi" `elem` directiveList) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".dualabi") (dumpDualABI defs)

     -- `--directive dumpcc` / `%cg rc2 dumpcc`: print the exact C
     -- compile/link command(s) about to run to stdout -- same
     -- directive mechanism as dumprcexpr/dumpdualabi above, but read
     -- here (rather than only inside Compiler.RC2.CC) since it's
     -- `compileExpr`'s own call sites that need the extra `verbose`
     -- argument threaded through.
     let dumpCC = "dumpcc" `elem` directiveList

     -- `%cg rc2 extraRuntime=<path>` / `inlineRuntime=<code>`: splice
     -- arbitrary C straight into the generated output, right after its
     -- own `#include`s (Emit.idr's `header`) -- `extraRuntime` reuses
     -- upstream's own generic, backend-agnostic file-based directive
     -- (`Compiler.Common.getExtraRuntime`, same one the Chez backend
     -- uses for `%cg chez extraRuntime=file.ss`) verbatim; `inlineRuntime`
     -- is this backend's own text-instead-of-a-file companion (see
     -- `getInlineRuntime`'s own doc comment for its one-line
     -- constraint). Real upstream RefC has no equivalent at all --
     -- it never reads `--directive`/`%cg` for anything.
     extraRuntimeFiles <- getExtraRuntime directiveList
     let inlineRuntime = getInlineRuntime directiveList
     let injectedRuntime = extraRuntimeFiles ++ (if inlineRuntime == "" then "" else "\n" ++ inlineRuntime)

     foreignLibs <- logTime 2 "rc2: C generation" $ generateCSourceFile defs exportedSigs noMain injectedRuntime outn
     Just _ <- logTime 2 "rc2: C compile" $ compileCObjectFile outn outobj dumpCC
       | Nothing => pure Nothing
     logTime 2 "rc2: C link" $ compileCFile outobj outexec foreignLibs dumpCC

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
codegenRC2 = MkCG compileExpr executeExpr Nothing Nothing
