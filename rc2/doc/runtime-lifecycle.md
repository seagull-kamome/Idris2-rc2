# Runtime lifecycle hooks (`idris2rc2_rtInit` / `idris2rc2_rtFinish`)

## What they are

`support/rc2/runtime.c` defines two no-argument functions:

```c
void idris2rc2_rtInit(void);    // called first thing in main()
void idris2rc2_rtFinish(void);  // called after the entry point returns
```

`Compiler.RC2.Emit`'s generated `main()` (its `footer`, in
`generateCSourceFile`) now brackets the whole run with them:

```c
int main(int argc, char *argv[])
{
    idris2rc2_rtInit();
    idris2_setArgs(argc, argv);           // as before, when linked
    IDRIS2RC2_Value *mainExprVal = __mainExpression_0();
    idris2rc2_trampoline(mainExprVal);
    idris2rc2_rtFinish();
    return 0;
}
```

Upstream RefC's generated `main()` (`idris2-src/src/Compiler/RefC/
RefC.idr`) has no equivalent -- this is an rc2-only addition, listed
under "Deliberate differences from upstream RefC" in the top-level
`README.md`.

## Why `rtInit` exists: `setlocale`

A C program starts in the `"C"` locale no matter what `LC_ALL` / `LANG`
/ `LC_CTYPE` say in the environment -- the environment is consulted
only when the program calls `setlocale(LC_*, "")`. rc2 never did, so
every rc2-compiled program ran in the `"C"` locale, and libc's
locale-sensitive machinery behaved accordingly. The one that matters in
practice is `<regex.h>` (`libs/rc2base`'s `Text.Regex.POSIX`): in the
`"C"` locale `regcomp`/`regexec` work **byte-wise** -- `.` matches one
byte, `[[:alpha:]]` and case-insensitive matching are ASCII-only -- so
a multi-byte UTF-8 subject is mis-analysed. With a UTF-8 `LC_CTYPE`,
glibc's regex engine switches to its multibyte path: `.` matches a
whole codepoint, character classes use the wide-character predicates.
(Match offsets stay **byte** offsets regardless of locale, so
`Data.String.RC2.unsafeStringByteSlice` -- which is what
`Text.Regex.POSIX` cuts spans with -- is unaffected and still correct.)

`idris2rc2_rtInit` therefore runs:

```c
setlocale(LC_ALL, "");        // adopt the environment's locale
setlocale(LC_NUMERIC, "C");   // ...but keep number formatting fixed
```

The `LC_NUMERIC` pin is because `support/rc2/numeric.c` formats
`Double` via `sprintf(buf, "%f", v)`, which *is* `LC_NUMERIC`-sensitive:
without the pin, `LANG=de_DE.UTF-8` would make `show (3.14 : Double)`
produce `"3,140000"`. Pinning it keeps `Double`'s textual form stable
across every environment. (TODO: give `numeric.c` a locale-independent
double-to-string path, then drop the pin so a program that *wants*
localised number formatting can opt into it.)

## The UTF-8-compatible-locale requirement (important)

rc2's `String` layer decodes **every** incoming C byte sequence as
UTF-8 (`support/rc2/idris2rc2_strings.c` + `utf8.c`; malformed bytes
become U+FFFD). Before this change that was academic for
locale-derived strings, because the `"C"` locale only ever produced
ASCII (a subset of UTF-8). Now that `rtInit` adopts the *environment's*
locale, any locale-sensitive libc output flows through the
environment's charset:

- `regexec` interprets the subject in `LC_CTYPE`'s charset;
- `strftime` / `nl_langinfo` produce localised text (month/day names)
  in `LC_CTYPE`'s charset;
- `strerror` / `gai_strerror` / `strsignal` are localised via
  `LC_MESSAGES`.

If the environment locale's charset is **not** UTF-8-compatible, those
bytes reach Idris `String` as malformed UTF-8 and decode to U+FFFD.
Non-UTF-8 multibyte locales (`ja_JP.eucJP`, `zh_CN.gb18030`,
`zh_CN.gbk`) and 8-bit locales (`de_DE.iso88591`, `ru_RU.koi8r`) all
break this way. Plain `C` / `POSIX` are fine (ASCII). **Run
rc2-compiled programs under a `*.UTF-8` locale (or `C` / `C.UTF-8`).**
This is a runtime constraint rc2 cannot enforce -- it is documented in
the top-level `README.md` and `libs/rc2base/doc/regex-posix.md`.

## Why `rtFinish` exists

`fflush(NULL)` -- flush every open stdio stream. A normal `return` from
`main()` already flushes on exit, so today this is belt-and-braces; it
matters for a future teardown path that exits less gently, or a hook
added here later.

## `--directive nomain`

A `nomain` build (`doc/export-support.md`, "Linking as a library")
emits **no** `main()` -- the hand-written C driver that links the
`%export`ed program supplies its own. That driver is responsible for
calling `idris2rc2_rtInit()` before the first exported call and
`idris2rc2_rtFinish()` before it exits; nothing calls them for it.

## Files

- `rc2/support/rc2/runtime.c` -- `idris2rc2_rtInit` / `idris2rc2_rtFinish`
  definitions.
- `rc2/support/rc2/runtime.h` -- their declarations (already reached by
  generated C via the `idris2rc2_runtime.h` umbrella).
- `rc2/src/Compiler/RC2/Emit.idr` -- `generateCSourceFile`'s `footer`,
  which emits the two calls.
- `rc2/tests/Test82RuntimeLocale/` -- reads `LC_CTYPE` / `LC_NUMERIC`
  back to prove both `setlocale` calls ran (`verify.sh` runs the suite
  under `LC_ALL=C.UTF-8`).
