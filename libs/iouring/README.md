# iouring

*[日本語](README.ja.md)*

`System.IO.Uring` -- Idris2 bindings to Linux's `io_uring` async I/O
interface, via [liburing](https://github.com/axboe/liburing). Almost
entirely direct `%foreign` bindings onto `liburing.h`'s own `static
inline` API (no shim needed -- rc2's code generator `#include`s every
`%foreign` header straight into the consumer's own generated `.c`);
the small shim that remains (`support/c/iouring_util.c`) only handles
ring lifetime, `sockaddr` construction, and a couple of out-parameter
signatures `%foreign` has no way to express directly. See
`doc/iouring.md` for the full design rationale and what this package
deliberately doesn't cover yet (fixed files/buffers, multishot ops,
linked SQEs, poll, `SQPOLL`).

## Build & test

Building needs **`liburing`, `pkg-config`, and a C compiler** on
`PATH` (e.g. `nix-shell -p liburing pkg-config gcc gnumake`), plus a
kernel new enough for `io_uring` (5.1+; every operation this package
covers works on considerably older kernels than that in practice).

Default Chez backend, plain type-check:
```sh
idris2 --build iouring.ipkg
```

Against `idris2-rc-cg`'s own `rc2` backend (`libs/iouring` lives
inside `idris2-rc-cg`, so no cross-repo `env.sh` juggling). Install
into the *same* `install/` prefix rc2 itself uses -- idris2 searches
its own installation prefix by default, so no separate package-path
setup is needed, and no `IDRIS2_PREFIX` export either -- `env.sh`'s
self-built `idris2` already defaults to this repo's own `install/` on
its own (run `idris2 --prefix` to see it). `-p iouring` alone is
enough to build against it -- `Compiler.RC2.CC`'s own `depPkgLibDirs`
already adds `-I`/`-L` for every depended-upon package's own `lib/`
automatically, no `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed:
```sh
cd idris2-rc-cg            # repo root
source ./env.sh
(cd libs/iouring && idris2 --install iouring.ipkg)

nix-shell -p liburing gcc gmp pkg-config --run \
  './rc2/build/exec/idris2-rc2 --cg rc2 -p iouring -o MyProgram libs/iouring/tests/TestNop.idr'

export LD_LIBRARY_PATH="$(pwd)/install/idris2-0.8.0/support/rc2:$LD_LIBRARY_PATH"
./build/exec/MyProgram
```

`liburing` itself links as a real shared library (`-luring`, added
automatically to the link by every `%foreign` declaration naming it --
this package's own static archive, `libidris2rc2iouring.a`, only ever
carries the handful of genuinely-compiled shim functions), so unlike
`notcurses`/`text-re2` it needs no extra `LD_LIBRARY_PATH` entry of
its own when built inside `nix-shell -p liburing` (the nix shell's own
environment already makes `liburing.so` findable at both compile and
run time).

`tests/verify.sh` runs the full automated suite: a `nop` submit/
complete round-trip, a real temp-file `openat`+`write`+`fsync`+`close`+
`read`-back, and a real loopback TCP `accept`/`connect`/`send`/`recv`
pair -- all headless, no TTY or network access beyond `127.0.0.1`
needed.

## Native library install location

Same convention as `rc2base`/`text-re2`/`notcurses` -- see
`libs/rc2base/README.md`'s "Native library install location" section.
`idris2 --install` copies only `.ttc`/`.ttm`/`.ipkg`; this package's
`postinstall` hook (`make -C support/c install`) is what puts
`libidris2rc2iouring.a` and `iouring_util.h` into
`<IDRIS2_PREFIX>/idris2-<ver>/iouring-0.1.0/lib/`. rc2's own
`Compiler.RC2.CC.depPkgLibDirs` finds that `lib/` automatically for
every depended-upon package (`-p iouring` or an `.ipkg` `depends`
entry is enough) -- no manual `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` needed
for *this* header; `liburing.h` itself is found the same way any
`nix-shell -p liburing`-provided header is, via the shell's own
environment.

## API

```idris2
import System.IO.Uring

main : IO ()
main = do
  Just ring <- init 8
    | Nothing => putStrLn "io_uring_queue_init failed"
  Just sqe <- getSqe ring
    | Nothing => putStrLn "submission queue full"
  prepNop sqe
  setUserData sqe 42
  _ <- submit ring
  Just completion <- waitCompletion ring
    | Nothing => putStrLn "wait failed"
  printLn (completion.userData, completion.res)
  exit ring
```

See `System.IO.Uring`'s own doc comments for the full API (`prepRead`/
`prepWrite`/`prepOpenat`/`prepClose`/`prepFsync`/`prepAccept`/
`prepConnect`/`prepSend`/`prepRecv`) and `tests/` for complete,
runnable examples of each.
