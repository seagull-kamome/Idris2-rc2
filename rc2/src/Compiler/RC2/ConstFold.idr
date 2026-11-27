||| Constant folding: constant `ExtPrim` calls (`prim__codegen`),
||| arithmetic/comparisons (RPrimVal/RCmpCase), constructors/closures
||| (RCConstCon/RCConstPartial), whole-program CAF-boundary crossing,
||| and RConCase scrutinee resolution. Runs between Compiler.RC2.Inline
||| and Phase 2 annotation. Four distinct designs live in one module --
||| see rc2/doc/const-con-fold.md, const-closure-fold.md,
||| const-caf-fold.md, and cast-fold-scope.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ConstFold

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Primitives
import Core.TT
import Core.Value

import Data.DPair
import Data.List
import Data.List.Quantifiers
import Data.List1
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| Cast folding mirrors upstream's `foldableOp`
||| (idris2-src/src/Compiler/Opts/ConstantFold.idr:20-25) except that
||| `IntType` folds like `Int64`. `to = StringType` is a separate case
||| (only the from-integer direction is safe; `Char -> String` stays
||| excluded). See `rc2/doc/cast-fold-scope.md` for every excluded direction.
foldableOp : {0 arity : Nat} -> PrimFn arity -> Bool
foldableOp BelieveMe = False
foldableOp (Cast from StringType) = isJust (intKind from)
foldableOp (Cast from to)   = isJust (intKind from) && isJust (intKind to)
foldableOp _                = True

||| Operands ConstFold itself will actually fold -- not `Db`
||| (host-eval-vs-runtime-cast mismatch, see
||| `rc2/doc/cast-fold-scope.md`'s "Double -> String"). Exported so
||| `Compiler.RC2.Inline`'s own `allLiteralArgs` guard stays in
||| lockstep with exactly what this pass folds, not a hand-duplicated
||| copy.
export
safeConst : Constant -> Bool
safeConst (Db _) = False
safeConst _ = True

||| The value of an integer constant of any width.
intValue : Constant -> Maybe Integer
intValue (I x) = Just (cast x)
intValue (I8 x) = Just (cast x)
intValue (I16 x) = Just (cast x)
intValue (I32 x) = Just (cast x)
intValue (I64 x) = Just (cast x)
intValue (BI x) = Just x
intValue (B8 x) = Just (cast x)
intValue (B16 x) = Just (cast x)
intValue (B32 x) = Just (cast x)
intValue (B64 x) = Just (cast x)
intValue _ = Nothing

||| A cast between `Char` and an integer constant, as rc2's runtime computes
||| it (rc2/doc/const-caf-fold.md, "Casts between `Char` and integers").
charCast : {0 arity : Nat} -> PrimFn arity -> Vect arity Constant -> Maybe Constant
charCast (Cast _ CharType) [c] = (\v => Ch (if codepoint v then chr (cast v) else '\0')) <$> intValue c
  where
    codepoint : Integer -> Bool
    codepoint v = (v >= 0 && v <= 0xD7FF) || (v >= 0xE000 && v <= 0x10FFFF)
charCast (Cast CharType to) [Ch ch] =
    let v : Integer = cast (ord ch)
    in case to of
            IntType => Just (I (cast v))
            Int32Type => Just (I32 (cast v))
            Int64Type => Just (I64 (cast v))
            IntegerType => Just (BI v)
            Bits32Type => Just (B32 (cast v))
            Bits64Type => Just (B64 (cast v))
            _ => Nothing
charCast _ _ = Nothing

||| Thin wrapper around `Core.Primitives.getOp`: apply `fn` to already-
||| resolved constant operands, subject to the safety exclusions above, but
||| for a cast to or from `Char` (`charCast`).
constFoldOp : {0 arity : Nat} -> PrimFn arity -> Vect arity Constant -> Maybe Constant
constFoldOp fn cs = charCast fn cs <|>
    if not (foldableOp fn) || not (compares fn || all safeConst cs)
       then Nothing
       else case getOp {vars = []} fn (map (NPrimVal EmptyFC) cs) of
                 Just (NPrimVal _ c) => Just c
                 _                   => Nothing
  where
    -- A comparison is exact on a `Double` too, whichever backend runs it
    -- (rc2/doc/cast-fold-scope.md).
    compares : {0 n : Nat} -> PrimFn n -> Bool
    compares (EQ _) = True
    compares (LT _) = True
    compares (LTE _) = True
    compares (GT _) = True
    compares (GTE _) = True
    compares _ = False

||| What a comparison of a value with itself gives: `<` and `>` false,
||| `==`, `<=` and `>=` true but for a `Double`, which may be NaN.
selfHolds : {0 arity : Nat} -> PrimFn arity -> Maybe Bool
selfHolds (LT _) = Just False
selfHolds (GT _) = Just False
selfHolds (EQ DoubleType) = Nothing
selfHolds (LTE DoubleType) = Nothing
selfHolds (GTE DoubleType) = Nothing
selfHolds (EQ _) = Just True
selfHolds (LTE _) = Just True
selfHolds (GTE _) = Just True
selfHolds _ = Nothing

||| `x + 0`, `0 + x` and `x - 0` of an `Integer`, and `"" ++ s` and `s ++ ""`:
||| the other operand (rc2/doc/const-caf-fold.md, "Identities").
identityOf : {0 arity : Nat} -> PrimFn arity -> Vect arity RCLocal -> Maybe RCLocal
identityOf (Add IntegerType) [a, b] = if zero b then Just a else if zero a then Just b else Nothing
  where
    zero : RCLocal -> Bool
    zero (RCConst (BI 0)) = True
    zero _ = False
identityOf (Sub IntegerType) [a, RCConst (BI 0)] = Just a
identityOf StrAppend [a, b] = if empty b then Just a else if empty a then Just b else Nothing
  where
    empty : RCLocal -> Bool
    empty (RCConst (Str "")) = True
    empty _ = False
identityOf _ _ = Nothing

||| A comparison of a local with itself (`selfHolds`).
selfCompare : {0 arity : Nat} -> PrimFn arity -> Vect arity RCLocal -> Maybe Bool
selfCompare op [a@(RCLoc _), b] = if a == b then selfHolds op else Nothing
selfCompare _ _ = Nothing

||| The range of a type whose `cast` to `Integer` keeps the value, and a
||| constant of that type for a value in the range. See `doc/widening-compare.md`.
widenSpec : PrimType -> Maybe (Integer, Integer, Integer -> Constant)
widenSpec IntType    = Just (-9223372036854775808, 9223372036854775807, \c => I (fromInteger c))
widenSpec Int8Type   = Just (-128, 127, \c => I8 (fromInteger c))
widenSpec Int16Type  = Just (-32768, 32767, \c => I16 (fromInteger c))
widenSpec Int32Type  = Just (-2147483648, 2147483647, \c => I32 (fromInteger c))
widenSpec Int64Type  = Just (-9223372036854775808, 9223372036854775807, \c => I64 (fromInteger c))
widenSpec Bits8Type  = Just (0, 255, \c => B8 (fromInteger c))
widenSpec Bits16Type = Just (0, 65535, \c => B16 (fromInteger c))
widenSpec Bits32Type = Just (0, 4294967295, \c => B32 (fromInteger c))
widenSpec Bits64Type = Just (0, 18446744073709551615, \c => B64 (fromInteger c))
widenSpec CharType   = Just (0, 1114111, \c => Ch (chr (fromInteger c)))
widenSpec _ = Nothing

||| `x op c` (`c op x` when `castFirst` is `False`) for an `x` known to lie
||| strictly on one side of `c`: `xGreater` says which.
holdsOutside : CmpOp -> (castFirst : Bool) -> (xGreater : Bool) -> Bool
holdsOutside (Element (LT _) _)  True  g = not g
holdsOutside (Element (LTE _) _) True  g = not g
holdsOutside (Element (GT _) _)  True  g = g
holdsOutside (Element (GTE _) _) True  g = g
holdsOutside (Element (LT _) _)  False g = g
holdsOutside (Element (LTE _) _) False g = g
holdsOutside (Element (GT _) _)  False g = not g
holdsOutside (Element (GTE _) _) False g = not g
holdsOutside (Element (EQ _) _)  _     _ = False

retypeCmp : PrimType -> CmpOp -> CmpOp
retypeCmp t (Element (LT _) _)  = Element (LT t) IsLT
retypeCmp t (Element (GT _) _)  = Element (GT t) IsGT
retypeCmp t (Element (EQ _) _)  = Element (EQ t) IsEQ
retypeCmp t (Element (LTE _) _) = Element (LTE t) IsLTE
retypeCmp t (Element (GTE _) _) = Element (GTE t) IsGTE

data WidenCmp = Decided Bool
              | Narrowed CmpOp (Vect 2 RCLocal)

||| A local bound directly to a constructor with at least one
||| non-constant field: its name, tag, (already resolved) field locals,
||| and the position of its one native field if it has exactly one --
||| the local's own id then names that field's box instead. See
||| `rc2/doc/constructor-escape-analysis.md`'s "Rewrite A".
record KnownCon where
  constructor MkKnownCon
  conName : Name
  conTag : Maybe Int
  ||| The (already resolved) field locals.
  conArgs : List RCLocal
  ||| Position of the one native field, if there is exactly one.
  conBoxPos : Maybe Nat

||| How a definition's locals are used, computed in one walk before
||| folding it -- the escape classification of
||| `rc2/doc/constructor-escape-analysis.md`. `escaping`: read anywhere
||| other than as an `RConCase` scrutinee or the closure an `RApp`
||| applies. `natives`: bound with a native `Rep`. `boxedUses`: read
||| somewhere only a Boxed value can go.
record UseInfo where
  constructor MkUseInfo
  escaping : SortedSet RCLocal
  natives : SortedSet LocalId
  boxedUses : SortedSet RCLocal

useInfo : RCExp -> UseInfo
useInfo = go (MkUseInfo empty empty empty)
  where
    reads : List RCLocal -> UseInfo -> UseInfo
    reads ls = { escaping $= \s => foldl (flip insert) s ls }

    boxed : List RCLocal -> UseInfo -> UseInfo
    boxed ls = { boxedUses $= \s => foldl (flip insert) s ls } . reads ls

    go : UseInfo -> RCExp -> UseInfo
    go acc (RV _ v) = boxed [v] acc
    go acc (RAppName _ _ _ args) = boxed args acc
    go acc (RAppNameRep _ _ _ _ _ args) = boxed args acc
    go acc (RAppFFIInline _ _ _ _ _ args) = boxed args acc
    go acc (RUnderApp _ _ _ args) = boxed args acc
    go acc (RDelay _ _ _ caps) = boxed caps acc
    go acc (RApp _ _ c args) = boxed (forget args) ({ boxedUses $= insert c } acc)
    go acc (RCon _ _ _ _ args _) = boxed args acc
    go acc (RExtPrim _ _ _ args _) = boxed args acc
    go acc (ROp _ _ _ args _) = reads (toList args) acc
    go acc (RStructGet _ structVar _ _) = boxed [structVar] acc
    go acc (RForce _ _ v _) = boxed [v] acc
    go acc (RStructSet _ structVar _ value _) = boxed [structVar, value] acc
    go acc (RFill _ cell field value _) = reads [field] (boxed [cell, value] acc)
    go acc (RLet _ var rep value body) =
        let acc' = go (go acc value) body
        in case rep of
                RBoxed => acc'
                _ => { natives $= insert var } acc'
    go acc (RCmpCase _ _ args _ t f) = go (go (reads (toList args) acc) t) f
    go acc (RConCase _ _ alts mDef) =
        let acc' = foldl (\a, (MkRConAlt _ _ _ _ b) => go a b) acc alts
        in maybe acc' (go acc') mDef
    go acc (RConstCase _ sc alts mDef) =
        let acc' = foldl (\a, (MkRConstAlt _ b) => go a b) (reads [sc] acc) alts
        in maybe acc' (go acc') mDef
    go acc (RDup _ _ _ b) = go acc b
    go acc (RDrop _ _ b) = go acc b
    go acc (RFree _ _ b) = go acc b
    go acc (RReleaseReuse _ _ b) = go acc b
    go acc (RReuseOffer _ _ _ _ b) = go acc b
    go acc (RLoop _ _ initial _ b) = go (boxed initial acc) b
    go acc (RLoopContinue _ args _) = boxed args acc
    go acc (RMemoize _ _ _ b) = go acc b
    go acc _ = acc

||| What an enclosing `case` on a local says about it where this pass is
||| (rc2/doc/const-caf-fold.md, "Constant-case alts").
data Matched : Type where
     ||| It is the constructor of the alt taken, with that alt's fields.
     IsCon : Name -> Maybe Int -> List LocalId -> Matched
     ||| It is none of the constructors of the alts a default is past.
     NotCons : List Name -> Matched
     ||| It is none of the constants of the alts a default is past.
     NotConsts : List Constant -> Matched

||| Everything this pass knows about a definition's locals, keyed by
||| `RCLoc`'s own `Int` id -- ids are minted by `RC.idr`'s per-
||| `LiftedDef` `NextVar` counter (monotonic, reset per definition), so
||| no id here can ever be shadowed/reused within the one `RCDef` this
||| is threaded through.
|||
||| `consts` values carry an `IsAnyConstLocal` proof (`Subset`, erased
||| at runtime) so they can only ever be one of `RCLocal`'s constant
||| forms -- `RCConstCon`/`RCConstPartial` included, see
||| `rc2/doc/const-con-fold.md`/`const-closure-fold.md` -- never a live
||| `RCLoc`. `aliases` maps a folded-away constructor field's own id to
||| the local the constructor was built from, and `knownCons` the
||| constructors themselves -- only non-escaping ones, and only when
||| `uses` is there at all. `knownPartials` is the same for a
||| partial application (`RUnderApp`) that is only ever applied. `bigLits`
||| holds the `Integer` literals too large for `RCConst` (`RC.idr`'s
||| `bindOne`): they keep their `let`, for ownership, but an op can still
||| read their value.
record Env where
  constructor MkEnv
  uses : Maybe UseInfo
  consts : SortedMap LocalId (Subset RCLocal IsAnyConstLocal)
  aliases : SortedMap LocalId RCLocal
  knownCons : SortedMap LocalId KnownCon
  knownPartials : SortedMap LocalId (Name, Nat, List RCLocal)
  bigLits : SortedMap LocalId Constant
  widened : SortedMap LocalId (PrimType, RCLocal)
  matched : SortedMap LocalId Matched

||| `knownCons`: whether to fold known constructors at all, which costs
||| a `useInfo` walk up front.
emptyEnv : (knownCons : Bool) -> RCExp -> Env
emptyEnv knownCons body = MkEnv (if knownCons then Just (useInfo body) else Nothing) empty empty empty empty empty empty empty

insertConst : LocalId -> Subset RCLocal IsAnyConstLocal -> Env -> Env
insertConst i c = { consts $= insert i c }

||| `==` of a local and a constant an enclosing default is past (`Matched`).
pastCompare : {0 arity : Nat} -> SortedMap LocalId Matched -> PrimFn arity -> Vect arity RCLocal -> Maybe Bool
pastCompare m (EQ _) [RCLoc i, RCConst c] =
    case lookup i m of
         Just (NotConsts cs) => if elem c cs then Just False else Nothing
         _ => Nothing
pastCompare m (EQ ty) [RCConst c, RCLoc i] = pastCompare m (EQ ty) [RCLoc i, RCConst c]
pastCompare _ _ _ = Nothing

||| Resolve `l` against `env` if it's a variable this pass has already
||| folded to a known constant value or an alias of another local --
||| otherwise `l` unchanged (still `RCLoc`, or already one of the other
||| constant forms, which are never looked up). An alias target is
||| resolved when it's recorded, so one lookup is enough.
resolveLocal : Env -> RCLocal -> RCLocal
resolveLocal env l@(RCLoc i) =
    case lookup i env.aliases of
         Just l' => l'
         Nothing => fromMaybe l (fst <$> lookup i env.consts)
resolveLocal _   l           = l

||| `RCConst` is already a literal (no `RLet` involved, see `bindOne`'s
||| own doc comment in RC.idr); `RCLoc` is resolved against whatever
||| this pass has folded so far. `RCNull`/`RCEmptyCon`/`RCConstCon`
||| never denote a plain `Constant`.
resolveConst : Env -> RCLocal -> Maybe Constant
resolveConst env l = case resolveLocal env l of
                           RCConst c => Just c
                           RCLoc i   => lookup i env.bigLits
                           _         => Nothing

||| A comparison of `Integer`s, one of them `cast` from a narrower type (`widened`)
||| and the other a literal, as a comparison in the narrower type, or decided
||| at once when the literal is out of its range. See `doc/widening-compare.md`.
cmpWidened : Env -> CmpOp -> Vect 2 RCLocal -> Maybe WidenCmp
cmpWidened env op [a, b] =
    case cmpOpTy op of
         IntegerType => case (castOf a, castOf b) of
                             (Just (ty, x), Nothing) => decide True ty x b
                             (Nothing, Just (ty, x)) => decide False ty x a
                             _ => Nothing
         _ => Nothing
  where
    castOf : RCLocal -> Maybe (PrimType, RCLocal)
    castOf (RCLoc i) = lookup i env.widened
    castOf _ = Nothing

    surrogate : Integer -> Bool
    surrogate c = c >= 55296 && c <= 57343

    decide : (castFirst : Bool) -> PrimType -> RCLocal -> RCLocal -> Maybe WidenCmp
    decide castFirst ty x other =
        case (widenSpec ty, resolveConst env other) of
             (Just (lo, hi, mk), Just (BI c)) =>
                 if c < lo then Just (Decided (holdsOutside op castFirst True))
                 else if c > hi then Just (Decided (holdsOutside op castFirst False))
                 else if ty == CharType && surrogate c then Nothing
                 else let k = RCConst (mk c)
                      in Just (Narrowed (retypeCmp ty op) (if castFirst then [x, k] else [k, x]))
             _ => Nothing

||| `l` is one of `RCLocal`'s constant forms *and* safe to stage as a
||| static C initializer -- kept at full (non-erased) multiplicity so
||| callers can build `allConstLocal`'s own `All` proof. Excludes
||| `RCConst (BI _)`: every other `Constant` renders as a compile-time-
||| constant C expression, but `BI` (GMP's `mpz_t`) always needs a real
||| function call (`idris2rc2_mkIntegerLiteral`). See
||| `rc2/doc/const-con-fold.md`'s Bug #2 for why this exclusion is
||| independent of -- and must be kept alongside -- the `RLet` case's
||| own native-eligibility guard below.
isConstLocalProof : (l : RCLocal) -> Maybe (IsAnyConstLocal l)
isConstLocalProof (RCLoc _)        = Nothing
isConstLocalProof (RCConst (BI x)) = if immInt64 x then Just ItIsConst2 else Nothing
isConstLocalProof RCNull                 = Just ItIsNull2
isConstLocalProof RCErased               = Just ItIsErased2
isConstLocalProof RCWorld                = Just ItIsWorld2
isConstLocalProof (RCConst _)            = Just ItIsConst2
isConstLocalProof (RCEmptyCon {})        = Just ItIsEmptyCon2
isConstLocalProof (RCConstCon {})        = Just ItIsConstCon2
isConstLocalProof (RCConstPartial {})    = Just ItIsConstPartial2

||| Whole-list version of `isConstLocalProof`, collecting each
||| element's own proof into the `All`-shaped obligation `RCConstCon`'s
||| own `argsConst` field requires -- `args` itself stays a plain
||| `List RCLocal` (see RCExp.idr's own doc comment for why
||| `RCConstCon` doesn't need every field re-typed to carry the proof).
export
allConstLocal : (args : List RCLocal) -> Maybe (All IsAnyConstLocal args)
allConstLocal [] = Just []
allConstLocal (x :: xs) = case isConstLocalProof x of
                               Nothing => Nothing
                               Just p  => map (\ps => p :: ps) (allConstLocal xs)

||| Named so `arity` has a type-signature-level home to be inferred
||| from -- inlining this as a bare `traverse (resolveConst env) args`
||| at each call site left `arity` (erased on `ROp`/`RCmpCase`, see
||| RCExp.idr) with nothing but the case scrutinee itself to pin its
||| `Vect` length down, which Idris2's elaborator couldn't resolve.
resolveConsts : {0 arity : Nat} -> Env -> Vect arity RCLocal -> Maybe (Vect arity Constant)
resolveConsts env = traverse (resolveConst env)

findConstAlt : Constant -> List RConstAlt -> Maybe RCExp -> Maybe RCExp
findConstAlt c [] def = def
findConstAlt c (MkRConstAlt c' body :: rest) def =
    if c == c' then Just body else findConstAlt c rest def

||| 0-arg CAFs already known to fold to a single constant, keyed by
||| `Name` -- a whole-program-scoped companion to `Env` above (which
||| can't name a CAF, only a per-definition local id). Rebuilt each
||| round of `Compiler.RC2.RC2`'s whole-program fixpoint loop. See
||| `rc2/doc/const-caf-fold.md`'s "CAF boundary crossing" for the
||| fixpoint algorithm and its termination argument.
public export
CafTable : Type
CafTable = SortedMap Name (Subset RCLocal IsAnyConstLocal)

findConAlt : Maybe Int -> List RConAlt -> Maybe RConAlt
findConAlt tag [] = Nothing
findConAlt tag (alt@(MkRConAlt _ _ tag' _ _) :: rest) =
    if tag == tag' then Just alt else findConAlt tag rest

insertConArgs : List LocalId -> List RCLocal -> Env -> Env
insertConArgs (i :: is) (v :: vs) env =
    case isConstLocalProof v of
         Just prf => insertConArgs is vs (insertConst i (Element v prf) env)
         Nothing  => insertConArgs is vs env
insertConArgs _ _ env = env

||| `Just` the compile-time-known value for an `RExtPrim` call site
||| guaranteed to always evaluate to it, `Nothing` otherwise -- matched
||| by base name only (`NS _ (UN (Basic pn))`), the same shape
||| `Compiler.RC2.Emit`'s own known-ExtPrim whitelist uses (its
||| `emitRC (RExtPrim ...)` case), not a fully-qualified comparison.
||| The `RPrimVal` this produces needs no ownership handling: by the
||| time Phase 2 sees it, it is just another literal (no refcount
||| bookkeeping), like every other constant this module folds.
constExtPrimValue : Name -> List RCLocal -> Maybe Constant
constExtPrimValue (NS _ (UN (Basic "prim__codegen"))) [] = Just (Str "rc2")
constExtPrimValue _ _ = Nothing

-- `foldConst` is self-recursive only (never mutually recursive with a
-- sibling function) -- its two small per-alt helpers are each called
-- from exactly one of its own case clauses, so they live as `where`
-- clauses on those clauses instead of a `mutual` block; each still
-- calls `foldConst` itself directly, which is fine since it's the
-- enclosing definition being defined.
foldConst : CafTable -> Env -> RCExp -> RCExp
-- `value` folds first (recursively, so a nested `RLet` chain like
-- `[1,2,3,4,5]`'s own ANF folds inside-out), then the *fold result*
-- (not the original shape) is classified -- see
-- rc2/doc/const-con-fold.md's Bug #1 for why that distinction matters.
-- A `RPrimVal`/`RCConstCon`/`RCConstPartial` result means "a known
-- constant": insert into `env`, drop the `RLet` if `body` (post-fold)
-- does not reference the variable.
foldConst caf env (RLet fc var rep value body) =
    let value' = foldConst caf env value
    in case value' of
            -- Only a native-eligible constant (`litRep`) is safe to
            -- splice into `env`/other nodes' `args` in place of the
            -- `RCLoc` -- a `BI` must keep its real `RCLoc` so `annotate`
            -- keeps tracking its ownership. See rc2/doc/const-con-fold.md's
            -- Bug #2: this guard is what fixes a confirmed `BI` memory leak.
            -- A `Str` literal is an immortal static, so it splices like a
            -- native one (rc2/doc/const-caf-fold.md, "String literals").
            RPrimVal _ c =>
                case litRep c of
                     Just _ =>
                         let body' = foldConst caf (insertConst var (Element (RCConst c) ItIsConst2) env) body
                         in if mentionsLocal (RCLoc var) body'
                               then RLet fc var rep value' body'
                               else body'
                     -- A large `Integer` literal keeps its `let` (see
                     -- above) but lends its value to the ops reading it;
                     -- once they have all folded, nothing needs it.
                     Nothing => case c of
                         BI _ =>
                             let body' = foldConst caf ({ bigLits $= insert var c } env) body
                             in if mentionsLocal (RCLoc var) body'
                                   then RLet fc var rep value' body'
                                   else body'
                         Str _ =>
                             let body' = foldConst caf (insertConst var (Element (RCConst c) ItIsConst2) env) body
                             in if mentionsLocal (RCLoc var) body'
                                   then RLet fc var rep value' body'
                                   else body'
                         _ => if c == WorldVal then foldNull var (Element RCWorld ItIsWorld2) else RLet fc var rep value' (foldConst caf env body)
            RV _ cval@(RCConstCon {}) =>
                let body' = foldConst caf (insertConst var (Element cval ItIsConstCon2) env) body
                in if mentionsLocal (RCLoc var) body'
                      then RLet fc var rep value' body'
                      else body'
            -- Mirrors the `RCConstCon` arm above for a `let`-rebinding
            -- of an already-folded closure constant, and also catches
            -- a bare `RUnderApp fc n missing []` used directly as a
            -- `let`'s value (the `RUnderApp` case below already folds
            -- that shape to this same `RV` form first). See
            -- rc2/doc/const-closure-fold.md's "Gap: a let-rebinding of
            -- an already-folded closure didn't propagate".
            RV _ cval@(RCEmptyCon {}) =>
                let body' = foldConst caf (insertConst var (Element cval ItIsEmptyCon2) env) body
                in if mentionsLocal (RCLoc var) body'
                      then RLet fc var rep value' body'
                      else body'
            RV _ cval@(RCConstPartial {}) =>
                let body' = foldConst caf (insertConst var (Element cval ItIsConstPartial2) env) body
                in if mentionsLocal (RCLoc var) body'
                      then RLet fc var rep value' body'
                      else body'
            -- The same for a string a CAF substitution (`cafValueOf`) or an
            -- inlined CAF left as a bare `RCConst`, and for a native-eligible
            -- constant a local became, such as a constant-case scrutinee in
            -- its alt (`RPrimVal` above says why not a `BI`).
            RV _ (RCConst c) =>
                if isJust (litRep c) || (case c of { Str _ => True; _ => False })
                   then let body' = foldConst caf (insertConst var (Element (RCConst c) ItIsConst2) env) body
                        in if mentionsLocal (RCLoc var) body'
                              then RLet fc var rep value' body'
                              else body'
                   else RLet fc var rep value' (foldConst caf env body)
            RErased _ => foldNull var (Element RCErased ItIsErased2)
            RV _ RCErased => foldNull var (Element RCErased ItIsErased2)
            RV _ RCWorld => foldNull var (Element RCWorld ItIsWorld2)
            RV _ RCNull => foldNull var (Element RCNull ItIsNull2)
            -- A non-escaping constructor with a non-constant field,
            -- possibly at the end of a let chain: the chain's bindings
            -- are floated out so the fields stay in scope for `body`.
            -- Its local, if still used afterwards, is its one native
            -- field's box. An escaping one is left alone: its native
            -- fields would be boxed again at every use instead of once.
            -- See rc2/doc/constructor-escape-analysis.md's "Rewrite A".
            ROp _ Nothing (Cast t IntegerType) [a] _ =>
                if isJust (widenSpec t)
                   then let body' = foldConst caf ({ widened $= insert var (t, resolveLocal env a) } env) body
                        in if mentionsLocal (RCLoc var) body'
                              then RLet fc var rep value' body'
                              else body'
                   else RLet fc var rep value' (foldConst caf env body)
            _ => case splitLetChain value' of
                      (wrap, con@(RCon _ n _ tag args Nothing)) =>
                          if maybe True (\u => contains (RCLoc var) u.escaping) env.uses || any isBigLiteral args
                             then RLet fc var rep value' (foldConst caf env body)
                             else let boxPos = singleNative args
                                      body' = foldConst caf ({ knownCons $= insert var (MkKnownCon n tag args boxPos) } env) body
                                  in wrap $ if contains (RCLoc var) (ownedUsedIn (singleton (RCLoc var)) body')
                                               then RLet fc var rep (maybe con (\k => boxOf k args) boxPos) body'
                                               else body'
                      -- The same for a partial application only ever applied:
                      -- each saturating `RApp` of it becomes a direct call, so
                      -- the closure is never built.
                      (wrap, pa@(RUnderApp _ n missing args@(_ :: _))) =>
                          if maybe True (\u => contains (RCLoc var) u.escaping) env.uses
                             then RLet fc var rep value' (foldConst caf env body)
                             else let body' = foldConst caf ({ knownPartials $= insert var (n, missing, args) } env) body
                                  in wrap $ if contains (RCLoc var) (ownedUsedIn (singleton (RCLoc var)) body')
                                               then RLet fc var rep pa body'
                                               else body'
                      _ => RLet fc var rep value' (foldConst caf env body)
  where
    -- A value held as C `NULL` (an erased value, the world token, a
    -- nullary constructor): every reader takes the constant instead, and
    -- the `let` goes once none is left.
    foldNull : LocalId -> Subset RCLocal IsAnyConstLocal -> RCExp
    foldNull var c =
        let body' = foldConst caf (insertConst var c env) body
        in if mentionsLocal (RCLoc var) body'
              then RLet fc var rep (foldConst caf env value) body'
              else body'

    splitLetChain : RCExp -> (RCExp -> RCExp, RCExp)
    splitLetChain (RLet fc' v r e b) = let (wrap, t) = splitLetChain b in (RLet fc' v r e . wrap, t)
    splitLetChain e = (id, e)

    -- A `BI` field must keep a real `RCLoc` for ownership
    -- (rc2/doc/const-con-fold.md's Bug #2), so it can't be aliased.
    isBigLiteral : RCLocal -> Bool
    isBigLiteral (RCConst (BI x)) = not (immInt64 x)
    isBigLiteral _ = False

    isNative : RCLocal -> Bool
    isNative (RCLoc j) = maybe False (\u => contains j u.natives) env.uses
    isNative _ = False

    singleNative : List RCLocal -> Maybe Nat
    singleNative args = case filter (isNative . snd) (zip [0 .. length args] args) of
                             [(k, _)] => Just k
                             _ => Nothing

    boxOf : Nat -> List RCLocal -> RCExp
    boxOf k args = maybe (RCrash fc "[rc2] ConstFold: known constructor lost its native field") (RV fc) (getAt k args)
foldConst _ env (RV fc l) = RV fc (resolveLocal env l)
-- A `RCon` whose `args` are all -- directly or via `env` -- already
-- constant folds to `RV` of a single `RCConstCon`. `reuseFrom` is
-- never folded (already excluded by matching only `Nothing`);
-- a tagged constructor without fields is the tagged integer `RCEmptyCon`
-- (as `RC.idr`'s `bindOne` makes it for an operand), not a heap cell;
-- NIL/NOTHING/ZERO/UNIT already route through `RCNull`, and C has no
-- zero-length static array. See
-- rc2/doc/const-con-fold.md's "Design" for the full reasoning,
-- including the field-by-field partial fold case.
foldConst caf env (RCon fc n ci tag args Nothing) =
    let resolvedArgs = map (resolveLocal env) args
    in case args of
            [] => case tag of
                       Just t => if isNullCon ci then RCon fc n ci tag args Nothing else RV fc (RCEmptyCon n ci t)
                       Nothing => RCon fc n ci tag args Nothing
            _  => case allConstLocal resolvedArgs of
                       Just argsConst => RV fc (RCConstCon n ci tag resolvedArgs {argsConst})
                       Nothing        => RCon fc n ci tag resolvedArgs Nothing
-- Every other node holding `RCLocal` operands gets them resolved
-- against `env` too, purely so `mentionsLocal` (the `RLet` case above)
-- sees the substitution -- unresolved, a use would keep looking "live"
-- forever, permanently blocking that `RLet` from folding away. See
-- rc2/doc/const-con-fold.md's Bug #1.
--
-- `args = []` is exactly a CAF call: resolve it against `CafTable` the
-- same way a local `RLet`-bound constant resolves against `env`. See
-- rc2/doc/const-caf-fold.md's "CAF boundary crossing".
foldConst caf env (RAppName fc lazy n args) =
    let args' = map (resolveLocal env) args
    in case args' of
            [] => case lookup n caf of
                       Just (Element cval _) => RV fc cval
                       Nothing               => RAppName fc lazy n []
            _  => RAppName fc lazy n args'
-- A literal, zero-args `RUnderApp` denotes the same constant closure
-- value as `RCConstPartial` -- folds unconditionally so a CAF whose
-- whole body is a bare zero-capture closure reference (no `RLet`
-- wrapper) is recognised as constant by `cafValueOf` too. A real
-- capture (`RUnderApp fc n missing (x :: xs)`) falls through
-- unchanged. See rc2/doc/const-closure-fold.md's "Design" section.
foldConst _ env (RUnderApp fc n missing args) =
    let args' = map (resolveLocal env) args
    in case allConstLocal args' of
            Just capsConst => if any isConstCon args'
                                 then RUnderApp fc n missing args'
                                 else RV fc (RCConstPartial n missing args' {capsConst})
            Nothing => RUnderApp fc n missing args'
  where
    -- A constant constructor among the captured values (a dictionary) stays an
    -- `RUnderApp`: `SpecClosure` specialises on it there (`underAppSites`), and
    -- inside an `RCConstPartial` it would not see it.
    isConstCon : RCLocal -> Bool
    isConstCon (RCConstCon {}) = True
    isConstCon _ = False
-- Saturating a constant closure is a plain direct call (named, so the later
-- passes see through it); an under-application builds an `RUnderApp`.
-- An over-application is left for `ArityRaise.applyFoldApplied`, which knows
-- the bare wrappers. See rc2/doc/const-closure-fold.md's "Saturated
-- application of a folded closure" and "Over-application of a folded closure".
foldConst _ env (RApp fc lazy c args) =
    let c' = resolveLocal env c
        args' = map (resolveLocal env) args
    in case c' of
            RCConstPartial n missing caps =>
                if length args' == missing
                   then RAppName fc lazy n (caps ++ forget args')
                   else if length args' < missing
                           then RUnderApp fc n (minus missing (length args')) (caps ++ forget args')
                           else RApp fc lazy c' args'
            RCLoc i =>
                case lookup i env.knownPartials of
                     Just (n, missing, captured) =>
                         if length args' == missing
                            then RAppName fc lazy n (captured ++ forget args')
                            else if length args' < missing
                                    then RUnderApp fc n (minus missing (length args')) (captured ++ forget args')
                                    else RApp fc lazy c' args'
                     Nothing => RApp fc lazy c' args'
            _ => RApp fc lazy c' args'
foldConst _ env (RExtPrim fc lazy p args postDrop) =
    let args' = map (resolveLocal env) args
    in case constExtPrimValue p args' of
            Just c  => RPrimVal fc c
            Nothing => RExtPrim fc lazy p args' postDrop
foldConst _ env (RStructGet fc structVar sf postDrop) =
    RStructGet fc (resolveLocal env structVar) sf postDrop
foldConst _ env (RDelay fc lr n caps) = RDelay fc lr n (map (resolveLocal env) caps)
foldConst _ env (RForce fc lr v postDrop) = RForce fc lr (resolveLocal env v) postDrop
foldConst _ env (RStructSet fc structVar sf value postDrop) =
    RStructSet fc (resolveLocal env structVar) sf (resolveLocal env value) postDrop
foldConst _ env (RFill fc cell field @{ok} value postDrop) =
    let Element field' ok' = mapFillIndex (resolveLocal env) field ok
    in RFill fc (resolveLocal env cell) field' @{ok'} (resolveLocal env value) postDrop
foldConst _ env (ROp fc lazy op args postDrop) =
    let resolvedArgs = map (resolveLocal env) args
    in case resolveConsts env args of
            Just cs => case constFoldOp op cs of
                            Just c  => RPrimVal fc c
                            Nothing => ROp fc lazy op resolvedArgs postDrop
            Nothing => case selfCompare op resolvedArgs <|> pastCompare env.matched op resolvedArgs of
                            Just b => RPrimVal fc (I (if b then 1 else 0))
                            Nothing => maybe (ROp fc lazy op resolvedArgs postDrop) (RV fc) (identityOf op resolvedArgs)
foldConst caf env (RCmpCase fc op args postDrop t f) =
    let t' = foldConst caf env t
        f' = foldConst caf env f
        resolvedArgs = map (resolveLocal env) args
    in case resolveConsts env args of
            Just cs => case constFoldOp op.fst cs of
                            Just (I 1) => t'
                            Just (I 0) => f'
                            _          => RCmpCase fc op resolvedArgs postDrop t' f'
            Nothing => case selfCompare op.fst resolvedArgs <|> pastCompare env.matched op.fst resolvedArgs of
                            Just b => if b then t' else f'
                            Nothing => case cmpWidened env op resolvedArgs of
                                            Just (Decided True)  => t'
                                            Just (Decided False) => f'
                                            Just (Narrowed op' args') => RCmpCase fc op' args' postDrop t' f'
                                            Nothing => RCmpCase fc op resolvedArgs postDrop t' f'
-- Mirrors `RConstCase`'s own scrutinee-resolution below, for tag
-- dispatch: a resolved `RCConstCon`/`RCEmptyCon` scrutinee makes the
-- whole case disappear in favour of the matching alt (fields
-- re-entered into `env` via `insertConArgs`). See
-- rc2/doc/const-caf-fold.md's "RConCase scrutinee resolution" for the
-- full design, and its "Bugs found" for why `RC.idr`'s `annotate`
-- needed three added intercepts once this could produce a bare `RV`
-- of a non-`RCConstCon`/`RCConstPartial` constant form.
foldConst caf env (RConCase fc sc alts mDef) =
    case resolveLocal env sc of
         RCConstCon _ _ tag args =>
             case findConAlt tag alts of
                  Just (MkRConAlt _ _ _ argIds body) =>
                      foldConst caf (insertConArgs argIds args env) body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         RCEmptyCon _ _ tag =>
             case findConAlt (Just tag) alts of
                  Just (MkRConAlt _ _ _ _ body) => foldConst caf env body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase folded scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         -- Nil, Nothing, Z and MkUnit are all NULL, so a NULL scrutinee
         -- takes whichever of their alternatives the case has. Left as a
         -- case, it would still name a local whose let this pass drops.
         RCNull =>
             case Data.List.find (\(MkRConAlt _ ci _ _ _) => isNullCon ci) alts of
                  Just (MkRConAlt _ _ _ _ body) => foldConst caf env body
                  Nothing =>
                      maybe (RCrash fc "[rc2] ConstFold: RConCase NULL scrutinee matched no alt and had no default")
                            (foldConst caf env) mDef
         sc'@(RCLoc i) => fromMaybe (byMatched i sc') (foldKnown i)
         _ => RConCase fc sc (map (foldConstAlt caf env) alts) (map (foldConst caf env) mDef)
  where
    foldConstAlt : CafTable -> Env -> RConAlt -> RConAlt
    foldConstAlt caf env (MkRConAlt name ci tag args body) =
        MkRConAlt name ci tag args (foldConst caf env body)

    findKnownAlt : Name -> Maybe Int -> List RConAlt -> Maybe RConAlt
    findKnownAlt n Nothing = Data.List.find (\(MkRConAlt n' _ _ _ _) => n == n')
    findKnownAlt _ tag = findConAlt tag

    -- Each field becomes an alias of its argument, except a native
    -- argument whose field is read as Boxed somewhere: that one reads
    -- the box the scrutinee's own local now names (`boxVar`) if it is
    -- the constructor's one native field, and is otherwise boxed once
    -- by a `let` -- never again at every Boxed read. `Nothing` when
    -- the field lists don't line up.
    bindKnownConArgs : (boxVar : LocalId) -> Maybe Nat -> Nat -> List LocalId -> List RCLocal -> Env
                    -> Maybe (Env, RCExp -> RCExp)
    bindKnownConArgs _ _ _ [] [] env = Just (env, id)
    bindKnownConArgs boxVar boxPos k (i :: is) (v :: vs) env =
        let rest = bindKnownConArgs boxVar boxPos (S k) is vs
        in case v of
                RCLoc j =>
                    if maybe False (\u => contains j u.natives && contains (RCLoc i) u.boxedUses) env.uses
                       then if boxPos == Just k
                               then rest ({ aliases $= insert i (RCLoc boxVar) } env)
                               else (\(env', wrap) => (env', RLet fc i RBoxed (RV fc v) . wrap)) <$> rest env
                       else rest ({ aliases $= insert i v } env)
                _ => rest (insertConArgs [i] [v] env)
    bindKnownConArgs _ _ _ _ _ _ = Nothing

    -- See rc2/doc/constructor-escape-analysis.md's "Rewrite A". A
    -- field-count mismatch can't come from a well-typed program, and
    -- the scrutinee's local may already name a box instead of the
    -- constructor, so it crashes rather than falling back to a `case`.
    foldKnown : LocalId -> Maybe RCExp
    foldKnown i = do
        MkKnownCon n tag args boxPos <- lookup i env.knownCons
        Just $ case findKnownAlt n tag alts of
                    Just (MkRConAlt _ _ _ argIds body) =>
                        case bindKnownConArgs i boxPos 0 argIds args env of
                             Just (env', wrap) => foldConst caf env' (wrap body)
                             Nothing => RCrash fc "[rc2] ConstFold: known constructor's field count doesn't match its alt"
                    Nothing =>
                        maybe (RCrash fc "[rc2] ConstFold: RConCase known scrutinee matched no alt and had no default")
                              (foldConst caf env) mDef

    altName : RConAlt -> Name
    altName (MkRConAlt n _ _ _ _) = n

    -- The case on `i`, each alt folded knowing its constructor and the
    -- default knowing every constructor it is past.
    -- An alt folded knowing its constructor.
    foldAltIn : LocalId -> RConAlt -> RConAlt
    foldAltIn i (MkRConAlt n ci tag args body) =
        MkRConAlt n ci tag args (foldConst caf ({ matched $= insert i (IsCon n tag args) } env) body)

    keep : LocalId -> RCLocal -> List Name -> List RConAlt -> RCExp
    keep i sc' past as =
        RConCase fc sc' (map (foldAltIn i) as)
                 (map (foldConst caf ({ matched $= insert i (NotCons (past ++ map altName as)) } env)) mDef)

    -- An alt's fields as aliases of the enclosing alt's. Every field has
    -- its own id before RC (`DeadVars` blanks them much later), so the
    -- lists only differ in a case of another arity, which a well-typed
    -- program does not have.
    aliasFields : List LocalId -> List LocalId -> Env -> Maybe Env
    aliasFields [] [] e = Just e
    aliasFields (a :: as) (b :: bs) e = aliasFields as bs ({ aliases $= insert a (resolveLocal e (RCLoc b)) } e)
    aliasFields _ _ _ = Nothing

    -- No alt left and no default: no value of the local's type reaches
    -- this case. It crashes rather than taking an alt Emit would not test.
    unreachable : RCExp
    unreachable = RCrash fc "[rc2] ConstFold: no alt of this case can be reached"

    -- A case again on a local an enclosing case matched: the alt of its
    -- constructor, or without the alts of those its default is past.
    byMatched : LocalId -> RCLocal -> RCExp
    byMatched i sc' = case lookup i env.matched of
        Just (IsCon n tag outer) => case findKnownAlt n tag alts of
            Just (MkRConAlt _ _ _ inner body) =>
                maybe (keep i sc' [] alts) (\e => foldConst caf e body) (aliasFields inner outer env)
            Nothing => maybe unreachable (foldConst caf env) mDef
        Just (NotCons past) => case filter (\a => not (elem (altName a) past)) alts of
            [] => maybe unreachable (foldConst caf env) mDef
            live => keep i sc' past live
        _ => keep i sc' [] alts
foldConst caf env (RConstCase fc sc alts mDef) =
    case resolveConst env sc of
         Just c  => let alts' = map (foldConstConstAlt caf env) alts
                        mDef' = map (foldConst caf env) mDef
                    in fromMaybe (RConstCase fc sc alts' mDef') (findConstAlt c alts' mDef')
         -- Without the alts of the constants an enclosing default is past;
         -- this default is past these alts' as well.
         Nothing =>
             let sc' = aliasOf sc
                 past : List Constant
                 past = case sc' of
                             RCLoc i => case lookup i env.matched of
                                             Just (NotConsts cs) => cs
                                             _ => []
                             _ => []
                 live : List RConstAlt
                 live = filter (\(MkRConstAlt c _) => not (elem c past)) alts
                 envDef : Env
                 envDef = case sc' of
                               RCLoc i => { matched $= insert i (NotConsts (past ++ map (\(MkRConstAlt c _) => c) live)) } env
                               _ => env
             in case (live, mDef) of
                     ([], Just d) => foldConst caf envDef d
                     -- An enclosing default is past every alt and there is no
                     -- default: a case of no alt, which Emit writes as nothing.
                     ([], Nothing) => if null alts then RConstCase fc sc' [] Nothing
                                         else RCrash fc "[rc2] ConstFold: no alt of this case can be reached"
                     _ => RConstCase fc sc' (map (foldConstConstAlt caf env) live) (map (foldConst caf envDef) mDef)
  where
    aliasOf : RCLocal -> RCLocal
    aliasOf l = case resolveLocal env l of
                     l'@(RCLoc _) => l'
                     _ => l

    -- Whether a scrutinee that matched `c` is `c` itself: a `Double` matching
    -- `0.0` may be `-0.0`, and no other two values compare equal (NaN matches
    -- nothing).
    pins : Constant -> Bool
    pins (Db d) = d /= 0
    pins _ = True

    -- In an alt, the scrutinee is its constant (rc2/doc/const-caf-fold.md,
    -- "Constant-case alts").
    foldConstConstAlt : CafTable -> Env -> RConstAlt -> RConstAlt
    foldConstConstAlt caf env (MkRConstAlt c body) =
        let env' = case (aliasOf sc, isConstLocalProof (RCConst c)) of
                        (RCLoc i, Just prf) => if pins c then insertConst i (Element (RCConst c) prf) env else env
                        _ => env
        in MkRConstAlt c (foldConst caf env' body)
foldConst caf env (RDup fc v extra body) = RDup fc v extra (foldConst caf env body)
foldConst caf env (RDrop fc vars body) = RDrop fc vars (foldConst caf env body)
foldConst caf env (RFree fc v body) = RFree fc v (foldConst caf env body)
foldConst caf env (RReleaseReuse fc v body) = RReleaseReuse fc v (foldConst caf env body)
foldConst caf env (RReuseOffer fc sc dupOnShared dropOnUnique body) =
    RReuseOffer fc sc dupOnShared dropOnUnique (foldConst caf env body)
-- `RLoop`/`RAppNameRep` can't exist yet at the point this pass runs
-- (before Compiler.RC2.Loop/DualABI) -- kept total as a plain
-- pass-through rather than assumed unreachable, same reasoning as
-- `Rewrite.idr`'s `renameRCExp`.
foldConst caf env (RLoop {sameLen} fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (foldConst caf env body)
foldConst _ _ e = e

||| A 0-arg CAF whose body has folded to a bare `RV fc cval` -- the
||| shape `Compiler.RC2.RC2`'s own whole-program fixpoint loop looks
||| for after each `foldConstDef` pass to grow `CafTable`. A bare
||| `RPrimVal` body is matched only for a `Str`: a numeric one is already
||| spliced into every call site by `Compiler.RC2.Inline`'s own
||| `isCallFree`, before `ConstFold` ever runs, but a string a fold itself
||| produced (`prim__codegen`, `target-os`) is not -- along with the
||| `RCConstCon`/`RCConstPartial` shapes `Inline` can't reach. See `rc2/doc/const-caf-fold.md`'s "Design" for the
||| fixpoint algorithm this feeds.
export
cafValueOf : RCDef -> Maybe (Subset RCLocal IsAnyConstLocal)
cafValueOf (MkRCFun [] _ _ (RV _ cval)) = (\prf => Element cval prf) <$> isConstLocalProof cval
cafValueOf (MkRCFun [] _ _ (RPrimVal _ c@(Str _))) = Just (Element (RCConst c) ItIsConst2)
cafValueOf _ = Nothing

||| A `Boxed` `let` whose value has become an `ROp`/`RPrimVal` with a native
||| result gets the rep Phase 1 would have given it. Phase 1 saw the value
||| before inlining and folding: `mod` on `Int` is a `case y == 0 of ...`
||| there, and `repOf` of a case is `Nothing`. See `rc2/doc/native-type-
||| inference.md`, "Refreshing a rep after folding".
refreshReps : RCExp -> RCExp
refreshReps e =
    case mapChildren refreshReps e of
         RLet fc var RBoxed value body =>
             RLet fc var (maybe RBoxed (RNative . TPrim) (repOf value)) value body
         e' => e'

||| `knownCons`: see `emptyEnv`.
export
foldConstDef : (knownCons : Bool) -> CafTable -> RCDef -> RCDef
foldConstDef kc caf (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (refreshReps (foldConst caf (emptyEnv kc body) body))
foldConstDef kc caf (MkRCError body) = MkRCError (refreshReps (foldConst caf (emptyEnv kc body) body))
foldConstDef _ _ d@(MkRCCon _ _ _) = d
foldConstDef _ _ d@(MkRCForeign _ _ _) = d

||| As `foldConstDef`, but with `seed` already in `Env`: each `(i, l)`
||| binds local id `i` to the constant `l`, exactly as if this pass had
||| folded it there itself. An `l` that isn't one of `RCLocal`'s own
||| constant forms (`isConstLocalProof`) is skipped rather than
||| rejected, so a caller needn't reconstruct the proof machinery.
|||
||| Exists for `Compiler.RC2.SpecClosure`'s own constant-constructor
||| specialization: seeding a parameter with the dictionary its call
||| sites always pass is the *whole* rewrite -- `resolveLocal`
||| substitutes it, the `RConCase` case folds the destructuring away
||| against it, and the `RApp` case then turns each method field (now
||| an `RCConstPartial`) into a direct call. See
||| `rc2/doc/constant-constructor-specialization.md`'s "Why nothing new
||| is needed downstream".
export
foldConstDefWith : CafTable -> List (LocalId, RCLocal) -> RCDef -> RCDef
foldConstDefWith caf seed d =
    case d of
         MkRCFun args retRep isWorker body => MkRCFun args retRep isWorker (refreshReps (foldConst caf (seeded body) body))
         MkRCError body => MkRCError (refreshReps (foldConst caf (seeded body) body))
         d'@(MkRCCon _ _ _) => d'
         d'@(MkRCForeign _ _ _) => d'
  where
    seeded : RCExp -> Env
    seeded body = foldl (\acc, (i, l) =>
                            maybe acc (\prf => insertConst i (Element l prf) acc) (isConstLocalProof l))
                       (emptyEnv True body) seed
