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

-- Not `idrisGetEnv` -- that's restricted to `Idris.Env.envNames`'s own
-- fixed, documented whitelist (for accurate `--help` env var listings),
-- and `IDRIS2_AR`/`AR` aren't in it (out of scope to add to idris2-src
-- itself for this). Plain `getEnv` has no such restriction.
findAR : IO String
findAR
    = do Nothing <- getEnv "IDRIS2_AR"
           | Just ar => pure ar
         Nothing <- getEnv "AR"
           | Just ar => pure ar
         pure "ar"

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

         -- `-Wno-error=deprecated-declarations`: the deprecated attribute
         -- on `fastPack`/`fastConcat` (idris2rc2_strings.h -- both leak
         -- their own malloc'd buffer, see KNOWN-BUGS.md) is a safety net,
         -- not something normal builds are expected to hit:
         -- `Compiler.RC2.Emit`'s own `createCFunctions` (see
         -- `fastPackFixedReplacement`) always redirects every
         -- `Prelude.Types.fastPack`/`fastConcat` call site to the
         -- leak-free `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` instead, so this
         -- declaration itself is never actually reached by generated
         -- code today. Kept `-Wno-error` anyway so a future regression in
         -- that redirect degrades to a visible warning, not a hard
         -- `-Werror` build failure for every program in existence.
         -- `-ffunction-sections -fdata-sections`: pairs with
         -- `compileCFile`'s own `--gc-sections`, letting the linker
         -- discard individual unused functions/globals at *section*
         -- granularity rather than only at whole-object-file
         -- granularity. Always safe (pure dead-code stripping, no
         -- behavior change) but specifically load-bearing for
         -- incremental mode: rc2 compiles one whole module to one `.o`,
         -- so a module needed for any single reason (e.g. `Prelude.IO`
         -- for `putStrLn`) otherwise drags in every *other* function it
         -- happens to also define -- including one that itself
         -- dangles a reference to something `Emit.idr`'s own
         -- `dropUnimplementableForeign`/`hasUsableForeignImpl`
         -- deliberately dropped (e.g. `Prelude.IO.threadWait`, calling
         -- the dropped `prim__threadWait`) even when the actual program
         -- being built never calls it -- see
         -- rc2/doc/incremental-compile.md's "Bugs found while
         -- implementing" and `CC.archiveObjectFiles`'s own doc comment
         -- for the rest of this same fix (archiving instead of linking
         -- bare `.o`s solves it at whole-module granularity; this
         -- solves what's left at per-function granularity).
         let runccobj = (escapeCmd $
             [cc, "-Werror", "-Wno-error=deprecated-declarations",
                  "-ffunction-sections", "-fdata-sections", "-c", sourceFile,
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

||| Bundles `objectFiles` into a single `ar`-format static archive at
||| `archivePath` (`rcs`: replace/create, add an index). Used by
||| incremental mode's own final link step (`Compiler.RC2.RC2`'s
||| `compileExprInc`) instead of listing every accumulated per-module
||| `.o` directly on `compileCFile`'s own command line below -- a plain
||| `.o` a linker command line names is *always* linked in whole,
||| unlike an archive member, which is only pulled in if something
||| still-unresolved at that point in the link actually needs a symbol
||| it provides. That distinction is exactly what lets incremental
||| mode's own "drop an unimplementable definition, fail at link time
||| instead" mechanism (`Emit.idr`'s `hasUsableForeignImpl`/
||| `generateCSourceFile`'s `dropUnimplementableForeign`,
||| rc2/doc/incremental-compile.md's "Bugs found while implementing")
||| degrade gracefully rather than universally: a module that
||| references a dropped definition (e.g. `Prelude.IO`'s own
||| `threadWait`, calling the dropped `prim__threadWait`) would
||| otherwise always be linked in whole regardless of whether the
||| program being built ever calls it, turning one always-present-but-
||| never-called reference into a link failure for every single
||| incrementally-compiled program, not just the ones that actually
||| call it.
export
archiveObjectFiles : {auto c : Ref Ctxt Defs}
                  -> (objectFiles : List String)
                  -> (archivePath : String)
                  -> (verbose : Bool)
                  -> Core (Maybe String)
archiveObjectFiles objectFiles archivePath verbose
    = do ar <- coreLift findAR
         let runar = escapeCmd ([ar, "rcs", archivePath] ++ objectFiles)
         log "compiler.refc.cc" 10 runar
         when verbose $ coreLift_ $ putStrLn runar
         0 <- coreLift $ system runar
           | _ => pure Nothing
         pure (Just archivePath)

||| `foreignLibs` -- distinct link-library names collected from every
||| program-level `%foreign` declaration's own lib field (see
||| `Compiler.RC2.Emit`'s `generateCSourceFile`/`linkLibName`) --
||| become `-l<name>` flags placed right after `objectFiles`, ahead of
||| the rc2 runtime and its own dependencies: the symbols they provide
||| are the ones a program's own FFI call sites reference directly, so
||| they need to resolve before anything downstream does. Lets a
||| binding to a genuinely external library (e.g. libcurl) link without
||| the caller having to set `IDRIS2_LDLIBS`/`LDLIBS` by hand. The `-L`
||| search path for those names includes every depended-upon package's
||| own `lib/` (see `depPkgLibDirs`), so a package shipping its own
||| native library (e.g. rc2base) also links without the caller
||| having to set `IDRIS2_LDFLAGS`/`IDRIS2_LIBS` by hand.
|||
||| `objectFiles` -- a list, not a single file: whole-program
||| compilation just passes a one-element list (its own single `.o`);
||| incremental mode's own final link step (`Compiler.RC2.RC2`'s
||| `compileExprInc`) passes a one-element list too, but of the single
||| archive `archiveObjectFiles` just bundled every accumulated
||| per-module `.o` into (see that function's own doc comment for why
||| an archive, not the raw list, matters there).
export
compileCFile : {auto c : Ref Ctxt Defs}
            -> (objectFiles : List String)
            -> (outFile : String)
            -> (foreignLibs : List String)
            -> (verbose : Bool)
            -> Core (Maybe String)
compileCFile objectFiles outFile foreignLibs verbose
    = do cc <- coreLift findCC
         cFlags <- coreLift findCFlags
         ldFlags <- coreLift findLDFlags
         ldLibs <- coreLift findLDLibs

         dirs <- getDirs
         rc2Dir <- findDataFile "rc2"
         supportFile <- findLibraryFile "libidris2_support.a"
         depLibDirs <- depPkgLibDirs

         -- `-lidris2rc2` must resolve before `supportFile` (the shared
         -- `libidris2_support.a`): C static linking resolves an
         -- unresolved symbol from the first library on the command
         -- line that provides it, and rc2's own runtime now provides
         -- native implementations (e.g. `idrnet_*`) for symbols the
         -- shared library also happens to define -- rc2's own must
         -- shadow the shared one, not the other way around. Anything
         -- rc2 doesn't provide natively still resolves from
         -- `supportFile` afterwards, unaffected by this reordering.
         -- `-Wno-error=deprecated-declarations`: see `compileCObjectFile`'s
         -- own comment on the same flag -- kept here too since this
         -- step's own `cc` invocation could in principle also compile
         -- from source (not just link an already-built object file),
         -- same reasoning either way.
         -- `-Wl,--gc-sections`: pairs with `compileCObjectFile`'s own
         -- `-ffunction-sections -fdata-sections` -- see that flag's own
         -- comment for why this matters specifically for incremental
         -- mode's own per-module `.o`s.
         let runcc = (escapeCmd $
             [cc, "-Werror", "-Wno-error=deprecated-declarations", "-Wl,--gc-sections"] ++ objectFiles ++ [
                  "-o", outFile,
                  "-L" ++ rc2Dir,
                  "-lidris2rc2"
                  ] ++ map ("-l" ++) foreignLibs ++ [
                  supportFile
                  ] ++ clibdirs (lib_dirs dirs) ++ clibdirs depLibDirs ++ [
                  "-lgmp", "-lm", "-lpthread"])
                  ++ " " ++ (unwords [cFlags, ldFlags, ldLibs])

         log "compiler.refc.cc" 10 runcc
         when verbose $ coreLift_ $ putStrLn runcc
         0 <- coreLift $ system runcc
           | _ => pure Nothing

         pure (Just outFile)
