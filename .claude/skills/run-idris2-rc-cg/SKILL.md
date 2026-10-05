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

Every command below expects a shell whose `PATH` already provides
whatever it needs (gcc, gmp, pkg-config, and valgrind for the full test
suite); no `nix-shell` wrapper is needed. The scripts don't spawn
`nix-shell` themselves. `idris2` itself comes from whatever is on
`PATH` after `source env.sh` (the self-built one) — nixpkgs' own
`idris2` package is bootstrap-only per this project's policy.

## Setup

`env.sh` must exist (it's gitignored; generate it with `./gen-env.sh`
after a clone, or again if the repo moves). It sets `PATH` (the
self-built `install/bin` first) and `LD_LIBRARY_PATH` (so a produced
executable can find `libidris2_support.so` at its own runtime).
Chez Scheme itself — needed by the Chez backend build step, the one
genuinely external dependency — must be on `PATH` as `scheme`; idris2
finds it there on its own, and `gen-env.sh` refuses to run without
it. Everything else the project's own unwrapped `idris2-rc2` binary
finds on its own under this repo's `install/` prefix. `smoke.sh`
sources `env.sh` automatically.

## Build

Skip this if `rc2/build/exec/idris2-rc2` already exists — `smoke.sh`
only builds when that's missing or `--build` is passed. Otherwise, the
exact commands (also what `smoke.sh --build` runs, from a shell with
gcc/gmp/pkg-config on `PATH`):

```bash
source env.sh
(cd rc2 && idris2 --build rc2.ipkg && idris2 --install rc2.ipkg)
```

No need to export `IDRIS2_PREFIX` here — the self-built
`install/bin/idris2` that `env.sh` puts on `PATH` already defaults to
this repo's own `install/` prefix on its own (baked in at bootstrap
time as `IdrisPaths.idr`'s `yprefix`; run `idris2 --prefix` to see
it). This only matters again if forcing nixpkgs' bootstrap `idris2`
instead (see below) — that one has no such baked-in default and
points at its own read-only nix store path.

`rc2/build/`/`install/` are shared, unlocked directories — running two
such builds concurrently (two sessions, or a session plus a subagent
each rebuilding to verify their own separate change) has been known to
corrupt the resulting `idris2-rc2.so`. `smoke.sh` and
`rc2/tests/verify.sh`/`bench.sh` all guard their own build step with
`rc2/tests/build-lock.sh`'s `acquire_build_lock` now, so driving a
build only through those scripts is already safe; running the raw
commands above by hand in more than one place at once is not — prefer
`smoke.sh --build` (or `verify.sh`, without `--skip-build`) over typing
this block directly if concurrency is a possibility.

This builds with whatever `idris2` `source env.sh` already put first
on `PATH` — the self-built `install/bin/idris2` by default. If that's
not set up yet, add `idris2` back to the `-p` list above (nixpkgs'
`idris2` package is bootstrap-only per project policy, so only reach
for this when you specifically lack a self-built compiler) — and in
that case export `IDRIS2_PREFIX="$(pwd)/install"` first, since
nixpkgs' `idris2` has no baked-in prefix of its own.

`--install` also builds and installs the runtime C library
(`libidris2rc2.a` under `install/idris2-0.8.0/support/rc2`) via
`rc2.ipkg`'s own postbuild/postinstall hooks — needed before compiling
any Idris2 program with `--cg rc2`.

## Run (agent path)

```bash
.claude/skills/run-idris2-rc-cg/smoke.sh
```

(add `valgrind` too with `--full-tests`; add `idris2` only if you lack
a self-built one yet and need `--build`'s bootstrap fallback.)

This builds rc2 if needed, compiles a tiny Idris2 program (prints a
string, sums a mapped list) through `--cg rc2` into a native
executable in a scratch dir (under `$CLAUDE_CODE_TMPDIR` when set,
else `mktemp`'s default), runs it, and diffs the output
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

Compile an arbitrary Idris2 program with rc2 directly:

```bash
source env.sh
(cd /some/scratch/dir && "$OLDPWD/rc2/build/exec/idris2-rc2" --cg rc2 Program.idr -o program)
/some/scratch/dir/build/exec/program
```

## Test

```bash
cd rc2/tests
source ../../env.sh
./verify.sh
```

Expected: `0 failed` on both summary lines verify.sh prints (the
refc-suite one, then the smoke-test-plus-valgrind one), with pass
counts equal to the previous run's plus any tests added since. Also reachable via `smoke.sh
--full-tests`. `idris2` is only needed for verify.sh's own Build step
and comes from whatever's already on `PATH` after sourcing `env.sh`
(the self-built one); add `--skip-build` if `rc2/build/exec/idris2-rc2`
is already built (this also skips the build lock entirely, since a
`--skip-build` run only reads the binary, never writes it — safe to
run any number of these concurrently), or add `idris2` to the `-p`
list above only if you specifically lack a self-built compiler
(nixpkgs' `idris2` is bootstrap-only per project policy).

## Gotchas

- **`IDRIS2_PREFIX` is normally unnecessary** with the self-built
  `idris2` from `env.sh` — it already defaults to this repo's own
  `install/` tree on its own (`idris2 --prefix` confirms it). It only
  becomes relevant again when deliberately forcing nixpkgs' bootstrap
  `idris2` instead (see "Build" above): that one defaults to its own
  read-only nix store path, so `idris2 --install` there needs
  `IDRIS2_PREFIX` exported first or it'll silently miss this repo's
  `install/` tree, and `idris2-rc2 --cg rc2` then can't find
  `support/rc2`'s runtime library.
- **Running a build/install step by hand, outside `smoke.sh`/
  `verify.sh`/`bench.sh`, bypasses the build lock** — if doing so
  while another session/subagent might also be building, take the lock
  yourself first, from the repo root, in the same shell as the build: `export RC2_DIR="$(pwd)/rc2"; source
  rc2/tests/build-lock.sh; acquire_build_lock`. `build-lock.sh` finds
  its lock file through `$RC2_DIR`; without it the lock path becomes
  `/build/.build.lock`, the `mkdir` fails, and the call exits at once
  with a misleading "another build is still holding ... after 600s"
  message.
