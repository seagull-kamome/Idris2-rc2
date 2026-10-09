# `CExpr:` -- a C expression as a `%foreign` target

`"CExpr:<expression>,<lib>,<header>"` binds a declaration to a C
expression or constant instead of a function name, so a macro, a
constant or a one-line expression needs no C shim.

```idris
%foreign "CExpr:O_CREAT,libc,fcntl.h"
prim__oCreat : Int32

%foreign "CExpr:abs($1),libc,stdlib.h"
prim__abs : Int32 -> Int32

%foreign "CExpr:(($1) > ($2) ? ($1) : ($2))"
prim__max : Int -> Int -> Int

%foreign "CExpr:srand($1),libc,stdlib.h"
prim__srand : Bits32 -> PrimIO ()

%foreign "CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"
prim__integerAdd : Integer -> Integer -> Integer
```

Implementation: `Compiler.RC2.ForeignSpec` (parsing and checking),
`Compiler.RC2.Emit.Foreign` (`ffiRawCall`, `emitGenericForeignWrapper`).
Tests: `rc2/tests/Test118FFI/FFICExpr.idr`, its `check.sh` and
`CExprErrors/`, and `rc2/tests/Test119FFINoRefc/CExprPriority.idr`.

## Options

The text after `CExpr:` is split at top-level commas. The first option
is the expression template. The second is the library and the third the
header file, exactly as for `"C:"`: the header is `#include`d and the
library linked (`libfoo` becomes `-lfoo`). Both are optional.

The header field may name several headers separated by `;`, e.g.
`"CExpr:O_CREAT|S_IRUSR,libc,fcntl.h;sys/stat.h"`. Each name is trimmed,
empty pieces (a trailing `;`) are ignored, and every distinct name becomes
one `#include <...>` line. Names are compared exactly (case-sensitive, no
path normalisation: `a.h` and `./a.h` are different), so a header repeated
within a field, or named by several declarations (alone or in lists, under
any tag), is included once. A name containing whitespace, `<`, `>` or `"` is
a compile error. The `;` is special only in this field: in the expression
it is ordinary C text (`({ a; b; })`) and in the library field it is
unchanged; only top-level commas separate options.

Compatibility: upstream and RefC read the header field as ONE name, so a
declaration that must also compile on RefC keeps a single header in its
`"C:"` alternative and uses `CExpr:`/`RC2:` (which RefC ignores) for the
multi-header form.

Include order: the includes are emitted in alphabetical order of the
header names (not first-occurrence order), after `idris2rc2_runtime.h`.
Headers should therefore be self-contained; a header that needs another to
be included before it must include that one itself.

Splitting respects nesting of `()`, `[]` and `{}` and C string and
character literals (with backslash escapes), so commas inside a macro
call, a string literal or a character literal do not split. Options are
trimmed. Unbalanced brackets and unterminated literals are compile
errors. The split applies to every tag rc2 accepts (`CExpr:`, `RC2:`,
`RefC:`, `C:`), replacing upstream's comma-only `parseCC`. `C:`, `RefC:` and `RC2:` strings parse as before (no existing one
contains brackets or quotes), and only the chosen string of a
declaration is examined. A `:` after the first one (as in
`?:`) is part of the expression.

## Placeholders

| text | meaning |
|---|---|
| `$1`, `$2`, ... `$10` | the declaration's arguments, 1-based, any number of digits |
| `$r` | the `Integer` result's out-parameter (an `mpz_t`), see "Integer results and arguments" |
| `$$` | a literal `$` |

A trailing `%World` of an `IO`/`PrimIO` type is not an argument and does
not count. An unused argument is allowed, and the same `$N` may appear
several times (the argument's marshalled expression is simply repeated;
it is a read, or a pure computation, so it is not evaluated for effect).
`$0`, `$N` beyond the argument count and a `$` followed by none of a
digit, `r` or `$` are compile errors naming the declaration. (`$r` is
taken greedily: `$result` is `$r` followed by `esult`.)

Placeholders are replaced textually, also inside string literals in the
template.

## Parenthesisation

Each placeholder is replaced by the already-marshalled argument
expression wrapped in parentheses (`$1` becomes `(v123)` or
`((idris2rc2_to_i32(v123)))`), so an argument can never change the
precedence of the expression it is substituted into. The whole
expression is emitted in parentheses when it is used as a value, and as
a bare statement (`expr;`) for a `PrimIO ()` declaration.

## Results and types

Arguments are marshalled by their Idris types and the result is packed
(or kept native, in a dual-ABI worker) exactly like the result of a
`"C:"` call: `Int32` narrows, `String` becomes `const char *`, `Ptr`
types are `void *`, `Char` is `char`. `CFBuffer` arguments are unwrapped
to the flat data pointer, like `"C:"`.

The expression must produce a value of the C type the Idris type maps to
(`PrimIO ()` may be any expression).

No prototype is emitted for a `CExpr:` declaration; the header option is
the only way to make macros and functions visible.

## Integer results and arguments

An `Integer` result is a GMP out-parameter, not a C return value. Where
`"C:"` prepends the out-parameter to the argument list of a function,
`CExpr:` has no call to prepend it to, so the template places it with
`$r`, valid only when the result type is `Integer` or `PrimIO Integer`:

```idris
%foreign "CExpr:mpz_add($r, $1, $2),libgmp,gmp.h"
prim__add : Integer -> Integer -> Integer

%foreign "CExpr:mpz_set_si($r, (long)($1)),libgmp,gmp.h"
prim__fromInt : Int -> Integer

%foreign "CExpr:mpz_pow_ui($r, $1, (unsigned long)($2)),libgmp,gmp.h"
prim__pow : Integer -> Int -> Integer
```

rc2 allocates a fresh `IDRIS2RC2_Integer` first, replaces each `$r` by
its `mpz_t` member (`retVar->v`), emits the expression as a bare
statement (its value, if any, is discarded) and returns the allocated
Integer, normalised to an immediate when it fits, exactly as for `"C:"`.
`$r` may appear any number of times and anywhere in the template (for
example `(mpz_set_si($r, 3), mpz_mul($r, $1, $r))`). It is *not*
wrapped in parentheses like `$N`: `retVar->v` is a postfix expression, so
its context cannot change its meaning, and it stays an array for
`sizeof` and for the decay to `mpz_ptr` at a call. There is only this one
out-parameter; a function with two (`mpz_tdiv_qr`) needs a shim.

An `Integer` argument `$N` is the argument's `mpz_t` (an
`mpz_ptr`, immediates included) exactly as for `"C:"`, parenthesised like
every placeholder. The callee must only read it.

An `Integer` result without `$r`, and `$r` in a declaration whose result is
not an `Integer`, are compile errors. A GMP function that returns a value
(`mpz_get_si`, `mpz_sgn`, `mpz_cmp`) is declared with the matching result
type and takes `Integer` arguments; wrap it in Idris to build an
`Integer`:

```idris
%foreign "CExpr:mpz_sgn($1),libgmp,gmp.h"
prim__sgn : Integer -> Int
```

rc2 never converts such a value into an `Integer` for you.

## Limits

- Other backends ignore `CExpr:`. A declaration that must also build
  with another backend carries that backend's own tag as well:

  ```idris
  %foreign "CExpr:abs($1),libc,stdlib.h"
           "C:abs,libc,stdlib.h"
           "scheme:abs"
  ```

## Priority

`CExpr:` is looked up first, before `RC2:`, `RefC:` and `C:`, whatever
the order of the strings in the declaration.
