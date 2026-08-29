module Compiler.RC2.EmitUtil

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- C-rendering primitives used by Compiler.RC2.Emit's own RCExp -> C
-- engine (split out of that module for size): name mangling and
-- literal/primop-to-C-text rendering, the module-state Ref tags
-- (ArgCounter/OutfileText/RepMap/etc.) and their small accessor
-- helpers, Boxed/native value-to-C-expression rendering
-- (rcVarToBoxedC/rcVarToNativeC), closure-building (makeClosure and
-- friends), case-alternative condition/chain rendering
-- (conAltCondExpr/emitAltChain), and the %foreign CFType<->C type
-- mapping (cTypeOfCFType/extractValue/packCFType/collectStructDefs).
-- Nothing in this module ever calls back into Compiler.RC2.Emit --
-- the dependency is one-directional, which is exactly what made this
-- split possible without a mutual-module cycle.

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Compiler.CompileExpr
import Compiler.Common
import Compiler.Generated

import Core.Directory
import Core.Context

import Idris.Syntax

import Libraries.Data.DList
import Data.List
import Data.List.Quantifiers
import Data.SortedSet
import Data.SortedMap
import Data.String
import Data.Vect

import Protocol.Hex
import Libraries.Utils.Path

import System
import System.File


%default covering

-- Name mangling (matches Compiler.RC2.RC2's original scheme, kept for
-- generated-symbol stability)

export
cCleanString : String -> String
cCleanString cs = showcCleanString (unpack cs) ""
  where
    showcCleanString : List Char -> String -> String
    showcCleanString [] = id
    showcCleanString (c ::cs) = (showcCleanStringChar c) . showcCleanString cs
      where
        showcCleanStringChar : Char -> String -> String
        showcCleanStringChar ' ' = ("_" ++)
        showcCleanStringChar '!' = ("_bang" ++)
        showcCleanStringChar '"' = ("_quotation" ++)
        showcCleanStringChar '#' = ("_number" ++)
        showcCleanStringChar '$' = ("_dollar" ++)
        showcCleanStringChar '%' = ("_percent" ++)
        showcCleanStringChar '&' = ("_and" ++)
        showcCleanStringChar '\'' = ("_tick" ++)
        showcCleanStringChar '(' = ("_parenOpen" ++)
        showcCleanStringChar ')' = ("_parenClose" ++)
        showcCleanStringChar '*' = ("_star" ++)
        showcCleanStringChar '+' = ("_plus" ++)
        showcCleanStringChar ',' = ("_comma" ++)
        showcCleanStringChar '-' = ("__" ++)
        showcCleanStringChar '.' = ("_dot" ++)
        showcCleanStringChar '/' = ("_slash" ++)
        showcCleanStringChar ':' = ("_colon" ++)
        showcCleanStringChar ';' = ("_semicolon" ++)
        showcCleanStringChar '<' = ("_lt" ++)
        showcCleanStringChar '=' = ("_eq" ++)
        showcCleanStringChar '>' = ("_gt" ++)
        showcCleanStringChar '?' = ("_question" ++)
        showcCleanStringChar '@' = ("_at" ++)
        showcCleanStringChar '[' = ("_bracketOpen" ++)
        showcCleanStringChar '\\' = ("_backslash" ++)
        showcCleanStringChar ']' = ("_bracketClose" ++)
        showcCleanStringChar '^' = ("_hat" ++)
        showcCleanStringChar '_' = ("_" ++)
        showcCleanStringChar '`' = ("_backquote" ++)
        showcCleanStringChar '{' = ("_braceOpen" ++)
        showcCleanStringChar '|' = ("_or" ++)
        showcCleanStringChar '}' = ("_braceClose" ++)
        showcCleanStringChar '~' = ("_tilde" ++)
        showcCleanStringChar c
           = if c < chr 32 || c > chr 126
                then (("u" ++ leftPad '0' 4 (asHex (cast c))) ++)
                else strCons c

||| Idris `Name` -> C identifier mangling. `export`ed for
||| `Compiler.RC2.DualABI`'s own reuse (Stage 4's own worker naming
||| embeds the *original* function's own mangled name -- see
||| `DualABI.idr`'s own `freshName` doc comment -- so a worker's own C
||| name is legible on sight instead of an opaque counter).
export
cName : Name -> String
cName (NS ns n) = cCleanString (showNSWithSep "_" ns) ++ "_" ++ cName n
cName (UN n) = cUserName n
  where
    cUserName : UserName -> String
    cUserName (Basic n) = cCleanString n
    cUserName (Field n) = "rec__" ++ cCleanString n
    cUserName Underscore = cCleanString "_"
cName (MN n i) = cCleanString n ++ "_" ++ cCleanString (show i)
cName (PV n d) = "pat__" ++ cName n
cName (DN _ n) = cName n
cName (Nested i n) = "n__" ++ cCleanString (show i) ++ "_" ++ cName n
cName (CaseBlock x y) = "case__" ++ cCleanString (show x) ++ "_" ++ cCleanString (show y)
cName (WithBlock x y) = "with__" ++ cCleanString (show x) ++ "_" ++ cCleanString (show y)
cName (Resolved i) = "fn__" ++ cCleanString (show i)

||| A C expression for `c`'s codepoint: a quoted char literal for
||| printable/alphanumeric chars (Idris's own `show` conveniently doubles
||| as valid C syntax for those), or a bare decimal codepoint otherwise.
||| Must NOT go through an intermediate `(char)` cast -- `char` is a
||| *signed* 8-bit type on most platforms, so for any codepoint above 127
||| (e.g. '\x9f' = 159) that cast reinterprets it as negative before it
||| gets used/widened again at the call site, corrupting the value (this
||| was a real bug: 159 became 4294967199 after `(uint32_t)(char)159`).
export
escapeChar : Char -> String
escapeChar c = if isAlphaNum c || isNL c
                  then show c
                  else show (ord c)

export
cStringQuoted : String -> String
cStringQuoted cs = strCons '"' (showCString (unpack cs) "\"")
  where
    showCChar : Char -> String -> String
    showCChar '\\' = ("\\\\" ++)
    showCChar c
       = if c < chr 32
            then (("\\x" ++ leftPad '0' 2 (asHex (cast c))) ++ "\"\"" ++)
            else if c < chr 127 then strCons c
            else if c < chr 65536 then (("\\u" ++ leftPad '0' 4 (asHex (cast c))) ++ "\"\"" ++)
            else (("\\U" ++ leftPad '0' 8 (asHex (cast c))) ++ "\"\"" ++)

    showCString : List Char -> String -> String
    showCString [] = id
    showCString ('"'::cs) = ("\\\"" ++) . showCString cs
    showCString (c ::cs) = (showCChar c) . showCString cs

export
showIntMin : Int -> String
showIntMin x = if x == -9223372036854775808
    then "INT64_MIN"
    else "INT64_C("++ show x ++")"

export
showInt64Min : Int64 -> String
showInt64Min x = if x == -9223372036854775808
    then "INT64_MIN"
    else "INT64_C("++ show x ++")"

export
cPrimType : PrimType -> String
cPrimType IntType = "Int64"
cPrimType Int8Type = "Int8"
cPrimType Int16Type = "Int16"
cPrimType Int32Type = "Int32"
cPrimType Int64Type = "Int64"
cPrimType IntegerType = "Integer"
cPrimType Bits8Type = "Bits8"
cPrimType Bits16Type = "Bits16"
cPrimType Bits32Type = "Bits32"
cPrimType Bits64Type = "Bits64"
cPrimType StringType = "string"
cPrimType CharType = "Char"
cPrimType DoubleType = "Double"
cPrimType WorldType = "void"

export
cOp : {0 arity : Nat} -> PrimFn arity -> Vect arity String -> String
cOp (Neg ty)      [x]       = "idris2rc2_negate_"  ++  cPrimType ty ++ "(" ++ x ++ ")"
cOp StrLength     [x]       = "idris2rc2_strLength(" ++ x ++ ")"
cOp StrHead       [x]       = "idris2rc2_strHead(" ++ x ++ ")"
cOp StrTail       [x]       = "idris2rc2_strTail(" ++ x ++ ")"
cOp StrReverse    [x]       = "idris2rc2_strReverse(" ++ x ++ ")"
cOp (Cast i o)    [x]       = "idris2rc2_cast_" ++ (cPrimType i) ++ "_to_" ++ (cPrimType o) ++ "(" ++ x ++ ")"
cOp DoubleExp     [x]       = "idris2rc2_mkDouble(exp(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleLog     [x]       = "idris2rc2_mkDouble(log(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoublePow     [x, y]    = "idris2rc2_mkDouble(pow(idris2rc2_to_double(" ++ x ++ "), idris2rc2_to_double(" ++ y ++ ")))"
cOp DoubleSin     [x]       = "idris2rc2_mkDouble(sin(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleCos     [x]       = "idris2rc2_mkDouble(cos(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleTan     [x]       = "idris2rc2_mkDouble(tan(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleASin    [x]       = "idris2rc2_mkDouble(asin(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleACos    [x]       = "idris2rc2_mkDouble(acos(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleATan    [x]       = "idris2rc2_mkDouble(atan(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleSqrt    [x]       = "idris2rc2_mkDouble(sqrt(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleFloor   [x]       = "idris2rc2_mkDouble(floor(idris2rc2_to_double(" ++ x ++ ")))"
cOp DoubleCeiling [x]       = "idris2rc2_mkDouble(ceil(idris2rc2_to_double(" ++ x ++ ")))"
cOp (Add ty)      [x, y]    = "idris2rc2_add_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (Sub ty)      [x, y]    = "idris2rc2_sub_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (Mul ty)      [x, y]    = "idris2rc2_mul_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (Div ty)      [x, y]    = "idris2rc2_div_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (Mod ty)      [x, y]    = "idris2rc2_mod_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (ShiftL ty)   [x, y]    = "idris2rc2_shiftl_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (ShiftR ty)   [x, y]    = "idris2rc2_shiftr_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (BAnd ty)     [x, y]    = "idris2rc2_and_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (BOr ty)      [x, y]    = "idris2rc2_or_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (BXOr ty)     [x, y]    = "idris2rc2_xor_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (LT ty)       [x, y]    = "idris2rc2_lt_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (GT ty)       [x, y]    = "idris2rc2_gt_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (EQ ty)       [x, y]    = "idris2rc2_eq_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (LTE ty)      [x, y]    = "idris2rc2_lte_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp (GTE ty)      [x, y]    = "idris2rc2_gte_" ++ cPrimType ty ++ "(" ++ x ++ ", " ++ y ++ ")"
cOp StrIndex      [x, i]    = "idris2rc2_strIndex(" ++ x ++ ", " ++ i ++ ")"
cOp StrCons       [x, y]    = "idris2rc2_strCons(" ++ x ++ ", " ++ y ++ ")"
cOp StrAppend     [x, y]    = "idris2rc2_strAppend(" ++ x ++ ", " ++ y ++ ")"
cOp StrSubstr     [x, y, z] = "idris2rc2_strSubstr(" ++ x ++ ", " ++ y  ++ ", " ++ z ++ ")"
cOp BelieveMe     [_, _, x] = "idris2rc2_dup(" ++ x ++ ")"
cOp Crash         [_, msg]  = "idris2rc2_crash(" ++ msg ++ ");"
cOp fn args = show fn ++ "(" ++ (showSep ", " $ toList args) ++ ")"

||| `True` for the Boxed `PrimFn`s whose own runtime primitive
||| (`rc2/support/rc2/numeric.h`) now consumes every operand it's handed
||| -- reusing a uniquely-referenced one's own heap storage in place
||| instead of allocating fresh, and dropping whichever operand it didn't
||| reuse itself -- rather than only reading its operands and leaving
||| ownership to the caller. `Compiler.RC2.Emit`'s `ROp` case uses this to
||| skip emitting its usual post-call drops for such an op's own operands
||| (the runtime primitive already disposed of them); see
||| rc2/doc/rop-reuse.md.
|||
||| `IntegerType` (GMP `mpz_t`-backed) covers every arithmetic/bitwise op
||| except `Div` -- `idris2rc2_div_Integer` is a real multi-statement
||| Euclidean-division algorithm in `numeric.c`, not yet given this
||| treatment. `Int64Type`/`Bits64Type` (genuinely heap-allocated once
||| past the small-int cache) and `DoubleType` (never cached, always a
||| real heap struct when Boxed) cover every op their own `PrimType` has
||| in the first place -- `Int8Type`/`Int16Type`/`Int32Type`/
||| `Bits8Type`/`Bits16Type`/`Bits32Type` are deliberately excluded
||| entirely: `Types.alwaysUnboxed` already means these are *always* a
||| tagged pointer at the C level, never a real heap allocation, so
||| `idris2rc2_isUnique` (a raw `->header.refCount` read) would be
||| undefined behaviour on one, and the existing `alwaysUnboxed` dup/drop
||| elision (`Compiler.RC2.RC`'s `alwaysUnboxedBoxedLocalsR`) already
||| means there's no post-call drop left to skip for them anyway.
|||
||| `IntType` (Idris2's plain, machine-width `Int`) is included alongside
||| every `Int64Type` case, not because it's itself reuse-eligible by
||| some separate reasoning, but because `EmitUtil.cPrimType` maps BOTH
||| to the identical C name (`"Int64"`) -- `Add IntType` and `Add
||| Int64Type` both lower to a call to the exact same
||| `idris2rc2_add_Int64`. Missing either one here would leave `Emit.idr`
||| still emitting its own old explicit post-call drop for that op's
||| operands on top of the now-consuming primitive's own internal drop:
||| a double-drop/use-after-free, not merely a missed optimisation.
export
isReuseConsumingOp : PrimFn arity -> Bool
isReuseConsumingOp (Add IntegerType)  = True
isReuseConsumingOp (Sub IntegerType)  = True
isReuseConsumingOp (Mul IntegerType)  = True
isReuseConsumingOp (Mod IntegerType)  = True
isReuseConsumingOp (Neg IntegerType)  = True
isReuseConsumingOp (BAnd IntegerType) = True
isReuseConsumingOp (BOr IntegerType)  = True
isReuseConsumingOp (BXOr IntegerType) = True
isReuseConsumingOp (ShiftL IntegerType) = True
isReuseConsumingOp (ShiftR IntegerType) = True
isReuseConsumingOp (Add Int64Type)    = True
isReuseConsumingOp (Sub Int64Type)    = True
isReuseConsumingOp (Mul Int64Type)    = True
isReuseConsumingOp (Div Int64Type)    = True
isReuseConsumingOp (Mod Int64Type)    = True
isReuseConsumingOp (Neg Int64Type)    = True
isReuseConsumingOp (BAnd Int64Type)   = True
isReuseConsumingOp (BOr Int64Type)    = True
isReuseConsumingOp (BXOr Int64Type)   = True
isReuseConsumingOp (ShiftL Int64Type) = True
isReuseConsumingOp (ShiftR Int64Type) = True
isReuseConsumingOp (Add IntType)    = True
isReuseConsumingOp (Sub IntType)    = True
isReuseConsumingOp (Mul IntType)    = True
isReuseConsumingOp (Div IntType)    = True
isReuseConsumingOp (Mod IntType)    = True
isReuseConsumingOp (Neg IntType)    = True
isReuseConsumingOp (BAnd IntType)   = True
isReuseConsumingOp (BOr IntType)    = True
isReuseConsumingOp (BXOr IntType)   = True
isReuseConsumingOp (ShiftL IntType) = True
isReuseConsumingOp (ShiftR IntType) = True
isReuseConsumingOp (Add Bits64Type)    = True
isReuseConsumingOp (Sub Bits64Type)    = True
isReuseConsumingOp (Mul Bits64Type)    = True
isReuseConsumingOp (Div Bits64Type)    = True
isReuseConsumingOp (Mod Bits64Type)    = True
isReuseConsumingOp (BAnd Bits64Type)   = True
isReuseConsumingOp (BOr Bits64Type)    = True
isReuseConsumingOp (BXOr Bits64Type)   = True
isReuseConsumingOp (ShiftL Bits64Type) = True
isReuseConsumingOp (ShiftR Bits64Type) = True
isReuseConsumingOp (Add DoubleType) = True
isReuseConsumingOp (Sub DoubleType) = True
isReuseConsumingOp (Mul DoubleType) = True
isReuseConsumingOp (Div DoubleType) = True
isReuseConsumingOp (Neg DoubleType) = True
isReuseConsumingOp _ = False

export
varName : RCLocal -> String
varName (RCLoc i) = "var_" ++ (show i)
varName (RCNull)  = "NULL"
-- Unreachable in practice: repOfLocal/inlineExprFor always intercept an
-- RCConst before anything falls back to reading its "variable name" (it
-- never had one -- see RCExp.idr's module note). Kept total regardless.
varName (RCConst _) = "/* [rc2] unreachable RCConst varName */"
-- Unlike RCConst, this *is* the real rendering path (not just a
-- defensive fallback): a nullary constructor's value is already
-- Value*-shaped, not a native scalar that would need boxing via
-- nativeMk, so it needs no RNative/InlineMap detour -- just a bare
-- tagged-pointer constant expression, exactly like RCNull's "NULL"
-- above. Reuses idris2rc2_mkBits32 as-is (identical bit pattern to a
-- dedicated constructor-tag encoding, and every constructor tag fits
-- comfortably in 32 bits) rather than adding a new runtime function.
varName (RCEmptyCon _ _ tag) = "idris2rc2_mkBits32(\{show tag})"
-- Unreachable in practice, same reasoning as RCConst above:
-- repOfLocal/inlineExprFor always intercept a RCConstCon first.
varName (RCConstCon {}) = "/* [rc2] unreachable RCConstCon varName */"

------------------------------------------------------------------------
-- Native (unboxed) codegen, driven by Compiler.RC2.Types' Rep inference.

export
nativeCType : PrimType -> String
nativeCType IntType = "int64_t"
nativeCType Int8Type = "int8_t"
nativeCType Int16Type = "int16_t"
nativeCType Int32Type = "int32_t"
nativeCType Int64Type = "int64_t"
nativeCType Bits8Type = "uint8_t"
nativeCType Bits16Type = "uint16_t"
nativeCType Bits32Type = "uint32_t"
nativeCType Bits64Type = "uint64_t"
nativeCType DoubleType = "double"
nativeCType CharType = "uint32_t"
nativeCType _ = "void*" -- unreachable: Types.nativeEligible excludes these

export
nativeMk : PrimType -> String -> String
nativeMk IntType x = "idris2rc2_mkInt64(" ++ x ++ ")"
nativeMk Int8Type x = "idris2rc2_mkInt8(" ++ x ++ ")"
nativeMk Int16Type x = "idris2rc2_mkInt16(" ++ x ++ ")"
nativeMk Int32Type x = "idris2rc2_mkInt32(" ++ x ++ ")"
nativeMk Int64Type x = "idris2rc2_mkInt64(" ++ x ++ ")"
nativeMk Bits8Type x = "idris2rc2_mkBits8(" ++ x ++ ")"
nativeMk Bits16Type x = "idris2rc2_mkBits16(" ++ x ++ ")"
nativeMk Bits32Type x = "idris2rc2_mkBits32(" ++ x ++ ")"
nativeMk Bits64Type x = "idris2rc2_mkBits64(" ++ x ++ ")"
nativeMk DoubleType x = "idris2rc2_mkDouble(" ++ x ++ ")"
nativeMk CharType x = "idris2rc2_mkChar(" ++ x ++ ")"
nativeMk _ x = x -- unreachable

export
nativeUnbox : PrimType -> String -> String
nativeUnbox IntType x = "idris2rc2_to_i64(" ++ x ++ ")"
nativeUnbox Int8Type x = "idris2rc2_to_i8(" ++ x ++ ")"
nativeUnbox Int16Type x = "idris2rc2_to_i16(" ++ x ++ ")"
nativeUnbox Int32Type x = "idris2rc2_to_i32(" ++ x ++ ")"
nativeUnbox Int64Type x = "idris2rc2_to_i64(" ++ x ++ ")"
nativeUnbox Bits8Type x = "idris2rc2_to_u8(" ++ x ++ ")"
nativeUnbox Bits16Type x = "idris2rc2_to_u16(" ++ x ++ ")"
nativeUnbox Bits32Type x = "idris2rc2_to_u32(" ++ x ++ ")"
nativeUnbox Bits64Type x = "idris2rc2_to_u64(" ++ x ++ ")"
nativeUnbox DoubleType x = "idris2rc2_to_double(" ++ x ++ ")"
nativeUnbox CharType x = "idris2rc2_to_char(" ++ x ++ ")"
nativeUnbox _ x = x -- unreachable

export
isSigned : PrimType -> Bool
isSigned IntType = True
isSigned Int8Type = True
isSigned Int16Type = True
isSigned Int32Type = True
isSigned Int64Type = True
isSigned _ = False

-- Bit width suffix for the idris2rc2_ediv_iN/idris2rc2_emod_iN family
-- (signed Euclidean division/modulo), shared by nativeOpExpr's Div and
-- Mod cases below.
export
intBits : PrimType -> String
intBits IntType = "64"; intBits Int8Type = "8"; intBits Int16Type = "16"
intBits Int32Type = "32"; intBits Int64Type = "64"; intBits _ = "64"

export
nativeOpExpr : {0 arity : Nat} -> PrimFn arity -> Vect arity String -> String
nativeOpExpr (Add ty)    [x, y] = "(" ++ x ++ " + " ++ y ++ ")"
nativeOpExpr (Sub ty)    [x, y] = "(" ++ x ++ " - " ++ y ++ ")"
nativeOpExpr (Mul ty)    [x, y] = "(" ++ x ++ " * " ++ y ++ ")"
nativeOpExpr (Div ty)    [x, y] =
    if isSigned ty then "idris2rc2_ediv_i" ++ intBits ty ++ "(" ++ x ++ ", " ++ y ++ ")"
                   else "(" ++ x ++ " / " ++ y ++ ")"
nativeOpExpr (Mod ty)    [x, y] =
    if isSigned ty then "idris2rc2_emod_i" ++ intBits ty ++ "(" ++ x ++ ", " ++ y ++ ")"
                   else "(" ++ x ++ " % " ++ y ++ ")"
nativeOpExpr (Neg ty)    [x]    = "(-(" ++ x ++ "))"
nativeOpExpr (ShiftL ty) [x, y] = "(" ++ x ++ " << " ++ y ++ ")"
nativeOpExpr (ShiftR ty) [x, y] = "(" ++ x ++ " >> " ++ y ++ ")"
nativeOpExpr (BAnd ty)   [x, y] = "(" ++ x ++ " & " ++ y ++ ")"
nativeOpExpr (BOr ty)    [x, y] = "(" ++ x ++ " | " ++ y ++ ")"
nativeOpExpr (BXOr ty)   [x, y] = "(" ++ x ++ " ^ " ++ y ++ ")"
-- A bare C cast to uint32_t would just reinterpret whatever bits
-- survive truncation as a codepoint; Char casts need the same
-- Unicode-scalar-range validation Compiler.RC2.Types.cfTypeNative's
-- own doc comment and support/rc2/numeric.h's boxed
-- idris2rc2_cast_*_to_Char already give the Boxed path, or this native
-- path (reachable whenever every operand of the cast chain is itself
-- native-eligible, e.g. two Int32/Bits32 literals) would silently
-- disagree with it for the exact same source expression.
nativeOpExpr (Cast i CharType) [x] = "idris2rc2_charFromCodepoint((int64_t)(" ++ x ++ "))"
nativeOpExpr (Cast i o)  [x]    = "((" ++ nativeCType o ++ ")(" ++ x ++ "))"
nativeOpExpr DoubleExp     [x] = "exp(" ++ x ++ ")"
nativeOpExpr DoubleLog     [x] = "log(" ++ x ++ ")"
nativeOpExpr DoublePow  [x, y] = "pow(" ++ x ++ ", " ++ y ++ ")"
nativeOpExpr DoubleSin     [x] = "sin(" ++ x ++ ")"
nativeOpExpr DoubleCos     [x] = "cos(" ++ x ++ ")"
nativeOpExpr DoubleTan     [x] = "tan(" ++ x ++ ")"
nativeOpExpr DoubleASin    [x] = "asin(" ++ x ++ ")"
nativeOpExpr DoubleACos    [x] = "acos(" ++ x ++ ")"
nativeOpExpr DoubleATan    [x] = "atan(" ++ x ++ ")"
nativeOpExpr DoubleSqrt    [x] = "sqrt(" ++ x ++ ")"
nativeOpExpr DoubleFloor   [x] = "floor(" ++ x ++ ")"
nativeOpExpr DoubleCeiling [x] = "ceil(" ++ x ++ ")"
nativeOpExpr fn args = "0 /* [rc2] unreachable native op " ++ show fn ++ " */"

||| The raw C boolean expression for a fused comparison (RCmpCase) --
||| `x`/`y` are already-native-or-unboxed operand expressions (see
||| `rcVarToNativeC`), same convention as `nativeOpExpr`. Unlike `cOp`'s
||| own LT/GT/EQ/LTE/GTE handling (which calls a runtime function
||| returning a freshly boxed Bool), this never allocates -- it's only
||| ever embedded directly as an `if` condition by `emitRC`'s own
||| RCmpCase case, the comparison's result never becomes a value at all.
export
nativeCmpExpr : PrimFn 2 -> Vect 2 String -> String
nativeCmpExpr (LT ty)  [x, y] = "(" ++ x ++ " < "  ++ y ++ ")"
nativeCmpExpr (GT ty)  [x, y] = "(" ++ x ++ " > "  ++ y ++ ")"
nativeCmpExpr (EQ ty)  [x, y] = "(" ++ x ++ " == " ++ y ++ ")"
nativeCmpExpr (LTE ty) [x, y] = "(" ++ x ++ " <= " ++ y ++ ")"
nativeCmpExpr (GTE ty) [x, y] = "(" ++ x ++ " >= " ++ y ++ ")"
nativeCmpExpr fn _ = "0 /* [rc2] unreachable native comparison " ++ show fn ++ " */"


export
nativeLitExpr : Constant -> String
nativeLitExpr (I x) = showIntMin x
nativeLitExpr (I8 x) = "INT8_C(\{show x})"
nativeLitExpr (I16 x) = "INT16_C(\{show x})"
nativeLitExpr (I32 x) = "INT32_C(\{show x})"
nativeLitExpr (I64 x) = showInt64Min x
nativeLitExpr (B8 x) = "UINT8_C(\{show x})"
nativeLitExpr (B16 x) = "UINT16_C(\{show x})"
nativeLitExpr (B32 x) = "UINT32_C(\{show x})"
nativeLitExpr (B64 x) = "UINT64_C(\{show x})"
nativeLitExpr (Db x) = show x
nativeLitExpr (Ch x) = "((uint32_t)" ++ escapeChar x ++ ")"
nativeLitExpr _ = "0 /* [rc2] unreachable native literal */"

export
data ArgCounter : Type where
export
data FunctionDefinitions : Type where
export
data IndentLevel : Type where
export
data HeaderFiles : Type where
export
data ForeignLibs : Type where
-- Raw C text from `%cg rc2 extraRuntime=<path>`/`inlineRuntime=<code>`
-- (Compiler.RC2.RC2's own `compileExpr`), spliced verbatim by `header`
-- right after the `#include`s and before any generated definition --
-- see the README's own "%cg rc2 directives" section for the design.
export
data InjectedRuntime : Type where
-- The nearest enclosing `RLoop`'s own loop params (id + Rep), in order
-- -- empty until `emitLoopInto` actually enters one, consulted only by
-- `tryEmitLoopContinue`'s own `RLoopContinue` case to know which
-- var_N to reassign (boxed or native, per each param's own `Rep`) for
-- each new value (`RLoopContinue`'s own arg list is guaranteed the same
-- length and order by construction, see its doc comment in RCExp.idr).
export
data LoopParams : Type where
export
data RepMap : Type where
-- Native-rep locals whose defining expression is safe and worthwhile to
-- splice directly into their (sole) use site instead of ever being
-- declared as a C variable at all -- holds the already-rendered C
-- expression text, keyed by local id. Two cases populate this:
--   1. A bare literal (Compiler.RC2.RC's Phase 1 binds *every*
--      non-trivial operand -- including literal constants -- to a fresh
--      let, purely for ANF shape; there's no sharing/evaluation-order
--      reason to actually declare a C variable for a literal).
--   2. A native op Compiler.RC2.RC's `annotate` decided is `RInlineNative`
--      (see Rep's own doc comment): no Boxed operands at all, and used
--      exactly once. Restricting to zero Boxed operands is what makes
--      this always safe to defer: every value such an op reads is
--      either another already-computed, stable native local (a
--      declared `var_N`, or itself a further InlineMap entry, so
--      transitively still never a Boxed read) or a literal -- nothing
--      that a dup/drop anywhere else in the function could invalidate
--      by the time the deferred read actually happens. Restricting to
--      exactly one use is what keeps this free -- inlining a multi-use
--      value would duplicate its computation. Unlike case 1 (a Phase 1
--      decision), this one is decided by Phase 2 -- postDrop/use-counts
--      aren't known yet during Phase 1's own conversion.
-- Consulted by rcVarToNativeC/rcVarToBoxedC so *uses* of such a local
-- inline its expression text directly instead of reading back a
-- pointless `var_N`.
export
data InlineMap : Type where
-- Struct name -> field name/type list, collected once (Part B,
-- generateCSourceFile) from every %foreign def's own CFStruct before
-- any RStructGet/RStructSet is lowered, and consulted by both `header`
-- (to emit each struct's own C `typedef`) and emitRC's own
-- RStructGet/RStructSet cases (to resolve a field's CFType). See
-- doc/c-struct-support.md's "Design" section, Parts B/C/D.
export
data StructDefs : Type where
-- `%foreign` name -> (worker C name, per-argument Rep, return Rep),
-- computed once up front by `Compiler.RC2.DualABI`'s `ffiWorkerTable`
-- and threaded straight through -- unlike `Compiler.RC2.DualABI`'s own
-- `MkRCFun` worker table (recovered by scanning a wrapper's own
-- `RAppNameRep` body), a `MkRCForeign` has no body to scan, so this is
-- genuine external state rather than something `createCFunctions`
-- could derive from `defs` alone. Consulted by `createCFunctions`'s
-- own `MkRCForeign` case to decide whether (and under what name/
-- signature) to emit a second, native-signature worker alongside the
-- always-emitted, always-Boxed wrapper -- see `doc/dual-abi.md`'s
-- "Stage 3c" section.
export
data FFIWorkers : Type where
export
data ConstDef
  = CDI64 String
  | CDB64 String
  | CDDb  String
  | CDStr String

||| State for `RCConstCon` staging (`boxedConstConExpr`): a lookup from
||| already-staged value to its file-scope static's name (dedup, same
||| role as `ConstDef`'s own `SortedMap`), paired with the finished C
||| definition text for each staged value *in staging order* -- always
||| children-before-parents, since `boxedConstConExpr` stages a nested
||| `RCConstCon` field before appending its own definition, and a C
||| static initializer can only take the address of an already-declared
||| static. `header` emits this list as-is, no further reordering.
export
data ConstConDef : Type where

export
constantName : ConstDef -> String
constantName = \case
  CDI64 x => go "Int64" x
  CDB64 x => go "Bits64" x
  CDDb x  => go "Double" x
  CDStr x => go "String" x
  where go : String -> String -> String
        go x y = "idris2rc2_constant_\{x}_\{y}"

------------------------------------------------------------------------

export
data OutfileText : Type where

public export
Output : Type
Output = DList String

------------------------------------------------------------------------

export
getNextCounter : {auto a : Ref ArgCounter Nat} -> Core String
getNextCounter = do
    c <- get ArgCounter
    put ArgCounter (S c)
    pure $ show c

export
getNewVarThatWillNotBeFreedAtEndOfBlock : {auto a : Ref ArgCounter Nat} -> Core String
getNewVarThatWillNotBeFreedAtEndOfBlock = pure $ "tmp_" ++ !(getNextCounter)

export
maxLineLengthForComment : Nat
maxLineLengthForComment = 60

export
lJust : (line:String) -> (fillPos:Nat) -> (filler:Char) -> String
lJust line fillPos filler =
    let n = length line in
    case isLTE n fillPos of
        (Yes prf) =>
            let missing = minus fillPos n
                fillBlock = pack (replicate missing filler)
            in
            line ++ fillBlock
        (No _) => line

export
increaseIndentation : {auto il : Ref IndentLevel Nat} -> Core ()
increaseIndentation = update IndentLevel S

export
decreaseIndentation : {auto il : Ref IndentLevel Nat} -> Core ()
decreaseIndentation = update IndentLevel pred

export
indentation : {auto il : Ref IndentLevel Nat} -> Core String
indentation = do
    iLevel <- get IndentLevel
    pure $ pack $ replicate (4 * iLevel) ' '

export
emit
  : {auto oft : Ref OutfileText Output} ->
    {auto il : Ref IndentLevel Nat} ->
    FC -> String -> Core ()
emit EmptyFC line = do
    indent <- indentation
    update OutfileText (flip snoc (indent ++ line))
emit fc line = do
    let comment = "// " ++ show fc
    indent <- indentation
    let indentedLine = indent ++ line
    update OutfileText $ case isLTE (length indentedLine) maxLineLengthForComment of
        (Yes _) => flip snoc (lJust indentedLine maxLineLengthForComment ' ' ++ " " ++ comment)
        (No _)  => flip appendR [indentedLine, (lJust ""   maxLineLengthForComment ' ' ++ " " ++ comment)]

export
applyFunctionToVars : {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> String
                    -> List String
                    -> Core ()
applyFunctionToVars fun vars = traverse_ (\v => emit EmptyFC $ fun ++ "(" ++ v ++ ");" ) vars

export
removeVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
removeVars = applyFunctionToVars "idris2rc2_drop"

export
dupVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
dupVars = applyFunctionToVars "idris2rc2_dup"

export
freeVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
freeVars = applyFunctionToVars "idris2rc2_free"

export
removeReuseConstructors : {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> List String
                        -> Core ()
removeReuseConstructors = applyFunctionToVars "idris2rc2_dropReuseConstructor"

export
repOfLocal : {auto r : Ref RepMap (SortedMap Int Rep)} -> RCLocal -> Core Rep
repOfLocal RCNull = pure RBoxed
-- RC.idr's bindOne only ever produces RCConst for a litRep-covered
-- (native-eligible) Constant -- see RCExp.idr's module note -- so this
-- is always RNative in practice; the RBoxed fallback is unreachable
-- defensive totality, not a real code path.
repOfLocal (RCConst c) = pure $ maybe RBoxed RNative (litRep c)
-- Always Boxed, same as RCNull -- its value is already a valid Value*
-- (a tagged pointer, per varName above), never a native scalar.
repOfLocal (RCEmptyCon {}) = pure RBoxed
-- Always Boxed -- a staged static IDRIS2RC2_Constructor is a real
-- Value*, same as any other heap constructor, never a native scalar.
repOfLocal (RCConstCon {}) = pure RBoxed
repOfLocal (RCLoc i) = do
    reps <- get RepMap
    pure $ fromMaybe RBoxed (SortedMap.lookup i reps)

||| The boxed C expression for constant `c`: a reference to an
||| already-staged file-scope static (`ConstDef`, if this exact value
||| has been staged before -- deduplicates across the *whole
||| compilation unit*, not just one definition), or (`dyngen`) a
||| small-value cache lookup, a fresh stage-and-reference (`orStagen`),
||| or -- values with neither available -- a fresh allocation minted
||| right here every time it's evaluated. Shared by `emitRC`'s own
||| `RPrimVal` case (an ordinary let-bound literal) and
||| `inlineExprFor`'s `RCConst` case (a non-native-eligible literal
||| RC.idr's `bindOne` decided needs no let-binding at all -- currently
||| only `Str` and a small-range `BI`, both of which always land in the
||| small-cache/`orStagen` branches below, never the "fresh allocation
||| every read" `BI`-outside-the-cache one -- see `bindOne`'s own
||| comment for why that one is deliberately excluded from RCConst).
export
boxedConstExpr : {auto a : Ref ArgCounter Nat}
              -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
              -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
              -> Constant -> Core String
boxedConstExpr c = do
    constdefs <- get ConstDef
    case lookup c constdefs of
         Just cdef => pure "((IDRIS2RC2_Value*)&\{constantName cdef})"
         Nothing => dyngen
  where
    orStagen : ConstDef -> Core String
    orStagen cdef = do
        constdefs <- get ConstDef
        put ConstDef $ insert c cdef constdefs
        pure "((IDRIS2RC2_Value*)&\{constantName cdef})"
    dyngen : Core String
    dyngen = case c of
        I x => if x >= 0 && x < 100
            then pure "(IDRIS2RC2_Value*)(&idris2rc2_smallInt64[\{show x}])"
            else orStagen $ CDI64 $ cCleanString $ show x
        I8 x  => pure "idris2rc2_mkInt8(INT8_C(\{show x}))"
        I16 x => pure "idris2rc2_mkInt16(INT16_C(\{show x}))"
        I32 x => pure "idris2rc2_mkInt32(INT32_C(\{show x}))"
        I64 x => if x >= 0 && x < 100
            then pure "(IDRIS2RC2_Value*)(&idris2rc2_smallInt64[\{show x}])"
            else orStagen $ CDI64 $ cCleanString $ show x
        BI x => if x >= 0 && x < 100
            then pure "idris2rc2_getSmallInteger(\{show x})"
            else pure "idris2rc2_mkIntegerLiteral(\"\{show x}\")"
        B8 x  => pure "idris2rc2_mkBits8(UINT8_C(\{show x}))"
        B16 x => pure "idris2rc2_mkBits16(UINT16_C(\{show x}))"
        B32 x => pure "idris2rc2_mkBits32(UINT32_C(\{show x}))"
        B64 x => if x >= 0 && x < 100
           then pure "(IDRIS2RC2_Value*)(&idris2rc2_smallBits64[\{show x}])"
           else orStagen $ CDB64 $ show x
        Db x => orStagen $ CDDb $ cCleanString $ show x
        Ch x  => pure "idris2rc2_mkChar(\{escapeChar x})"
        Str _ => orStagen $ CDStr !(getNextCounter)
        PrT t => pure $ cPrimType t
        WorldVal => pure "(NULL /* World */)"

mutual
    ||| C initializer text for one `RCConstCon` field: `l` is always
    ||| already one of `RCLocal`'s constant forms, enforced by `prf`
    ||| (`IsAnyConstLocal`, RCExp.idr) rather than a runtime check -- an
    ||| `RCLoc` can't reach here at all, so there's no case for it and
    ||| no crash to write. `RCNull`/`RCEmptyCon` render exactly as
    ||| `varName` would (they're never InlineMap'd -- no detour
    ||| needed); `RCConst` goes through `boxedConstExpr`, the same
    ||| staging a let-bound literal of the same value would use; a
    ||| nested `RCConstCon` stages itself first via `boxedConstConExpr`,
    ||| which requires the narrower `IsConstLocal` (a fresh `ItIsConstCon`
    ||| built here, not unwrapped from `prf` -- see its own doc comment).
    constConFieldExpr : {auto a : Ref ArgCounter Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                     -> (l : RCLocal) -> {0 prf : IsAnyConstLocal l} -> Core String
    constConFieldExpr RCNull               = pure "NULL"
    constConFieldExpr (RCConst c)          = boxedConstExpr c
    constConFieldExpr (RCEmptyCon _ _ tag) = pure "idris2rc2_mkBits32(\{show tag})"
    constConFieldExpr l@(RCConstCon {})    = boxedConstConExpr l {prf=ItIsConstCon}
    constConFieldExpr (RCLoc _) {prf=_} impossible

    ||| Walks `args` alongside its own `All` proof so each element's
    ||| individual `IsAnyConstLocal` witness reaches `constConFieldExpr`.
    ||| The proof stays erased (`0`) the whole way down -- Idris2 still
    ||| lets an erased value be pattern-matched to guide which case of
    ||| a *callee* runs (here, which `constConFieldExpr` clause), as
    ||| long as nothing downstream ever treats the matched pieces as a
    ||| kept value.
    constConFieldExprsFor : {auto a : Ref ArgCounter Nat}
                          -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                          -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                          -> (args : List RCLocal) -> (0 argsConst : All IsAnyConstLocal args) -> Core (List String)
    constConFieldExprsFor [] [] = pure []
    constConFieldExprsFor (l :: ls) (p :: ps) = do
        e  <- constConFieldExpr l {prf=p}
        es <- constConFieldExprsFor ls ps
        pure (e :: es)

    ||| The boxed C expression for constant constructor value `l` (an
    ||| `RCConstCon` -- see `Compiler.RC2.ConstFold`): a reference to an
    ||| already-staged file-scope static (deduplicates across the whole
    ||| compilation unit, same as `boxedConstExpr`), or a fresh stage-
    ||| then-reference otherwise. The staged static mirrors
    ||| `IDRIS2RC2_Constructor`'s own layout field-for-field (see
    ||| `emitRC`'s `RCon` case for the dynamic-allocation equivalent)
    ||| but as a fixed-size array instead of a flexible array member --
    ||| plain C has no static initializer for a flexible array member --
    ||| and stamps `IDRIS2RC2_STOCKVAL` (the same immortal-refcount
    ||| marker the small-int cache and `ConstDef` values already use)
    ||| instead of the `refCount = 1` a fresh heap allocation gets.
    ||| `prf`'s type (`IsConstLocal`, narrower than `IsAnyConstLocal`
    ||| above) targets `RCConstCon` alone, so every other `RCLocal`
    ||| constructor is ill-typed here -- no runtime fallback needed.
    boxedConstConExpr : {auto a : Ref ArgCounter Nat}
                      -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                      -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                      -> (l : RCLocal) -> {0 prf : IsConstLocal l} -> Core String
    boxedConstConExpr l@(RCConstCon n _ tag args {argsConst}) {prf=ItIsConstCon} = do
        (names, _) <- get ConstConDef
        case lookup l names of
             Just nm => pure "((IDRIS2RC2_Value*)&\{nm})"
             Nothing => do
                 argExprs <- constConFieldExprsFor args argsConst
                 nm <- ("constcon_" ++) <$> getNextCounter
                 let nameField = maybe "idris2rc2_constr_\{cName n}" (const "NULL") tag
                 let tagField = maybe "-1" show tag
                 let def = "static struct { IDRIS2RC2_Header header; int32_t arity; int32_t tag; char const *name; IDRIS2RC2_Value *args[\{show (length args)}]; } const \{nm} = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_CONSTRUCTOR), \{show (length args)}, \{tagField}, \{nameField}, { \{showSep ", " argExprs} } };"
                 (names', defs') <- get ConstConDef
                 put ConstConDef (insert l nm names', defs' ++ [def])
                 pure "((IDRIS2RC2_Value*)&\{nm})"

||| `Just` the C expression text standing in for `l`'s never-declared
||| variable if it's an InlineMap-registered local, or an RCConst (see
||| InlineMap's and RCLocal's own comments -- a native-eligible one
||| renders as a plain native literal, ready to box; anything else
||| RC.idr's `bindOne` still chose to make an RCConst goes through
||| `boxedConstExpr`, the same staging/caching a let-bound literal of
||| the same value would use), `Nothing` for an ordinary declared local.
export
inlineExprFor : {auto a : Ref ArgCounter Nat}
             -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
             -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
             -> {auto lm : Ref InlineMap (SortedMap Int String)}
             -> RCLocal -> Core (Maybe String)
inlineExprFor RCNull = pure Nothing
inlineExprFor (RCConst c) = Just <$> case litRep c of
    Just _  => pure $ nativeLitExpr c
    Nothing => boxedConstExpr c
-- Nothing, same as RCNull: rendered directly by varName, not through
-- the InlineMap/RNative detour (see repOfLocal above).
inlineExprFor (RCEmptyCon {}) = pure Nothing
inlineExprFor l@(RCConstCon {}) = Just <$> boxedConstConExpr l {prf=ItIsConstCon}
inlineExprFor (RCLoc i) = do
    inlined <- get InlineMap
    pure $ SortedMap.lookup i inlined

||| RCLocal -> C, Rep-aware: a bare use of `l` if it's already Boxed, or a
||| fresh box of its native value otherwise (natives have no refcount, so
||| boxing them here always allocates an independent fresh value -- there
||| is no borrow/move distinction to make). Any dup this use needed was
||| already made explicit as a wrapping RDup node earlier in the tree (see
||| the module note), so this never dups on its own. An InlineMap'd local
||| (or a non-native-eligible RCConst, see `inlineExprFor`) has no `var_N`
||| to read in the first place -- its expression text is used as-is.
export
rcVarToBoxedC : {auto a : Ref ArgCounter Nat}
             -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
             -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
             -> {auto r : Ref RepMap (SortedMap Int Rep)}
             -> {auto lm : Ref InlineMap (SortedMap Int String)}
             -> RCLocal -> Core String
rcVarToBoxedC l = do
    rep <- repOfLocal l
    inlined <- inlineExprFor l
    pure $ case rep of
                RNative ty => nativeMk ty (fromMaybe (varName l) inlined)
                -- Always InlineMap'd by construction (Rep.RInlineNative's
                -- own doc comment) -- `fromMaybe (varName l) inlined` is
                -- defensive totality, not a real fallback path.
                RInlineNative ty => nativeMk ty (fromMaybe (varName l) inlined)
                -- Was unconditionally `varName l` before a non-native-
                -- eligible RCConst (String/small Integer) could ever be
                -- RBoxed -- every existing RBoxed local is a genuine
                -- `RCLoc` whose `inlineExprFor` is always `Nothing`
                -- anyway, so this is a no-op change for them, but a real
                -- fix for the new RCConst case.
                RBoxed => fromMaybe (varName l) inlined

||| An operand for a Boxed-result `ROp` (see its own `emitRC` case
||| below): an already-`RBoxed` local renders via `rcVarToBoxedC` as-is,
||| ownership already accounted for elsewhere -- nothing extra to free.
||| A `RNative`/`RInlineNative` operand still needs `rcVarToBoxedC`'s own
||| fresh `nativeMk` box to feed the Boxed C primitive, but unlike that
||| function's other call sites (a constructor field, a return value --
||| contexts that immediately hand the fresh box's ownership off to
||| someone else), an `ROp` argument has nowhere to hand it to: the C
||| primitive only reads it, so the fresh box must be named here and
||| dropped once the op is done reading it, or it leaks (found via
||| `Test16LoopContinuePostDrop.idr`: `Types.repOf` never promotes a
||| `case`/`if`-valued `RLet` to Native even when a branch's own value is
||| a plain native arithmetic chain, so that branch's `ROp` ends up
||| Boxed-result while still reading a genuinely Native operand).
export
boxOpArg : {auto a : Ref ArgCounter Nat}
        -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
        -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
        -> {auto r : Ref RepMap (SortedMap Int Rep)}
        -> {auto lm : Ref InlineMap (SortedMap Int String)}
        -> {auto oft : Ref OutfileText Output}
        -> {auto il : Ref IndentLevel Nat}
        -> FC -> RCLocal -> Core (String, Maybe String)
boxOpArg fc l = do
    rep <- repOfLocal l
    expr <- rcVarToBoxedC l
    case rep of
         RBoxed => pure (expr, Nothing)
         _ => do
             let tmp = "opBox_" ++ !(getNextCounter)
             emit fc $ "IDRIS2RC2_Value *" ++ tmp ++ " = " ++ expr ++ ";"
             pure (tmp, Just tmp)

||| The C expression to use for `l` as an operand of a native op expecting
||| type `ty`: the raw variable if it's already native, or an inline
||| unboxing extraction if it's boxed. Never dups/drops -- reading a value
||| for a native op doesn't take ownership either way. An InlineMap'd
||| local inlines its expression text directly instead of reading back a
||| `var_N` that was never declared.
export
rcVarToNativeC : {auto a : Ref ArgCounter Nat}
              -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
              -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
              -> {auto r : Ref RepMap (SortedMap Int Rep)}
              -> {auto lm : Ref InlineMap (SortedMap Int String)}
              -> PrimType -> RCLocal -> Core String
-- `RCNull` here is never a real value to unbox -- it only ever reaches
-- this function as one of Compiler.RC2.MutualLoop's own `RCNull`
-- padding slots (a smaller-arity member's unused trailing loop param,
-- see `buildGroup`'s own `padded`), reaching a param
-- Compiler.RC2.Loop's native-shadow promotion happened to promote to
-- `RNative` because some *other* member of the same merged group does
-- read that slot natively -- MutualLoop's own invariant ("members with
-- a smaller arity simply never reference their own unused trailing
-- slots") guarantees this specific value is never actually read on the
-- path that receives it. `nativeUnbox`'s ordinary `RBoxed` case would
-- otherwise unbox a literal C `NULL`, straight into a null-pointer
-- dereference in the runtime accessor -- a real crash this exact
-- pattern used to hit before this clause existed.
rcVarToNativeC _ RCNull = pure "0"
rcVarToNativeC ty l = do
    rep <- repOfLocal l
    inlined <- inlineExprFor l
    pure $ case rep of
                -- Unreachable in practice: a non-native-eligible RCConst
                -- (the only new source of an RBoxed `inlined`) is never a
                -- native op's own operand (String/Integer are never
                -- native-eligible types to begin with) -- guarded anyway
                -- for the same reason `nativeCType`/`nativeMk`/
                -- `nativeUnbox`'s own catch-all cases are.
                RBoxed => nativeUnbox ty (fromMaybe (varName l) inlined)
                _ => fromMaybe (varName l) inlined

||| The reuse-reservation C variable's name for scrutinee `sc` -- a pure,
||| deterministic function of `sc`'s own id, computed identically
||| wherever it's needed (the offering RConAlt's own uniqueness check,
||| the RCon(s) that may claim it, any RReleaseReuse that releases it)
||| with no lookup table required at all, unlike the old ReuseMap this
||| replaced: Compiler.RC2.Reuse already resolved *which* RCon (if any)
||| claims a given offer, encoding that pairing directly as data
||| (RCon.reuseFrom = Just sc) rather than something Emit has to
||| rediscover via a name-keyed map at emission time.
export
reuseVarName : RCLocal -> String
reuseVarName sc = "reuse_" ++ varName sc

||| Mechanically lower an `RReuseOffer` node (see its own doc comment in
||| RCExp.idr): declare the reservation variable and emit the runtime
||| uniqueness check that either repurposes `sc`'s storage in place or
||| (if `sc` turned out shared) dup's every entry in `dupOnShared` --
||| already exactly the set that needs it, precomputed by
||| Compiler.RC2.Reuse -- and drops `sc` normally. A fixed template,
||| the same shape every time; no set computation of any kind happens
||| here.
|||
||| The unique branch also drops every `dropOnUnique` entry -- fields
||| destructured out of `sc` but never referenced past this point,
||| whose release the not-unique branch gets for free from `sc`'s own
||| recursive drop below. The unique branch never drops `sc` itself
||| (its storage is reserved for reuse instead), so that free ride
||| doesn't happen there -- these need an explicit drop of their own,
||| in this branch only (see `RReuseOffer`'s own doc comment for the
||| leak this fixes).
export
emitReuseOffer : {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> RCLocal -> (dupOnShared : List RCLocal) -> (dropOnUnique : List RCLocal) -> Core ()
emitReuseOffer sc dupOnShared dropOnUnique = do
    let sc' = varName sc
    let reuseVar = reuseVarName sc
    emit EmptyFC $ "IDRIS2RC2_Constructor* " ++ reuseVar ++ " = NULL;"
    emit EmptyFC $ "if (idris2rc2_isUnique(" ++ sc' ++ ")) {"
    increaseIndentation
    emit EmptyFC $ reuseVar ++ " = (IDRIS2RC2_Constructor*)" ++ sc' ++ ";"
    removeVars (varName <$> dropOnUnique)
    decreaseIndentation
    emit EmptyFC "} else {"
    increaseIndentation
    dupVars (varName <$> dupOnShared)
    removeVars [sc']
    decreaseIndentation
    emit EmptyFC "}"

public export
data TailPositionStatus = InTailPosition | NotInTailPosition

||| Where a fully-evaluated RCExp's value ultimately goes: either into a
||| named C variable -- freshly declared right here (`SinkVar True _`,
||| e.g. an `RLet`'s own binding) or already declared by whoever set up
||| this `Sink` in the first place (`SinkVar False _`, e.g. a case's own
||| pre-declared result slot, see `resolveSink`) -- or straight out via a
||| C `return` statement (`SinkReturn`, only ever handed down while
||| `tailPosition` is `InTailPosition`, since nothing after a `return`
||| would ever run). Generalises what used to be a bare `(declare, target)`
||| pair (`assignInto`'s old signature) so that `RConCase`/`RConstCase`/
||| `RCmpCase`'s own branches can write straight into the caller's real
||| destination -- a variable *or* a `return` -- instead of a throwaway
||| `switchReturnVar` that then had to be copied into it: the same "build
||| directly into the real destination" idea as `tryBuildClosureInto`'s
||| own doc comment, generalised to branching constructs, and to `return`
||| as a destination in its own right.
|||
||| `SinkReturn` carries the enclosing function's own `retRep` (`MkRCFun`'s
||| own field, see `createCFunctions`) -- `RBoxed` renders exactly as
||| before; `RNative`/`RInlineNative` means the enclosing C function's
||| own declared return type is a native scalar, not
||| `IDRIS2RC2_Value *`, so every reachable tail leaf must render its own
||| value natively too (`emitInto`'s own fallback dispatches on this;
||| every other construct in this module just threads `sink` straight
||| through, so nothing else needs to know) -- see
||| `Compiler.RC2.DualABI`'s own Stage 3b for what promotes a worker's
||| own `retRep` in the first place.
public export
data Sink = SinkVar Bool String | SinkReturn Rep

||| Turn a `Sink` that might still need its own variable declared
||| (`SinkVar True _`) into one that's guaranteed already-declared
||| (`SinkVar False _`, unchanged if already such; `SinkReturn` always
||| passes through unchanged) -- emitting the variable's own
||| `NULL`-initialised declaration up front if needed. Shared by every
||| multi-branch construct (`RCmpCase`/`RConCase`/`RConstCase`) that must
||| pre-declare its result slot exactly *once*, before any branch, so
||| every branch can then just plainly assign into the same
||| already-in-scope variable -- declaring it separately inside each
||| branch's own `{ }` block would scope it to that block alone, making
||| it unreadable the moment the `if`/`switch` closes.
export
resolveSink : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> FC -> Sink -> Core Sink
resolveSink fc (SinkVar True target) = do
    emit fc "IDRIS2RC2_Value * \{target} = NULL;"
    pure (SinkVar False target)
resolveSink _ sink = pure sink

||| Emit the one statement that finally disposes of an already-evaluated
||| expression string per `sink` -- the common tail end of every leaf
||| (non-branching) `RCExp` shape `emitInto` ever falls back to plain
||| `emitRC` for.
export
finalizeSink : {auto oft : Ref OutfileText Output}
            -> {auto il : Ref IndentLevel Nat}
            -> FC -> Sink -> String -> Core ()
finalizeSink fc (SinkVar True target) valStr = emit fc "IDRIS2RC2_Value * \{target} = \{valStr};"
finalizeSink fc (SinkVar False target) valStr = emit fc "\{target} = \{valStr};"
finalizeSink fc (SinkReturn _) valStr = emit fc "return \{valStr};"

||| Whether a case's alts need `else`-chaining at all. Every branch
||| reached under `SinkReturn` is guaranteed (inductively, via
||| `emitInto`'s own dispatch -- see its doc comment) to end in either
||| `return` or `goto loop;`, both of which leave the enclosing function
||| entirely -- so a later alt's own condition is provably never even
||| reached once an earlier one has already matched, `else` or not.
||| Dropping it lets each alt stand as an independent `if`, matching
||| what actually happens at runtime, and skips re-checking a condition
||| control could never still reach anyway. Any other `Sink` (a plain
||| variable) falls through after its own assignment -- exactly one
||| branch must run, so the chain must stay `if`/`else if`/`else` to
||| guarantee that.
export
chainsWithElse : Sink -> Bool
chainsWithElse (SinkReturn _) = False
chainsWithElse (SinkVar _ _) = True

export
integerSwitch : List RConstAlt -> Bool
integerSwitch [] = True
integerSwitch (MkRConstAlt c _  :: _) =
    case c of
        (I x) => True
        (I8 x) => True
        (I16 x) => True
        (I32 x) => True
        (I64 x) => True
        (B8 x) => True
        (B16 x) => True
        (B32 x) => True
        (B64 x) => True
        (BI x) => True
        (Ch x) => True
        _ => False

||| Correctly sign-aware int64 extraction for RConstCase's "integer
||| switch" fast path below, dispatched on the constant type of the alt
||| being matched (every alt in an integer-switch shares the same
||| underlying type, per `integerSwitch`). The pointer-tagged unboxed
||| representation used for Int8/Int16/Int32 (like Bits8/Bits16/Bits32/
||| Char) carries no runtime type tag of its own to say whether the stored
||| bit pattern should be read back signed or unsigned -- unlike
||| `idris2rc2_extractInt`'s generic fallback (always an unsigned
||| zero-extend, harmless for the unsigned types but wrong for negative
||| Int8/16/32 literals, e.g. -128 would extract as 128), this picks the
||| same type-specific signed accessor the native-unboxing path already
||| uses (see `rcVarToNativeC`/`nativeUnbox`).
export
extractIntExpr : Constant -> String -> String
extractIntExpr (I8 _) x = "idris2rc2_to_i8(\{x})"
extractIntExpr (I16 _) x = "idris2rc2_to_i16(\{x})"
extractIntExpr (I32 _) x = "idris2rc2_to_i32(\{x})"
extractIntExpr _ x = "idris2rc2_extractInt(\{x})"

export
const2Integer : Constant -> Integer -> String
const2Integer c i =
    case c of
        (I x) => showIntMin x
        (I8 x) => "INT8_C(\{show x})"
        (I16 x) => "INT16_C(\{show x})"
        (I32 x) => "INT32_C(\{show x})"
        (I64 x) => showInt64Min x
        (BI x) => show x
        (Ch x) => escapeChar x
        (B8 x) => "UINT8_C(\{show x})"
        (B16 x) => "UINT16_C(\{show x})"
        (B32 x) => "UINT32_C(\{show x})"
        (B64 x) => "UINT64_C(\{show x})"
        _ => show i

||| Populate `target` with a newly-built closure over `n`, `missing`
||| args still unset for further partial application -- either
||| declaring it fresh (`declare = True`, `target` not yet in scope: an
||| enclosing `RLet`'s own `var_N`) or assigning into an existing
||| variable (`declare = False`: a `Sink`'s own already-declared
||| variable, see `buildClosureIntoSink`/`resolveSink`). Takes the
||| target name explicitly rather than always minting a fresh
||| `closure_N` so a caller that already has its own destination
||| variable in hand can build directly into it instead of declaring/
||| using a throwaway `closure_N` and immediately copying it into the
||| real target right after -- two statements doing the work of one.
export
makeClosureInto : {auto a : Ref ArgCounter Nat}
                -> {auto oft : Ref OutfileText Output}
                -> {auto il : Ref IndentLevel Nat}
                -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                -> {auto r : Ref RepMap (SortedMap Int Rep)}
                -> {auto lm : Ref InlineMap (SortedMap Int String)}
                -> FC
                -> (declare : Bool)
                -> (target : String)
                -> Name
                -> List RCLocal
                -> Nat
                -> Core ()
makeClosureInto fc declare target n args missing = do
    let nargs = length args
    let decl : String = if declare then "IDRIS2RC2_Value *" else ""
    emit fc "\{decl}\{target} = (IDRIS2RC2_Value *)idris2rc2_mkClosure((IDRIS2RC2_Value *(*)())\{cName n}, \{show $ nargs + missing}, \{show nargs});"
    let arglist = "((IDRIS2RC2_Closure*)\{target})->args"
    _ <- foldlC (\k, v => do
        vStr <- rcVarToBoxedC v
        emit EmptyFC $ "\{arglist}[\{show k}] = \{vStr};"
        pure (S k)) 0 args
    pure ()

||| As `makeClosureInto`, but mints its own fresh `closure_N` name and
||| returns it as an expression -- for call sites where the closure is
||| just a sub-expression (e.g. a tail call's own trampoline argument)
||| with no existing destination variable to build into directly.
export
makeClosure : {auto a : Ref ArgCounter Nat}
            -> {auto oft : Ref OutfileText Output}
            -> {auto il : Ref IndentLevel Nat}
            -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
            -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
            -> {auto r : Ref RepMap (SortedMap Int Rep)}
            -> {auto lm : Ref InlineMap (SortedMap Int String)}
            -> FC
            -> Name
            -> List RCLocal
            -> Nat
            -> Core String
makeClosure fc n args missing = do
    let closure = "closure_\{!(getNextCounter)}"
    makeClosureInto fc True closure n args missing
    pure closure

||| As `makeClosureInto`, but resolving a `Sink` first instead of a bare
||| `(declare, target)` pair: an existing variable destination builds
||| directly into it, same as `makeClosureInto` always did; `SinkReturn`
||| has no variable to build into at all (a closure needs several
||| statements -- the `mkClosure` call plus one assignment per field --
||| so it can never collapse into a single `return` expression), so this
||| mints its own throwaway temporary (same as plain `makeClosure`) and
||| returns *that* via a trailing `return` statement.
export
buildClosureIntoSink : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> FC -> Sink -> Name -> List RCLocal -> Nat -> Core ()
buildClosureIntoSink fc (SinkVar declare target) n args missing =
    makeClosureInto fc declare target n args missing
buildClosureIntoSink fc (SinkReturn _) n args missing = do
    closure <- makeClosure fc n args missing
    emit fc "return \{closure};"

-- Must match the dispatch switch in support/rc2/runtime.c
-- (`idris2rc2_dispatchClosure`'s own fixed `IDRIS2RC2_FUN0`..`FUN8`/
-- `FUNSTAR` function-pointer types, all-`IDRIS2RC2_Value*`-only).
-- Governs two things, both about a function that CAN be dispatched
-- through that closure machinery -- i.e. an ordinary function or a
-- dual-ABI wrapper, never a dual-ABI *worker* (see `MkRCFun`'s own
-- `isWorker` field doc comment and `createCFunctions`'s own use of it
-- below -- a worker is only ever called via a direct, statically-named
-- `RAppNameRep`, never stored in a `Closure`, so it's exempt from both
-- of these regardless of its own argument count):
-- 1. `emitRC`'s own `RAppName`/`NotInTailPosition` case above: past
--    this many arguments, a non-tail call builds a closure and
--    trampolines it rather than calling directly (unrelated to
--    dual-ABI, `RAppName` is never a dual-ABI call).
-- 2. `createCFunctions`'s own C declaration shape for a non-worker
--    `MkRCFun`: past this many arguments, the function is declared
--    taking a single `IDRIS2RC2_Value *var_arglist[]` instead of
--    individually-typed positional parameters, matching
--    `IDRIS2RC2_FUNSTAR`.
export
MaxExtractFunArgs : Nat
MaxExtractFunArgs = 20

||| Split a non-empty list into everything but its last element, and the
||| last element itself, in order -- `Nothing` for an empty list. Used
||| by `emitAltChain` to single out a case's final alt, the one that can
||| skip its own condition check when there's no explicit default (see
||| its own doc comment).
export
splitLast : List a -> Maybe (List a, a)
splitLast xs = case reverse xs of
    [] => Nothing
    (l :: ls) => Just (reverse ls, l)

||| The raw boolean C expression (no `if (...)` wrapper) deciding
||| whether scrutinee `sc'` (already rendered via `varName`) matches
||| `alt`'s own constructor.
export
conAltCondExpr : String -> RConAlt -> Core String
conAltCondExpr sc' (MkRConAlt name coninfo tag args body) = do
    let erased = coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
    pure $ if erased then "NULL == \{sc'} /* \{show name} \{show coninfo} */"
           else if coninfo == CONS || coninfo == JUST || coninfo == SUCC
           then "NULL != \{sc'} /* \{show name} \{show coninfo} */"
           else case tag of
                -- Untagged (name-compared) constructors are never
                -- zero-argument+tagged, so RCEmptyCon never covers them
                -- -- sc' is always a real heap IDRIS2RC2_Constructor*
                -- here.
                Nothing   => "! strcmp(((IDRIS2RC2_Constructor *)\{sc'})->name, idris2rc2_constr_\{cName name})"
                -- sc' may be a tagged pointer (a zero-argument
                -- constructor of *this* ADT, see RCEmptyCon in
                -- RCExp.idr) as well as a real heap
                -- IDRIS2RC2_Constructor* -- idris2rc2_conTag
                -- (support/rc2/datatypes.h) checks which.
                Just tag' => "idris2rc2_conTag(\{sc'}) == \{show tag'} /* \{show name} */"

||| Render a case's own `if`-chain against `alts`, given a `Core String`
||| condition expression and a `Core ()` body renderer per alt (each
||| assuming indentation is the caller's -- `emitAltChain`'s own -- to
||| manage), plus an optional default/fallback (`renderDefault`) for
||| anything `alts` alone doesn't cover. Shared control-flow shape
||| between `emitConCaseInto` and `emitConstCaseInto` -- the only two
||| case constructs that dispatch over a genuine *list* of alts
||| (`RCmpCase` always has exactly two, rendered directly by
||| `emitCmpCaseInto` instead).
|||
||| Whenever there's no explicit default (`renderDefault = Nothing`),
||| the very last alt in `alts` skips its own condition entirely --
||| coverage already guarantees it matches once every earlier condition
||| has failed, `else`-chained or not (see `chainsWithElse`). When
||| `sink` also turns out to be `SinkReturn`, every *other* alt drops
||| its `else`-chaining too (`chainsWithElse` again), and the trailing
||| piece (that skipped-condition last alt, or an explicit default)
||| drops even its own `{ }` wrapper and any extra indentation -- under
||| `SinkReturn`, this case's own rendering is always the last thing in
||| whatever C block contains it (a function body, or an enclosing
||| case's own already-diverging branch -- see `chainsWithElse`'s own
||| doc comment), so there's nothing for a tighter scope to protect
||| against here. Together, a 2-alt case with no default in tail
||| position (e.g. a `Bool`-shaped match) collapses to the simplest
||| possible `if (...) { ...; return ...; } ...; return ...;` shape,
||| and a single-alt case with no default (only one constructor is even
||| possible) collapses further still, to no `if` at all.
export
emitAltChain : {auto oft : Ref OutfileText Output}
            -> {auto il : Ref IndentLevel Nat}
            -> Sink -> (alt -> Core String) -> (alt -> Core ()) -> Maybe (Core ()) -> List alt -> Core ()
emitAltChain sink condExpr renderBody renderDefault alts = do
    let chained = chainsWithElse sink
    let (condAlts, tailAlt) = case (renderDefault, splitLast alts) of
             (Nothing, Just (initAlts, lastAlt)) => (initAlts, Just lastAlt)
             _ => (alts, Nothing)
    finalEls <- foldlC (\els, alt => do
        cond <- condExpr alt
        emit emptyFC "\{els}if (\{cond}) {"
        increaseIndentation
        renderBody alt
        decreaseIndentation
        if chained
           then pure "} else "
           else do
               emit emptyFC "}"
               pure "") "" condAlts
    let trailing : Maybe (Core ()) = maybe renderDefault (Just . renderBody) tailAlt
    whenJust trailing $ \body =>
        if chained
           then do
               emit emptyFC "\{finalEls}{"
               increaseIndentation
               body
               decreaseIndentation
               emit emptyFC "}"
           else body

-- RefC-tagged foreign calls go to our own runtime (buffer.c's own
-- functions, which expect the whole IDRIS2RC2_Buffer.buf allocation
-- including its `int size` header -- they read/write it themselves), so
-- CFBuffer is unwrapped one level only. C-tagged foreign calls (e.g.
-- `supportC`'s libidris2_support functions like idris2_readBufferData) are
-- generic byte-buffer functions with no notion of that header -- they
-- expect a flat pointer straight to the data, so CFBuffer must skip past
-- it too. Mirrors RefC.idr's `CLang`/`CLangC`/`CLangRefC` split.
public export
data CLang = CLangC | CLangRefC

-- Accepted FFI tags, in priority order. "RefC" is accepted (and treated as
-- directly callable, not stubbed) because prelude/base/contrib bake a
-- handful of load-bearing low-level primitives (fastPack, fastConcat,
-- fastUnpack, string iterators) into %foreign/%transform pairs hardcoded
-- to the "RefC" tag; our own runtime provides matching C symbols for
-- those so we can reuse the declarations as-is instead of forking prelude.
export
ffiTags : List String
ffiTags = ["RC2", "RefC", "C"]

||| The C type a `%foreign` argument/return, or a struct field, of this
||| `CFType` is rendered as. Lifted out of `createCFunctions`'s own
||| `where` (originally scoped to its `MkRCForeign` case alone) so
||| `RStructGet`/`RStructSet`'s own lowering (Part D,
||| doc/c-struct-support.md) can share it for a field's own `CFType`,
||| not just a whole `%foreign` def's. Placed ahead of the `mutual`
||| block below (rather than alongside `createCFunctions`, its own
||| original home) so `emitRC`'s own `RStructGet`/`RStructSet` cases,
||| earlier in that same block, can see it.
export
cTypeOfCFType : CFType -> String
cTypeOfCFType CFUnit          = "void"
cTypeOfCFType CFInt           = "int64_t"
cTypeOfCFType CFInt8          = "int8_t"
cTypeOfCFType CFInt16         = "int16_t"
cTypeOfCFType CFInt32         = "int32_t"
cTypeOfCFType CFInt64         = "int64_t"
cTypeOfCFType CFUnsigned8     = "uint8_t"
cTypeOfCFType CFUnsigned16    = "uint16_t"
cTypeOfCFType CFUnsigned32    = "uint32_t"
cTypeOfCFType CFUnsigned64    = "uint64_t"
cTypeOfCFType CFString        = "const char *"
cTypeOfCFType CFDouble        = "double"
cTypeOfCFType CFChar          = "char"
cTypeOfCFType CFPtr           = "void *"
cTypeOfCFType CFGCPtr         = "void *"
cTypeOfCFType CFBuffer        = "void *"
cTypeOfCFType CFWorld         = "void *"
cTypeOfCFType (CFFun x y)     = "void *"
cTypeOfCFType (CFIORes x)     = "void *"
cTypeOfCFType (CFStruct x ys) = "void *"
cTypeOfCFType (CFUser x ys)   = "void *"
cTypeOfCFType n = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

||| Read a C value of this `CFType` out of a Boxed `varName` (a
||| `%foreign` argument, or -- Part D -- an `RStructGet`'s own field
||| read). Lifted out of `createCFunctions`'s own `where` for the same
||| reason as `cTypeOfCFType` above.
|||
||| `CFStruct`'s own case reuses `CFPtr`'s already-working line
||| verbatim, rather than the `idris_crash` this used to be (see
||| doc/c-struct-support.md's "Part A"): a struct is always accessed by
||| pointer in this design, and `cTypeOfCFType` already renders both
||| identically (`"void *"`), so there was never a reason for this to
||| diverge from `CFPtr`'s own handling.
export
extractValue : (cLang : CLang) -> (cfType:CFType) -> (varName:String) -> String
extractValue _ CFUnit           varName = "NULL"
extractValue _ CFInt            varName = "(idris2rc2_to_i64(" ++ varName ++ "))"
extractValue _ CFInt8           varName = "(idris2rc2_to_i8(" ++ varName ++ "))"
extractValue _ CFInt16          varName = "(idris2rc2_to_i16(" ++ varName ++ "))"
extractValue _ CFInt32          varName = "(idris2rc2_to_i32(" ++ varName ++ "))"
extractValue _ CFInt64          varName = "(idris2rc2_to_i64(" ++ varName ++ "))"
extractValue _ CFUnsigned8      varName = "(idris2rc2_to_u8(" ++ varName ++ "))"
extractValue _ CFUnsigned16     varName = "(idris2rc2_to_u16(" ++ varName ++ "))"
extractValue _ CFUnsigned32     varName = "(idris2rc2_to_u32(" ++ varName ++ "))"
extractValue _ CFUnsigned64     varName = "(idris2rc2_to_u64(" ++ varName ++ "))"
extractValue _ CFString         varName = "((IDRIS2RC2_String*)" ++ varName ++ ")->str"
extractValue _ CFDouble         varName = "(idris2rc2_to_double(" ++ varName ++ "))"
extractValue _ CFChar           varName = "((char)idris2rc2_to_char(" ++ varName ++ "))"
extractValue _ CFPtr            varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
extractValue _ CFGCPtr          varName = "((IDRIS2RC2_GCPointer*)" ++ varName ++ ")->p->p"
extractValue CLangRefC CFBuffer varName = "((IDRIS2RC2_Buffer*)" ++ varName ++ ")->buf"
extractValue CLangC    CFBuffer varName = "((IDRIS2RC2_RawBuffer*)((IDRIS2RC2_Buffer*)" ++ varName ++ ")->buf)->data"
extractValue _ CFWorld          _       = "(IDRIS2RC2_Value *)NULL"
extractValue _ (CFFun x y)      varName = "(IDRIS2RC2_Closure*)" ++ varName
extractValue c (CFIORes x)      varName = extractValue c x varName
extractValue _ (CFStruct x xs)  varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
extractValue _ (CFUser x xs)    varName = "(IDRIS2RC2_Value*)" ++ varName
extractValue _ n _ = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

||| Wrap a raw C value of this `CFType` (a `%foreign` return, or --
||| Part D -- the value read for an `RStructGet`, or `RStructSet`'s own
||| field being written) into a Boxed `IDRIS2RC2_Value*`. Lifted out of
||| `createCFunctions`'s own `where` for the same reason as
||| `cTypeOfCFType` above.
|||
||| `CFStruct`'s own case reuses `CFPtr`'s already-working line
||| verbatim -- see `extractValue`'s own doc comment above, same
||| reasoning (this used to call an undefined `makeStruct` helper).
export
packCFType : (cfType:CFType) -> (varName:String) -> String
packCFType CFUnit          varName = "((IDRIS2RC2_Value *)NULL)"
packCFType CFInt           varName = "idris2rc2_mkInt64(" ++ varName ++ ")"
packCFType CFInt8          varName = "idris2rc2_mkInt8(" ++ varName ++ ")"
packCFType CFInt16         varName = "idris2rc2_mkInt16(" ++ varName ++ ")"
packCFType CFInt32         varName = "idris2rc2_mkInt32(" ++ varName ++ ")"
packCFType CFInt64         varName = "idris2rc2_mkInt64(" ++ varName ++ ")"
packCFType CFUnsigned64    varName = "idris2rc2_mkBits64(" ++ varName ++ ")"
packCFType CFUnsigned32    varName = "idris2rc2_mkBits32(" ++ varName ++ ")"
packCFType CFUnsigned16    varName = "idris2rc2_mkBits16(" ++ varName ++ ")"
packCFType CFUnsigned8     varName = "idris2rc2_mkBits8(" ++ varName ++ ")"
packCFType CFString        varName = "idris2rc2_mkString(" ++ varName ++ ")"
packCFType CFDouble        varName = "idris2rc2_mkDouble(" ++ varName ++ ")"
packCFType CFChar          varName = "idris2rc2_mkChar((unsigned char)" ++ varName ++ ")"
packCFType CFPtr           varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
packCFType CFGCPtr         varName = "idris2rc2_mkGCPointer(" ++ varName ++ ", NULL)"
packCFType CFBuffer        varName = "idris2rc2_mkBuffer(" ++ varName ++ ")"
packCFType CFWorld         _       = "(IDRIS2RC2_Value *)NULL"
packCFType (CFFun x y)     varName = "makeFunction(" ++ varName ++ ")"
packCFType (CFIORes x)     varName = packCFType x varName
packCFType (CFStruct x xs) varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
packCFType (CFUser x xs)   varName = varName
packCFType n _ = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

||| Every `CFStruct` reachable inside a `%foreign` def's own argument/
||| return `CFType`s, by struct name, keyed the first time each name is
||| seen (later re-occurrences of the same name are assumed identical,
||| matching upstream's own Chez backend -- see
||| doc/c-struct-support.md's "Part B"). Recurses into `CFIORes`/
||| `CFFun`, and into a `CFStruct`'s own field types too (a field can
||| itself be a nested struct pointer). Direct algorithmic port of
||| Chez's own `mkStruct`/`Structs` (`Compiler/Scheme/Chez.idr`),
||| rewritten in rc2's own idiom -- a `SortedMap` built via `foldl`
||| instead of a `List String` `Ref` threaded through Scheme-code
||| generation, since there's no Scheme code to emit here.
export
collectStructDefs : CFType -> SortedMap String (List (String, CFType)) -> SortedMap String (List (String, CFType))
collectStructDefs (CFStruct n flds) acc =
    if isJust (lookup n acc)
       then acc
       else foldl (\acc', (_, ty) => collectStructDefs ty acc') (insert n flds acc) flds
collectStructDefs (CFIORes t) acc = collectStructDefs t acc
collectStructDefs (CFFun a b) acc = collectStructDefs b (collectStructDefs a acc)
collectStructDefs _ acc = acc

