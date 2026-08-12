module Compiler.RC2.Types

-- Pure, syntax-directed helpers for native type inference. Compiler.RC2.RC
-- calls `repOf` directly at each RLet it builds, during the Lifted ->
-- RCExp conversion itself -- there is no separate whole-tree analysis
-- pass, and no side table: the decided Rep is stored right on the RLet
-- node (see RCExp.idr).
--
-- Scope (see the project plan's Stage 3 note): this only ever proposes
-- Rep for *intermediate* let-bound locals coming directly from a numeric
-- PrimFn or a numeric literal -- function parameters and return values
-- stay boxed (the calling convention is unchanged). Even so, a chain of
-- arithmetic on an already-boxed input (e.g. `let y = x + 1; let z = y *
-- 2 in z`) now allocates zero intermediate boxed values instead of one
-- per operation: `x` is unboxed once, and `y`/`z` live as raw C locals
-- until they cross back over a boxed boundary (return, constructor field,
-- function argument, case scrutinee, ...), where Emit boxes them on the
-- spot. Comparisons (LT/GT/EQ/LTE/GTE) still always produce a boxed Bool
-- in this increment -- fusing them directly into C `if` conditions is
-- noted as future work in the project plan.

import Compiler.RC2.RCExp
import Core.CompileExpr
import Core.TT

%default covering

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

ifNative : PrimType -> Maybe PrimType
ifNative ty = if nativeEligible ty then Just ty else Nothing

||| PrimTypes whose rc2 runtime representation is *always* a tagged
||| pointer (payload packed into the pointer word itself, see
||| support/rc2/datatypes.h's module note), never a real heap
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
