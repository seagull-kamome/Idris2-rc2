# CLAUDE.md

This repo hosts **rc2**, an independent external C code generator backend
for Idris2. See `README.md`, `CHANGES.md`, `TODO.md` for project
overview, history, and known gaps.

## Layout

- `idris2-src/` — reference clone of upstream Idris2 (gitignored,
  read-only, never edited; re-fetch via
  `git clone https://github.com/idris-lang/Idris2.git idris2-src`)
- `install/` — build output (gitignored)
- `rc2/` — the actual deliverable (own package, own runtime, own tests)
- `rc2/doc/` — implementation deep-dives for specific compiler passes,
  meant to let a future session regain context without re-deriving the
  design (currently: `reuse-analysis.md` for the constructor-reuse-in-
  place pass, `native-type-inference.md` for native/unboxed Rep
  inference). Not a replacement for `CHANGES.md`/`TODO.md` — those stay
  the changelog and gap tracker; `rc2/doc/` is where the *why* and the
  bugs-found-along-the-way for a specific subsystem live.
- `env.sh` / `gen-env.sh` — environment setup; `source env.sh` before
  building/running rc2 or plain `idris2`

## Build & test

```sh
cd rc2 && source ../env.sh

# compiler
nix-shell -p idris2 gmp pkg-config --run 'idris2 --build rc2.ipkg'

# runtime library (support/rc2/libidris2rc2.a)
cd support/rc2
nix-shell -p gcc gmp pkg-config --run 'make && make install'
cd ../..

# ported upstream RefC regression suite
cd tests/refc-suite
nix-shell -p gcc gmp pkg-config --run './run.sh'
```

Hand-written smoke tests (`rc2/tests/Test1Basics.idr` .. `Test6NativeInts.idr`)
and benchmarks (`rc2/tests/Bench*.idr`) are compiled/run the same way
`idris2-rc2 --cg rc2 <file>.idr -o <out>` is used above.

## Conventions

- Code, comments, and commit messages: English.
- When changing codegen (`Compiler/RC2/Emit.idr`, `RC.idr`, `Types.idr`,
  `RCExp.idr`), verify the generated C against real RefC
  (`idris2 --cg refc`) for parity, and re-run the full refc-suite plus
  the `rc2/tests/*.idr` smoke tests and benchmarks before considering
  the change done.
- Never modify git config. Set identity inline per-commit only:
  `git -c user.name="..." -c user.email="..." commit ...`.
- Only commit when the user explicitly asks.
- Don't delete test build artifacts (`build/`, generated `.c` files)
  right after a test run — leave them in place for review until after
  the related commit lands. They're gitignored, so nothing extra ends
  up staged.
- Don't delete test build artifacts (`build/`, generated `.c` files)
  immediately after a test run — leave them in place for review until
  after the related commit lands. They're gitignored, so nothing extra
  ends up staged.
- When making functional changes, record the details in `CHANGES.md`
  using a few lines of concise text.


