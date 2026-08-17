module Compiler.RC2.RC2

-- Pipeline orchestration: 
-- 1. Lifted -> RCExp (`Compiler.RC2.RC`)
-- 2. Constructor reuse (`Compiler.RC2.Reuse`)
-- 3. Native shadow caching (`Compiler.RC2.ConAltNative`)
-- 4. Loop/Tail call conversion (`Compiler.RC2.MutualLoop`, `Compiler.RC2.Loop`)
-- 5. Dual ABI synthesis (`Compiler.RC2.DualABI`)
-- 6. C generation (`Compiler.RC2.Emit`)
-- 7. C compiler invocation (`Compiler.RC2.CC`)

import Compiler.RC2.CC
import Compiler.RC2.ConAltNative
import Compiler.RC2.DualABI
import Compiler.RC2.Emit
import Compiler.RC2.Inline
import Compiler.RC2.Pretty
import Compiler.RC2.RC
import Compiler.RC2.RCExp
import Compiler.RC2.Reuse
import Compiler.RC2.MutualLoop
import Compiler.RC2.Loop

import Compiler.Common
import Compiler.LambdaLift

import Core.Context
import Core.Directory
import Core.Options

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
applyReuse (MkRCFun args retRep body) = MkRCFun args retRep (resolveReuse body)
applyReuse (MkRCError body) = MkRCError (resolveReuse body)
applyReuse d@(MkRCCon _ _ _) = d
applyReuse d@(MkRCForeign _ _ _) = d

||| Optional pipeline-stage disabling, via `--directive
||| no<stagename>`, for A/B regression isolation (e.g. "does this
||| observed difference/leak trace back to one specific pass") without
||| editing `toRCDefs` itself and rebuilding `idris2-rc2` -- the whole
||| reason this exists is that doing exactly that by hand (comment out
||| one `. applyX` in the pipeline above, rebuild, retest, put it back,
||| rebuild again) is what `Compiler.RC2.ConAltNative`'s own two
||| reverted implementation attempts needed to isolate their own bugs
||| from pre-existing ones (see `KNOWN-BUGS.md`'s own two small
||| pre-existing leaks, told apart from that work this way). Recognised
||| directives: `noinline`, `noreuse`, `noconaltnative`, `nomutualloop`,
||| `noloop`, `nodualabi` (disables both `DualABI`'s own worker/wrapper
||| synthesis *and* its own call-site rewriting together -- the rewrite
||| needs the worker table the synthesis step builds, so splitting them
||| wouldn't be meaningful). Each stage is still purely additive/optional
||| in the sense that skipping any of them should still produce *correct*
||| (if less optimised, and possibly no longer byte-for-byte matching
||| real `idris2 --cg refc`'s own output shape) C -- none of
||| `Compiler.RC2.Inline`/`Reuse`/`ConAltNative`/`MutualLoop`/`Loop`/
||| `DualABI` is required by anything downstream of it for correctness,
||| only for the optimisation it itself provides. "Not perfectly
||| complete" by design: a coarse, whole-stage on/off switch, not
||| fine-grained per-function/per-node control.
toRCDefs : List String -> List (Name, LiftedDef) -> Core (List (Name, RCDef))
toRCDefs disabled lds0 = do
    lds <- if "noinline" `elem` disabled then pure lds0 else applyInlineLifted lds0
    reused <- traverse (\(n, ld) => do
                  d0 <- toRCDef ld
                  let d1 = if "noreuse" `elem` disabled then d0 else applyReuse d0
                  let d2 = if "noconaltnative" `elem` disabled then d1 else applyConAltNative d1
                  pure (n, d2)) lds
    merged <- if "nomutualloop" `elem` disabled then pure reused else applyMutualLoop reused
    let looped = if "noloop" `elem` disabled
                    then merged
                    else map (\(n, d) => (n, applyLoop n d)) merged
    if "nodualabi" `elem` disabled
       then pure looped
       else do
           withWorkers <- applyDualABI looped
           pure $ applyCallSiteRewrite withWorkers

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
     -- this one `directives sess` list -- upstream idris2's own generic
     -- per-invocation string passthrough (see Compiler.ES.Codegen's own
     -- "minimal"/"compact" directives for precedent), so none of this
     -- needs any changes to idris2-src itself. Fetched once, up front,
     -- since `toRCDefs`'s own pipeline-stage disabling (see its own doc
     -- comment) needs it before `toRCDefs` runs, not just after like
     -- `dumprcexpr`/`dumpdualabi` (which only ever inspect its *output*).
     sess <- getSession
     let disabledStages = filter (`elem` directives sess)
                             ["noinline", "noreuse", "noconaltnative", "nomutualloop", "noloop", "nodualabi"]
     cdata <- getCompileData False Lifted tm
     defs <- toRCDefs disabledStages (lambdaLifted cdata)

     -- `--directive dumprcexpr`: dump the final RCExp -- this exact
     -- `defs`, after every non-disabled stage above has run, i.e.
     -- precisely what generateCSourceFile is about to consume -- to a
     -- human-readable `.crexpr` file next to the `.c` output. Purely a
     -- debugging aid (see Pretty.idr's own module note); idris2-src's
     -- own generic `--dumplifted`/`--dumpanf`/etc. hooks (wired
     -- entirely inside Compiler.Common.getCompileDataWith, already used
     -- above via getCompileData) don't reach this far -- RCExp only
     -- exists after rc2's own toRCDefs runs.
     when ("dumprcexpr" `elem` directives sess) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".rcexpr") (prettyProgram defs)

     -- `--directive dumpdualabi`: Stage 2's own verification tool for
     -- the (not yet wired into this pipeline) dual-calling-convention
     -- eligibility analysis -- see Compiler.RC2.DualABI's own module
     -- note and doc/loop-conversion.md-style follow-up notes once this
     -- lands. Same "--directive" mechanism as dumprcexpr above.
     when ("dumpdualabi" `elem` directives sess) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".dualabi") (dumpDualABI defs)

     generateCSourceFile defs outn
     Just _ <- compileCObjectFile outn outobj
       | Nothing => pure Nothing
     compileCFile outobj outexec

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
