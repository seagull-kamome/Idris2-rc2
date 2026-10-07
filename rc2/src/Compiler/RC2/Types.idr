module Compiler.RC2.Types

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Provides helpers for native type inference, deciding `Rep` for
-- intermediate let-bound locals during normalization.
-- Native unboxed representation is used for arithmetic chains, while
-- boxed representation remains for function boundaries.
-- Out of scope: a two-way match on Idris2's own Bool encoding, which
-- Compiler.RC2.RC's `normalize` fuses into a dedicated `RCmpCase` node
-- instead (see RCExp.idr's own `CmpOp` and doc comment on
-- RCmpCase) -- a distinct, narrower optimisation from the let-bound-
-- local Rep this module otherwise decides.

import Compiler.RC2.RCExp
import Core.CompileExpr
import Core.TT

import Data.List
import Data.SortedSet

%default total

export
nativeEligible : PrimType -> Bool
nativeEligible IntType = True
nativeEligible Int8Type = True
nativeEligible Int16Type = True
nativeEligible Int32Type = True
nativeEligible Int64Type = True
nativeEligible Bits8Type = True
nativeEligible Bits16Type = True
nativeEligible Bits32Type = True
nativeEligible Bits64Type = True
nativeEligible DoubleType = True
nativeEligible CharType = True
nativeEligible _ = False

||| Comparison operand types a fused `RCmpCase` may take as plain Boxed
||| values (never native): the comparison is a C `int` over the operands
||| themselves (`idris2rc2_<op>_<ty>_raw`), see doc/native-type-inference.md.
export
boxedCmpEligible : PrimType -> Bool
boxedCmpEligible IntegerType = True
boxedCmpEligible StringType = True
boxedCmpEligible _ = False

ifNative : PrimType -> Maybe PrimType
ifNative ty = if nativeEligible ty then Just ty else Nothing

||| PrimTypes whose rc2 runtime representation is *always* a tagged
||| pointer (payload packed into the pointer word itself, see
||| support/rc2/idris2rc2_datatypes.h's module note), never a real heap
||| allocation -- unlike IntType/Int64Type/Bits64Type (which allocate
||| for values outside the small-int cache) or DoubleType (which always
||| allocates). idris2rc2_dup/idris2rc2_drop/idris2rc2_free on such a
||| value are unconditional runtime no-ops: the `idris2rc2_is_unboxed`
||| bit-check short-circuits before ever touching a refcount. Exported
||| so RC.idr's `alwaysUnboxedBoxedLocalsR` can identify *Boxed*
||| locals (typically function arguments -- the calling convention
||| itself is unchanged) that are nonetheless safe to exempt from
||| dup/drop entirely: not because they're natively-represented (they
||| still are `IDRIS2RC2_Value*` at the C level), but because those
||| calls on them were always going to be no-ops anyway, so generating
||| them at all is pure waste.
export
alwaysUnboxed : PrimType -> Bool
alwaysUnboxed Int8Type = True
alwaysUnboxed Int16Type = True
alwaysUnboxed Int32Type = True
alwaysUnboxed Bits8Type = True
alwaysUnboxed Bits16Type = True
alwaysUnboxed Bits32Type = True
alwaysUnboxed CharType = True
alwaysUnboxed _ = False

||| The `PrimFn`s whose Boxed result is *always* `idris2rc2_mkBool(..)`,
||| a tagged `Int8` immediate, never a heap value: the five comparisons,
||| whatever their operand type. Every `idris2rc2_{lt,gt,eq,lte,gte}_<T>`
||| in `support/rc2/idris2rc2_numeric.h` (the `IDRIS2RC2_CMPOP` macro for
||| the fixed-width and `Double`/`Char` types, and the hand-written
||| `Integer`/`string` ones) ends in `return idris2rc2_mkBool(..)`, so
||| dup/drop/free on the result are unconditional runtime no-ops, the
||| same fact `alwaysUnboxed` records for operand positions. Evidence
||| for RC.idr's `alwaysUnboxedBoxedLocalsR` is the *producer* (a `let`
||| bound to one of these), never how a local is later consumed. See
||| `rc2/doc/native-type-inference.md`.
export
boolResultOp : PrimFn arity -> Bool
boolResultOp (LT _)  = True
boolResultOp (LTE _) = True
boolResultOp (EQ _)  = True
boolResultOp (GTE _) = True
boolResultOp (GT _)  = True
boolResultOp _       = False

||| A `%foreign` argument/return `CFType`'s own native-eligible
||| `PrimType`, if any -- the FFI-boundary counterpart to
||| `nativeEligible` above, used by `Compiler.RC2.DualABI`'s FFI worker
||| synthesis (no function body to analyse there, unlike
||| `paramEligibility`/`returnEligibility` -- the C ABI a `%foreign`
||| declaration commits to already decides eligibility by itself).
||| `CFChar` included even though `Compiler.RC2.Emit.Util.nativeCType
||| CharType` (`uint32_t`, a full Idris `Char`'s own Unicode codepoint)
||| disagrees with `cTypeOfCFType CFChar` (a plain 1-byte C `char`,
||| also `Compiler.RC2.Emit.Util`) -- unlike every other case here,
||| where the two already agree and a native-eligible position can
||| cross into `%foreign`'s own call verbatim, `Compiler.RC2.Emit`'s
||| `emitFFIWorker` casts explicitly at that one call boundary instead
||| of skipping the conversion. Same narrowing a `CFChar` argument/return
||| already gets on the always-Boxed wrapper path (`idris2rc2_to_char`/
||| `idris2rc2_mkChar`), just paid as a register-width cast instead of a
||| box/unbox round trip.
export
cfTypeNative : CFType -> Maybe PrimType
cfTypeNative CFInt        = Just IntType
cfTypeNative CFInt8       = Just Int8Type
cfTypeNative CFInt16      = Just Int16Type
cfTypeNative CFInt32      = Just Int32Type
cfTypeNative CFInt64      = Just Int64Type
cfTypeNative CFUnsigned8  = Just Bits8Type
cfTypeNative CFUnsigned16 = Just Bits16Type
cfTypeNative CFUnsigned32 = Just Bits32Type
cfTypeNative CFUnsigned64 = Just Bits64Type
cfTypeNative CFDouble     = Just DoubleType
cfTypeNative CFChar       = Just CharType
cfTypeNative _            = Nothing

||| The PrimType a specific operand of `op` needs, given the op's own
||| result type `ty`: every operand shares `ty` except Cast's single
||| argument, whose *source* type is the op's own `i`, not `ty`. Shared
||| by RC.idr (deciding which Boxed operands are alwaysUnboxed) and
||| Emit.idr (rendering/unboxing each operand) so there's one definition
||| of this correspondence, not two kept in sync by hand.
export
opArgTyFor : PrimType -> PrimFn arity -> PrimType
opArgTyFor _ (Cast i _) = i
opArgTyFor ty _         = ty

||| The Rep a PrimFn's result would have, if native-eligible. Comparisons
||| are deliberately absent (always Boxed Bool in this increment).
export
opResultRep : PrimFn arity -> Maybe PrimType
opResultRep (Add ty) = ifNative ty
opResultRep (Sub ty) = ifNative ty
opResultRep (Mul ty) = ifNative ty
opResultRep (Div ty) = ifNative ty
opResultRep (Mod ty) = ifNative ty
opResultRep (Neg ty) = ifNative ty
opResultRep (ShiftL ty) = ifNative ty
opResultRep (ShiftR ty) = ifNative ty
opResultRep (BAnd ty) = ifNative ty
opResultRep (BOr ty) = ifNative ty
opResultRep (BXOr ty) = ifNative ty
-- Both sides must be native-eligible: unlike the other numeric ops (which
-- use one `ty` for both operand and result), Cast's *source* type `i` can
-- be something with no native representation at all (Integer's arbitrary
-- precision, or String) -- reading such a value "natively" would just
-- reinterpret its boxed pointer as an integer. Casts from those stay on
-- the existing fully-boxed idris2rc2_cast_* path.
opResultRep (Cast i o) = if nativeEligible i then ifNative o else Nothing
opResultRep DoubleExp = Just DoubleType
opResultRep DoubleLog = Just DoubleType
opResultRep DoublePow = Just DoubleType
opResultRep DoubleSin = Just DoubleType
opResultRep DoubleCos = Just DoubleType
opResultRep DoubleTan = Just DoubleType
opResultRep DoubleASin = Just DoubleType
opResultRep DoubleACos = Just DoubleType
opResultRep DoubleATan = Just DoubleType
opResultRep DoubleSqrt = Just DoubleType
opResultRep DoubleFloor = Just DoubleType
opResultRep DoubleCeiling = Just DoubleType
opResultRep _ = Nothing

||| The range of an immediate Int/Int64 or Integer, [-2^62, 2^62)
||| (doc/immediate-ints.md). An `Integer` in it is always immediate, so
||| such a literal is a C constant like any fixed-width one.
export
immInt64 : Integer -> Bool
immInt64 v = v >= -4611686018427387904 && v < 4611686018427387904

||| Exported so both RC.idr's `bindOne` (deciding whether a literal
||| operand needs an RCConst at all, see RCExp.idr's module note) and
||| Emit.idr's `repOfLocal` (rendering one) can share this single
||| source of truth instead of re-deriving it.
export
litRep : Constant -> Maybe PrimType
litRep (I _) = Just IntType
litRep (I8 _) = Just Int8Type
litRep (I16 _) = Just Int16Type
litRep (I32 _) = Just Int32Type
litRep (I64 _) = Just Int64Type
litRep (B8 _) = Just Bits8Type
litRep (B16 _) = Just Bits16Type
litRep (B32 _) = Just Bits32Type
litRep (B64 _) = Just Bits64Type
litRep (Db _) = Just DoubleType
litRep (Ch _) = Just CharType
litRep _ = Nothing

||| What Rep `e` would produce if it were bound directly by a let (only
||| ROp/RPrimVal ever propose Native -- everything else, including a bare
||| variable passthrough, stays Boxed in this increment). Called by
||| Compiler.RC2.RC right when it builds each RLet, so the result can be
||| stored on the node immediately -- see RCExp.Rep.
|||
||| `e` may itself be a chain of synthetic RLets (Compiler.RC2.RC's own
||| ANF-normalisation introduces one whenever an operand isn't already a
||| plain variable, e.g. the literal `2` in `d * 2`) wrapping the actual
||| ROp/RPrimVal -- see through those to find it.
export
repOf : RCExp -> Maybe PrimType
repOf (RLet _ _ _ _ body) = repOf body
repOf (ROp _ _ op _ _) = opResultRep op
repOf (RPrimVal _ c) = litRep c
repOf _ = Nothing

||| Every genuine `RCLoc` scrutinised by an `RConstCase` whose alts are all
||| constants of an `alwaysUnboxed` type (`B8`, `Char`, `Int8`...): by
||| Idris2's typing such a local holds a tagged immediate (a `Bool`, an
||| all-nullary enum or a `Bits8`), whatever its declared `Rep`, so
||| dup/drop/free on it are no-ops, as for `alwaysUnboxedBoxedLocalsR`'s
||| operands. Evidence is the alts' own constant kind (`litRep`), never a
||| bare `0`/`1`: an `Int` or `Nat` match has `I`/`BI` alts and does not
||| qualify. Only the unboxing decision uses this; the case itself, its
||| default branch included, is untouched. Switch: `--directive noboolcase`.
||| See `doc/native-type-inference.md`, "Typed-constant case scrutinees".
||| Shared by `RC.definitionNatives` and `DualABI`'s call-site rewrite, which
||| must not give such a local a `postDrop` `annotate` never paired with a dup.
export covering
typedConstScrutinees : RCExp -> SortedSet RCLocal
typedConstScrutinees e = go empty e
  where
    immediateAlts : List RConstAlt -> Bool
    immediateAlts [] = False
    immediateAlts alts = all (\(MkRConstAlt c _) => maybe False alwaysUnboxed (litRep c)) alts

    covering
    go : SortedSet RCLocal -> RCExp -> SortedSet RCLocal
    go acc (RConstCase fc sc alts mDef) =
        let acc' = case sc of
                        RCLoc _ => if immediateAlts alts then insert sc acc else acc
                        _ => acc
        in foldl go acc' (children (RConstCase fc sc alts mDef))
    go acc x = foldl go acc (children x)

||| Removes `imm`'s locals from every `RAppNameRep` `postDrop`. A local
||| `typedConstScrutinees` found is refcount-free for `annotate`, so no dup
||| pairs with the drop `DualABI`'s call-site rewrite adds for a Boxed
||| argument its worker reads natively. A no-op at run time (an immediate);
||| it keeps the IR consistent with `natives` for `rcexpr-lint`. Only
||| `postDrop`: the field `dup`/`drop`s that `ConAltNative` re-derives are
||| the follow-up in TODO.md.
export covering
stripImmediatePostDrop : SortedSet RCLocal -> RCExp -> RCExp
stripImmediatePostDrop imm e =
    if null (Prelude.toList imm) then e else go e
  where
    covering
    go : RCExp -> RCExp
    go (RAppNameRep fc n argReps retRep pd args) =
        RAppNameRep fc n argReps retRep (filter (\l => not (contains l imm)) pd) args
    go x = mapChildren go x
