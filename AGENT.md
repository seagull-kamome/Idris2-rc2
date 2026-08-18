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
  continuation, `inlining.md` for the whole-program `Lifted`-to-`Lifted`
  inlining pass that lets an interface-dispatched comparison fuse into
  `RCmpCase` through a call boundary, `branch-sinking.md` for the
  loop-independent pass that moves a `let`-bound value into the one
  branch arm that actually reads it, dropping it everywhere else
  instead of computing it unconditionally, `cast-fold-scope.md` for an
  investigated-but-not-pursued gap: why `Compiler.RC2.ConstFold`'s
  constant folding excludes `Char`-/`Double`-to-`String` casts and any
  `String`-sourced `Cast`). Not
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
以下を金言とせよ。

コードには How
テストコードには What
コミットログには Why
コードコメントには Why not


### コメント規約
コード内のコメントは極力排除する。
コード自体が何をしているか説明するような冗長なコメント(How)は禁止します。
どうしても必要場合は(Why not/特異な制約等)を除き、コメント無しのクリーンな
コードを書きなさい。

モジュールの先頭には、そのモジュールの役目と負うべき責任についてのコメントと
Copyright表記を書きなさい。

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.


### Cコード
./code-style-C.md を参照

### Idris2コード
./code-style-Idris2.md を参照

### テストコード

退行テスト、スモークテストの期待出力はあらかじめテキストファイルを作っておき、
diffのみで成否判定できるようにする。
全てのテストを順番に実行して成否判定するシェルスクリプト'tests/verify.sh'を用意する。
テストの実施はこのスクリプトで行い成否判定の手間を簡略化する。
新しいテストを作成したらスクリプトも更新する。
テストを単体で走らせる必要が生じた場合の手順はこのスクリプトを見ればわかるようにしておく。
テストの結果生じる生成物(生成したCコード、IRダンプ、テスト出力)はtests/build以下に
置きテスト終了時には消さずに後で確認できるように残しおく。このディレクトリはテストスクリプト
の先頭で掃除してからテストが実施されるようにしておく。

ベンチマークテストも同様にシェルスクリプト'tests/bench.sh'を用意しテスト手順のミスを減らす。


## Build & test

See `README.md`'s own "Building and running" and "Testing" sections for
the actual commands and flags (`idris2 --build rc2.ipkg`,
`rc2/tests/verify.sh`, `rc2/tests/bench.sh`) — don't duplicate them
here.

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
  immediately after a test run — leave them in place for review until
  after the related commit lands. They're gitignored, so nothing extra
  ends up staged.
- TODO.mdには積み残しの課題を記録する。実装が済んでドキュメント化した項目は削除する。
- ドキュメントを読めばわかる事はコードのコメントには書かず、参照リンクの記載に留める。


