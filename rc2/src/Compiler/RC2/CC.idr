module Compiler.RC2.CC

-- Invokes the system C compiler to turn generated C into an executable,
-- linking against our own runtime (libidris2rc2.a, found via the "rc2"
-- data directory) and the cross-backend libidris2_support.a that every
-- Idris2 codegen relies on for basic OS/IO primitives (see
-- support/c/idris_support.c upstream).

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

export
compileCFile : {auto c : Ref Ctxt Defs}
            -> (objectFile : String)
            -> (outFile : String)
            -> Core (Maybe String)
compileCFile objectFile outFile
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
                  supportFile,
                  "-lidris2rc2",
                  "-L" ++ rc2Dir
                  ] ++ clibdirs (lib_dirs dirs) ++ [
                  "-lgmp", "-lm", "-lpthread"])
                  ++ " " ++ (unwords [cFlags, ldFlags, ldLibs])

         log "compiler.refc.cc" 10 runcc
         0 <- coreLift $ system runcc
           | _ => pure Nothing

         pure (Just outFile)
