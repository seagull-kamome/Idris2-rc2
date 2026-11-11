# Libraries: `--directive staticlib` and `sharedlib`

Build the `%export`ed functions of a program (`export-support.md`) into a
library instead of an executable: `-o foo` writes, under `build/exec/`,

| directive   | writes                                                         |
|-------------|----------------------------------------------------------------|
| `staticlib` | `libfoo.a`, `foo.h`, `foo.link`                                  |
| `sharedlib` | `libfoo.so`, `foo.h`, `foo.link`                                 |

(a name that already starts with `lib` is not given another). The two are
exclusive. Both imply `nomain`, and the program still needs a `main` (`-o` asks
for one); it is never run. Only whole-program compiles build a library: with
the incremental mode on (`incremental-compile.md`) these directives make
`compileExpr` take the whole-program path.

`foo.h` holds the prototype of each exported function, as the wrapper
(`Emit.Foreign.emitExportWrapper`) defines it, and `foo.link` the flags a host
adds to its link line, after the library: the runtime, the support library, the
search paths of the dependency packages, `-lgmp -lm -lpthread`, and the `%foreign`
libraries of the program. Use it as `$(cat foo.link)`.

## The host owns the runtime

The library does nothing at load time and brings no runtime. The host, C or rc2,
calls `idris2rc2_rtInit()` once before the first call into the library,
`idris2rc2_rtFinish()` at the end, and `idris2rc2_enableMultiThreading()` before
it starts a second thread (`idris2rc2_runtime.h`, `runtime-lifecycle.md`,
`hybrid-refcount.md`). A host that is itself rc2 code does all of this already; a
library that did it too would do it twice. For the same reason there is one copy
of the runtime in a process: its state (the thread-local heaps of the cell
pool, the multi-threading flag, the registry of memoized CAFs) is not
something two copies can share, and a value that crosses from a library to the
host is freed by whichever side drops it last.

## Symbols

All of the code of a library is one C file. In library mode every function and
constant of it is `static` but the wrappers of the `%export`s, so the only symbols
of `libfoo.a` or `libfoo.so` are the exports (`nm -g --defined-only`, and
`tests/library/run.sh` checks it). Two libraries of one program, or a library
and a host built by rc2, can therefore define the same internal names (the
numbered `Main_add_123`, the same Prelude functions) with different
bodies, with no clash when linked statically and no interposition when loaded
as shared libraries.

## Static library

A host links `libfoo.a` and the runtime archive, as for any C library:

```sh
gcc -I$RT -Ibuild/exec host.c build/exec/libfoo.a $(cat build/exec/foo.link) -o host
```

(`$RT` is `$(idris2 --libdir)/support/rc2`, where `idris2rc2_runtime.h` is.) Several
static libraries go into one host. The runtime comes from the archive, which is
as it always has been.

## Shared library

`libfoo.so` is compiled `-fPIC -ftls-model=initial-exec` and linked with
`-shared` alone: the runtime stays undefined in it and is resolved when it is
loaded. The runtime has to be one shared object for the whole process:
`shared/libidris2rc2.so` (`support/rc2/Makefile`, built with `-fPIC` and installed
next to `libidris2rc2.a`; in a directory of its own so that a plain `-lidris2rc2`
keeps finding the archive). `foo.link` of a shared library names it, with an
`-rpath`. So:

```sh
gcc -I$RT -Ibuild/exec host.c -Lbuild/exec -lfoo $(cat build/exec/foo.link) -Wl,-rpath,$PWD/build/exec -o host
```

A host written in rc2 asks for the same with `--directive sharedruntime`, which
links the executable against `libidris2rc2.so` instead of the archive, and
links the libraries by `%foreign "C:name,libfoo,foo.h"` (`ffi-cexpr.md`), with
`IDRIS2_CFLAGS=-I<dir>` and `IDRIS2_LDFLAGS="-L<dir> -Wl,-rpath,<dir>"`.
`tests/library/Host.idr` calls two libraries built from the same definitions
this way.

Why not the archive in the host: the linker takes only the members of an archive
that something it links needs, so a host that does not use `idris2rc2_strAppend`
has no such symbol for a library to find, and a `dlopen` of the library fails
(`undefined symbol: idris2rc2_strAppend`, seen with a C host that only
calls `idris2rc2_rtInit`). With a shared runtime every function is there
whatever the host uses, and the processes that load several libraries share
one state.

`-ftls-model=initial-exec` keeps the pool's fast path (a thread-local heap read,
inlined from `idris2rc2_memory.h`) one load from the thread pointer instead of a call
of `__tls_get_addr`. It requires the runtime to be loaded with the host (a
`DT_NEEDED` entry of the host, as `foo.link` makes it, or the host's own
copy); it fails for a runtime that is itself `dlopen`ed later.

## Where a shared library is found

Nothing is built into `libfoo.so` about where anything is: it has a soname (its file
name) and no rpath and no `DT_NEEDED`. The loader's usual rules decide, so:

- **The library.** `foo.link` does not name its directory. A host that links it
  (`-L<dir> -lfoo`) records `libfoo.so` as a `DT_NEEDED`, and finds it at run time
  through its own `RUNPATH` (`-Wl,-rpath,<dir>`, or `$ORIGIN` for a library installed
  next to it), `LD_LIBRARY_PATH` or the system cache. A host that `dlopen`s it names
  the path itself. The host's builder chooses; an absolute rpath into a build
  directory is not put in on their behalf.
- **The runtime.** `foo.link` of a shared library has `-L<dir>/shared
  -Wl,-rpath,<dir>/shared -lidris2rc2`, with `<dir>` the support directory of the
  toolchain that built the library (`$(idris2 --libdir)/support/rc2`). That absolute
  path ends up in the host's `RUNPATH`; for a host that moves to another machine,
  replace it, or install `libidris2rc2.so` where the loader looks.
- **The library's own dependency on the runtime.** `libfoo.so` leaves the runtime's
  symbols undefined and carries no `DT_NEEDED libidris2rc2.so` on purpose. The host
  provides the runtime, as a shared object or as a static copy it exports, and a
  `DT_NEEDED` in the library would load a second copy next to a host that has its
  own, with the state of the runtime twice. The price is that a library `dlopen`ed
  by a process that has no runtime loaded fails with `undefined symbol` (the host of
  `tests/library/dl.c` has it from `foo.link`).

## The code of the packages is copied

A library is generated from the whole program, so the definitions of the packages
it uses (`prelude`, `base`, ...) that its exports reach are part of it, as
`static` functions (a library calling `Data.List.sort` holds `sortBy`, `mergeBy`
and their helpers). The host has its own copies of what it uses. Not the code only:
the global state of Idris code is copied with it. A top-level constant or a
global `IORef` made with `unsafePerformIO` (a memoized CAF) exists once in the host
and once in each library that reaches it, and the copies are not shared. A value
cannot be shared either: what passes through an `%export` is a scalar, a `String`,
a pointer or an `Integer`, never a data structure, so copies with different
layouts never meet. Native code (`%foreign` libraries) is not copied; the host
links it once. Sharing the Idris code of the packages would need per-module
compiles and the same package versions throughout (`KNOWN-BUGS.md`).

## What is not covered

- Native libraries of dependency packages (`libidris2rc2base.a`, ...) are
  linked by the host as the `.link` file lists them; they are not built
  `-fPIC`, so cannot go into a `.so`, and a package whose native part keeps
  state needs a single copy as well.
- Incremental (per-module) compiles do not build libraries.
- A deep non-tail recursion in a library runs on the stack of the calling thread
  (`KNOWN-BUGS.md`).

## Tests

`tests/library/run.sh` (called from `tests/verify.sh`): static and shared libraries
built from `AddLib.idr` and `Add2Lib.idr` (same definitions, other export names),
each with only its exports as symbols; both static libraries in one C host
(`host.c`); both shared libraries in one C host; a host that `dlopen`s a library
(`dl.c`); an rc2 host with `sharedruntime` (`Host.idr`), whose link is checked for
`libidris2rc2.so`.
