# `idris2-rc2-norepl`: the driver without the REPL, and building the compiler with rc2

`rc2-norepl.ipkg` builds a second executable, `idris2-rc2-norepl`, next to
`idris2-rc2`. It is the same compiler (`Compiler.RC2.*` come from the installed
`rc2` package) with a driver that has no REPL. It was made to answer one
question: can the compiler itself be built by rc2, without Chez Scheme?
The answer is yes (see "Result"). `rc2.ipkg` and `idris2-rc2` are untouched; the only change to the compiler is item 3 under "What it took".

## Layout

```
rc2/rc2-norepl.ipkg          sourcedir = "src_norepl", depends rc2
rc2/src_norepl/NoRepl/Main.idr          main = mainNoRepl [("rc2", codegenRC2)]
rc2/src_norepl/NoRepl/Driver.idr        the driver (copied from Idris.Driver, see below)
rc2/src_norepl/NoRepl/SchemeStubs.idr   %foreign_impl stubs for Libraries.Utils.Scheme
```

The modules are named `NoRepl.*` so that they cannot be mixed up with the
upstream `Idris.Driver` or with `Main` of `rc2.ipkg`.

## What was taken from upstream

`NoRepl.Driver` copies, from `idris2-src/src/Idris/Driver.idr`: `findInputs`,
`splitPaths`, `updateEnv`, `ignoreMissingIpkg`, `checkVerbose`, `stMain`,
`quitOpts` and `mainWithCodegens` (as `mainNoRepl`); and, from
`Idris/SetOptions.idr`, `postOptions` (as `postOptionsNoRepl`). Left out:

- the banner, `updateREPLOpts` (the editor), and the final `repl` / `replIDE`
  call: after the options have been run, the program says that it has no REPL and
  exits with status 1;
- `--yaffle`, `--ttm`, `--ide-mode`, `--ide-mode-socket` `--repl [package]` and `--client <cmd>`: each
  is refused with a message;
- the `replCmd` branch of `postOptions`.

When the upstream sources are updated, compare these functions with the copies.

## Building

```sh
cd rc2
source ../env.sh
idris2 --build rc2.ipkg && idris2 --install rc2.ipkg      # the rc2 package first
idris2 --build rc2-norepl.ipkg                              # with Chez, as usual
./tests/norepl-smoke.sh                                     # checks that build
```

With rc2 itself (the compiler built without Chez):

```sh
build/exec/idris2-rc2 --cg rc2 --build rc2-norepl.ipkg      # about 10 minutes
```

## What it took

1. `Idris.Package.processPackage` (`--build`, `--install`, ...) can reach `repl`
   through a private `runRepl`, so the REPL is still linked, and with it the
   REPL's `Scheme` evaluation mode (`Core.SchemeEval`), which calls Chez through
   the `%foreign "scheme:..."` declarations of `Libraries.Utils.Scheme`. Copying
   `Package.idr` (about 1100 lines) was not worth it.
2. So `NoRepl.SchemeStubs` gives each of those 29 declarations a `%foreign_impl`
   whose body stops the program (`abort()`). Nothing in a batch compile calls them;
   a call would be a bug, and it is loud.
3. rc2 did not know the foreign type `ForeignObj` (`CFForeignObj`). It is now
   passed through like `CFUser` (`Emit/Util.idr`, `Emit/Foreign.idr`).

## Result

- rc2 builds `idris2-rc2-norepl` itself: about 75 s of code generation and 9 more
  minutes for the C compiler on a 114 MB C file; the executable is 15 MB.
- The rc2-built compiler compiles programs and gives the same C as the Chez-built
  one (`Hello`, `Test149StrLiteralFold`, `Test87SpecConstCon`), except that a
  `Double` literal is printed by the rc2 runtime (`4611686018427388000.0`
  where Chez prints `4.611686018427388e18`; the same value).
- It type-checks `libs/control-async` in 8.2 s; the Chez-built one takes 4.9 s,
  so the rc2-built compiler is about 1.7 times slower there. That is the
  number to bring down.
- `--build` of an ipkg with an executable and `--typecheck` work.

## Not done

- The REPL is not out of the binary; only the way to it from the command line is
  closed. Removing it needs a copy of `processPackage`.
- The `.ttc` files of `prelude`, `base`, `contrib` and the compiler's own API
  package are still written by the upstream `idris2` (built by Chez). Producing
  them with the rc2-built compiler (`--build` of those packages) is the next step
  towards a toolchain without Chez.
