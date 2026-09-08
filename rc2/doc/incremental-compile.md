# Incremental (per-module) compilation

**Status: working end-to-end**, on branch `feature/rc2-incremental-compile`.
`prelude`/`base`/`linear`/`contrib`/`network` (272 modules total) all
rebuild cleanly under `--inc rc2` with zero missing incremental data;
real executables built with `--cg rc2 --inc rc2` (including one using
`Data.List`/`Data.SortedMap`, not just a bare `putStrLn`) run and
produce correct output, and touching one source file and rebuilding
only recompiles that file (`rc2/tests/verify.sh`'s own 111/0/0
whole-program baseline unaffected throughout). The design sections
below (mostly) predate any code and are kept as originally written;
"Bugs found while implementing" and "End-to-end verification" document
what actually turned up once `incCompileFile`/`incCompile`/
`compileExprInc` existed to try against real code, several of which
the design sections below didn't anticipate.

## Motivation

rc2's own whole-program pipeline (`RC2.idr`'s `toRCDefs`) recompiles
every reachable definition in the entire program from scratch on every
build, even when only one module's source changed. For a real project
with many modules this dominates edit-compile-run turnaround. Upstream
already solved this generically (`Compiler.Common.Codegen`'s
`incCompileFile`/`incExt` fields, wired into `Idris.ProcessIdr.process`
and the TTC format) and Chez implements it
(`Compiler.Scheme.Chez.incCompile`/`compileExprInc`) -- this document
adapts that same upstream mechanism to rc2's C backend.

## Upstream mechanism (recap)

- `Codegen.incCompileFile : Maybe (... -> sourcefile -> Core (Maybe (objfile, List extraData)))`
  and `Codegen.incExt : Maybe String` are the two fields a backend
  fills in to opt into incremental support.
- `Idris.ProcessIdr.process` calls `incCompileFile` once **per module**,
  right after that module finishes elaborating, on exactly the
  definitions newly added to `Core.Context`'s `toIR : NameMap ()` field
  (populated by `addToSave`, called for every top-level function/data
  constructor/case-lambda/PE-specialization elaborated from that
  module's own source -- i.e. "everything this module itself defines",
  regardless of whether anything calls it yet). `Compiler.Common.getIncCompileData`
  already implements the generic "compile just `toIR`'s definitions"
  data-gathering step; a backend's `incCompileFile` only needs to turn
  that into object code.
- The result `(objfile, extraData)` is stashed into the TTC
  (`Core.Context.setIncData`/`incData` field) alongside the module's
  own compiled definitions. Importing modules accumulate every
  dependency's incData into `allIncData`
  (`Core.Context.addImportedInc`) -- if *any* imported module is
  missing incData for the active codegen, that codegen's incremental
  support is silently abandoned for the whole build
  (`missingIncremental`, `Idris.ProcessIdr`) and it falls back to a
  full whole-program rebuild. A module whose own source and imports'
  interface hashes are unchanged, and which already has incData for
  the active codegen, skips reprocessing entirely (`processMod`'s
  `sourceUnchanged && ... && incrementalOK` check) -- this is where the
  actual compile-time win comes from, not from anything backend-side.
- `Codegen.compileExpr` (the existing whole-program entry point, called
  exactly once, at the very end, on the real `main` `ClosedTerm`) is
  the only place that ever produces the final executable. A backend
  that supports incremental compilation still implements this --
  Chez's `compileExprInc` checks `allIncData`, and if present, compiles
  *only* the tiny root expression itself into a fresh file and links it
  against every accumulated per-module `.so` (loaded via
  `load-shared-object`, resolved dynamically by Scheme's own top-level
  `define` namespace).
- CLI: `--cg rc2 --inc rc2` (`--incremental-cg`/`--inc`,
  `Idris.CommandLine`) selects rc2 as the active codegen and opts it
  into incremental mode (`setIncrementalCG`, which itself checks
  `incCompileFile` isn't `Nothing` before allowing this); equivalently,
  `IDRIS2_INC_CGS=rc2` (`docs/source/backends/incremental.rst`).
  `Idris.Package.installFrom` already copies each module's incremental
  object file on `install` generically, keyed purely off `incExt` --
  nothing rc2-specific needed there.

### Custom/external backends need nothing extra

rc2 is itself a *custom* backend in upstream's own sense
(`docs/source/backends/custom.rst`): `Main.idr` calls
`Idris.Driver.mainWithCodegens [("rc2", codegenRC2)]` to produce the
standalone `idris2-rc2` executable, rather than being folded into the
main `idris2` binary's own built-in codegen list. Checked both
`docs/source/backends/custom.rst` (the backend-authoring guide) and
`docs/source/backends/backend-cookbook.rst` (765 lines, zero mentions
of incremental compilation anywhere in it) -- neither document, nor
`Compiler.Common`/`Idris.ProcessIdr`'s own source, treats a
`mainWithCodegens`-registered codegen any differently from a built-in
one for this purpose. `session.codegen`/`incrementalCGs` compare by
`CG` value (a custom backend is tagged `Other "rc2"`, the same
`Other "rc2"` tag `RC2.idr`'s own `getDirectives (Other "rc2")` call
already relies on elsewhere for the existing `--directive` mechanism),
and every piece of the incremental machinery (TTC `incData` embedding,
`missingIncremental`'s rebuild-skip check, `installFrom`'s object-file
copy) keys off that value generically. So: no additional plumbing is
needed on rc2's side beyond implementing `incCompileFile`/`incExt`
themselves -- the "custom backend" packaging is not a separate concern.

### The real practical prerequisite: rc2 needs its own incrementally-built prelude/base/contrib/network

`incremental.rst`'s "Building executables incrementally" section is
explicit: *every* imported module -- transitively, including
`prelude`/`base`/`contrib`/`network` -- must already carry incData for
the active codegen, or the whole build silently falls back to
whole-program compilation (`missingIncremental`). Upstream ships
prebuilt Chez incremental artifacts for exactly those packages "by
default" -- meaning someone already ran an incremental Chez build of
each and installed the resulting `.so` sidecars next to their `.ttc`s.
Nobody has ever done the rc2 equivalent: today's self-built toolchain
installs one ordinary (non-incremental) set of `.ttc`s that every
backend -- chez, RefC, rc2 -- shares interchangeably, precisely
*because* a `.ttc` alone carries no backend-specific object code and
whole-program codegen is regenerated fresh from it every time
regardless of which backend is active. That interchangeability is
exactly what breaks under `--inc rc2`: a real program almost always
imports at least `prelude`, so rc2's own incremental mode has nothing
useful to link against for any real program until `prelude`/`base`/
`contrib`/`network` are each separately rebuilt with
`idris2-rc2 --inc rc2 --install-with-src <pkg>.ipkg` (or equivalent)
and reinstalled with their own `.o` sidecars. This is a one-time
toolchain-setup task, orthogonal to the compiler-side implementation
work below, but it's the actual blocker for trying this feature out on
anything beyond a synthetic single/two-module fixture with no
dependencies -- tracked here rather than assumed away.

## Why rc2 doesn't need Chez's "recompile the root term separately" step

Chez's `compileExprInc` still has to synthesize a small dynamic-load
wrapper for the root term because Scheme's cross-module linkage is
**dynamic**: a `.so`'s top-level `define`s only become callable once
`load-shared-object`ed into a live Scheme namespace at run time, and
the root term itself was never part of any module's own `toIR`, so it
never got compiled by any `incCompileFile` call.

C's cross-module linkage is **static** (ordinary linker symbol
resolution), and rc2 doesn't need an equivalent detour: `main`'s own
body is already just an ordinary top-level Idris definition
(`Main.main`, called with a Boxed `%World` token) that lands in the
`Main` module's own `toIR` like any other definition -- it gets
compiled into `Main.o` by the very same per-module `incCompileFile`
call as everything else `Main.idr` defines. The only thing missing is
the literal C `int main(void)` entry point that calls it, which is
pure boilerplate with no dependence on the `ClosedTerm` Chez's
`compileExprInc` needs. `Emit.idr`'s `generateCSourceFile` already has
exactly the parameter to control this: `noMain`, added earlier for the
`%export`-as-library scenario (`rc2/doc/export-support.md`, "Linking
as a library"). Incremental mode reuses it verbatim: pass
`noMain = (moduleNS /= nsAsModuleIdent mainNS)` when generating a
module's own `.c` -- true for every module except the one literally
named `Main` (same check `Idris.ProcessIdr.processMod` already makes
at its own `ns /= nsAsModuleIdent mainNS` guard).

Consequence: rc2's final whole-program `compileExpr`, in incremental
mode, does **no C code generation at all** -- it degenerates to a pure
link step over `allIncData`'s accumulated `.o` files (`Main.o` already
contains `main()`). This is simpler than Chez's own final step.

## Which existing passes need to change -- and which don't

The naive worry going in was that `ConstFold`'s whole-program CAF
fixpoint, `Loop`/`MutualLoop`'s callee tables, and `DualABI`'s worker/
call-site rewriting all assume full-program visibility and would need
real rework to become "module-boundary-safe". Reading each one's
actual implementation shows this mostly isn't true -- they were never
given anything *but* the def list `toRCDefs` passes them, and already
degrade safely today whenever a callee isn't in that list (true right
now too, for every foreign/builtin/constructor call already outside
whole-program `defs`). Restricting that list to one module's own
`toIR` scope, for incremental compiles, is therefore enough on its
own -- no code changes needed in these passes:

- **`ConstFold.foldConstProgram`**: `rebuildTable`/`cafValueOf` only
  ever consult the def list they're handed. A call to a CAF defined in
  another module simply never has a table entry, so it's never folded
  -- safe (a missed optimization across the module boundary, not a
  correctness risk). Nothing to change.
- **`MutualLoop.applyMutualLoop`**: per the user's own confirmation,
  Idris doesn't allow mutual recursion across module boundaries in the
  first place (mutual blocks are a single-module syntactic construct)
  -- there is no cross-module case for this pass to ever see. Nothing
  to change.
- **`Loop.buildCalleeTable`/`applyLoop`**: the table is built purely
  from the passed def list (`buildCalleeTable`'s own doc comment: "each
  entry comes purely from that one definition's own body ... never by
  consulting any other entry"). A callee outside the module has no
  entry, and a table-lookup miss already means "not eligible" today
  (this is the exact same path every foreign/builtin call target
  outside `defs` already takes in the current whole-program build).
  Nothing to change.
- **`DualABI.applyDualABI`/`applyCallSiteRewrite`**: whether a function
  `n` gets a native worker synthesized is decided purely from `n`'s
  *own* body (`paramEligibility`/`returnEligibility`), never from its
  callers -- so a module's own functions still get worker-optimized
  regardless of who calls them from outside. Call-site *rewriting* to
  use a worker's native ABI only fires when the callee's worker entry
  is present in the worker table, itself built from the same
  module-restricted def list -- a cross-module call site simply never
  matches and stays an ordinary Boxed call, automatically. Nothing to
  change.
- **`Sink`/`DupMerge`/`Reuse`/`ConAltNative`/`RC.normalize`+`annotate`/
  `Inline`**: already purely per-definition or already module-local
  today (they never held a whole-program invariant to begin with).
  Nothing to change.
- **Constant staging** (`EmitUtil.stageConstCon`/`genConstant`,
  `ConstDef`/`ConstConDef`): already emits every staged value/
  constructor/closure as C `static` -- safe to duplicate verbatim
  across per-module translation units with no symbol collision. Cross-
  module *sharing* of an identical constant is lost (each module now
  emits its own copy) -- see "Deferred: cross-module constant sharing"
  below. Nothing required for correctness.
- **Function declarations** (`Emit.declarationsOf`): already emitted
  with no `static` qualifier, i.e. already ordinary external C
  linkage, forward-declared as prototypes. Already exactly what
  separate translation units calling each other need. Nothing to
  change.

## What actually needs to change

Only `DeadCode.pruneDeadDefs` and the top-level driver
(`Compiler.RC2.RC2`) need real work:

1. **Skip dead-code elimination entirely in incremental mode.**
   `pruneDeadDefs`'s reachability-from-`roots` model is inherently
   whole-program -- a definition this module doesn't currently call
   itself may still be called from a module compiled later (or already
   compiled, from this one). This is also *why* a CAF that `ConstFold`
   reduced to "just returns a constant" can't be dropped either (the
   TODO.md note this doc replaces) -- that's not a separate mechanism,
   it's a direct consequence of skipping DCE: the original definition
   simply survives, unpruned, exactly like every other still-needed
   definition. `toRCDefs` already has a directive-driven stage-disable
   list (`"nodeadcode"` among others, see `rc2/doc/directives.md`) built
   for A/B isolation -- the new `incCompile` (below) reuses it verbatim
   by unconditionally including `"nodeadcode"` in the `disabled` list
   it passes to `toRCDefs`, on top of whatever `--directive noXXX`
   flags the user also supplied. No new parameter on `toRCDefs` itself.

2. **New `incCompile` function** (`Compiler.RC2.RC2`, mirrors Chez's
   `incCompile`):
   - `cdata <- getIncCompileData False Lifted` -- same `UsePhase` the
     whole-program path already uses (`toRCDefs` only ever needs
     `LiftedDef`s, never ANF/VMCode).
   - If `namedDefs cdata` is empty: return `Just ("", [])` (matches
     Chez -- record that the module was incrementally compiled with no
     actual output, still needed for `missingIncremental`'s later
     check to pass).
   - Otherwise: derive the module's own `ModuleIdent` from `sourcefile`
     (`ctxtPathToNS`, same helper `getObjFileName`/`getTTCFileName`
     already use) to decide `noMain` (see above) and to compute output
     paths; run `toRCDefs (nub ("nodeadcode" :: disabledStages)) [] (lambdaLifted cdata)`;
     `generateCSourceFile` into the ttc build directory's own
     `<modpath>.c` (`getTTCFileName sourcefile "c"`); `compileCObjectFile`
     it into `<modpath>.o` (skip `compileCFile` -- no link at this
     stage); return `Just (objRelativeName, foreignLibs)`, where
     `objRelativeName` is `getObjFileName sourcefile "o"` (relative,
     the form stored in the TTC and later resolved against each
     dependency's own build directory) and `foreignLibs` is exactly
     this module's own `generateCSourceFile` foreign-library result --
     upstream's own `extraData : List String` slot exists for exactly
     this (Chez stores its own per-module foreign lib names the same
     way).
   - `codegenRC2 = MkCG compileExpr executeExpr (Just incCompile) (Just "o")`.

3. **`compileExpr`'s incremental branch.** Same shape as Chez's own
   `compileExpr` (`if not wholeProgram sesh && RC2 elem incrementalCGs sesh then ... else compileExprWhole ...`):
   look up `allIncData` for `RC2`; if present, skip
   `getCompileDataWith`/`toRCDefs`/`generateCSourceFile` entirely and
   go straight to linking every accumulated `.o` (each resolved to its
   real path the same way an import's `.ttc` is resolved) plus the
   union of every module's own `foreignLibs`, via `compileCFile`.
   Falls back to today's whole-program path if `allIncData` is missing
   RC2's entry (mirrors Chez's own "missing incremental compile data,
   reverting to whole program compilation" fallback message).

4. **`CC.compileCFile` signature**: generalize its single
   `objectFile : String` parameter to `objectFiles : List String`
   (placed in the `cc` invocation the same way, just multiple
   positional arguments instead of one) -- the only call site is
   `RC2.idr`'s own `compileExpr`, in both the whole-program branch
   (always a one-element list, unchanged behavior) and the new
   incremental branch (the accumulated `.o` list).

## Bugs found while implementing (and how each was fixed)

Verification against real code (a `prelude.ipkg` rebuild with
`--cg rc2 --inc rc2`, once `incCompile`/`compileExprInc` existed)
turned up three real gaps the design sections above didn't predict --
all three share the same root cause: `Emit.idr`'s forward-declaration
machinery (`collectDeclarations`/`declarationsOf`) was only ever
exercised with `defs` being the *whole* program, where every name it
could possibly need to reference is, by construction, already present
in that same list. Once `defs` is legitimately a single module's own
subset, that assumption breaks in three distinct spots. (`ConstFold`/
`MutualLoop`/`Loop`/`DualABI` -- the passes the "Which existing passes
need to change" section above worried about -- needed no changes in
the end, exactly as predicted there; the real gaps were all in `Emit`,
which that section didn't cover since it's not one of the whole-
program-fixpoint-style passes.)

1. **Untagged constructor name references across modules.** A
   constructor built without a small-int tag (`RCon`'s own `tag = Nothing`,
   or `RCConstCon`'s equivalent) sets its runtime `->name` field to a
   file-scope `idris2rc2_constr_<name>` string constant
   (`createCFunctions`'s own `RCon` case; `EmitUtil.boxedConstConExpr`'s
   `nameField`). `declarationsOf`/`collectDeclarations` only forward-
   declares this for a constructor the *current* `defs` list itself
   defines -- a module that merely *references* one owned by another
   module (found via `Prelude.Basics` referencing `Builtin.Void`) got
   no declaration at all: a plain "undeclared identifier" C error.
   Fixed by a new exhaustive walker, `untaggedConstructorRefsD`
   (`Emit.idr`), collecting every such reference across a module's own
   `defs`, subtracting the ones that module already owns, and emitting
   an `extern char const idris2rc2_constr_<name>[];` for the remainder
   -- a no-op in whole-program mode (the subtraction always empties the
   set there, since ownership is total), real once `defs` narrows.
2. **Direct cross-module function calls.** The exact same story for
   `RAppName`/`RUnderApp`/`RCConstClosure` references to another
   module's own top-level function (`declarationsOf`'s `MkRCFun` case
   is equally `defs`-local-only) -- found via `Prelude.Num` calling
   `Prelude.EqOrd`'s own comparison functions directly by name: a C
   "implicit declaration of function" error. Fixed the same way, a new
   walker `externalFunctionRefsD`, with one added subtlety: the first
   attempt declared every such reference with an unspecified, K&R-style
   empty-parens parameter list (`IDRIS2RC2_Value *name();`), trusting
   traditional C's "unspecified arguments" semantics to let a real call
   through regardless of declared arity -- this broke on the actual
   toolchain's own C standard default, which (a real difference C23
   introduced) treats bare `()` the same as `(void)`: a genuine 2-
   argument call to a name declared that way is a hard "too many
   arguments" error. Fixed for real by tracking the exact arity from
   any real `RAppName` call site to that name (the true, authoritative
   arity, since a saturated direct call's own argument count always
   matches the callee's real arity), falling back to arity 0 only for a
   name referenced solely as a function-pointer value
   (`RUnderApp`/`RCConstClosure`, always consumed through an explicit
   erased-signature cast already, so the declared arity there is moot).
3. **`%foreign` declarations with no rc2-usable calling convention.**
   `Prelude.IO.prim__threadWait` is declared
   `%foreign "scheme:blodwen-thread-wait"` only -- no `"C:..."`/
   `"RefC:..."`/`"RC2:..."` convention exists for it at all, since only
   Chez ever needed one. `collectDeclarations`'s own `MkRCForeign` case
   throws a hard `InternalError` when `parseCC` matches nothing -- in
   whole-program mode this is unreachable in practice (nothing in any
   existing rc2 program calls `threadWait`, so `DeadCode.pruneDeadDefs`
   always removes the declaration before `collectDeclarations` ever
   sees it), but incremental mode deliberately never runs `DeadCode` at
   all (see "What actually needs to change" above) -- every module's
   *entire* `toIR`, used or not, real convention or not, reaches
   `collectDeclarations` regardless, and this one had simply never been
   reached before. Decided not to turn this into a runtime crash stub
   -- but also, on reflection, not to soften whole-program mode's own
   existing behavior either: `generateCSourceFile` gained a
   `dropUnimplementableForeign : Bool` parameter, `False` for
   `compileExprWhole` (keeps today's hard, immediately-attributable
   `InternalError` naming the exact Idris function -- if such a
   declaration is ever genuinely reachable there, something in the
   program truly calls a function rc2 can't implement, worth failing
   on immediately and unambiguously) and `True` for `incCompile` (a
   `%foreign` declaration with no rc2-usable convention is dropped
   from `defs` entirely, before either forward-declaration or
   definition generation runs, treating it as if it simply didn't
   exist). Any real caller (if one ever turns up) then falls out of
   gap #2's own mechanism above automatically -- an ordinary
   "referenced but not defined anywhere" name -- so it still gets a
   plain `extern` prototype and the failure surfaces as a *link-time*
   "undefined reference" there instead of either a compile-time stop
   or a deferred runtime crash.

Each of these three was found and fixed on real code (a genuine
`prelude.ipkg` incremental rebuild) -- with fix #3 in place, all 14
`prelude` modules build cleanly under `--inc rc2` with zero errors and
zero "no incremental compile data" warnings.

## Known limitation (decided, not a bug to fix): no C struct support under `--inc rc2`

Rebuilding `base.ipkg` incrementally next (same `--inc rc2`, prelude
already clean) got 28/136 modules in before a new, structurally
different failure: `System.FFI.idr`'s own

```idris2
prim__getField : {s : _} -> forall fs, ty . Struct s fs -> (n : String) -> ... -> PrimIO ty

getField : {sn : _} -> (s : Struct sn fs) -> (n : String) -> ...
getField s n = prim__getField s n fieldok
```

`prim__getField`/`prim__setField` (`Compiler.RC2`'s own C-struct-
support machinery, `rc2/doc/c-struct-support.md`) require their own
struct-name/field-name arguments to be literal strings *at the call
site* -- there's no other way to know which C struct/field a call
means, since this isn't a real FFI call with its own declared type,
it's a primitive rc2 recognizes structurally. `getField` above is
deliberately generic (`n : String` is an ordinary bound parameter, not
a literal) -- every *real* call site in a real program supplies a
literal (`getField myStruct "x"`), and whole-program compilation never
notices because `Compiler.RC2.Inline` always inlines a function this
small into every call site, so `prim__getField`'s own arguments at the
only place it's ever actually emitted are already the caller's own
literals; `getField`'s own standalone definition (with `n` still a
plain bound variable) never survives to be compiled at all, since
nothing calls the un-inlined version and `DeadCode`/upstream's own
reachability prune it away first.

Incremental compilation breaks this the same general way as gap #3
above (never runs `DeadCode`, so `getField`'s own module-level
definition is compiled for real, literal-check included). Unlike gap
#3 though, `getField` isn't actually unimplementable the way a no-
convention `%foreign` declaration is: it has a perfectly real
implementation for every genuine call site, *only* reachable through
inlining, which is precisely what compiling it as a standalone
reusable object file (the entire point of incremental compilation)
cannot provide -- a cross-module caller needs this inlining to happen
in *its own* module, against *its own* literal argument, which a
separately-compiled `getField.o` structurally can't retroactively
supply.

**Implemented anyway, as the same "drop it" move as gap #3** (the
user's own call, once the tradeoff above was laid out): `RC.idr`'s
`normalize` tags both throw sites with a dedicated, greppable marker
(`notInlinedStructFieldMarker`) instead of a free-text message;
`RC2.idr`'s `toRCDefs` gained an `incremental : Bool` parameter, and
in incremental mode only, catches exactly that marker around each
individual `toRCDefPreFold` call and drops that one definition from
the result (whole-program mode's own `incremental = False` path is
completely unchanged -- still an uncaught `InternalError`, since this
case is unreachable there in practice, per the paragraph above). A
program never touching structs is unaffected either way; one that does
now gets the same link-time "undefined reference" outcome as gap #3,
instead of `getField`'s own defining module (`System.FFI`) taking the
whole package's incremental build down with it. Verified for real: a
full `--inc rc2` rebuild of `base.ipkg` (`getField` lives in
`System.FFI`, part of `base`) completed end-to-end afterward, where it
previously aborted outright at `System.FFI` -- see "Cascading fragility
of a single missing/failed module" below for what that rebuild then
went on to reveal.

The forcing-unconditional-inlining alternative floated earlier (forcing
`prim__getField`/`prim__setField`-wrapping functions to always inline
regardless of `Compiler.RC2.Inline`'s normal size/eligibility
heuristics, so a *caller's* own incremental compile still inlines them
down to literals even though `getField` itself is never compiled as a
standalone function anywhere) was not pursued, in favor of the
simpler, already-established "drop it" mechanism above.

**Net effect: `--inc rc2` still doesn't support C struct support**
(`Compiler.RC2`'s `getField`/`setField`/`Struct` machinery,
`rc2/doc/c-struct-support.md`) -- a program actually calling
`getField`/`setField` will fail to *link* when incrementally compiled,
same as any other gap-#3-style drop. What changed is blast radius, not
capability: previously, merely *defining* such a wrapper anywhere in a
module (whether or not any real program used it) crashed that
module's entire incremental compile with a confusing internal error;
now it compiles cleanly and only a genuine caller ever notices, at
link time. Whole-program compilation (`compileExprWhole`, the default)
is completely unaffected either way. Tracked as a `TODO.md` entry
pointing back here rather than a silent gap, so it doesn't get
rediscovered from scratch. `rc2/tests/verify.sh` stayed at its usual
111/0/0 baseline throughout all of the above.

### Possible follow-up improvements to the above (not done, worth reconsidering)

The three fixes above were chosen to be minimal and locally reasoned
about, not necessarily the best long-term shape. Left here so a future
session doesn't have to rediscover these tradeoffs from scratch:

- **Gaps #1/#2 duplicate a full 25-case `RCExp`/`RCLocal` walk twice**
  (`untaggedConstructorRefsD` and `externalFunctionRefsD`, both right
  next to each other in `Emit.idr`) for two conceptually-related
  "what does this module reference but not own" questions. Matches
  this codebase's own established precedent of one dedicated walker
  per concern (`Compiler.RC2.DeadCode`'s own `usedFunctionNamesR`'s doc
  comment states the same reasoning explicitly) rather than a shared
  generic fold, but two nearly-identical 25-case walkers is still a
  lot of surface area to keep in sync if `RCExp`/`RCLocal` ever grows a
  new constructor -- worth a generic "visit every embedded `RCLocal`
  in an `RCExp`" fold both could be built on top of, if a third such
  walker is ever needed and the duplication starts to hurt for real
  (YAGNI until then, per this project's own general stance on
  abstraction -- see `AGENT.md`).
- **The `extern` declarations gaps #1/#2 emit are untyped/unchecked
  across translation units** -- each module derives its own guess at
  an external name's shape (exact arity for a real call, arity 0 for a
  closure-only reference) independently, with no shared header the
  compiler could use to catch a real mismatch between what a caller
  assumes and what the definer's own module actually emits. This
  mirrors a limitation the runtime already accepts for closures
  (`EmitUtil`'s own erased-function-pointer-cast convention already
  can't be arity-checked by the compiler either), so it's not a new
  category of risk, but it is one incremental compilation newly
  extends to *direct* calls too, which didn't have this exposure
  before. A more robust design would generate real per-module header
  files (a proper build-system-level "compile signatures first, then
  bodies" phase, closer to how genuine incremental C/C++ builds work)
  instead of each module re-deriving externs from its own limited
  view -- bigger, deferred; the current approach was chosen because it
  needed no new build-orchestration machinery at all, only `Emit.idr`
  changes.
- **Gap #3's link-time failure surfaces only a mangled C symbol name**
  (e.g. `Prelude_IO_prim__threadWait`) in the linker's own "undefined
  reference" message, with no trace back to the original Idris name or
  to *why* it has no implementation (missing convention vs. a genuine
  typo). A nicer version could name-mangle these specific drops
  distinctly (e.g. a `idris2rc2_unimplemented_ffi_<name>` symbol) so a
  future linker error is at least greppable back to this exact
  mechanism, or emit a comment in the generated `.c` at every call site
  noting the drop. Not done -- the plain approach was chosen to match
  gap #2's own existing "just extern-declare and let the linker sort
  it out" mechanism exactly, rather than inventing a second, parallel
  one.

## Major finding: one module's missing incremental data cascades to the *rest of that build*, not just its own importers

Not an rc2 bug -- this lives entirely in upstream's own
`Core.Context.addImportedInc` -- but serious enough for rc2's own
purposes that it's worth its own section rather than folding into
"Known gaps". Found rebuilding `base.ipkg` incrementally end-to-end for
the first time, once the `getField` fix above let it get past
`System.FFI`: the build completed all 136 modules with zero errors,
but scanning every installed `.ttc` afterward for the `rc2` CG tag
(`grep -c rc2` -- a crude but effective incData presence check) showed
only **36 of 136** modules actually carrying incremental data. The
other **100** -- including modules with no plausible relationship to
the one that triggered this, like `Data.Vect`, `Control.Monad.State`,
`Data.SortedMap` -- had none at all.

The cause: **one single module (`System.File.Meta`) failed to produce
an object file**, for a reason that has nothing to do with any of the
gaps above -- a real, otherwise-valid `%foreign "C:idris2_fileIsTTY,
libidris2_support,idris_file.h"` declaration. Initially misdiagnosed
as a stale-nixpkgs version-skew problem; checked properly instead
(don't guess, verify): `idris2_fileIsTTY` *is* implemented, right there
in idris2-src's own `support/c/idris_file.c` (added the same commit as
`System.File.Meta`'s own `isTTY`/`prim__fileIsTTY`) -- `idris_file.h`
simply never gained the matching prototype line every other function
in that file has, an isolated upstream oversight in idris2-src's own
current source, not staleness. Confirmed with a byte-for-byte `diff`
that `install/idris2-0.8.0/support/c/idris_file.h` (this project's own
self-built copy) is identical to `idris2-src/support/c/idris_file.h`
-- the self-build faithfully reproduced idris2-src's own header
exactly as it is upstream; nothing fell back to an older nix-provided
copy. Whole-program compilation would fail exactly the same way if any
test actually called `isTTY` (it just never has, so `DeadCode`/
upstream's own reachability fetch always excludes the declaration
before this ever surfaces) -- not a design or implementation gap in
rc2's own incremental support at all, and not a self-build problem
either. `incCompile` correctly returns `Nothing` for that one module
(per-module graceful degradation, working as designed) -- but
the *next* module that imports it (`addImportedInc`, `Core.Context`)
reacts by deleting `rc2` from the session's own `incrementalCGs`
*entirely*, not just noting that one import as unusable. Every module
processed afterward in that same `idris2-rc2` invocation -- for the
*rest of that package's build*, regardless of whether it has any
import relationship to the failing module at all -- silently gets no
incremental data either, with no further warning printed (the warning
itself only fires while `rc2` is still in `incrementalCGs`, so it
prints exactly once, right when the cascade starts, and then goes
quiet even though the effect keeps spreading).

This means the practical reliability of `--inc rc2` (or, by this same
mechanism, `--inc chez`) hinges on *zero* modules failing anywhere in
a large dependency-ordered build -- one bad `%foreign` declaration,
anywhere, silently disables incremental compilation for most of
everything processed after it in that same invocation, not just for
programs that actually depend on the broken module. For a from-scratch
rebuild of a whole standard library (this session's own use case), that's
a real risk: `base` alone is 136 modules, and this session found two
independent module-level failures (`getField`'s own literal
requirement, `idris2_fileIsTTY`'s own missing header prototype -- a
one-line upstream oversight in idris2-src itself, filed/fixed
separately from this doc's own concerns) on the very first attempt.
Whether this is worth working around on rc2's own side
(e.g. detecting the cascade and re-attempting incremental compilation
for modules after it within the same invocation, or some other
mitigation) or is simply a sharp edge to document and route around
(e.g. `IDRIS2_INC_CGS` per-package, rebuilding a package a second time
once its own first module-level failure is fixed, since a *second*
`--install` run reprocesses every module fresh and would pick up
`rc2` incData wherever no failure recurs) is an open question for
whoever picks this back up -- not attempted this session, since it's a
property of upstream's own incremental machinery, not something local
to `Compiler.RC2`.

## End-to-end verification: five more bugs found actually running a program

Getting `prelude`/`base`/`linear`/`contrib`/`network` to rebuild
cleanly (the previous two sections) only proves each *module* compiles
to a valid `.o` in isolation -- it says nothing about whether those
`.o`s actually *link and run correctly together* as a real executable.
They didn't, not at first: a trivial `Hello.idr` (`--cg rc2 --inc rc2`)
surfaced five more real bugs, in order, each fixed before moving to
the next. `rc2/tests/verify.sh` stayed at 111/0/0 after every one.

1. **`noMain` used the wrong namespace.** `incCompile` derived it via
   `ctxtPathToNS sourceFile`, which infers the namespace from the
   *file path* (`Hello.idr` -> `Hello`) -- wrong, since Idris2 lets a
   file's own `module Main` declaration differ from its filename
   precisely for the entry-point case (`Hello.idr` containing
   `module Main` is completely ordinary and exactly what every `-o`
   invocation does). Every module compiled with `noMain = True`,
   including `Main` itself -- `undefined reference to main` at link
   time (the linker's own C runtime startup code, `_start`, always
   needs a real `main` symbol from somewhere). Fixed by reading the
   module's own already-recorded *declared* namespace off `Ctxt`
   (`currentNS`) instead of re-deriving anything from the file path.
2. **`%World`'s own typecase name string was never defined anywhere.**
   `PrimIO.unsafeCreateWorld`'s `%MkWorld` construction references
   `idris2rc2_constr__percentWorld` as an untagged constructor name --
   gap #1's own fix correctly `extern`-declares it wherever referenced,
   but nothing anywhere ever *defines* it, since (like `Int`/`Char`/
   `(->)` before it) it has no backing top-level declaration in the
   program at all. `undefined reference to idris2rc2_constr__percentWorld`
   at link time. Fixed by adding it to `runtime.c`'s own existing
   "predeclared primitive typecase name" list right alongside those
   (same list, RefC's own `support/refc/prim.c` doesn't have this one
   either -- not because it's handled differently there, but because
   whole-program compilation, rc2's own included, always inlines
   `unsafeCreateWorld` into its own single caller before this shape
   ever reaches Emit; only compiling `PrimIO.idr` in total isolation
   ever exposes it).
3. **No root-term codegen means no `main()` caller either.** Design
   said "no separate root-term recompile step needed, `Main.main` is
   just another `toIR` member" -- true for `Main.main` itself, but the
   whole-program footer's own hardcoded call to `__mainExpression_0()`
   (the `ClosedTerm`-synthesized wrapper `getCompileDataWith` builds
   fresh every time, `Compiler.Common`) has nothing to call in
   incremental mode -- that name is never a member of any module's own
   `toIR` at all. `Emit.idr`'s `generateCSourceFile` gained a
   `directEntryPoint : Maybe String` parameter: `Nothing` keeps
   today's whole-program footer verbatim; `Just call` (`incCompile`'s
   own `Main`-module case only) splices a complete call expression
   instead, built by `incCompile` itself from whatever it finds.
4. **`Main.main`'s own real arity isn't reliably 1.** First attempt at
   (3) hardcoded `"\{cname}(idris2rc2_freshWorld())"` (build one fresh
   `%World` token -- a small new `idris2rc2_freshWorld()` runtime
   helper, same construction `createCFunctions` would emit inline for
   an ordinary untagged 0-arity `RCon` -- and call `Main.main` with
   it). Worked for a bare `putStrLn` (`Main.main` compiled at arity 1,
   taking a real `%World` parameter) -- and silently produced a
   working-looking executable that printed *nothing at all* for a
   slightly bigger program (`let`-bound pure values ahead of the first
   real `IO` action). `--directive dumprcexpr` showed why: that
   `Main.main` compiled at arity 0, its own body building an
   `RUnderApp`-style closure (`partial Main.{main:31} missing=1 [v0]`)
   still missing its `%World` argument -- calling it with zero
   arguments only *builds that closure* and returns it, never runs
   anything. Not "already resolved", just a CAF standing in for the
   same function. Fixed by branching on `Main.main`'s own real
   `MkRCFun` arity in `defs` (available in `incCompile`, unlike
   `Emit.idr` itself, which deliberately knows nothing about this):
   arity 0 additionally wraps the call in `idris2rc2_applyClosure(...,
   idris2rc2_freshWorld())` -- the same general-purpose runtime
   function *every* other under-applied closure in the entire program
   is always fed through, exactly what whole-program mode's own
   `PrimIO.unsafeCreateWorld` body (`apply v0 v1`) already does for
   this identical reason; arity >=1 keeps the direct call from before
   (already correct -- the `%World` token there is a real, typed C
   parameter, so a direct call already does the equivalent `apply` for
   free). Verified against both shapes afterward, not just re-tested
   against the one that broke.
5. **Two more cross-linking hazards, found linking a real multi-module
   program** (a small program using `Data.List`/`Data.SortedMap`,
   deliberately not just a bare `putStrLn` -- `base`'s own 136-module
   clean rebuild only proves each module compiles standalone, not that
   several of them link and run correctly together):
   - **Whole-`.o` linking defeats gap #3's own "drop it, fail at link
     time" mechanism.** `compileExprInc`'s own final link step listed
     every accumulated `.o` directly on the linker command line --
     but a bare `.o` named that way is *always* linked in whole,
     unlike an archive member (only pulled in if something still-
     unresolved actually needs a symbol it provides). Since `base`'s
     own `Prelude.IO.threadWait` (calling the deliberately-dropped
     `prim__threadWait`) lives in the very same `.o` as `putStrLn`
     itself, any program calling `putStrLn` -- i.e. every program --
     pulled in `threadWait`'s own dangling reference too, regardless of
     whether it ever called `threadWait`. Fixed with a new
     `CC.archiveObjectFiles` (`ar rcs`) bundling every accumulated
     `.o` into one static archive before linking, restoring real
     per-module selection.
   - **Same problem, one level finer.** Archiving alone wasn't enough:
     `putStrLn` and `threadWait` are both *in the same module*
     (`Prelude.IO`), so needing one still drags in the whole `.o`
     (hence the other) regardless of per-*file* archive selection.
     Fixed with `-ffunction-sections -fdata-sections` at compile time
     plus `-Wl,--gc-sections` at link time (`CC.idr`, unconditional,
     both modes -- pure dead-code stripping, never changes behavior),
     letting the linker discard individual unused functions at
     *section*, not whole-object-file, granularity.
   - **A name-freshening counter that assumed whole-program
     uniqueness.** `Compiler.RC2.MutualLoop`'s own synthesized
     dispatcher names (`MN "rc2_mutualLoop" i`) number `i` from a
     fresh-per-compile counter -- globally unique in whole-program
     mode (one shared counter), but *not* across separate incremental
     compiles, each restarting its own counter at 0. `multiple
     definition of rc2_mutualLoop_0` linking `Data.List`/
     `Data.SortedMap.Dependent`/`Prelude.Types` together (three
     unrelated modules that each happened to need one). Fixed by
     making `fnSignature` emit `static` for any name
     `isMutualLoopMerged` recognizes (`Compiler.RC2.Util`, already
     used elsewhere to exclude these from other passes) -- safe
     unconditionally, since this dispatcher is never meant to be
     referenced from outside its own generated `.c` in the first
     place, whole-program or incremental.

## Deferred: cross-module constant sharing

The TODO.md note this document replaces also raised: since each module
now stages its own copy of any constant it needs (constant dedup is
inherently module-scoped once translation units split), could a
constant's own C symbol name be derived deterministically from its
*value* (e.g. a content hash) and declared `__attribute__((weak))`
instead of `static`, so the linker collapses byte-identical copies
emitted by separate modules back into one at link time? This is a real
technique (weak-symbol merging) and doesn't affect correctness either
way (only static's memory duplication) -- worth a follow-up, but out of
scope for the first working version of this feature: it needs the
generated initializer text to be provably byte-identical for any two
occurrences of the same source value across modules (field emission
order, float formatting, etc.), which the current sequential-counter
naming (`constcon_0`, `constcon_1`, ...) doesn't need to guarantee
today.

## Known gaps for v1 (not blocking, but not solved by this design)

- `%export`ed wrapper generation (`RC2.idr`'s `validateExport`/
  `emitExportWrapper` path) isn't addressed here -- needs its own look
  at whether an exported name's wrapper can be emitted per-module
  (likely yes, it only needs that one name's own signature) before
  incremental mode supports library-target builds, not just
  executables.
- `%cg rc2 extraRuntime=<path>`/`inlineRuntime=<code>` directives
  (`rc2/doc/directives.md`) splice raw C into the single whole-program
  file today; which module(s) should receive them in per-module mode
  (every module needing external linkage vs. duplicated-and-`static`)
  isn't decided yet.
- Not yet tested: a dependency package that itself ships incrementally-
  compiled rc2 object files (upstream's own generic `allIncData`/
  `installFrom` machinery should handle this transparently, but rc2
  hasn't exercised that path) -- see the "practical prerequisite"
  section above: `prelude`/`base`/`contrib`/`network` all need this
  before any real program can benefit, and nothing does it yet.

## Verification: done, both steps

Every Idris program implicitly imports `prelude` (`addPrelude`,
`Idris.ProcessIdr.processMod`) -- there is no such thing as a "no
dependencies" fixture, so a genuine end-to-end incremental round trip
was blocked on the prelude/base/linear/contrib/network rebuild above
until that rebuild actually succeeded. Both steps below are now done,
not just planned:

1. **Graceful fallback, before the bootstrap existed.** Confirmed
   early on, before any of the standard packages had rc2 incData yet:
   building an ordinary rc2 test with `--cg rc2 --inc rc2` silently,
   correctly fell back to whole-program compilation (`missingIncremental`
   tripping on `prelude`'s own missing incData, same as the design
   predicted) -- no crash, no silently-half-skipped build.
2. **Real incremental round trip, after the bootstrap.** With
   `prelude`/`base`/`linear`/`contrib`/`network` all rebuilt clean
   (272 modules, zero missing incData -- "End-to-end verification"
   above), two throwaway programs (`Hello.idr`, a bare `putStrLn`; and
   a second one using `Data.List.sort`/`Data.SortedMap`) both built
   with `--cg rc2 --inc rc2` and ran with correct output, and editing
   `Hello.idr`'s own message and rebuilding only recompiled `Hello`
   itself (no reprocessing of `prelude`/`base` visible in the output --
   `missingIncremental`'s own `sourceUnchanged && ... && incrementalOK`
   skip, working as designed) before relinking.

`rc2/tests/verify.sh` stayed at its usual 111/0/0 whole-program
baseline throughout every fix above -- none of the incremental-only
code paths are reachable without `--inc rc2`.
