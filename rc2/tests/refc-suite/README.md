# RefC regression-suite port

The tests in this directory are ported from upstream Idris2's own RefC
regression suite (`idris2-src/tests/refc/*`), so that rc2 gets checked
against the same real-world programs RefC is checked against, not just
rc2's own hand-written smoke tests (`rc2/tests/*.idr`).

Run with:

```
source ../../../env.sh
nix-shell -p gcc gmp pkg-config --run './run.sh'
```

## Ported (17)

Each subdirectory holds the original `.idr` source (unmodified unless
noted below) plus an `expected` file. Most `expected` files are the
upstream RefC ones, verbatim -- rc2 is expected to produce byte-identical
output to RefC for ordinary programs, and `run.sh` diffs against it.

- `args`, `basicpatternmatch`, `doubles`, `garbageCollect`, `integers`,
  `issue1778`, `issue2424`, `issue2452`, `piTypecase001`, `prims`,
  `refc001`, `refc002`, `refc003`, `reg001`, `strings`, `wasm32cmp001`,
  `reuse`.

Two of these needed their `expected` adjusted for reasons that aren't rc2
bugs:

- **`prims`**: `printLn codegen` prints the backend name (`"refc"` vs.
  `"rc2"`) -- adjusted accordingly.
- **`basicpatternmatch`**: three of upstream's expected lines
  (`Bits32 0x80000000`, `Int64` min/max literal matches) encode a *known
  RefC bug*, explicitly flagged in the test source itself with `-- FIXME:
  wont work` comments -- RefC fails to match these boundary-value
  constant-case literals and falls through to the catch-all branch. rc2
  does not have this bug (verified by direct C-code inspection: the fix
  was making `RConstCase`'s "integer switch" fast path use a
  type-specific signed/unsigned extraction instead of a single ambiguous
  one -- see `Emit.idr`'s `extractIntExpr`), so its `expected` reflects
  the *correct* result instead of reproducing RefC's bug.

- **`reuse`**: only the functional part (the two `treePrint` traversals)
  is ported. Upstream's `expected` also greps the *generated RefC C
  source* for the shape of RefC's specific constructor-reuse-in-place
  codegen (`awk -v RS= '/Value \*Main_insert/'`) -- meaningless for rc2,
  whose generated C has an entirely different shape even though it
  implements the same optimization (see `Emit.idr`'s
  `addReuseConstructor`/reuse-map machinery). Dropped rather than adapted.

## Skipped (4) -- with reasons

- **`buffer`**: exercises `Data.Buffer`, whose "RefC"-tagged
  `%foreign`/`%transform` FFI path is explicitly out of scope for rc2 (see
  the project plan's scope notes) -- not implemented, not ported.
- **`clock`**: same reasoning, for `System.Clock`.
- **`ccompilerArgs`**: verifies RefC's `CC.idr` correctly parses/passes
  `CFLAGS`/`LDFLAGS`/`LDLIBS` env vars through to the C compiler
  invocation, using a companion C library it builds and links against.
  rc2's own `CC.idr` (`Compiler/RC2/CC.idr`) has equivalent flag-handling
  logic, but porting this test faithfully (its own `library/` C project,
  env var wiring) was judged out of proportion to the rest of this
  port; left as a documented gap rather than done half-way.
- **`callingConvention`**: `awk`-inspects the *shape* of RefC's own
  generated C (specific function names/argument-passing patterns
  RefC's own borrow/ownership algorithm produces) -- not meaningful for
  rc2, whose codegen (own ANF-normalisation, explicit RDup/RDrop/RFree
  primitives, native-type inference) produces structurally different C by
  design. There is no equivalent "shape" to assert without writing a
  whole new rc2-specific test from scratch, which is future work, not a
  port.

## Bugs found and fixed while porting

Porting real (not hand-written) programs surfaced several bugs no prior
test in `rc2/tests/` happened to exercise:

1. **Missing `idris2rc2_constr_<PrimType>` declarations.** Idris2's
   "typecase" feature (pattern-matching a `Type` value against `Int`,
   `Bits16`, `(_ -> _)`, etc. -- see `piTypecase001`,
   `basicpatternmatch`) compiles to an untagged constructor
   match/build with *no backing top-level definition anywhere in the
   program* (`Compiler.CompileExpr.toCExpTm`'s `Ref fc (TyCon arity) fn`
   and `Bind fc x (Pi ...) sc` cases synthesize a bare `CCon` on the
   fly). RefC itself special-cases this by predeclaring the fixed set of
   primitive-type name strings directly in its runtime
   (`support/refc/prim.c`), not by discovering them via the usual
   per-program definition pass. rc2 didn't -- fixed by adding the
   equivalent fixed set of `idris2rc2_constr_*` strings to
   `support/rc2/runtime.c`/`.h`.
2. **`refc_fork` unimplemented.** `Prelude.IO.prim__fork` is declared
   with a bare `%foreign "C:refc_fork"` (not gated behind the
   `RC2`/`RefC`/`C` tag-reuse mechanism at all -- every C backend is
   expected to just provide a matching symbol). RefC's own
   implementation is itself an unimplemented stub (prints a message,
   exits) -- true OS-thread support was never added there either. Added
   a matching stub to `support/rc2/ioprims.c`/`.h` for parity.
3. **`stringIteratorToString`'s 4th parameter had the wrong pointer
   type** (`IDRIS2RC2_Value *` instead of `IDRIS2RC2_Closure *`,
   mismatching what Emit.idr's FFI codegen actually casts a `CFFun`
   argument to) -- a strict-pointer-type compile error under
   `-Wincompatible-pointer-types`. Fixed the declared type in
   `idris2rc2_strings.h`/`.c`.
4. **Sign confusion in `RConstCase`'s "integer switch" fast path.**
   `idris2rc2_extractInt`'s generic unboxed-value extraction always
   zero-extends (correct for `Bits8`/`16`/`32`/`Char`, but wrong for
   negative `Int8`/`Int16`/`Int32` literals -- e.g. `-128` extracted as
   `128`, so `case x of -128 => ...` never matched). Fixed by dispatching
   to the already-existing type-specific signed accessors
   (`idris2rc2_to_i8`/`i16`/`i32`) for those three types specifically
   (`Emit.idr`'s new `extractIntExpr`), matching what the native-unboxing
   path already did correctly.
5. **`escapeChar`'s C-literal rendering for non-printable/non-alphanumeric
   chars routed through an intermediate `(char)` cast** (`"(char)" ++
   show (ord c)`). `char` is signed on this platform, so any codepoint
   above 127 (e.g. `'\x9f'` = 159) got reinterpreted as negative by that
   cast, then sign-extended again at the call site -- 159 became
   4294967199 end-to-end. Fixed by dropping the cast entirely (a bare
   decimal literal is valid, unambiguous C in every context this is used
   from).
6. **`Bits64` (and `Bits8`/`16`/`32`) → `Integer` cast used `mpz_set_si`
   (signed)** on the unsigned C value, so `Bits64` values `>= 2^63`
   (e.g. `UINT64_MAX`) got reinterpreted as negative before GMP ever saw
   them (`18446744073709551615` became `-1`). Fixed by splitting
   `numeric.c`'s `IDRIS2RC2_CAST_TO_INTEGER` macro into signed
   (`mpz_set_si`) and unsigned (`mpz_set_ui`) variants, applied to the
   right types.

All fixes verified against upstream RefC's actual output (not just
against what the code "should" do in the abstract) by compiling and
running each test with both backends and diffing.
