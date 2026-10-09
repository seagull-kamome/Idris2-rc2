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
| `$$` | a literal `$` |

A trailing `%World` of an `IO`/`PrimIO` type is not an argument and does
not count. An unused argument is allowed, and the same `$N` may appear
several times (the argument's marshalled expression is simply repeated;
it is a read, or a pure computation, so it is not evaluated for effect).
`$0`, `$N` beyond the argument count and a `$` followed by neither a
digit nor `$` are compile errors naming the declaration.

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

## Limits

- `Integer` arguments and results are rejected at compile time. rc2
  passes an `Integer` result as a leading GMP out-parameter of a callee,
  and an expression has no callee. Use `"C:"` with a function for
  those.
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
