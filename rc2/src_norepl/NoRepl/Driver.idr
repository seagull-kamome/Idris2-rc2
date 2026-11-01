||| The driver of `Idris.Driver` without the REPL, the IDE protocol, `--yaffle`
||| and `--ttm`: what is left is the batch compiler (`--build`, `--install`,
||| `--check`, `-o`, `--exec` and the options around them). See doc/norepl.md
||| for what was taken from upstream and what was left out.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module NoRepl.Driver

import Compiler.Common

import Core.Binary
import Core.Directory
import Core.InitPrimitives
import Core.Metadata
import Core.UnifyState
import Core.Options
import Core.Unify

import Idris.CommandLine
import Idris.Env
import Idris.Package
import Idris.Parser
import Idris.ProcessIdr
import Idris.REPL
import Idris.SetOptions
import Idris.Syntax
import Idris.Version
import Idris.Error
import Idris.Pretty

import IdrisPaths

import Data.List1
import Data.Maybe
import Data.String
import System
import System.Directory
import System.File.Meta
import System.File.Virtual
import Libraries.Utils.Path
import System.Term

%default covering

public export
CustomBackends : Type
CustomBackends = List (String, Codegen)

findInputs : List CLOpt -> Maybe (List1 String)
findInputs [] = Nothing
findInputs (InputFile f :: fs) =
  let rest = maybe [] toList (findInputs fs)
  in  Just (f ::: rest)
findInputs (_ :: fs) = findInputs fs

splitPaths : String -> List1 String
splitPaths = map trim . split (==pathSeparator)

updateEnv : {auto c : Ref Ctxt Defs} ->
            {auto o : Ref ROpts REPLOpts} ->
            Core ()
updateEnv
    = do defs <- get Ctxt
         noColor <- coreLift [ isJust noc || not tty | noc <- idrisGetEnv "NO_COLOR", tty <- isTTY stdout ]
         when noColor $ setColor False
         bprefix <- coreLift $ idrisGetEnv "IDRIS2_PREFIX"
         setPrefix (fromMaybe yprefix bprefix)
         bpath <- coreLift $ idrisGetEnv "IDRIS2_PATH"
         whenJust bpath $ traverseList1_ addExtraDir . splitPaths
         bdata <- coreLift $ idrisGetEnv "IDRIS2_DATA"
         whenJust bdata $ traverseList1_ addDataDir . splitPaths
         blibs <- coreLift $ idrisGetEnv "IDRIS2_LIBS"
         whenJust blibs $ traverseList1_ addLibDir . splitPaths
         pdirs <- coreLift $ idrisGetEnv "IDRIS2_PACKAGE_PATH"
         whenJust pdirs $ traverseList1_ addPackageSearchPath . splitPaths
         cg <- coreLift $ idrisGetEnv "IDRIS2_CG"
         whenJust cg $ \ e => case getCG (options defs) e of
           Just cg => setCG cg
           Nothing => throw (InternalError ("Unknown code generator " ++ show e))
         inccgs <- coreLift $ idrisGetEnv "IDRIS2_INC_CGS"
         whenJust inccgs $ \ cgs =>
           traverseList1_ (setIncrementalCG False) $
             map trim (split (==',') cgs)
         defs <- get Ctxt
         addPackageSearchPath !pkgGlobalDirectory
         catch (addPkgDir "prelude" anyBounds) (const (pure ()))
         catch (addPkgDir "base" anyBounds) (const (pure ()))
         addDataDir (prefix_dir (dirs (options defs)) </>
                        ("idris2-" ++ showVersion False version) </> "support")
         addLibDir (prefix_dir (dirs (options defs)) </>
                        ("idris2-" ++ showVersion False version) </> "lib")
         Just cwd <- coreLift $ currentDir
              | Nothing => throw (InternalError "Can't get current directory")
         addLibDir cwd

ignoreMissingIpkg : List CLOpt -> Bool
ignoreMissingIpkg [] = False
ignoreMissingIpkg (IgnoreMissingIPKG :: _) = True
ignoreMissingIpkg (c :: cs) = ignoreMissingIpkg cs

checkVerbose : List CLOpt -> Bool
checkVerbose [] = False
checkVerbose (Verbose :: _) = True
checkVerbose (_ :: xs) = checkVerbose xs

unavailable : List CLOpt -> Maybe String
unavailable [] = Nothing
unavailable (Yaffle _ :: _) = Just "--yaffle"
unavailable (Metadata _ :: _) = Just "--ttm"
unavailable (RunREPL _ :: _) = Just "--client"
unavailable (Package REPL _ :: _) = Just "--repl"
unavailable (IdeMode :: _) = Just "--ide-mode"
unavailable (IdeModeSocket _ :: _) = Just "--ide-mode-socket"
unavailable (_ :: xs) = unavailable xs

postOptionsNoRepl : {auto c : Ref Ctxt Defs} ->
                    {auto u : Ref UST UState} ->
                    {auto s : Ref Syn SyntaxInfo} ->
                    {auto o : Ref ROpts REPLOpts} ->
                    {auto m : Ref MD Metadata} ->
                    REPLResult -> PostSession -> Core ControlFlow
postOptionsNoRepl res@(ErrorLoadingFile {}) (MkPostSession _ (Just _) _ _)
    = pure Abort
postOptionsNoRepl _ (MkPostSession check out ex _)
    = do controlFlow <- newRef ControlFlow Continue
         whenJust out $ \ outfile => do
             ignore $ compileExp (PRef EmptyFC (UN $ Basic "main")) outfile
             put ControlFlow Abort
         flip traverse_ (reverse ex) $ \ expr => do
             setCurrentElabSource expr
             let Right (_, _, e) = runParser (Virtual Interactive) Nothing expr $ aPTerm <* eoi
                   | Left err => throw err
             ignore $ execExp e
             put ControlFlow Abort
         when check $
             put ControlFlow Abort
         get ControlFlow

stMain : List (String, Codegen) -> List CLOpt -> Core ()
stMain cgs opts
    = do defs <- initDefs
         let updated = foldl (\o, (s, _) => addCG (s, Other s) o) (options defs) cgs
         c <- newRef Ctxt ({ options := updated } defs)
         s <- newRef Syn initSyntax
         setCG {c} $ maybe Chez (Other . fst) (head' cgs)
         addPrimitives

         setWorkingDir "."
         when (ignoreMissingIpkg opts) $
            setSession ({ ignoreMissingPkg := True } !getSession)

         o <- newRef ROpts (REPL.Opts.defaultOpts Nothing (REPL InfoLvl) cgs)
         updateEnv
         fname <- case (findInputs opts) of
                       Just (fname ::: Nil) => pure $ Just fname
                       Nothing => pure Nothing
                       Just (fname1 ::: fnames) => do
                         let suggestion = nearMatchOptSuggestion fname1
                         renderedSuggestion <- maybe (pure "") render suggestion
                         quitWithError $
                           UserError """
                                     Expected at most one input file but was given: \{joinBy ", " (fname1 :: fnames)}
                                     \{renderedSuggestion}
                                     """
         update ROpts { mainfile := fname }

         s <- newRef PostS defaultPost
         Continue <- preOptions opts
            | Abort => pure ()

         Continue <- flip catch quitWithError $ processPackageOpts opts
            | Abort => pure ()

         flip catch quitWithError $
            do when (checkVerbose opts) $
                   setOutput (REPL InfoLvl)
               u <- newRef UST initUState
               origin <- maybe
                 (pure $ Virtual Interactive) (\fname => do
                   modIdent <- ctxtPathToNS fname
                   pure (PhysicalIdrSrc modIdent)
                   ) fname
               m <- newRef MD (initMetadata origin)
               session <- getSession
               fname <- if findipkg session
                           then findIpkg fname
                           else pure fname
               setMainFile fname
               result <- case fname of
                    Nothing => logTime 1 "Loading prelude" $ do
                                 when (not $ noprelude session) $
                                   readPrelude True
                                 pure Done
                    Just f => logTime 1 "Loading main file" $ do
                                res <- loadMainFile f
                                displayStartupErrors res
                                pure res

               post <- get PostS
               Continue <- catch (postOptionsNoRepl result post)
                               (\err => emitError err *> pure Abort)
                | Abort => do
                     ropts <- get ROpts
                     showTimeRecord
                     whenJust (errorLine ropts) $ \ _ =>
                       coreLift $ exitWith (ExitFailure 1)
               showTimeRecord
               coreLift $ do
                 ignore $ fPutStrLn stderr "idris2-rc2-norepl has no REPL: give it something to do (-o, --exec, --check, --build, --install)"
                 exitWith (ExitFailure 1)

  where

  quitWithError : {auto c : Ref Ctxt Defs} ->
                {auto s : Ref Syn SyntaxInfo} ->
                {auto o : Ref ROpts REPLOpts} ->
                Error -> Core a
  quitWithError err = do
    doc <- display err
    msg <- render doc
    coreLift (die msg)

quitOpts : List CLOpt -> IO ControlFlow
quitOpts [] = pure Continue
quitOpts (Version :: _)
    = do putStrLn versionMsg
         pure Abort
quitOpts (TTCVersion :: _)
    = do printLn ttcVersion
         pure Abort
quitOpts (Help Nothing :: _)
    = do putStrLn usage
         pure Abort
quitOpts (Help (Just HelpLogging) :: _)
    = do putStrLn helpTopics
         pure Abort
quitOpts (Help (Just HelpPragma) :: _)
    = do putStrLn pragmaTopics
         pure Abort
quitOpts (_ :: opts) = quitOpts opts

export
mainNoRepl : List (String, Codegen) -> IO ()
mainNoRepl cgs = do
  Right opts <- getCmdOpts
    | Left err => do ignore $ fPutStrLn stderr $ "Error: " ++ err
                     exitWith (ExitFailure 1)
  Continue <- quitOpts opts
    | Abort => pure ()
  setupTerm
  whenJust (unavailable opts) $ \flag => do
    ignore $ fPutStrLn stderr $ "Error: " ++ flag ++ " is not available without the REPL"
    exitWith (ExitFailure 1)
  coreRun (stMain cgs opts)
    (\err : Error => do ignore $ fPutStrLn stderr $ "Uncaught error: " ++ show err
                        exitWith (ExitFailure 1))
    (\res => pure ())
