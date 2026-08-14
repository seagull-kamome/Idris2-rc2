# CLAUDE.md

This repo hosts **rc2**, an independent external C code generator backend
for Idris2. See `README.md`, `TODO.md` for project
overview, history, and known gaps; `KNOWN-BUGS.md` for confirmed,
already-investigated test quirks (reference-installation defects,
pre-existing leaks, etc.) that don't need re-investigating when they
show up again during testing.

## Layout

- `idris2-src/` — reference clone of upstream Idris2 (gitignored,
  read-only, never edited; re-fetch via
  `git clone https://github.com/idris-lang/Idris2.git idris2-src`)
- `install/` — build output (gitignored). Also the place to `git clone`
  any external package needed only temporarily (e.g. for a one-off
  benchmark comparison) -- everything under `install/` is already
  gitignored wholesale, so nothing needs adding to `.gitignore` per
  clone. Don't clone such things at the repo root.
- `rc2/` — the actual deliverable (own package, own runtime, own tests)
- `rc2/doc/` — implementation deep-dives for specific compiler passes,
  meant to let a future session regain context without re-deriving the
  design (currently: `reuse-analysis.md` for the constructor-reuse-in-
  place pass, `native-type-inference.md` for native/unboxed Rep
  inference, `loop-conversion.md` for self-/mutual-tail-call ->
  `goto` conversion and native-shadow loop params, `reading-the-ir.md`
  for how to dump and read the `RCExp` IR itself — a practical
  reference, not a pass write-up, `dual-abi.md` for the dual (Boxed/
  native) calling convention letting native representations cross
  ordinary function-call boundaries — a living document, updated as
  later stages land, `con-alt-native.md` for caching a repeatedly-
  native-read constructor-destructured field into a fresh native
  shadow, `reuse-monadic-bind-gap.md` for an investigated-but-not-
  pursued gap: constructor reuse doesn't reach across a monadic-bind
  continuation). Not
  a replacement for `TODO.md` — those stay the changelog
  and gap tracker; `rc2/doc/` is where the *why* and the
  bugs-found-along-the-way for a specific subsystem live.
  `rc2/doc/ja/` holds Japanese translations of some files directly
  under `rc2/doc/` (same filenames) — the English originals are always
  authoritative and are the only ones maintained on every edit; only
  update `rc2/doc/ja/` when specifically asked to translate/sync it.
- `env.sh` / `gen-env.sh` — environment setup; `source env.sh` before
  building/running rc2 or plain `idris2`

## コーディング規約

- Cの関数名、グローバル変数、マクロ等には 'idris2rc2_' のプリフィックスをつける。
  マクロの場合は 'IDRIS2RC2_'を使う。

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
- TODO.mdには積み残しの課題を記録する。実装が済んでドキュメント化した項目は書かない。
- ドキュメントを読めばわかる事はコードのコメントには書かず、参照リンクの記載に留める。


