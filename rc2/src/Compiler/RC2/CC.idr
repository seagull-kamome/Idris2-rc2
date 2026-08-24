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
import Libraries.Utils.Path

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

||| Every currently depended-upon package's own `lib` subdirectory
||| (Idris2's own packaging convention for shipping a compiled native
||| library alongside a package -- see `libs/rc2base/support/c/
||| Makefile`'s `install` target for a concrete producer).
||| `package_dirs`/`extra_dirs` are already resolved to this build's
||| transitive dependency install roots by upstream's own
||| Idris.Package.addDeps (mirrors the same fields
||| Core.Directory.findLibraryFile searches for exact-filename
||| lookups) -- no new dependency-resolution logic needed here, just
||| search each one's own lib/ for both headers (-I) and compiled
||| libraries (-L), since that's where this repo's own packages (e.g.
||| rc2base) put both. Lets a dependency's native library link
||| without the caller having to set IDRIS2_CFLAGS/IDRIS2_LDFLAGS by
||| hand.
depPkgLibDirs : {auto c : Ref Ctxt Defs} -> Core (List String)
depPkgLibDirs
    = do dirs <- getDirs
         pure (map (</> "lib") (package_dirs dirs ++ extra_dirs dirs))

export
compileCObjectFile : {auto c : Ref Ctxt Defs}
                  -> (sourceFile : String)
                  -> (objectFile : String)
                  -> (verbose : Bool)
                  -> Core (Maybe String)
compileCObjectFile sourceFile objectFile verbose
    = do cc <- coreLift findCC
         cFlags <- coreLift findCFlags
         cppFlags <- coreLift findCPPFlags

         rc2Dir <- findDataFile "rc2"
         cDir <- findDataFile "c"
         depLibDirs <- depPkgLibDirs

         let runccobj = (escapeCmd $
             [cc, "-Werror", "-c", sourceFile,
                  "-o", objectFile,
                  "-I" ++ rc2Dir,
                  "-I" ++ cDir] ++ map ("-I" ++) depLibDirs)
                  ++ " " ++ cppFlags ++ " " ++ cFlags

         log "compiler.refc.cc" 10 runccobj
         -- `--directive dumpcc` / `%cg rc2 dumpcc`: print the exact
         -- compile/link command about to run, unconditionally (not
         -- gated behind a log level) -- printed before running so
         -- it's still visible if the command itself fails.
         when verbose $ coreLift_ $ putStrLn runccobj
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
||| the caller having to set `IDRIS2_LDLIBS`/`LDLIBS` by hand. The `-L`
||| search path for those names includes every depended-upon package's
||| own `lib/` (see `depPkgLibDirs`), so a package shipping its own
||| native library (e.g. rc2base) also links without the caller
||| having to set `IDRIS2_LDFLAGS`/`IDRIS2_LIBS` by hand.
export
compileCFile : {auto c : Ref Ctxt Defs}
            -> (objectFile : String)
            -> (outFile : String)
            -> (foreignLibs : List String)
            -> (verbose : Bool)
            -> Core (Maybe String)
compileCFile objectFile outFile foreignLibs verbose
    = do cc <- coreLift findCC
         cFlags <- coreLift findCFlags
         ldFlags <- coreLift findLDFlags
         ldLibs <- coreLift findLDLibs

         dirs <- getDirs
         rc2Dir <- findDataFile "rc2"
         supportFile <- findLibraryFile "libidris2_support.a"
         depLibDirs <- depPkgLibDirs

         let runcc = (escapeCmd $
             [cc, "-Werror", objectFile,
                  "-o", outFile,
                  supportFile
                  ] ++ map ("-l" ++) foreignLibs ++ [
                  "-lidris2rc2",
                  "-L" ++ rc2Dir
                  ] ++ clibdirs (lib_dirs dirs) ++ clibdirs depLibDirs ++ [
                  "-lgmp", "-lm", "-lpthread"])
                  ++ " " ++ (unwords [cFlags, ldFlags, ldLibs])

         log "compiler.refc.cc" 10 runcc
         when verbose $ coreLift_ $ putStrLn runcc
         0 <- coreLift $ system runcc
           | _ => pure Nothing

         pure (Just outFile)
