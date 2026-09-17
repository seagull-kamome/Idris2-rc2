# notcurses

`System.Notcurses` -- Idris2 bindings to [notcurses](https://notcurses.com/)'
`notcurses-core` API, through a small shim (`support/c/nc_util.c`) built
into its own static archive `libidris2rc2notcurses.a`. `rc2` backend only.

See `doc/notcurses.md` for the full design rationale (why a shim
exists at all despite most of the binding calling straight onto
notcurses' own real symbols) and for what this package deliberately
doesn't cover yet.

## Build & test

Building the shim needs **`notcurses`, `pkg-config`, and a C
compiler** on `PATH` (e.g. `nix-shell -p notcurses pkg-config gcc
gnumake`).

Default Chez backend, plain type-check:
```sh
idris2 --build notcurses.ipkg
```

Against `idris2-rc-cg`'s own `rc2` backend (`libs/notcurses` lives
inside `idris2-rc-cg`, so no cross-repo `env.sh` juggling). Install
into the *same* `install/` prefix rc2 itself uses -- idris2 searches
its own installation prefix by default, so no separate package-path
setup is needed, and no `IDRIS2_PREFIX` export either -- `env.sh`'s
self-built `idris2` already defaults to this repo's own `install/` on
its own (run `idris2 --prefix` to see it). `-p notcurses` alone is
enough to build against it -- `Compiler.RC2.CC`'s own `depPkgLibDirs`
already adds `-I`/`-L` for every depended-upon package's own `lib/`
automatically, no `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed:
```sh
cd idris2-rc-cg            # repo root
source ./env.sh
(cd libs/notcurses && idris2 --install notcurses.ipkg)

./rc2/build/exec/idris2-rc2 --cg rc2 -p notcurses -o MyProgram libs/notcurses/examples/Hello.idr

# libidris2rc2notcurses is a static archive -- baked straight into
# MyProgram, nothing of its own to find at runtime. notcurses-core
# itself stays a real shared library, so it's the only one still
# needed on LD_LIBRARY_PATH here.
INSTALLED_NOTCURSES_LIBDIR="$(nix-shell -p notcurses pkg-config --run 'pkg-config --variable=libdir notcurses-core')"
export LD_LIBRARY_PATH="$(pwd)/install/idris2-0.8.0/support/rc2:$INSTALLED_NOTCURSES_LIBDIR:$LD_LIBRARY_PATH"
./build/exec/MyProgram
```

`tests/verify.sh` automates the build+link+run steps above for a
program that only calls `notcurses_version()` -- notcurses itself
needs a real terminal to `init` into, which an automated/sandboxed
environment generally doesn't have, so that's as far as an
unattended check can go. **`examples/` has runnable, interactive
programs for verifying everything else by hand** -- run each directly
in a real terminal (see `examples/README.md`).

## Native library install location

Same convention (and same rc2-specific caveat) as `rc2base`/
`text-re2` -- see `libs/rc2base/README.md`'s "Native library install
location" section. `idris2 --install` copies only `.ttc`/`.ttm`/
`.ipkg`; this package's `postinstall` hook (`make -C support/c
install`) is what puts `libidris2rc2notcurses.a` and `nc_util.h` into
`<IDRIS2_PREFIX>/idris2-<ver>/notcurses-0.1.0/lib/`. rc2's own
`Compiler.RC2.CC.depPkgLibDirs` finds that `lib/` automatically for
every depended-upon package (`-p notcurses` or an `.ipkg` `depends`
entry is enough) -- no manual `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed
for *this*. Being a static archive, `libidris2rc2notcurses.a` itself
needs nothing on `LD_LIBRARY_PATH` at runtime (unlike `notcurses-core`,
still a real shared library) -- see the `LD_LIBRARY_PATH` shown above.
