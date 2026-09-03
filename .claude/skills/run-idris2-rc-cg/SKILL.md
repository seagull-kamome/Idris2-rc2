---
name: run-idris2-rc-cg
description: Build rc2 (idris2-rc-cg's independent external C code generator backend for Idris2), compile and run a smoke-test Idris2 program through it, and run its test suite. Use when asked to build rc2, run/test rc2, compile an Idris2 program with the rc2 backend, or verify rc2 still works after a change.
---

`idris2-rc-cg` (package name `rc2`) is a compiler backend, not an app
with a UI — "running" it means building the `idris2-rc2` binary,
using it to compile a small Idris2 program to a native executable,
and running *that* executable. Drive it via
`.claude/skills/run-idris2-rc-cg/smoke.sh`, which does exactly that
and checks the output.

All paths below are relative to `idris2-rc-cg/` (the unit root, i.e.
this repo).

## Prerequisites

Every command below expects to be run from inside a single `nix-shell
-p ...` invocation that already provides whatever it needs (gcc, gmp,
pkg-config, and valgrind for the full test suite) — the scripts
themselves no longer spawn `nix-shell` internally, so wrap the whole
invocation yourself rather than expecting per-command isolation.
`idris2` itself is normally NOT in that `-p` list: whenever a build
step needs it, it comes from whatever's already on `PATH` after
`source env.sh` (the self-built one) — nixpkgs' own `idris2` package
is bootstrap-only per this project's policy, so only add `idris2` to
a `-p` list if you specifically lack a self-built one. Nothing to
install ahead of time beyond `nix` itself being on `PATH`.

## Setup

`env.sh` must exist (it's checked into the repo already; regenerate
with `./gen-env.sh` — needs `nix-shell -p idris2` — only if it's
missing or stale after a nix update). It sets `CHEZ`, `IDRIS2_LIBS`,
`IDRIS2_DATA`, `IDRIS2_PACKAGE_PATH`, `LD_LIBRARY_PATH` so the
project's own unwrapped `idris2-rc2` binary can find the standard
libraries. `smoke.sh` sources it automatically.

## Build

Skip this if `rc2/build/exec/idris2-rc2` already exists — `smoke.sh`
only builds when that's missing or `--build` is passed. Otherwise, the
exact commands (also what `smoke.sh --build` runs, from inside a
nix-shell providing gcc/gmp/pkg-config):

```bash
nix-shell -p gcc gmp pkg-config --run '
  source env.sh
  export IDRIS2_PREFIX="$(pwd)/install"
  cd rc2 && idris2 --build rc2.ipkg && idris2 --install rc2.ipkg
'
```

This builds with whatever `idris2` `source env.sh` already put first
on `PATH` — the self-built `install/bin/idris2` by default. If that's
not set up yet, add `idris2` back to the `-p` list above (nixpkgs'
`idris2` package is bootstrap-only per project policy, so only reach
for this when you specifically lack a self-built compiler).

`--install` also builds and installs the runtime C library
(`libidris2rc2.a` under `install/idris2-0.8.0/support/rc2`) via
`rc2.ipkg`'s own postbuild/postinstall hooks — needed before compiling
any Idris2 program with `--cg rc2`.

## Run (agent path)

```bash
nix-shell -p gcc gmp pkg-config --run '.claude/skills/run-idris2-rc-cg/smoke.sh'
```

(add `valgrind` too with `--full-tests`; add `idris2` only if you lack
a self-built one yet and need `--build`'s bootstrap fallback.)

This builds rc2 if needed, compiles a tiny Idris2 program (prints a
string, sums a mapped list) through `--cg rc2` into a native
executable in a scratch temp dir, runs it, and diffs the output
against the expected `hello from rc2` / `30`. Exit 0 + `== smoke test
OK ==` means the backend genuinely produces working native binaries,
not just that the compiler itself built.

Flags:

| flag | effect |
|---|---|
| (none) | build rc2 only if `rc2/build/exec/idris2-rc2` is missing, then smoke-compile+run |
| `--build` | force a rebuild first |
| `--full-tests` | also run `rc2/tests/verify.sh` (refc-suite + smoke + valgrind, ~10 min) |

## Run (human path)

Compile an arbitrary Idris2 program with rc2 directly — must be run
with the working directory *outside* the `rc2/` package tree (see
Gotchas):

```bash
source env.sh
nix-shell -p gcc gmp pkg-config --run \
  "cd /some/scratch/dir && '$(pwd)/rc2/build/exec/idris2-rc2' --cg rc2 Program.idr -o program"
/some/scratch/dir/build/exec/program
```

## Test

```bash
cd rc2/tests
source ../../env.sh
nix-shell -p gcc gmp pkg-config valgrind --run './verify.sh'
```

Expected: `70 passed, 0 known, 0 failed` (refc-suite 21, 40 smoke
tests, and valgrind leak checks all included). Also reachable via
`smoke.sh --full-tests`. `idris2` is only needed for verify.sh's own
Build step and comes from whatever's already on `PATH` after sourcing
`env.sh` (the self-built one); add `--skip-build` if
`rc2/build/exec/idris2-rc2` is already built, or add `idris2` to the
`-p` list above only if you specifically lack a self-built compiler
(nixpkgs' `idris2` is bootstrap-only per project policy).

## Gotchas

- **Compiling from inside `rc2/` (or any directory whose ancestor has
  an `.ipkg`) fails** with `Source file "..." is not in the source
  directory "..."` — `idris2-rc2` auto-detects `rc2.ipkg` itself
  (`sourcedir = "src"`) and tries to resolve your program against
  *that* package's source dir. Always `cd` to a scratch directory
  with no `.ipkg` above it before invoking `idris2-rc2 --cg rc2` on
  your own program (`smoke.sh` does this via `mktemp -d`).
- **`nix-shell --run` resets the shell's cwd on this machine** — a
  bare `cd` before the `nix-shell` call does not carry into it;
  `cd` has to happen *inside* the `--run '...'` string, which is why
  the commands above are shaped that way.
- **Forgetting `IDRIS2_PREFIX` before `idris2 --install`** silently
  installs into the default (often read-only, nix-store-adjacent)
  location instead of this repo's own `install/` tree, and
  `idris2-rc2 --cg rc2` then can't find `support/rc2`'s runtime
  library. Always export it relative to the repo root first.
