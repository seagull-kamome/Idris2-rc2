# rc2's directive system (`--directive VALUE` / `%cg rc2 <directive>`)

A reference for every directive rc2 recognises: what each one does, why
it exists, and how to actually pass one. Companion to
`doc/reading-the-ir.md` (which documents `dumprcexpr`'s own *output*
format in depth -- this document is about the directive mechanism
itself and every directive built on top of it).

## 1. The mechanism

Idris2 has a generic, backend-agnostic `%cg <codegen> <directive>`
source pragma (parsed, aggregated across transitive imports, persisted
in TTC) alongside a repeatable CLI `--directive VALUE` flag -- both
entirely generic upstream machinery (`Core.Context.addDirective`/
`cgdirectives`, `Idris.Session`'s CLI parsing); no idris2-src changes
were needed to support any directive documented here, including the
rc2-only ones. `Compiler.RC2.RC2.compileExpr` reads the union of both
sources once, up front, via `getDirectives (Other "rc2")` (rc2's own
registered codegen name), into a single `directiveList : List String`
that every directive below is checked against.

```idris2
%cg rc2 noloop
%cg rc2 dumprcexpr
%cg rc2 extraRuntime=path/to/helpers.c
```

```sh
idris2-rc2 --cg rc2 --directive noloop --directive dumprcexpr Program.idr -o program
```

Real upstream RefC never reads `--directive`/`%cg` for anything at all
(nothing in `idris2-src/src/Compiler/RefC/RefC.idr` calls
`getDirectives`/`getSession`) -- every directive in this document is
either rc2-only in behavior, or (`extraRuntime`) rc2 simply consuming a
generic mechanism RefC happens not to.

## 2. Pipeline-stage disabling (`no<stagename>`)

For A/B regression isolation ("does this observed difference/leak trace
back to one specific pass") without editing `Compiler.RC2.RC2.toRCDefs`
and rebuilding `idris2-rc2` by hand. Each stage is purely
additive/optional: skipping it should still produce *correct* (if less
optimised, and possibly no longer byte-for-byte matching real
`idris2 --cg refc`'s own output shape) C -- none of them is required by
anything downstream of it for correctness, only for the optimisation it
itself provides. Coarse by design: a whole-stage on/off switch, not
fine-grained per-function/per-node control.

| Directive | Disables |
|---|---|
| `noinline` | `Compiler.RC2.Inline`'s whole-program inlining (`doc/inlining.md`). |
| `noconstfold` | `Compiler.RC2.ConstFold`'s whole-program fixpoint fold -- arithmetic/comparison/constructor/closure/CAF folding *and* the constant `ExtPrim` fold (`prim__codegen`), which since the `Compiler.RC2.ConstExtPrim` pass was merged in is also gated by this directive. |
| `noconaltnative` | `Compiler.RC2.ConAltNative`'s native-shadow field caching (`doc/con-alt-native.md`). |
| `nomutualloop` | `Compiler.RC2.MutualLoop`'s mutual-tail-recursion merge. |
| `noloop` | `Compiler.RC2.Loop`'s self-tail-call -> `goto` conversion, plus native-shadow/loop-invariant promotion (`doc/loop-conversion.md`). |
| `nosink` | `Compiler.RC2.Sink`'s branch-local sinking (`doc/branch-sinking.md`). |
| `nodualabi` | Both `Compiler.RC2.DualABI`'s worker/wrapper synthesis *and* its call-site rewriting together -- the rewrite needs the worker table the synthesis step builds, so splitting them wouldn't be meaningful (`doc/dual-abi.md`). |
| `nodeadcode` | `Compiler.RC2.DeadCode`'s pruning of definitions left with zero remaining callers (`doc/dead-code-elim.md`). |
| `nodupmerge` | `Compiler.RC2.DupMerge`'s batching of several individual `RDup` nodes into one higher-`extra` `RDup`. |

Two directives that look like they belong on this list but don't:

- **`noreuse` is retired, not merely undocumented.** It used to disable
  `Compiler.RC2.Reuse`, but disabling it reliably corrupted the heap in
  most smoke tests, for a root cause never diagnosed -- see
  `KNOWN-BUGS.md`'s "Retired: `--directive noreuse` no longer exists"
  for the full history. `applyReuse` now always runs unconditionally;
  passing `--directive noreuse` today is a harmless no-op, same as any
  other unrecognized directive string.
- **`nomain` is a real, currently-supported directive, just not a
  pipeline-stage disable.** It's read as its own plain `Bool` directly
  in `compileExpr`, not threaded through `toRCDefs`/`disabled` at all,
  and only controls whether `Compiler.RC2.Emit`'s `footer` emits a C
  `main()` -- see section 5 below and `doc/export-support.md`'s
  "Linking as a library" section for the end-to-end scenario it exists
  for (linking an `%export`ed program into a hand-written C driver that
  supplies its own `main`). Because that generated `main()` is also
  where the runtime lifecycle hooks are called, a `nomain` driver must
  call `idris2rc2_rtInit()` / `idris2rc2_rtFinish()` itself -- see
  `doc/runtime-lifecycle.md`.

## 3. Debug-dump directives

All three share `directiveList`, checked *after* `toRCDefs` has already
produced its result (unlike section 2's stage disables, which
`toRCDefs` itself needs to consult *before* it runs).

- **`dumprcexpr`** -- dumps the final `RCExp`, after every non-disabled
  pipeline stage, to a `.rcexpr` file next to the `.c` output. See
  `doc/reading-the-ir.md` for the full format reference and how to read
  one.
- **`dumpdualabi`** -- dumps `Compiler.RC2.DualABI`'s own Stage 2
  eligibility analysis to a `.dualabi` file, same directive mechanism as
  `dumprcexpr`. See `doc/dual-abi.md`.
- **`dumpcc`** -- prints the exact C compile/link command(s) about to
  run, to stdout.

## 4. Code-injection directives

Two directives splice arbitrary C straight into the generated `.c`,
right after its own `#include`s and before any generated definition
(`Compiler.RC2.Emit`'s `header`) -- so the injected code can use rc2's
own runtime types (`IDRIS2RC2_Value` etc.) and be called from generated
function bodies below it:

```idris2
%cg rc2 extraRuntime=path/to/helpers.c
%cg rc2 inlineRuntime=int64_t helper(int64_t x) { return x * 2; };
```

- **`extraRuntime=<path>`** reads the whole file and splices its
  contents in verbatim -- the same generic directive (and the same
  `Compiler.Common.getExtraRuntime`) the Chez backend already uses for
  `%cg chez extraRuntime=file.ss`.
- **`inlineRuntime=<code>`** is rc2's own text-instead-of-a-file
  companion (no upstream equivalent).

### The two `inlineRuntime` landmines

Both are inherent to Idris2's own generic `%cg` lexer/parser, not
fixable without touching idris2-src, and not specific to any one
directive value -- they'd bite any sufficiently multi-line/brace-ending
`%cg` directive text, rc2-defined or not.

1. **Must stay on one line.** The `%cg name { ... }` braced form stops
   at the *first* literal `}` with no nesting support, so any real C
   function body (which has one) would get silently truncated. Writing
   the code right after `inlineRuntime=` (not `{`) instead hits the
   lexer's other, unbraced fallback, which just consumes the rest of
   the line verbatim with no brace-balancing at all -- but only if it's
   all on one line.
2. **Must not end with a literal `}`.** `Idris.Parser`'s own
   `stripBraces` unconditionally strips one trailing `}` (and one
   leading `{`) from *any* `%cg` directive's captured text, whichever
   lexer form produced it -- it can't tell a real function body's own
   closing brace from the braced form's delimiter. Since a C function
   definition always ends in `}`, this silently eats it, and the
   resulting mangled C only fails much later, at the gcc step, far from
   the real cause. A trailing `;` after the function's own `}` (a
   harmless empty top-level C declaration) sidesteps it, since that `;`
   becomes the new last character instead. For anything longer or
   trickier than a one-line snippet, use `extraRuntime=` and a real file
   instead.

### Natural pairing: bare `%foreign "C:funcName"`

The natural pairing for either directive is a *bare*
`%foreign "C:funcName"` declaration -- no lib/header field at all --
calling straight into the injected code by plain textual order in the
one generated translation unit. That skips building any separate
static library or wiring up `IDRIS2_CFLAGS`/`IDRIS2_LDFLAGS` entirely;
contrast with `libs/rc2base`'s own README, which needs all of that
because its C helpers live in a real separate `.a`.

## 5. Struct-typedef suppression (`externStruct=<name>`)

`Compiler.RC2.Emit`'s struct-collection pass (Part C,
`doc/c-struct-support.md`'s "Design" section) emits a `typedef struct
{ ... } name;` per distinct struct name reachable from any `%foreign`
def's own `Struct "name" [...]`-typed argument/return -- unconditionally,
with no check for whether `name` is already `typedef`'d by an included
system/library header. A struct name real code actually wants to bind
against (not just a program's own private struct, like
`Test24CStructSupport`'s own `test_point`) is frequently already
defined that way -- the sibling `idris2-curl` repo's own
`doc/version-info-struct.md` has a real example: libcurl's own
`curl/curl.h` already `typedef`s `curl_version_info_data`. Compiling
both typedefs into the same translation unit fails with `error:
conflicting types for 'name'`, from gcc, not from rc2 itself.

```idris2
%cg rc2 externStruct=curl_version_info_data
%cg rc2 externStruct=some_other_struct_name
```

Repeatable, one name per occurrence. Each named struct is skipped only
in `header`'s own typedef-emission step -- `StructDefs` (the field
name/type table `RStructGet`/`RStructSet` resolve a field against) is
never filtered, so `getField`/`setField` on a `Struct` of that name
keep working exactly as normal, compiling to the same
`((name*)ptr)->field` C expression as any other struct.

**The Idris-side field list becomes purely nominal for a name in this
set.** Ordinarily (no `externStruct`), that field list is
authoritative -- it *is* rc2's own generated struct's real field order
and layout, byte for byte. Once a name is marked `externStruct`, rc2
emits no typedef of its own for it at all, so `((name*)ptr)->field`
compiles against whichever real definition the included header
actually provides -- the C compiler resolves that field's offset from
*that* definition, never from the Idris declaration's own order. So a
field's name and type in the `Struct` declaration still have to match
the real external struct's own field for the resulting cast to be
correct (same name; a C-type-compatible type per `cTypeOfCFType`), but
the declaration's field *order* is irrelevant to correctness, and it
never needs to list every field of the real struct -- only whichever
subset `getField`/`setField` call sites actually touch, in whatever
order is convenient.

## 6. Using directives in practice

- Directly on the `idris2-rc2` command line: `--directive VALUE`,
  repeatable (see section 1's example).
- Via `rc2/tests/verify.sh`'s own `--directive VALUE` flag, repeatable,
  forwarded straight to `idris2-rc2` -- the standard way to isolate a
  regression to one specific pass while testing, e.g. `--directive
  noloop` or `--directive noconstfold`, without hand-editing
  `toRCDefs`/rebuilding in between runs.

## 7. Motivating smoke tests

`rc2/tests/Test31CgExtraRuntime.idr` (`extraRuntime=`) and
`rc2/tests/Test32CgInlineRuntime.idr` (`inlineRuntime=`) are the
dedicated regression tests for section 4's directives.
`rc2/tests/Test84CgExternStruct.idr` is section 5's own, and its own
companion header's comment shows the `conflicting types` failure this
directive exists to avoid. All three are listed in `verify.sh`'s
`NO_REFC_DIFF_TESTS`, since real RefC never reads `--directive`/`%cg`
for anything at all -- there's no shared baseline behavior to diverge
from, and no meaningful RefC comparison for `verify.sh` to make.

## Files

- `rc2/src/Compiler/RC2/RC2.idr` -- `toRCDefs`'s own stage-disable
  wiring, `compileExpr`'s own `directiveList` fetch and every directive
  read from it, `getInlineRuntime`, `getExternStructs`.
- `rc2/src/Compiler/RC2/Emit/Util.idr` -- `InjectedRuntime`, the
  header-scoped state the two code-injection directives write into;
  `ExternStructs`, section 5's own.
- `rc2/tests/Test31CgExtraRuntime/`, `rc2/tests/Test32CgInlineRuntime/`,
  `rc2/tests/Test84CgExternStruct/` -- the motivating smoke tests
  (section 7).
- `KNOWN-BUGS.md` -- `noreuse`'s retirement history.
