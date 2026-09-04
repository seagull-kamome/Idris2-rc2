module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Compiler.RC2.DeadCode's own RCLocal-aware fix
-- (`usedFunctionNamesL`, see DeadCode.idr's own doc comment): once
-- Compiler.RC2.ConstFold folds an interface-dictionary-shaped `RCon`
-- (every field a zero-filled `RUnderApp` closure) into a single
-- `RCConstCon`, each field's own target function `Name` becomes
-- invisible to a walker that only inspects `RCExp` nodes -- if
-- `usedFunctionNamesR` doesn't also look *inside* every `RCLocal` it
-- sees, `Compiler.RC2.DeadCode.pruneDeadDefs` incorrectly treats a
-- definition reachable *only* through a folded dictionary field as
-- dead code and drops it, even though the immortal static literal
-- `Compiler.RC2.EmitUtil` generates for that field still names it by
-- symbol.
--
-- `secret`'s own implementation (`onlyReachableViaDict`) is never
-- called or referenced anywhere in this program except as the third
-- field of the folded `Greeter Dog` dictionary -- `main` only ever
-- calls `greet`/`loud` (via `useGreeter`), never `secret`. Its own
-- survival therefore depends entirely on `DeadCode.idr` correctly
-- tracing into the folded constant; `onlyReachableHelper` (called only
-- from `onlyReachableViaDict`'s own body) is a second link in that same
-- chain, confirming the trace isn't limited to one hop.
--
-- EXPECTED TO FAIL (a build error, not a silent pass) if the
-- `DeadCode.idr` fix (`usedFunctionNamesL`, plus the exhaustive
-- `usedFunctionNamesR` rewrite that calls it on every `RCLocal`-typed
-- field) is missing or incomplete. Verified by hand while implementing
-- this test: temporarily neutering `usedFunctionNamesL` back to
-- `const empty` and rebuilding reproduces a real C compile error --
-- `error: '...' undeclared here (not in a function)` inside a
-- `constclosure_N` static initializer, since the pruned function's own
-- C definition (and even its forward declaration) is entirely absent
-- from the generated `.c` -- a compile-stage failure rather than a
-- link-stage "undefined reference" specifically because a static
-- initializer's address-of is checked by the C compiler itself, not
-- deferred to the linker the way an ordinary call site's reference
-- would be. Restoring the fix builds and passes again. (Also
-- confirmed the same reverted build breaks EVERY rc2 program, not just
-- this one -- `{__mainExpression:0}`'s own entry-point continuation is
-- itself a zero-filled `RUnderApp` closure and folds via this exact
-- mechanism regardless of interfaces, so the gap this test targets is
-- strictly narrower here than the general breakage without the fix.)

interface Greeter a where
  greet : a -> String
  loud : a -> String
  secret : a -> String

data Dog = MkDog

onlyReachableHelper : String -> String
onlyReachableHelper s = s ++ "!"

onlyReachableViaDict : Dog -> String
onlyReachableViaDict MkDog = onlyReachableHelper "shh"

Greeter Dog where
  greet MkDog = "woof"
  loud MkDog = "WOOF!!"
  secret = onlyReachableViaDict

useGreeter : Greeter a => a -> String
useGreeter x = greet x ++ " / " ++ loud x

main : IO ()
main = putStrLn (useGreeter MkDog)
