module Compiler.RC2.CC

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Invokes the system C compiler to build an executable from generated C code,
-- linking against the `rc2` runtime and upstream Idris2 support library.

import Core.Context.Log
import Core.Options
import Core.Directory

import System
import Idris.Env

import Data.String

%default total

findCC : IO String
findCC
    = do Nothing <- idrisGetEnv "IDRIS2_CC"
           | Just cc => pure cc
         Nothing <- idrisGetEnv "CC"
           | Just cc => pure cc
         pure "cc"

findCFlags : IO String
findCFlags
    = do Nothing <- idrisGetEnv "IDRIS2_CFLAGS"
           | Just v => pure v
         Nothing <- idrisGetEnv "CFLAGS"
           | Just v => pure v
         pure ""

findCPPFlags : IO String
findCPPFlags
    = do Nothing <- idrisGetEnv "IDRIS2_CPPFLAGS"
           | Just v => pure v
         Nothing <- idrisGetEnv "CPPFLAGS"
           | Just v => pure v
         pure ""

findLDFlags : IO String
findLDFlags
    = do Nothing <- idrisGetEnv "IDRIS2_LDFLAGS"
           | Just v => pure v
         Nothing <- idrisGetEnv "LDFLAGS"
           | Just v => pure v
         pure ""

findLDLibs : IO String
findLDLibs
    = do Nothing <- idrisGetEnv "IDRIS2_LDLIBS"
           | Just v => pure v
         Nothing <- idrisGetEnv "LDLIBS"
           | Just v => pure v
         pure ""

clibdirs : List String -> List String
clibdirs ds = map (\d => "-L" ++ d) ds

export
compileCObjectFile : {auto c : Ref Ctxt Defs}
                  -> (sourceFile : String)
                  -> (objectFile : String)
                  -> Core (Maybe String)
compileCObjectFile sourceFile objectFile
    = do cc <- coreLift findCC
         cFlags <- coreLift findCFlags
         cppFlags <- coreLift findCPPFlags

         rc2Dir <- findDataFile "rc2"
         cDir <- findDataFile "c"

         let runccobj = (escapeCmd $
             [cc, "-Werror", "-c", sourceFile,
                  "-o", objectFile,
                  "-I" ++ rc2Dir,
                  "-I" ++ cDir])
                  ++ " " ++ cppFlags ++ " " ++ cFlags

         log "compiler.refc.cc" 10 runccobj
         0 <- coreLift $ system runccobj
           | _ => pure Nothing

         pure (Just objectFile)

||| `foreignLibs` -- distinct link-library names collected from every
||| program-level `%foreign` declaration's own lib field (see
||| `Compiler.RC2.Emit`'s `generateCSourceFile`/`linkLibName`) --
||| become `-l<name>` flags placed right after `objectFile`, ahead of
||| the rc2 runtime and its own dependencies: the symbols they provide
||| are the ones a program's own FFI call sites reference directly, so
||| they need to resolve before anything downstream does. Lets a
||| binding to a genuinely external library (e.g. libcurl) link without
||| the caller having to set `IDRIS2_LDLIBS`/`LDLIBS` by hand.
export
compileCFile : {auto c : Ref Ctxt Defs}
            -> (objectFile : String)
            -> (outFile : String)
            -> (foreignLibs : List String)
            -> Core (Maybe String)
compileCFile objectFile outFile foreignLibs
    = do cc <- coreLift findCC
         cFlags <- coreLift findCFlags
         ldFlags <- coreLift findLDFlags
         ldLibs <- coreLift findLDLibs

         dirs <- getDirs
         rc2Dir <- findDataFile "rc2"
         supportFile <- findLibraryFile "libidris2_support.a"

         let runcc = (escapeCmd $
             [cc, "-Werror", objectFile,
                  "-o", outFile,
                  supportFile
                  ] ++ map ("-l" ++) foreignLibs ++ [
                  "-lidris2rc2",
                  "-L" ++ rc2Dir
                  ] ++ clibdirs (lib_dirs dirs) ++ [
                  "-lgmp", "-lm", "-lpthread"])
                  ++ " " ++ (unwords [cFlags, ldFlags, ldLibs])

         log "compiler.refc.cc" 10 runcc
         0 <- coreLift $ system runcc
           | _ => pure Nothing

         pure (Just outFile)
