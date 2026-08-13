module Compiler.RC2.RC2

-- Orchestration: getCompileData (stopping at the Lifted phase -- rc2 does
-- not use Compiler.ANF at all) -> Compiler.RC2.RC (Lifted -> RCExp) ->
-- Compiler.RC2.Reuse (constructor-reuse-in-place, on the fully
-- Phase-1+2'd tree) -> Compiler.RC2.MutualLoop (mutual tail recursion
-- loop conversion, whole-program) -> Compiler.RC2.Loop (self-tail-call
-- loop conversion -- including MutualLoop's own synthesised merged
-- functions, whose internal transitions are already ordinary self-
-- tail-calls by construction) -> Compiler.RC2.Emit (RCExp -> C) ->
-- Compiler.RC2.CC (cc invocation).

import Compiler.RC2.CC
import Compiler.RC2.Emit
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
applyReuse (MkRCFun args isLoop body) = MkRCFun args isLoop (resolveReuse body)
applyReuse (MkRCError body) = MkRCError (resolveReuse body)
applyReuse d@(MkRCCon _ _ _) = d
applyReuse d@(MkRCForeign _ _ _) = d

toRCDefs : List (Name, LiftedDef) -> Core (List (Name, RCDef))
toRCDefs lds = do
    reused <- traverse (\(n, ld) => (n,) . applyReuse <$> toRCDef ld) lds
    merged <- applyMutualLoop reused
    pure $ map (\(n, d) => (n, applyLoop n d)) merged

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
     cdata <- getCompileData False Lifted tm
     defs <- toRCDefs (lambdaLifted cdata)

     -- `--directive dumprcexp`: dump the final RCExp -- this exact
     -- `defs`, after Reuse/MutualLoop/Loop have all run, i.e. precisely
     -- what generateCSourceFile is about to consume -- to a human-
     -- readable `.crexpr` file next to the `.c` output. Purely a
     -- debugging aid (see Pretty.idr's own module note); idris2-src's
     -- own generic `--dumplifted`/`--dumpanf`/etc. hooks (wired
     -- entirely inside Compiler.Common.getCompileDataWith, already used
     -- above via getCompileData) don't reach this far -- RCExp only
     -- exists after rc2's own toRCDefs runs. `--directive` is upstream
     -- idris2's own generic per-invocation string passthrough (see
     -- Compiler.ES.Codegen's own "minimal"/"compact" directives for
     -- precedent), so this needs no changes to idris2-src at all.
     sess <- getSession
     when ("dumprcexp" `elem` directives sess) $
         coreLift_ $ writeFile (outputDir </> outfile ++ ".crexpr") (prettyProgram defs)

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
