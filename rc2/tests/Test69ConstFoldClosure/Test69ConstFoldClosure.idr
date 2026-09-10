module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Merged regression suite for Compiler.RC2.ConstFold's closure- and
-- CAF-folding (RCConstClosure / whole-program CafTable / RConCase
-- scrutinee fold). Eight formerly separate tests, one section each,
-- every original doc comment kept verbatim. `main` runs all sections
-- in order; the saved .expected is their concatenation.
--
--   1  interface-dictionary structural fold  (was Test69ConstFoldClosureDict)
--   2  DeadCode survival through folded field (was Test71ConstFoldClosureDeadCodeSurvival)
--   3  let-bound closure-alias fold          (was Test72ConstFoldClosureAliasFold)
--   4  folded closure in call-arg position   (was Test73ConstFoldClosureCallArg)
--   5  closure-shaped CAF across a boundary  (was Test74ConstFoldCafBoundaryClosure)
--   6  RConCase scrutinee fold               (was Test75ConstFoldConCaseScrutinee)
--   7  mutually-referencing CAF fixpoint cap (was Test76ConstFoldMutualCafSafety)
--   8  CAF alias-chain iteration off-by-one  (was Test77ConstFoldCafChainCap)
--   9  bare point-free (CSE-hoisted) CAF     (was Test78ConstFoldBareClosureAliasCaf)
--
-- The loop/valgrind companion (dispatch through a folded dictionary
-- hundreds of times under valgrind) stays its own test,
-- Test70ConstFoldClosureCallthrough.

import System
import Decidable.Equality

-- ============================================================
-- Section 1: interface-dictionary structural fold
--            (was Test69ConstFoldClosureDict)
-- ============================================================
-- A literal, zero-args `RUnderApp` -- a bare reference to a named
-- top-level function, no captured values -- folds into a constant leaf
-- the same way `RCConstCon` already folded a fully-constant
-- constructor. `Greeter Dog`'s own instance dictionary is exactly the
-- shape this exists for: a 3-field record whose every field is a
-- zero-filled closure over one of the three method implementations
-- below (`greet_Dog`/`loud_Dog`/`cnt_Dog`, Idris2's own generated
-- names) -- since `isConstLocalProof` now recognises each of those as
-- `RCConstClosure`, ConstFold's existing `RCon`-folding logic
-- (unmodified -- see ConstFold.idr's own module note) folds the
-- *whole* dictionary into a single immortal `RCConstCon`, with no code
-- of its own having to know anything about interfaces specifically.
--
-- Confirmed by hand via `--directive dumprcexpr`: `Main.main`'s own
-- dump shows the dictionary passed to `Main.useGreeter` as a single
-- folded literal -- `#Main.Greeter@Just 0([#Main.{main:0}/1~closure,
-- #Main.{main:1}/1~closure, #Main.{main:2}/1~closure])` -- never a
-- `RCon`/`RUnderApp` chain. The generated `.c` confirms this isn't
-- just a pretty-printer artifact: `Main_main`'s own C function body has
-- no `idris2rc2_mkClosure(` call anywhere building the dictionary or
-- any of its three fields, only three `constclosure_N` file-scope
-- statics referenced from a single `constcon_N` static -- both staged
-- once, at file scope, and simply addressed by `Main_main`, never
-- rebuilt.

interface Greeter a where
  greet : a -> String
  loud : a -> String
  cnt : a -> Int

data Dog = MkDog

Greeter Dog where
  greet MkDog = "woof"
  loud MkDog = "WOOF!!"
  cnt MkDog = 1

-- Genuinely polymorphic over `a` -- the `Greeter a` dictionary is
-- passed as a real runtime value and each method is projected out of
-- it at runtime (`case`-destructure + `apply`), never specialised away
-- per instantiation. This is what forces the instance dictionary
-- itself to exist as a real constant value in the first place.
useGreeter : Greeter a => a -> String
useGreeter x = greet x ++ " / " ++ loud x ++ " x" ++ show (cnt x)

-- ============================================================
-- Section 2: DeadCode survival through a folded dictionary field
--            (was Test71ConstFoldClosureDeadCodeSurvival)
-- ============================================================
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
-- `secretG`'s own implementation (`onlyReachableViaDict`) is never
-- called or referenced anywhere in this program except as the third
-- field of the folded `Greeter71 Dog71` dictionary -- `main` only ever
-- calls `greet71`/`loud71` (via `useGreeter71`), never `secretG`. Its
-- own survival therefore depends entirely on `DeadCode.idr` correctly
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
-- would be. (Also confirmed the same reverted build breaks EVERY rc2
-- program, not just this one -- `{__mainExpression:0}`'s own
-- entry-point continuation is itself a zero-filled `RUnderApp` closure
-- and folds via this exact mechanism regardless of interfaces, so the
-- gap this section targets is strictly narrower here than the general
-- breakage without the fix.)

interface Greeter71 a where
  greet71 : a -> String
  loud71 : a -> String
  secretG : a -> String

data Dog71 = MkDog71

onlyReachableHelper : String -> String
onlyReachableHelper s = s ++ "!"

onlyReachableViaDict : Dog71 -> String
onlyReachableViaDict MkDog71 = onlyReachableHelper "shh"

Greeter71 Dog71 where
  greet71 MkDog71 = "woof"
  loud71 MkDog71 = "WOOF!!"
  secretG = onlyReachableViaDict

useGreeter71 : Greeter71 a => a -> String
useGreeter71 x = greet71 x ++ " / " ++ loud71 x

-- ============================================================
-- Section 3: let-bound closure-alias fold
--            (was Test72ConstFoldClosureAliasFold)
-- ============================================================
-- Regression test for the `RV _ (RCConstClosure {})` arm added to
-- Compiler.RC2.ConstFold's `RLet` value-classification (mirroring the
-- pre-existing `RCConstCon` arm right above it): a `let`-bound alias
-- of an already-folded closure constant (`let b = a`) must itself
-- re-enter `env` as the same constant, not just resolve `a`'s own
-- uses -- otherwise a later constructor built from `b` (rather than
-- `a` directly) never reaches the `RCConstCon` fold at all.
--
-- Getting a genuine, surviving `let b = a` (a plain local-to-local
-- alias) into rc2's own IR is the hard part: Idris2's own frontend
-- eagerly collapses that exact shape (confirmed by hand via
-- `--directive dumplifted`). `mkAlias` below is marked `%noinline`
-- specifically to survive as a real call in the *Lifted* IR --
-- `Compiler.RC2.Inline` (rc2's own, separate, Lifted-level inliner,
-- which does not honour `%noinline` since that flag is upstream's
-- `Compiler.Inline` concept) then splices `mkAlias`'s body (bare
-- parameter passthrough) into the call site, turning `b`'s own value
-- into exactly `RV fc (RCLoc a)` before ConstFold ever runs -- which
-- folds through `env` into `RV fc (RCConstClosure ...)`, landing
-- precisely on the new arm.
--
-- Confirmed structurally: without the new arm, `dict`'s own
-- construction (`MkDict a b`) stays a genuine `RCon` -- the generated
-- `.c` has a real `idris2rc2_newConstructor(2, 1)` call inside
-- `Main_main`. With the arm, `dict` folds into a single immortal
-- `RCConstCon` (a `constcon_N` static whose two fields both directly
-- reference the *same* `constclosure_N` static) and `Main_main`
-- contains no constructor-allocating call at all.

greetFn : String -> String
greetFn s = "hello " ++ s ++ "!"

record Dict where
  constructor MkDict
  fnA : String -> String
  fnB : String -> String

useDict : Dict -> String -> String
useDict d s = fnA d s ++ " / " ++ fnB d s

%noinline
mkAlias : (String -> String) -> (String -> String)
mkAlias f = f

sectionAliasFold : String
sectionAliasFold =
  let a = greetFn
      b = mkAlias a
      dict = MkDict a b
  in useDict dict "world"

-- ============================================================
-- Section 4: folded closure in a call-argument position
--            (was Test73ConstFoldClosureCallArg)
-- ============================================================
-- Regression test for `Compiler.RC2.ConstFold`'s `RCConstClosure`
-- folding (rc2/doc/const-closure-fold.md) when a zero-filled closure
-- flows into an ordinary CALL ARGUMENT position, not just a
-- constructor/dictionary field (Section 1's own shape) -- this is the
-- exact `map double [1,2,3,4,5]` shape `TODO.md`'s former "Dropped:
-- closure generation for statically-known higher-order function
-- arguments" entry was about. `useIt`'s own `double` argument is
-- confirmed (by hand, `--directive dumprcexpr` + generated-C
-- inspection) to fold into a single immortal `constclosure_N` static
-- baked directly into `useIt`'s own compiled body -- called three
-- times below from `main` with no `idris2rc2_mkClosure` call for
-- `double` appearing anywhere, proving the closure is genuinely folded
-- once at compile time, not rebuilt per call.

double : Int -> Int
double x = x * 2

useIt : List Int -> List Int
useIt xs = map double xs

-- ============================================================
-- Section 5: closure-shaped CAF referenced across a definition boundary
--            (was Test74ConstFoldCafBoundaryClosure)
-- ============================================================
-- Regression test for Compiler.RC2.ConstFold's whole-program CAF fold
-- (RC2.idr's own `foldConstProgram`): `dict74` is a closure-shaped CAF
-- (a record whose every field is a zero-filled closure, same shape as
-- Section 1's own interface dictionary) referenced from a SEPARATE
-- definition (`useDict74`), not built inline inside `main` -- crossing
-- exactly the call boundary Compiler.RC2.Inline's own `isCallFree
-- (LUnderApp {}) = False` unconditionally refuses to cross (see
-- ConstFold.idr's own `CafTable` doc comment). If this folds
-- correctly, it's proof the whole-program `CafTable`, not `Inline`, is
-- what did it.
--
-- Confirmed by hand via `--directive dumprcexpr`: `Main.useDict74`'s
-- own dump references the folded `Main.dict74` dictionary directly as a
-- `RCConstCon`/`RCConstClosure` literal, never a `RAppName ...
-- "Main.dict74" []` call.

record Pair74 where
  constructor MkPair74
  fn1 : Int -> Int
  fn2 : Int -> Int

d74op1 : Int -> Int
d74op1 x = x + 1

d74op2 : Int -> Int
d74op2 x = x * 2

dict74 : Pair74
dict74 = MkPair74 d74op1 d74op2

useDict74 : Pair74 -> Int -> Int
useDict74 p x = p.fn2 (p.fn1 x)

-- ============================================================
-- Section 6: RConCase scrutinee fold
--            (was Test75ConstFoldConCaseScrutinee)
-- ============================================================
-- Regression test for Compiler.RC2.ConstFold's `RConCase` scrutinee
-- fold (its own module note): `directCase`'s scrutinee `x` is a
-- known-constant constructor (`RCConstCon`, from the `let` immediately
-- above it), so the whole `case` -- tag dispatch included -- must fold
-- away entirely at compile time, down to a single `RPrimVal`.
-- `areaOf`'s own two calls keep a genuinely dynamic scrutinee (an
-- ordinary function argument), exercising the pass's required fallback
-- (`RConCase` unchanged but for its own recursively-folded alts) and
-- doubling as the Reuse/Emit audit: a `RConCase` whose scrutinee
-- ConstFold *did* resolve must never reach Emit at all (see
-- ConstFold.idr's own doc comment for why: `EmitUtil.idr`'s `varName`
-- has no real rendering for `RCConstCon` reaching a runtime tag
-- check), which this section's own passing run (not just its output)
-- confirms.

data Shape = Circle Int64 | Square Int64

areaOf : Shape -> Int64
areaOf (Circle r) = r * r
areaOf (Square s) = s * s + 1

directCase : Int64
directCase =
  let x : Shape
      x = Circle 5
  in case x of
          Circle r => r * r
          Square s => s * s + 1

-- ============================================================
-- Section 7: mutually-referencing CAF fixpoint cap
--            (was Test76ConstFoldMutualCafSafety)
-- ============================================================
-- Safety-net regression for Compiler.RC2.RC2's `foldConstProgram`
-- whole-program fixpoint loop: `chainA`/`chainB` are two CAFs that
-- reference EACH OTHER (`chainA` builds `More 1 chainB`, `chainB`
-- builds `More 2 chainA`), so neither one's `cafValueOf` ever
-- stabilizes to a single constant no matter how many rounds
-- `foldConstProgram` runs -- there is no correct fold here, only a
-- non-terminating one if the loop had no fixed iteration cap. The one
-- thing this section actually checks is that `maxConstFoldIterations`
-- bounds the loop and the program still compiles and runs normally
-- (un-folded `chainA`/`chainB`, ordinary `RAppName` calls) rather than
-- hanging the compiler or crashing at runtime.
--
-- `sumFirst 3 chainA` is never actually evaluated (`length args > 100`
-- is always false with no CLI arguments) -- it exists only to give the
-- compiler a live, statically-reachable use of the mutually-recursive
-- `chainA`/`chainB` pair, so `Compiler.RC2.DeadCode` can't just prune
-- them away before `ConstFold` even has anything to loop on.

data Chain : Type where
  End : Chain
  More : Int -> Chain -> Chain

chainA : Chain
chainB : Chain

chainA = More 1 chainB
chainB = More 2 chainA

sumFirst : Nat -> Chain -> Int
sumFirst Z _ = 0
sumFirst (S k) End = 0
sumFirst (S k) (More x rest) = x + sumFirst k rest

-- ============================================================
-- Section 8: CAF alias-chain iteration off-by-one
--            (was Test77ConstFoldCafChainCap)
-- ============================================================
-- Off-by-one regression for Compiler.RC2.RC2's `maxConstFoldIterations`
-- (4): a 3-hop CAF alias chain (`capC = capB`, `capB = capA`,
-- `capA = MkBox d77op1 0`) over a record type (not a bare function
-- type -- `capA = d77op1` alone would type-elaborate to an
-- eta-expanded 1-arg `Main.capA`, not a genuine 0-arg CAF, so `Box`
-- keeps each hop a real CAF). Each `RAppName fc lazy "Main.cap_" []`
-- hop only resolves once the CAF one hop further down the chain has
-- itself already been entered into
-- `Compiler.RC2.ConstFold.CafTable` by a PRIOR whole-program fixpoint
-- round -- resolving the whole chain therefore needs multiple rounds,
-- not one. If the iteration cap were off by one (too low to let the
-- chain fully resolve), `main` would still produce the correct answer
-- but `--directive dumprcexpr` would show a residual `RAppName
-- "Main.capB"`/`"Main.capA"` reference instead of `main` applying a
-- single folded `RCConstClosure` directly (confirmed by hand: with the
-- cap actually at 4, `Main.capA`/`capB`/`capC` disappear from the dump
-- entirely, pruned by `Compiler.RC2.DeadCode` once nothing calls them
-- by name anymore).

-- Two fields, not one -- a single-field record is optimised as a
-- transparent newtype (no real boxing at all), which would silently
-- put us right back in the eta-expanded-1-arg-function situation this
-- section exists to avoid.
record Box where
  constructor MkBox
  run : Int -> Int
  tag : Int

d77op1 : Int -> Int
d77op1 x = x + 1

capA : Box
capA = MkBox d77op1 0

capB : Box
capB = capA

capC : Box
capC = capB

-- ============================================================
-- Section 9: bare point-free (CSE-hoisted) CAF
--            (was Test78ConstFoldBareClosureAliasCaf)
-- ============================================================
-- Regression test for Compiler.RC2.ConstFold's `foldConst` on a BARE
-- closure-alias CAF: upstream idris2-src's own Compiler.Opts.CSE pass
-- ("move duplicate expressions introduced during autosearch ... to the
-- top level") hoists the repeated, resolved `decEq` dictionary
-- reference below (`DecEq (Maybe Nat)`'s own `decEq` needs `DecEq Nat`'s
-- dictionary passed in, and `checkPair` calls `decEq` at that same
-- type twice) into a fresh top-level `csegen:N` CAF whose ENTIRE BODY
-- -- confirmed via `idris2 --dumplifted` -- is `<name underapp 2>()`,
-- i.e. a bare, zero-capture `LUnderApp`/`RUnderApp` with no enclosing
-- `let` at all. This is the exact shape (missing=2, args=[]) diagnosed
-- in the wild in idris2-missing-containers's `Main.idr` (`csegen:23 =
-- decEq`) -- CSE is what produces a genuinely point-free top-level CAF
-- here, unlike an ordinary user-written alias, which idris2-src's own
-- lambda-lifting eta-expands to a normal 1-arg function before rc2
-- ever sees it.
--
-- Before the fix, `foldConst`'s top-level `RUnderApp fc n missing args`
-- arm only resolved `args`, never reclassifying the whole node into
-- `RCConstClosure` -- so `cafValueOf`'s `MkRCFun [] _ _ (RV _ cval)`
-- pattern (RC2.idr) never matched the `csegen` CAF, it never entered
-- `CafTable`, and both call sites below kept a real `RAppName ...
-- {csegen:N} []` / `call {csegen:N} []` CAF lookup instead of
-- referencing the shared closure constant directly. Confirmed by hand
-- via `--directive dumprcexpr` post-fix: the CAF's own definition now
-- dumps as a `RCConstClosure` value (the `~closure` `Show` form), and
-- both call sites reference it directly rather than via a repeated
-- `RAppName`/`call {csegen:N} []`.

checkPair : Maybe Nat -> Maybe Nat -> Maybe Nat -> Maybe Nat -> Bool
checkPair a b c d =
    case decEq a b of
         Yes _ => True
         No _ => case decEq c d of
                      Yes _ => True
                      No _ => False

main : IO ()
main = do
  putStrLn (useGreeter MkDog)                     -- section 1
  putStrLn (useGreeter71 MkDog71)                 -- section 2
  putStrLn sectionAliasFold                       -- section 3
  printLn (useIt [1,2,3])                         -- section 4
  printLn (useIt [4,5,6])
  printLn (useIt [7,8,9])
  printLn (useDict74 dict74 10)                   -- section 5
  printLn directCase                              -- section 6
  printLn (areaOf (Circle 5))
  printLn (areaOf (Square 3))
  args <- getArgs                                 -- section 7
  if length args > 100
     then printLn (sumFirst 3 chainA)
     else putStrLn "ok"
  printLn (capC.run 41)                           -- section 8
  printLn (checkPair (Just 3) (Just 3) (Just 4) (Just 5))  -- section 9
