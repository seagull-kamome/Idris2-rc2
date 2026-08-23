module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for `%cg rc2 inlineRuntime=<code>` (Compiler.RC2.RC2):
-- like `%cg rc2 extraRuntime=<path>` (Test31CgExtraRuntime), but the C
-- text is written directly in the directive's own value instead of
-- read from a file. MUST stay on one line -- see getInlineRuntime's
-- own doc comment (RC2.idr) and the README's "%cg rc2 directives"
-- section for why (Idris2's own `%cg { ... }` braced form can't
-- survive a literal `}` inside it, so this instead relies on the
-- lexer's unrestricted "rest of the line" fallback, which only
-- triggers because `inlineRuntime=` doesn't start with `{`).
--
-- Also MUST NOT end with a literal `}` (after trimming): the parser's
-- own `stripBraces` (Idris/Parser.idr) unconditionally strips a
-- trailing `}` from a %cg directive's captured text, regardless of
-- which lexer alternative produced it -- it can't tell "this closing
-- brace was a real, load-bearing part of the payload" (any C function
-- body) from "this closing brace was the %cg { ... } form's own
-- delimiter". A harmless trailing `;` (an empty top-level C
-- declaration) after the function's own `}` keeps it from being the
-- last character, so it survives untouched.

%cg rc2 inlineRuntime=int64_t idris2rc2_test32_inline_triple(int64_t x) { return x * 3; };

%foreign "C:idris2rc2_test32_inline_triple"
prim__inlineTriple : Int -> PrimIO Int

main : IO ()
main = printLn !(primIO (prim__inlineTriple 7))
