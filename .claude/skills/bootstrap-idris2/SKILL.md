---
name: bootstrap-idris2
description: (Re)build this repo's permanent self-built idris2 toolchain (install/bin/idris2) from idris2-src, using nixpkgs' idris2 ONLY as the one-time bootstrap compiler. Use when idris2-src has been updated to a new upstream commit, when install/ is missing or broken, or when specifically diagnosing whether a bug is unique to the self-built compiler's own dev-snapshot state.
---

## When to use this

This repo's default compiler for all rc2 work is the **self-built**
`install/bin/idris2`, built from `idris2-src/` (a clone of upstream
Idris2) — never nixpkgs' own `idris2` package (see `AGENT.md`'s
"Policy: don't use nixpkgs' idris2 for rc2 work"). nixpkgs' `idris2`
is used ONLY as the bootstrap compiler for the very first build pass
below — never for rc2 itself, never for test/benchmark comparisons.

Run this skill when:
- `idris2-src/` was just updated (`git merge --ff-only origin/main`,
  per `AGENT.md`'s Layout section) and the self-built toolchain needs
  rebuilding to match, or
- `install/bin/idris2` / `install/idris2-0.8.0/` is missing or broken
  and needs to be (re)built from scratch, or
- diagnosing whether a bug is specific to the self-built compiler's
  own dev-snapshot state (per `AGENT.md`'s documented `--nix-idris2`
  escape hatch in `verify.sh`/`bench.sh`) and a fresh reference build
  is needed to compare against.

**Do not run this casually — it overwrites the shared, permanent
`install/` toolchain that every other rc2 build/test/benchmark script
in this repo relies on.** Only run it when explicitly asked, or when
one of the triggers above genuinely applies. This can take a while
(compiling the whole Idris2 compiler plus its own libraries, twice)
— not something to run speculatively.

## Prerequisites

- `idris2-src/` exists and is up to date.
- `env.sh` exists at the repo root (`./gen-env.sh` if missing/stale —
  needs `nix-shell -p idris2`, the same one-time-bootstrap-only
  exception as below).

## Step 1: first-pass build, using nixpkgs' idris2 as the boot compiler

This is the ONLY step in this whole skill (and one of the only places
in this whole repo) where nixpkgs' `idris2` package is legitimately
used — as the boot compiler (`IDRIS2_BOOT`, defaults to whatever
`idris2` resolves to on `PATH`) to compile `idris2-src` for the first
time.

```bash
cd idris2-src
export PREFIX="$(cd .. && pwd)/install"
nix-shell -p idris2 gcc gmp pkg-config --run 'make all && make install'
```

This produces a working `install/bin/idris2`, but one built BY
nixpkgs' idris2, not yet self-hosted.

## Step 2: self-hosting pass, rebuilding with the just-built compiler

Rebuilds `idris2-src` again, this time using the toolchain Step 1 just
produced as its own boot compiler — no nixpkgs `idris2` involved at
all. This is what makes the final `install/` toolchain genuinely
self-hosted (its own prelude/base/contrib/network all built by
itself), matching `AGENT.md`'s Layout section description.

```bash
cd idris2-src
source ../env.sh
make clean
export PREFIX="$(cd .. && pwd)/install"
export IDRIS2_BOOT="$(cd .. && pwd)/install/bin/idris2"
nix-shell -p gcc gmp pkg-config --run 'make all && make install'
```

(`source ../env.sh` is needed here because `$IDRIS2_BOOT` is now a
plain, unwrapped binary — same reason rc2's own build needs it, see
`gen-env.sh`'s own comment.)

## Step 3: install the Idris2 API package (needed for rc2)

`rc2.ipkg` depends on the `idris2` package (the compiler-as-library
API), needed by any external codegen backend — confirmed present at
`install/idris2-0.8.0/idris2-0.8.0/`. Per upstream's own
`idris2-src/INSTALL.md` ("Installing the Idris 2 API"), this only
works correctly once the self-hosting step above is done, since the
intermediate code versions need to stay consistent — so run it with
`IDRIS2_BOOT` still pointing at the self-built compiler from Step 2:

```bash
cd idris2-src
source ../env.sh
export PREFIX="$(cd .. && pwd)/install"
export IDRIS2_BOOT="$(cd .. && pwd)/install/bin/idris2"
nix-shell -p gcc gmp pkg-config --run 'make install-api'
```

## Step 4 (optional but recommended): run upstream's own test suite

Confirms the freshly self-hosted compiler is sound before relying on
it for rc2 work:

```bash
cd idris2-src
source ../env.sh
nix-shell -p gcc gmp pkg-config chez --run 'make test'
```

## Step 5: verify rc2 itself still builds against the new toolchain

```bash
cd rc2
source ../env.sh
export IDRIS2_PREFIX="$(cd .. && pwd)/install"
nix-shell -p gcc gmp pkg-config --run 'idris2 --build rc2.ipkg && idris2 --install rc2.ipkg'
```

Then run `rc2/tests/verify.sh` as usual (see the `run-idris2-rc-cg`
skill) to confirm nothing regressed against the new toolchain.

## Gotchas

- **`make install`/`make install-api` without `PREFIX` set** silently
  installs into the default `$HOME/.idris2` instead of this repo's
  own `install/` tree. Always export `PREFIX` (not `IDRIS2_PREFIX` --
  that's `rc2.ipkg`'s own install-time variable, a different thing;
  `idris2-src`'s own Makefile reads `PREFIX` for itself and derives
  its own internal `IDRIS2_PREFIX` from it) before any `make`
  invocation above.
- **Step 2 forgetting `make clean` first** can leave stale `.ttc`
  files built by a different boot-compiler version lying around,
  causing confusing "TTC data is in an older format" errors later.
- **Step 2/3 forgetting to `source ../env.sh`** makes the freshly
  built `install/bin/idris2` (used as `$IDRIS2_BOOT`) fail to find
  Chez/its own support libraries, since it's a plain unwrapped binary
  unlike nixpkgs' own wrapped one.
- **Step 3 (`install-api`) run with `IDRIS2_BOOT` still `idris2`
  (nixpkgs')** instead of the self-built one produces an API package
  whose intermediate `.ttc` versions don't match the self-hosted
  compiler that will actually load it later -- always do Step 3 after
  Step 2, with `IDRIS2_BOOT` still pointed at the self-built binary.
