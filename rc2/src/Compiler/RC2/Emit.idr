module Compiler.RC2.Emit

-- RCExp -> C. Mostly mechanical: every ownership decision (dup/drop/free,
-- and what to drop and when), every native-vs-boxed representation
-- decision, and the constructor-reuse-in-place decision were already made
-- by Compiler.RC2.RC/Compiler.RC2.Reuse and are baked into the tree as
-- data (explicit RDup/RDrop/RFree nodes, RLet's Rep field, RCon's
-- reuseFrom, RConAlt's offersReuse, RReleaseReuse). This module never
-- (re)analyses any of those; it just maintains a small incrementally-built
-- `RepMap` so that a *use* of a local (which only carries its RCLocal id)
-- can look back up the Rep its binding RLet already decided. Every local
-- variable use (RV, and every RCLocal appearing as a call/constructor/op
-- argument) is lowered as-is, with no per-use dup decision: any refcount
-- adjustment a use needs has already been made explicit as a wrapping
-- RDup/RDrop/RFree node earlier in the tree, which this module just
-- lowers to the matching runtime call.
--
-- In particular, an `RDrop`'s own var list never needs re-filtering
-- here: Compiler.RC2.RC's `Owned` set (the sole source of every
-- `RDrop` it produces, via `dropUnusedOwnedVars`'s set-difference) only
-- ever gains members at three sites (a function's own args, an RLet's
-- own bound var, an RConAlt's own destructured args), and all three
-- exclude `natives`-listed locals and only ever insert genuine `RCLoc`s
-- -- never `RCConst`/`RCEmptyCon`/`RCNull`. A `keepBoxedLocals`
-- Native/RCConst/RCEmptyCon/RCNull re-filter used to sit in front of
-- every `RDrop` lowering below as a defensive measure; removed once
-- this was confirmed airtight (see TODO.md's former "Architecture"
-- note on this exact question).
--
-- A few things this module still *does* decide (deliberately, not an
-- oversight -- see TODO.md's "Architecture" section for the one left
-- unaddressed):
--   * `tryBuildClosureInto`/`makeClosureInto`: which C statements a
--     closure build/partial-application ends up as. Purely a codegen-
--     shape optimisation (fewer statements, no throwaway `closure_N`
--     immediately copied into its real destination) with zero effect on
--     runtime semantics -- unlike the ownership/representation decisions
--     above, there's no *semantic* fact for Compiler.RC2.RC's IR to carry
--     about this, only a syntactic one about how many C statements to
--     spend saying it.
--   * `RPrimVal`'s small-int cache / constant-staging (`dyngen`/
--     `orStagen`): a literal's own *value* decides whether it uses the
--     small-int cache or gets staged into a deduplicated top-level
--     constant -- inherently file-scoped (dedup spans the whole
--     compilation unit, not one definition), so it doesn't fit the
--     "decide once per node during Lifted -> RCExp conversion" shape the
--     elevations above use even if moved.

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Compiler.CompileExpr
import Compiler.Common
import Compiler.Generated

import Core.Directory
import Core.Context

import Idris.Syntax

import Libraries.Data.DList
import Data.SortedSet
import Data.SortedMap
import Data.Vect

import Protocol.Hex
import Libraries.Utils.Path

import System
import System.File

%default covering

------------------------------------------------------------------------
-- Name mangling (matches Compiler.RC2.RC2's original scheme, kept for
-- generated-symbol stability)

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

showcCleanString : List Char -> String -> String
showcCleanString [] = id
showcCleanString (c ::cs) = (showcCleanStringChar c) . showcCleanString cs

cCleanString : String -> String
cCleanString cs = showcCleanString (unpack cs) ""

cUserName : UserName -> String
cUserName (Basic n) = cCleanString n
cUserName (Field n) = "rec__" ++ cCleanString n
cUserName Underscore = cCleanString "_"

cName : Name -> String
cName (NS ns n) = cCleanString (showNSWithSep "_" ns) ++ "_" ++ cName n
cName (UN n) = cUserName n
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
escapeChar : Char -> String
escapeChar c = if isAlphaNum c || isNL c
                  then show c
                  else show (ord c)

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

showIntMin : Int -> String
showIntMin x = if x == -9223372036854775808
    then "INT64_MIN"
    else "INT64_C("++ show x ++")"

showInt64Min : Int64 -> String
showInt64Min x = if x == -9223372036854775808
    then "INT64_MIN"
    else "INT64_C("++ show x ++")"

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

------------------------------------------------------------------------
-- Native (unboxed) codegen, driven by Compiler.RC2.Types' Rep inference.

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

-- Box a raw C expression of the given native type into a fresh
-- IDRIS2RC2_Value*.
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

-- Unbox a boxed IDRIS2RC2_Value* into a raw C expression of the given
-- native type.
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
intBits : PrimType -> String
intBits IntType = "64"; intBits Int8Type = "8"; intBits Int16Type = "16"
intBits Int32Type = "32"; intBits Int64Type = "64"; intBits _ = "64"

-- Raw C expression for a native-eligible PrimFn, given each operand's
-- already-native-or-unboxed C expression string.
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
nativeCmpExpr : PrimFn 2 -> Vect 2 String -> String
nativeCmpExpr (LT ty)  [x, y] = "(" ++ x ++ " < "  ++ y ++ ")"
nativeCmpExpr (GT ty)  [x, y] = "(" ++ x ++ " > "  ++ y ++ ")"
nativeCmpExpr (EQ ty)  [x, y] = "(" ++ x ++ " == " ++ y ++ ")"
nativeCmpExpr (LTE ty) [x, y] = "(" ++ x ++ " <= " ++ y ++ ")"
nativeCmpExpr (GTE ty) [x, y] = "(" ++ x ++ " >= " ++ y ++ ")"
nativeCmpExpr fn _ = "0 /* [rc2] unreachable native comparison " ++ show fn ++ " */"


rc2traverseVect : (a -> Core b) -> Vect n a -> Core (Vect n b)
rc2traverseVect f [] = pure []
rc2traverseVect f (x :: xs) = do
    x' <- f x
    xs' <- rc2traverseVect f xs
    pure (x' :: xs')

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

data ArgCounter : Type where
data FunctionDefinitions : Type where
data IndentLevel : Type where
data HeaderFiles : Type where
-- The enclosing function's own parameter ids, in order -- set once per
-- function (createCFunctions), consulted only by tryEmitSelfTailCall's
-- own RSelfTailCall case to know which var_N to reassign for each new
-- argument value (RSelfTailCall's own arg list is guaranteed the same
-- length and order by construction, see its doc comment).
data FunctionArgs : Type where
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
data InlineMap : Type where
data ConstDef
  = CDI64 String
  | CDB64 String
  | CDDb  String
  | CDStr String

constantName : ConstDef -> String
constantName = \case
  CDI64 x => go "Int64" x
  CDB64 x => go "Bits64" x
  CDDb x  => go "Double" x
  CDStr x => go "String" x
  where go : String -> String -> String
        go x y = "idris2rc2_constant_\{x}_\{y}"

------------------------------------------------------------------------

data OutfileText : Type where

Output : Type
Output = DList String

------------------------------------------------------------------------

getNextCounter : {auto a : Ref ArgCounter Nat} -> Core String
getNextCounter = do
    c <- get ArgCounter
    put ArgCounter (S c)
    pure $ show c

getNewVarThatWillNotBeFreedAtEndOfBlock : {auto a : Ref ArgCounter Nat} -> Core String
getNewVarThatWillNotBeFreedAtEndOfBlock = pure $ "tmp_" ++ !(getNextCounter)

maxLineLengthForComment : Nat
maxLineLengthForComment = 60

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

increaseIndentation : {auto il : Ref IndentLevel Nat} -> Core ()
increaseIndentation = update IndentLevel S

decreaseIndentation : {auto il : Ref IndentLevel Nat} -> Core ()
decreaseIndentation = update IndentLevel pred

indentation : {auto il : Ref IndentLevel Nat} -> Core String
indentation = do
    iLevel <- get IndentLevel
    pure $ pack $ replicate (4 * iLevel) ' '

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

applyFunctionToVars : {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> String
                    -> List String
                    -> Core ()
applyFunctionToVars fun vars = traverse_ (\v => emit EmptyFC $ fun ++ "(" ++ v ++ ");" ) vars

removeVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
removeVars = applyFunctionToVars "idris2rc2_drop"

dupVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
dupVars = applyFunctionToVars "idris2rc2_dup"

freeVars : {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> List String
           -> Core ()
freeVars = applyFunctionToVars "idris2rc2_free"

removeReuseConstructors : {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> List String
                        -> Core ()
removeReuseConstructors = applyFunctionToVars "idris2rc2_dropReuseConstructor"

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
repOfLocal (RCLoc i) = do
    reps <- get RepMap
    pure $ fromMaybe RBoxed (SortedMap.lookup i reps)

||| `Just` the C expression text standing in for `l`'s never-declared
||| variable if it's an InlineMap-registered local, or a native-eligible
||| RCConst (see InlineMap's and RCLocal's own comments), `Nothing` for
||| an ordinary declared local.
inlineExprFor : {auto lm : Ref InlineMap (SortedMap Int String)} -> RCLocal -> Core (Maybe String)
inlineExprFor RCNull = pure Nothing
inlineExprFor (RCConst c) = pure $ Just (nativeLitExpr c)
-- Nothing, same as RCNull: rendered directly by varName, not through
-- the InlineMap/RNative detour (see repOfLocal above).
inlineExprFor (RCEmptyCon {}) = pure Nothing
inlineExprFor (RCLoc i) = do
    inlined <- get InlineMap
    pure $ SortedMap.lookup i inlined

||| RCLocal -> C, Rep-aware: a bare use of `l` if it's already Boxed, or a
||| fresh box of its native value otherwise (natives have no refcount, so
||| boxing them here always allocates an independent fresh value -- there
||| is no borrow/move distinction to make). Any dup this use needed was
||| already made explicit as a wrapping RDup node earlier in the tree (see
||| the module note), so this never dups on its own. An InlineMap'd local
||| has no `var_N` to read in the first place -- its expression text is
||| boxed fresh instead.
rcVarToBoxedC : {auto r : Ref RepMap (SortedMap Int Rep)} -> {auto lm : Ref InlineMap (SortedMap Int String)} -> RCLocal -> Core String
rcVarToBoxedC l = do
    rep <- repOfLocal l
    inlined <- inlineExprFor l
    pure $ case rep of
                RNative ty => nativeMk ty (fromMaybe (varName l) inlined)
                -- Always InlineMap'd by construction (Rep.RInlineNative's
                -- own doc comment) -- `fromMaybe (varName l) inlined` is
                -- defensive totality, not a real fallback path.
                RInlineNative ty => nativeMk ty (fromMaybe (varName l) inlined)
                RBoxed => varName l

||| The C expression to use for `l` as an operand of a native op expecting
||| type `ty`: the raw variable if it's already native, or an inline
||| unboxing extraction if it's boxed. Never dups/drops -- reading a value
||| for a native op doesn't take ownership either way. An InlineMap'd
||| local inlines its expression text directly instead of reading back a
||| `var_N` that was never declared.
rcVarToNativeC : {auto r : Ref RepMap (SortedMap Int Rep)} -> {auto lm : Ref InlineMap (SortedMap Int String)} -> PrimType -> RCLocal -> Core String
rcVarToNativeC ty l = do
    rep <- repOfLocal l
    inlined <- inlineExprFor l
    pure $ case rep of
                RNative _ => fromMaybe (varName l) inlined
                RInlineNative _ => fromMaybe (varName l) inlined
                RBoxed => nativeUnbox ty (varName l)

||| The reuse-reservation C variable's name for scrutinee `sc` -- a pure,
||| deterministic function of `sc`'s own id, computed identically
||| wherever it's needed (the offering RConAlt's own uniqueness check,
||| the RCon(s) that may claim it, any RReleaseReuse that releases it)
||| with no lookup table required at all, unlike the old ReuseMap this
||| replaced: Compiler.RC2.Reuse already resolved *which* RCon (if any)
||| claims a given offer, encoding that pairing directly as data
||| (RCon.reuseFrom = Just sc) rather than something Emit has to
||| rediscover via a name-keyed map at emission time.
reuseVarName : RCLocal -> String
reuseVarName sc = "reuse_" ++ varName sc

||| Lower an RConAlt's `offersReuse` (see its own doc comment): declare
||| the reservation variable and emit the runtime uniqueness check that
||| either repurposes `sc`'s storage in place or (if `sc` turned out
||| shared) drops it normally -- dup'ing whichever of the destructured
||| field variables (`conArgs`) are still alive (i.e. not already in
||| `shouldDrop`, the branch's own drop list) first, since `sc`'s own
||| teardown would otherwise recursively drop them out from under
||| whatever still needs them.
emitReuseOffer : {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> RCLocal -> (conArgs : List String) -> (shouldDrop : List String) -> Core ()
emitReuseOffer sc conArgs shouldDrop = do
    let sc' = varName sc
    let reuseVar = reuseVarName sc
    emit EmptyFC $ "IDRIS2RC2_Constructor* " ++ reuseVar ++ " = NULL;"
    emit EmptyFC $ "if (idris2rc2_isUnique(" ++ sc' ++ ")) {"
    increaseIndentation
    emit EmptyFC $ reuseVar ++ " = (IDRIS2RC2_Constructor*)" ++ sc' ++ ";"
    decreaseIndentation
    emit EmptyFC "} else {"
    increaseIndentation
    dupVars (conArgs \\ shouldDrop)
    removeVars [sc']
    decreaseIndentation
    emit EmptyFC "}"

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
data Sink = SinkVar Bool String | SinkReturn

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
finalizeSink : {auto oft : Ref OutfileText Output}
            -> {auto il : Ref IndentLevel Nat}
            -> FC -> Sink -> String -> Core ()
finalizeSink fc (SinkVar True target) valStr = emit fc "IDRIS2RC2_Value * \{target} = \{valStr};"
finalizeSink fc (SinkVar False target) valStr = emit fc "\{target} = \{valStr};"
finalizeSink fc SinkReturn valStr = emit fc "return \{valStr};"

integer_switch : List RConstAlt -> Bool
integer_switch [] = True
integer_switch (MkRConstAlt c _  :: _) =
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
||| underlying type, per `integer_switch`). The pointer-tagged unboxed
||| representation used for Int8/Int16/Int32 (like Bits8/Bits16/Bits32/
||| Char) carries no runtime type tag of its own to say whether the stored
||| bit pattern should be read back signed or unsigned -- unlike
||| `idris2rc2_extractInt`'s generic fallback (always an unsigned
||| zero-extend, harmless for the unsigned types but wrong for negative
||| Int8/16/32 literals, e.g. -128 would extract as 128), this picks the
||| same type-specific signed accessor the native-unboxing path already
||| uses (see `rcVarToNativeC`/`nativeUnbox`).
extractIntExpr : Constant -> String -> String
extractIntExpr (I8 _) x = "idris2rc2_to_i8(\{x})"
extractIntExpr (I16 _) x = "idris2rc2_to_i16(\{x})"
extractIntExpr (I32 _) x = "idris2rc2_to_i32(\{x})"
extractIntExpr _ x = "idris2rc2_extractInt(\{x})"

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
makeClosureInto : {auto a : Ref ArgCounter Nat}
                -> {auto oft : Ref OutfileText Output}
                -> {auto il : Ref IndentLevel Nat}
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
makeClosure : {auto a : Ref ArgCounter Nat}
            -> {auto oft : Ref OutfileText Output}
            -> {auto il : Ref IndentLevel Nat}
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
buildClosureIntoSink : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> FC -> Sink -> Name -> List RCLocal -> Nat -> Core ()
buildClosureIntoSink fc (SinkVar declare target) n args missing =
    makeClosureInto fc declare target n args missing
buildClosureIntoSink fc SinkReturn n args missing = do
    closure <- makeClosure fc n args missing
    emit fc "return \{closure};"

-- Must match the dispatch switch in support/rc2/runtime.c.
MaxExtractFunArgs : Nat
MaxExtractFunArgs = 8

||| RC.idr wraps a branch/scope body in a leading `RDrop` node whenever
||| there are dead owned variables at its entry. Peel it off so its drop
||| list can be refined by the reuse-in-place analysis below (instead of
||| unconditionally emitting the drops as-is).
peelDrop : RCExp -> (List RCLocal, RCExp)
peelDrop (RDrop _ locs cont) = (locs, cont)
peelDrop e = ([], e)

mutual
    ||| Declare an `RLet`'s own binding: record its `Rep` (so later *uses*
    ||| of `var` can look it up), then either inline it (a literal, or an
    ||| `RInlineNative`), declare a plain native C scalar, or build/copy
    ||| its Boxed value into `var_N`. Shared by `emitRC`'s and
    ||| `emitNativeValue`'s own `RLet` cases (identical in both except
    ||| for what continues afterward, which each caller keeps to itself)
    ||| *and* `tryBuildClosureInto`'s own `RLet` case -- an `RLet`
    ||| standing between it and a closure-shaped tail expression still
    ||| needs its binding declared exactly as it would be anywhere else,
    ||| it just isn't the end of that search.
    declareLet : {auto a : Ref ArgCounter Nat}
               -> {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
               -> {auto r : Ref RepMap (SortedMap Int Rep)}
               -> {auto lm : Ref InlineMap (SortedMap Int String)}
               -> {auto fa : Ref FunctionArgs (List Int)}
               -> FC -> Int -> Rep -> RCExp -> Core ()
    declareLet fc var rep value = do
        update RepMap (insert var rep)
        case (rep, value) of
             (RNative _, RPrimVal _ c) => update InlineMap (insert var (nativeLitExpr c))
             (RInlineNative ty, _) => inlineNative ty var value
             (RNative ty, _) => declareNative fc ty var value
             (RBoxed, _) => emitInto fc (SinkVar True "var_\{show var}") NotInTailPosition value

    ||| If `value` is a self-tail-call (`RSelfTailCall`, see its own doc
    ||| comment) -- possibly wrapped in leading RDup/RDrop/RFree/RLet,
    ||| same as `tryBuildClosureInto` -- emit the loop-back: snapshot
    ||| every new argument value into a fresh temporary first (a plain
    ||| simultaneous-assignment safeguard against aliasing, e.g.
    ||| `f x y = f y x` -- nothing here is an ownership decision,
    ||| `annotate` (Phase 2) already decided every argument's dup/move
    ||| before Compiler.RC2.Loop ever ran, see `RSelfTailCall`'s own doc
    ||| comment), reassign the function's own parameter variables from
    ||| those temporaries, then `goto loop;`.
    |||
    ||| Returns `Nothing` if the loop-back was emitted (nothing left for
    ||| the caller to assign or return -- control already left via the
    ||| `goto`), or `Just leftover` using the same leftover protocol as
    ||| `tryBuildClosureInto`, for the same reason (a peeled wrapper's
    ||| side effect must not be emitted twice).
    tryEmitSelfTailCall : {auto a : Ref ArgCounter Nat}
                        -> {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                        -> {auto r : Ref RepMap (SortedMap Int Rep)}
                        -> {auto lm : Ref InlineMap (SortedMap Int String)}
                        -> {auto fa : Ref FunctionArgs (List Int)}
                        -> RCExp -> Core (Maybe RCExp)
    tryEmitSelfTailCall (RDup fc v cont) = do
        dupVars [varName v]
        tryEmitSelfTailCall cont
    tryEmitSelfTailCall (RDrop fc vs cont) = do
        -- `vs` is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> vs)
        tryEmitSelfTailCall cont
    tryEmitSelfTailCall (RFree fc v cont) = do
        freeVars [varName v]
        tryEmitSelfTailCall cont
    tryEmitSelfTailCall (RLet fc var rep value body) = do
        declareLet fc var rep value
        tryEmitSelfTailCall body
    tryEmitSelfTailCall (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        tryEmitSelfTailCall cont
    tryEmitSelfTailCall (RSelfTailCall fc newArgs) = do
        fnArgs <- get FunctionArgs
        temps <- traverse (\v => do
            t <- getNewVarThatWillNotBeFreedAtEndOfBlock
            vStr <- rcVarToBoxedC v
            emit fc "IDRIS2RC2_Value *\{t} = \{vStr};"
            pure t) newArgs
        traverse_ (\(argId, t) => emit fc "var_\{show argId} = \{t};") (zip fnArgs temps)
        emit fc "goto loop;"
        pure Nothing
    tryEmitSelfTailCall e = pure (Just e)

    ||| If `value` is a partial application (RUnderApp), or an InTailPosition
    ||| tail call (RAppName -- see emitRC's own RAppName case, which only
    ||| ever produces a bare closure name in that tail position, never
    ||| otherwise) -- either possibly wrapped in leading RDup/RDrop/RFree for
    ||| their own operands' refcounting, or in one or more RLet bindings
    ||| that have nothing to do with the closure itself (both of which
    ||| `annotate`/Phase 1's own ANF normalisation can wrap around any
    ||| expression uniformly, without changing what the *tail* expression
    ||| actually is) -- lower those wrappers first, then build the closure
    ||| directly into `sink` (via `buildClosureIntoSink`/`makeClosureInto`)
    ||| instead of the throwaway `closure_N` a generic `emitRC value`
    ||| would produce (only to have the caller immediately copy it into
    ||| the real destination right after -- two statements for one).
    |||
    ||| Returns `Nothing` if the closure was built (nothing left for the
    ||| caller to do), or `Just leftover` if `value` wasn't shaped like
    ||| this at all -- `leftover` is *not* always `value` itself: peeling
    ||| an RDup/RDrop/RFree/RLet wrapper on the way down already emits
    ||| that wrapper's own side effect (a dup/drop/free call, or a let
    ||| declaration), so if the search dead-ends partway through, the
    ||| caller must resume from what's left (the innermost un-peeled
    ||| expression), not restart from `value` -- re-running `emitRC` on
    ||| the original `value` would emit every wrapper's side effect a
    ||| second time. (An earlier version returned a bare `Bool` and had
    ||| exactly this bug: any Boxed `RLet` whose value was e.g. an
    ||| RDup-wrapped non-tail-position `RAppName` -- an ordinary, common
    ||| shape, not exotic -- had its dup emitted twice, permanently
    ||| leaking one reference. Found via `Prelude.Types.foldr`.)
    tryBuildClosureInto : {auto a : Ref ArgCounter Nat}
                        -> {auto oft : Ref OutfileText Output}
                        -> {auto il : Ref IndentLevel Nat}
                        -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                        -> {auto r : Ref RepMap (SortedMap Int Rep)}
                        -> {auto lm : Ref InlineMap (SortedMap Int String)}
                        -> {auto fa : Ref FunctionArgs (List Int)}
                        -> Sink -> TailPositionStatus -> RCExp -> Core (Maybe RCExp)
    tryBuildClosureInto sink tailPosition (RDup fc v cont) = do
        dupVars [varName v]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RDrop fc vs cont) = do
        -- `vs` is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> vs)
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RFree fc v cont) = do
        freeVars [varName v]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink tailPosition (RLet fc var rep value body) = do
        declareLet fc var rep value
        tryBuildClosureInto sink tailPosition body
    tryBuildClosureInto sink tailPosition (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        tryBuildClosureInto sink tailPosition cont
    tryBuildClosureInto sink _ (RUnderApp fc n missing args) = do
        buildClosureIntoSink fc sink n args missing
        pure Nothing
    tryBuildClosureInto sink InTailPosition (RAppName fc _ n args) = do
        buildClosureIntoSink fc sink n args 0
        pure Nothing
    tryBuildClosureInto _ _ e = pure (Just e)

    ||| Render `value`'s native expression and declare it as a plain
    ||| `TYPE var_N = ...;` C scalar, discharging its own pending
    ||| Boxed-operand drop(s) immediately after (see `emitNativeValue`'s
    ||| own doc comment for why that ordering matters). Shared by
    ||| `emitRC`'s and `emitNativeValue`'s own RLet cases for a plain
    ||| (non-inlined) `RNative` local -- identical in both except for
    ||| what continues afterward, which each caller keeps to itself.
    declareNative : {auto a : Ref ArgCounter Nat}
                  -> {auto oft : Ref OutfileText Output}
                  -> {auto il : Ref IndentLevel Nat}
                  -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                  -> {auto r : Ref RepMap (SortedMap Int Rep)}
                  -> {auto lm : Ref InlineMap (SortedMap Int String)}
                  -> {auto fa : Ref FunctionArgs (List Int)}
                  -> FC -> PrimType -> Int -> RCExp -> Core ()
    declareNative fc ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        emit fc $ "\{nativeCType ty} var_\{show var} = \{valStr};"
        removeVars $ map varName pending

    ||| As `declareNative`, but for an `RInlineNative` local: no C
    ||| variable ever declared, its rendered expression goes straight
    ||| into InlineMap instead (see `Rep.RInlineNative`'s own doc
    ||| comment). Also shared by `emitRC`'s and `emitNativeValue`'s own
    ||| RLet cases.
    inlineNative : {auto a : Ref ArgCounter Nat}
                 -> {auto oft : Ref OutfileText Output}
                 -> {auto il : Ref IndentLevel Nat}
                 -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                 -> {auto r : Ref RepMap (SortedMap Int Rep)}
                 -> {auto lm : Ref InlineMap (SortedMap Int String)}
                 -> {auto fa : Ref FunctionArgs (List Int)}
                 -> PrimType -> Int -> RCExp -> Core ()
    inlineNative ty var value = do
        (valStr, pending) <- emitNativeValue ty value
        update InlineMap (insert var valStr)
        removeVars $ map varName pending

    ||| Evaluate `value` (in `tailPosition`) and dispose of its result per
    ||| `sink` -- either declaring/assigning a named C variable, or (only
    ||| ever while `tailPosition` is `InTailPosition`, since nothing after
    ||| a `return` would run) emitting a plain C `return` statement. Tries
    ||| `tryEmitSelfTailCall` first (a self-tail-call has nothing to hand
    ||| any `Sink` at all -- control leaves via `goto` -- see its own doc
    ||| comment), then `tryBuildClosureInto` (skips a throwaway `closure_N`
    ||| when `value` is a closure build that can go straight into `sink`
    ||| -- see its own doc comment). A leftover `RCmpCase`/`RConCase`/
    ||| `RConstCase` is handled specially too (`emitCmpCaseInto`/
    ||| `emitConCaseInto`/`emitConstCaseInto`), so every branch writes
    ||| straight into the *caller's own* `sink` instead of a throwaway
    ||| `switchReturnVar` that then has to be copied into it -- the same
    ||| "build directly into the real destination" idea as
    ||| `tryBuildClosureInto`, applied to branching constructs (and,
    ||| in tail position, letting a whole chain of nested cases collapse
    ||| straight down to a `return` in each leaf branch, with no
    ||| intermediate variable anywhere along the way). Anything else (a
    ||| genuine single-expression leaf: `RV`, `RCon`, `ROp`, `RExtPrim`,
    ||| `RPrimVal`, `RErased`, `RCrash`, `RApp`, a non-tail `RAppName`)
    ||| falls back to the general `emitRC`-then-`finalizeSink` route.
    ||| Every "evaluate this RCExp and store/return its result" site in
    ||| this module goes through here, so the choice between those routes
    ||| is only ever written once.
    emitInto : {auto a : Ref ArgCounter Nat}
             -> {auto oft : Ref OutfileText Output}
             -> {auto il : Ref IndentLevel Nat}
             -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
             -> {auto r : Ref RepMap (SortedMap Int Rep)}
             -> {auto lm : Ref InlineMap (SortedMap Int String)}
             -> {auto fa : Ref FunctionArgs (List Int)}
             -> FC -> Sink -> TailPositionStatus -> RCExp -> Core ()
    emitInto fc sink tailPosition value = do
        -- Same "resume from the leftover, not the original value" care
        -- as tryBuildClosureInto's own doc comment explains, chained
        -- across every stage.
        afterSelfTail <- tryEmitSelfTailCall value
        whenJust afterSelfTail $ \v1 => do
            leftover <- tryBuildClosureInto sink tailPosition v1
            whenJust leftover $ \remaining =>
                case remaining of
                     RCmpCase fc' op args postDrop whenTrue whenFalse =>
                         emitCmpCaseInto sink tailPosition fc' op args postDrop whenTrue whenFalse
                     RConCase fc' sc alts mDef =>
                         emitConCaseInto sink tailPosition fc' sc alts mDef
                     RConstCase fc' sc alts def =>
                         emitConstCaseInto sink tailPosition fc' sc alts def
                     _ => do
                         valStr <- emitRC remaining tailPosition
                         finalizeSink fc sink valStr

    ||| A case branch (or default): emit the drops RC.idr's `annotate`
    ||| already decided on (the peeled leading RDrop), preceded by the
    ||| mechanical lowering of a reuse offer if Compiler.RC2.Reuse left
    ||| one on this alt (`offersReuse`, see RConAlt's own doc comment --
    ||| `Nothing` for every non-matched-constructor branch, since only a
    ||| matched constructor scrutinee can ever be offered), then the
    ||| body itself. Mirrors RC2/RefC's `concaseBody`.
    |||
    ||| `matched`, when `Just (sc, conArgs)`, means this branch destructured
    ||| `conArgs` directly out of `sc`'s own storage (`sc->args[k]`) --
    ||| plain pointer aliasing, not independently reference-counted. Any
    ||| `conArgs` entry that survives past this branch (i.e. isn't itself
    ||| in the peeled drop list) therefore needs an explicit dup *here*,
    ||| before `sc` potentially goes away below, or `sc`'s own teardown
    ||| would free/repurpose storage a still-live field is pointing into.
    ||| `conArgs` entries that *are* already dying are deliberately left
    ||| out of the flat drop list -- their release comes for free from
    ||| however `sc` itself gets torn down (ordinary recursive
    ||| idris2rc2_drop, or the reuse check below), so dropping them a
    ||| second time here would double-free. This applies unconditionally
    ||| to *every* matched-constructor branch, not only ones offering
    ||| reuse -- it's what makes destructured fields safe to keep using at
    ||| all, independent of whether Compiler.RC2.Reuse ever fires.
    |||
    ||| `offersReuse` additionally selects, only for `sc` itself, and only
    ||| when `sc` is actually in the peeled drop list, whether its own
    ||| release goes through the ordinary path (a plain drop, folded into
    ||| the same flat removeVars call as everything else) or the reuse
    ||| uniqueness check (`emitReuseOffer`). `sc` not being in the drop
    ||| list at all (still owned elsewhere) means nothing is emitted for
    ||| it here either way.
    branchBody : {auto a : Ref ArgCounter Nat}
               -> {auto oft : Ref OutfileText Output}
               -> {auto il : Ref IndentLevel Nat}
               -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
               -> {auto r : Ref RepMap (SortedMap Int Rep)}
               -> {auto lm : Ref InlineMap (SortedMap Int String)}
               -> {auto fa : Ref FunctionArgs (List Int)}
               -> (matched : Maybe (RCLocal, List String)) -> (offersReuse : Bool)
               -> Sink -> RCExp -> TailPositionStatus -> Core ()
    branchBody matched offersReuse sink body tailPosition = do
        let (shouldDrop0, body') = peelDrop body
        -- shouldDrop0 is already guaranteed Boxed-only -- see the
        -- module note.
        let shouldDrop = varName <$> shouldDrop0
        case matched of
             Nothing => removeVars shouldDrop
             Just (sc, conArgs) => do
                 let sc' = varName sc
                 if offersReuse
                    then do
                        emitReuseOffer sc conArgs shouldDrop
                        removeVars (shouldDrop \\ (sc' :: conArgs))
                    else do
                        dupVars (conArgs \\ shouldDrop)
                        removeVars (shouldDrop \\ conArgs)
        -- `sink` is already fully resolved -- any variable it names was
        -- declared once by the enclosing RConCase/RConstCase/RCmpCase
        -- before any branch ran (see `resolveSink`), or it's `SinkReturn`
        -- and names nothing at all.
        emitInto emptyFC sink tailPosition body'

    ||| Lower a fused comparison branch (see RCExp.idr's own doc comment
    ||| on RCmpCase and `nativeCmpExpr`): the comparison is evaluated once
    ||| into a raw C `int` (no heap allocation for the Bool it would
    ||| otherwise be), `postDrop` (Compiler.RC2.RC's `annotate`) is
    ||| lowered immediately after -- same ordering rule as ROp's own
    ||| postDrop, see its doc comment -- and then exactly one of the two
    ||| branches runs, each writing straight into `sink` (resolved once,
    ||| before either branch -- see `resolveSink`) instead of a throwaway
    ||| `switchReturnVar`.
    emitCmpCaseInto : {auto a : Ref ArgCounter Nat}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                    -> {auto r : Ref RepMap (SortedMap Int Rep)}
                    -> {auto lm : Ref InlineMap (SortedMap Int String)}
                    -> {auto fa : Ref FunctionArgs (List Int)}
                    -> Sink -> TailPositionStatus -> FC -> PrimFn 2 -> Vect 2 RCLocal
                    -> List RCLocal -> RCExp -> RCExp -> Core ()
    emitCmpCaseInto sink tailPosition fc op args postDrop whenTrue whenFalse = do
        case cmpArgTy op of
             Nothing => throw $ InternalError "[rc2] RCmpCase: not a comparison op"
             Just ty => do
                 argStrs <- rc2traverseVect (rcVarToNativeC ty) args
                 let condVar = "cmp_" ++ !(getNextCounter)
                 emit fc $ "int " ++ condVar ++ " = " ++ nativeCmpExpr op argStrs ++ ";"
                 removeVars $ map varName postDrop
                 resolvedSink <- resolveSink fc sink
                 emit emptyFC "if (\{condVar}) {"
                 increaseIndentation
                 emitInto emptyFC resolvedSink tailPosition whenTrue
                 decreaseIndentation
                 emit emptyFC "} else {"
                 increaseIndentation
                 emitInto emptyFC resolvedSink tailPosition whenFalse
                 decreaseIndentation
                 emit emptyFC "}"

    ||| Lower a constructor-tag switch: each alt (and the default, if
    ||| any) writes straight into `sink` (resolved once, before any alt
    ||| -- see `resolveSink`) instead of a throwaway `switchReturnVar`.
    emitConCaseInto : {auto a : Ref ArgCounter Nat}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                    -> {auto r : Ref RepMap (SortedMap Int Rep)}
                    -> {auto lm : Ref InlineMap (SortedMap Int String)}
                    -> {auto fa : Ref FunctionArgs (List Int)}
                    -> Sink -> TailPositionStatus -> FC -> RCLocal -> List RConAlt -> Maybe RCExp -> Core ()
    emitConCaseInto sink tailPosition fc sc alts mDef = do
        let sc' = varName sc
        resolvedSink <- resolveSink fc sink
        _ <- foldlC (\els, (MkRConAlt name coninfo tag args body offersReuse) => do
            let erased = coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
            if erased then emit emptyFC "\{els}if (NULL == \{sc'} /* \{show name} \{show coninfo} */) {"
                else if coninfo == CONS || coninfo == JUST || coninfo == SUCC
                then emit emptyFC "\{els}if (NULL != \{sc'} /* \{show name} \{show coninfo} */) {"
                else do
                    case tag of
                        -- Untagged (name-compared) constructors are
                        -- never zero-argument+tagged, so RCEmptyCon
                        -- never covers them -- sc' is always a real
                        -- heap IDRIS2RC2_Constructor* here.
                        Nothing   => emit emptyFC "\{els}if (! strcmp(((IDRIS2RC2_Constructor *)\{sc'})->name, idris2rc2_constr_\{cName name})) {"
                        -- sc' may be a tagged pointer (a zero-argument
                        -- constructor of *this* ADT, see RCEmptyCon in
                        -- RCExp.idr) as well as a real heap
                        -- IDRIS2RC2_Constructor* -- idris2rc2_conTag
                        -- (support/rc2/datatypes.h) checks which.
                        Just tag' => emit emptyFC "\{els}if (idris2rc2_conTag(\{sc'}) == \{show tag'} /* \{show name} */) {"

            increaseIndentation
            _ <- foldlC (\k, arg => do
                emit emptyFC "IDRIS2RC2_Value *var_\{show arg} = ((IDRIS2RC2_Constructor*)\{sc'})->args[\{show k}];"
                pure (S k) ) 0 args
            branchBody (Just (sc, varName . RCLoc <$> args)) (isJust offersReuse) resolvedSink body tailPosition
            decreaseIndentation
            pure "} else ") "" alts

        case mDef of
            Nothing => pure ()
            Just body => do
                emit emptyFC "} else {"
                increaseIndentation
                branchBody Nothing False resolvedSink body tailPosition
                decreaseIndentation
        emit emptyFC "}"

    ||| Lower a constant/tag switch: same "each alt writes straight into
    ||| the once-resolved `sink`" shape as `emitConCaseInto`, just over
    ||| `RConstCase`'s own two dispatch strategies (a fast integer switch
    ||| via `extractIntExpr`, or the string/double equality chain).
    emitConstCaseInto : {auto a : Ref ArgCounter Nat}
                       -> {auto oft : Ref OutfileText Output}
                       -> {auto il : Ref IndentLevel Nat}
                       -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                       -> {auto r : Ref RepMap (SortedMap Int Rep)}
                       -> {auto lm : Ref InlineMap (SortedMap Int String)}
                       -> {auto fa : Ref FunctionArgs (List Int)}
                       -> Sink -> TailPositionStatus -> FC -> RCLocal -> List RConstAlt -> Maybe RCExp -> Core ()
    emitConstCaseInto sink tailPosition fc sc alts def = do
        let sc' = varName sc
        resolvedSink <- resolveSink fc sink
        case integer_switch alts of
            True => do
                tmpint <- getNewVarThatWillNotBeFreedAtEndOfBlock
                let extractExpr : String
                    extractExpr = case alts of
                                       (MkRConstAlt c0 _ :: _) => extractIntExpr c0 sc'
                                       [] => "idris2rc2_extractInt(\{sc'})"
                emit emptyFC "int64_t \{tmpint} = \{extractExpr};"
                _ <- foldlC (\els, (MkRConstAlt c body) => do
                    emit emptyFC "\{els}if (\{tmpint} == \{const2Integer c 0}) {"
                    increaseIndentation
                    branchBody Nothing False resolvedSink body tailPosition
                    decreaseIndentation
                    pure "} else ") "" alts
                pure ()

            False => do
                _ <- foldlC (\els, (MkRConstAlt c body) => do
                    case c of
                        Str x => emit emptyFC "\{els}if (! strcmp(\{cStringQuoted x}, ((IDRIS2RC2_String *)\{sc'})->str)) {"
                        Db  x => emit emptyFC "\{els}if (((IDRIS2RC2_Double *)\{sc'})->v == \{show x}) {"
                        x => throw $ InternalError "[rc2] RConstCase : unsupported type. \{show fc} \{show x}"
                    increaseIndentation
                    branchBody Nothing False resolvedSink body tailPosition
                    decreaseIndentation
                    pure "} else ") "" alts
                pure ()

        case def of
            Nothing => pure ()
            Just body => do
                emit emptyFC "} else {"
                increaseIndentation
                branchBody Nothing False resolvedSink body tailPosition
                decreaseIndentation
        emit emptyFC "}"

    emitRC : {auto a : Ref ArgCounter Nat}
           -> {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
           -> {auto r : Ref RepMap (SortedMap Int Rep)}
           -> {auto lm : Ref InlineMap (SortedMap Int String)}
           -> {auto fa : Ref FunctionArgs (List Int)}
           -> RCExp
           -> TailPositionStatus
           -> Core String

    emitRC (RV fc v) _ = rcVarToBoxedC v
    -- InTailPosition is unreachable here: emitInto's tryBuildClosureInto
    -- always intercepts an InTailPosition RAppName itself, building the
    -- closure straight into whichever Sink the caller handed down (see
    -- buildClosureIntoSink) -- so emitRC only ever sees RAppName in
    -- NotInTailPosition, where the call must actually be resolved
    -- (trampolined) right here rather than deferred as a closure.
    emitRC (RAppName fc _ n args) InTailPosition = throw $ InternalError "[rc2] RAppName (InTailPosition) reached emitRC directly (not intercepted by tryBuildClosureInto)"
    emitRC (RAppName fc _ n args) NotInTailPosition = do
        let nargs = length args
        if nargs > MaxExtractFunArgs
           then pure "idris2rc2_trampoline(\{!(makeClosure fc n args 0)})"
           else do
               argStrs <- traverse rcVarToBoxedC args
               pure "idris2rc2_trampoline(\{cName n}(\{concat $ intersperse ", " argStrs}))"

    -- Unreachable: emitInto's tryBuildClosureInto always intercepts
    -- RUnderApp itself, for any tailPosition -- a partial application is
    -- always a closure build, tail position or not (see
    -- buildClosureIntoSink).
    emitRC (RUnderApp fc n missing args) _ = throw $ InternalError "[rc2] RUnderApp reached emitRC directly (not intercepted by tryBuildClosureInto)"
    emitRC (RApp fc _ closure arg) tailPosition = do
       closureStr <- rcVarToBoxedC closure
       argStr <- rcVarToBoxedC arg
       pure $ (case tailPosition of
           NotInTailPosition => "idris2rc2_applyClosure"
           InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"

    -- Unreachable in practice, same reasoning as RSelfTailCall's own
    -- case below: emitInto's tryBuildClosureInto always peels an RLet
    -- (declaring it via declareLet) before ever falling back to a bare
    -- emitRC call, so this construct itself should never reach emitRC
    -- directly. Failing loudly here (rather than silently re-declaring
    -- `var` a second time, or worse, skipping its declaration) is the
    -- safer choice.
    emitRC (RLet fc var rep value body) _ = throw $ InternalError "[rc2] RLet reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

    emitRC (RCon fc n coninfo tag args reuseFrom) _ = do
        if coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
            then pure "(NULL /* \{show n} */)"
            else do
                let createNewConstructor = " = idris2rc2_newConstructor("
                                 ++ (show (length args))
                                 ++ ", "  ++ maybe "-1" show tag  ++ ");"

                emit fc " // constructor \{show n}"
                -- `reuseFrom` (Compiler.RC2.Reuse) already decided
                -- whether this construction may claim an offered
                -- scrutinee's storage -- just lower it: reference the
                -- same deterministically-named reservation variable its
                -- offering RConAlt already declared (see reuseVarName),
                -- no lookup needed.
                constr <- the (Core String) $ case reuseFrom of
                    Just sc => do
                        let reuseVar = reuseVarName sc
                        emit fc "if (! \{reuseVar}) {"
                        increaseIndentation
                        emit fc $ reuseVar ++ createNewConstructor
                        decreaseIndentation
                        emit fc "}"
                        pure reuseVar
                    Nothing => do
                        let constr = "constructor_\{!(getNextCounter)}"
                        emit fc $ "IDRIS2RC2_Constructor* " ++ constr ++ createNewConstructor
                        when (Nothing == tag) $ emit fc "\{constr}->name = idris2rc2_constr_\{cName n};"
                        pure constr
                let arglist = "\{constr}->args"
                _ <- foldlC (\k, v => do
                    vStr <- rcVarToBoxedC v
                    emit EmptyFC $ "\{arglist}[\{show k}] = \{vStr};"
                    pure (S k)) 0 args
                pure "(IDRIS2RC2_Value*)\{constr}"

    emitRC (ROp fc _ op args postDrop) _ = do
        -- Reached only when Compiler.RC2.Types decided this op's result
        -- stays Boxed (comparisons, or a non-numeric op) -- operands may
        -- still individually be native locals (e.g. a comparison over an
        -- earlier native arithmetic chain), hence the Rep-aware boxing.
        argStrs <- rc2traverseVect rcVarToBoxedC args
        let resultVar = "primVar_" ++ !(getNextCounter)
        emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = " ++ cOp op argStrs ++ ";"
        -- `postDrop` (Compiler.RC2.RC's `annotate`) already lists exactly
        -- which operands are Boxed and need dropping now that this op is
        -- done reading them -- just lower it, no re-deriving here.
        removeVars $ map varName postDrop
        pure resultVar

    emitRC (RExtPrim fc _ p args) _ = do
        let prims : List String =
            ["prim__newIORef", "prim__readIORef", "prim__writeIORef", "prim__newArray",
             "prim__arrayGet", "prim__arraySet", "prim__getField", "prim__setField",
             "prim__os", "prim__codegen", "prim__onCollect", "prim__onCollectAny" ]
        case p of
            NS _ (UN (Basic pn)) =>
               unless (elem pn prims) $ throw $ InternalError $ "[rc2] Unknown primitive: " ++ cName p
            _ => throw $ InternalError $ "[rc2] Unknown primitive: " ++ cName p
        emit fc $ "// call to external primitive " ++ cName p
        -- ext-prim args are used owned/as-is (see RC.idr's module note on
        -- RExtPrim); box any that happen to be native locals first.
        argStrs <- traverse rcVarToBoxedC args
        pure $ "idris2rc2_\{cName p}("++ showSep ", " argStrs ++")"

    -- Unreachable in practice, same reasoning as RLet's own case above:
    -- emitInto's dispatch always intercepts a leftover RCmpCase/
    -- RConCase/RConstCase itself (routing it to emitCmpCaseInto/
    -- emitConCaseInto/emitConstCaseInto's Sink-aware handling) before
    -- ever falling back to a bare emitRC call. Failing loudly here is
    -- the safer choice: reaching this would mean every branch just
    -- silently reverted to a throwaway switchReturnVar, undoing the
    -- point of that dispatch without any other visible symptom.
    emitRC (RCmpCase fc op args postDrop whenTrue whenFalse) _ = throw $ InternalError "[rc2] RCmpCase reached emitRC directly (not intercepted by emitInto)"
    emitRC (RConCase fc sc alts mDef) _ = throw $ InternalError "[rc2] RConCase reached emitRC directly (not intercepted by emitInto)"
    emitRC (RConstCase fc sc alts def) _ = throw $ InternalError "[rc2] RConstCase reached emitRC directly (not intercepted by emitInto)"

    emitRC (RPrimVal fc (I x)) tailPosition = emitRC (RPrimVal fc (I64 $ cast x)) tailPosition
    emitRC (RPrimVal fc c) _ = do
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

    emitRC (RErased fc) _ = pure "NULL"
    emitRC (RCrash fc x) _ = pure "(NULL /* CRASH */)"
    -- Unreachable in practice: emitInto always tries tryEmitSelfTailCall
    -- first, which intercepts every RSelfTailCall (however deeply
    -- RDup/RDrop/RFree/RLet-wrapped) before it could ever reach a bare
    -- emitRC call -- see RSelfTailCall's own doc comment. Unlike
    -- varName's RCConst case, failing loudly here (rather than returning
    -- some placeholder string) is the safer choice: reaching this would
    -- mean the goto-loop was never emitted at all, silently turning a
    -- loop into infinite recursion.
    emitRC (RSelfTailCall fc _) _ = throw $ InternalError "[rc2] RSelfTailCall reached emitRC directly (not intercepted by tryEmitSelfTailCall)"
    -- Unreachable in practice, same reasoning as RLet's own case above:
    -- emitInto's tryBuildClosureInto always peels these wrapper nodes
    -- (emitting their own dup/drop/free/reuse-release side effect) on
    -- the way down before ever falling back to a bare emitRC call.
    emitRC (RDrop fc locs cont) _ = throw $ InternalError "[rc2] RDrop reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RDup fc loc cont) _ = throw $ InternalError "[rc2] RDup reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RFree fc loc cont) _ = throw $ InternalError "[rc2] RFree reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"
    emitRC (RReleaseReuse fc loc cont) _ = throw $ InternalError "[rc2] RReleaseReuse reached emitRC directly (not intercepted by emitInto/tryBuildClosureInto)"

    ||| The raw C expression for a value Compiler.RC2.Types has decided is
    ||| Native ty -- only ROp/RPrimVal ever get marked this way.
    -- Returns the native C expression for `e` together with any Boxed
    -- locals `e`'s own tail op reads but doesn't own a further use of --
    -- Compiler.RC2.RC's `annotate` already decided those are "consumed"
    -- here (see splitBorrows), so they need exactly one drop, but not
    -- before the expression string is actually *read* by whichever
    -- statement the caller embeds it in. The caller (either emitRC's
    -- RLet case below, or this function's own RLet case) is what emits
    -- that statement, so it -- not this function -- is what must emit the
    -- drop, and only *after* doing so: emitting it here unconditionally
    -- would run the drop before the value it reads from is ever used,
    -- freeing it out from under its own extraction (a real regression an
    -- earlier version of this fix hit for heap-allocated 64-bit types).
    emitNativeValue : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> {auto fa : Ref FunctionArgs (List Int)}
                     -> PrimType -> RCExp -> Core (String, List RCLocal)
    emitNativeValue ty (ROp fc _ op args postDrop) = do
        argStrs <- rc2traverseVect (\v => rcVarToNativeC (opArgTyFor ty op) v) args
        -- `postDrop` is exactly the Boxed operands this op needs dropped
        -- (Compiler.RC2.RC's `annotate` already decided this, same as
        -- emitRC's boxed-ROp case) -- a native-result op still reads
        -- them (via rcVarToNativeC's unboxing above) and owes them that
        -- same cleanup, we just can't emit it *here*: unlike emitRC, our
        -- caller hasn't necessarily emitted the statement that actually
        -- performs the read yet (we only return an inline expression
        -- string), so dropping now could run before that read happens.
        -- Hand `postDrop` back so whoever *does* emit that statement can
        -- drop right after it -- see this function's own doc comment.
        pure (nativeOpExpr op argStrs, postDrop)
    emitNativeValue ty (RPrimVal fc c) = pure (nativeLitExpr c, [])
    -- RC.idr's own ANF-normalisation wraps any non-trivial operand (e.g. a
    -- literal) in a synthetic RLet before the "real" ROp/RPrimVal --
    -- declare it (native or boxed, whichever Compiler.RC2.Types decided)
    -- and keep unwinding to find the tail expression. This synthetic
    -- let's own value gets its pending-drop list (if any) discharged
    -- right here, immediately after its own declaration statement; only
    -- `body`'s eventual tail-op pending list is returned onward.
    emitNativeValue ty (RLet fc var rep value body) = do
        declareLet fc var rep value
        emitNativeValue ty body
    -- A native-typed let's *value* can still legitimately be wrapped in
    -- RDup/RDrop/RFree: those govern its own boxed operands (e.g. `x + x`
    -- where `x` is a boxed parameter needs a dup before the add), which is
    -- an entirely separate concern from whether the op's *result* ends up
    -- native. Just lower the wrapper and keep unwinding.
    emitNativeValue ty (RDup fc loc cont) = do
        dupVars [varName loc]
        emitNativeValue ty cont
    emitNativeValue ty (RFree fc loc cont) = do
        freeVars [varName loc]
        emitNativeValue ty cont
    emitNativeValue ty (RDrop fc locs cont) = do
        -- locs is already guaranteed Boxed-only -- see the module note.
        removeVars (varName <$> locs)
        emitNativeValue ty cont
    emitNativeValue ty (RReleaseReuse fc loc cont) = do
        removeReuseConstructors [reuseVarName loc]
        emitNativeValue ty cont
    emitNativeValue ty e = throw $ InternalError "[rc2] internal: expected a native-producing expression"

addCommaToList : List String -> List String
addCommaToList [] = []
addCommaToList (x :: xs) = ("  " ++ x) :: map (", " ++) xs

getArgsNrList : List ty -> Nat -> List Nat
getArgsNrList [] _ = []
getArgsNrList (x :: xs) k = k :: getArgsNrList xs (S k)

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
cTypeOfCFType CFString        = "char *"
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

varNamesFromList : List ty -> Nat -> List String
varNamesFromList str k = map (("var_" ++) . show) (getArgsNrList str k)

createFFIArgList : List CFType
                -> Core $ List (String, String, CFType)
createFFIArgList cftypeList = do
    let sList = map cTypeOfCFType cftypeList
    let varList = varNamesFromList cftypeList 1
    pure $ zip3 sList varList cftypeList

emitFDef : {auto oft : Ref OutfileText Output}
        -> {auto il : Ref IndentLevel Nat}
        -> (funcName:Name)
        -> (arglist:List (String, String, CFType))
        -> Core ()
emitFDef funcName [] = emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName ++ "(void)"
emitFDef funcName ((varType, varName, varCFType) :: xs) = do
    emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName
    emit EmptyFC "("
    increaseIndentation
    emit EmptyFC $ "  IDRIS2RC2_Value *" ++ varName
    traverse_ (\(varType, varName, varCFType) => emit EmptyFC $ ", IDRIS2RC2_Value *" ++ varName) xs
    decreaseIndentation
    emit EmptyFC ")"

-- RefC-tagged foreign calls go to our own runtime (buffer.c's own
-- functions, which expect the whole IDRIS2RC2_Buffer.buf allocation
-- including its `int size` header -- they read/write it themselves), so
-- CFBuffer is unwrapped one level only. C-tagged foreign calls (e.g.
-- `supportC`'s libidris2_support functions like idris2_readBufferData) are
-- generic byte-buffer functions with no notion of that header -- they
-- expect a flat pointer straight to the data, so CFBuffer must skip past
-- it too. Mirrors RefC.idr's `CLang`/`CLangC`/`CLangRefC` split.
data CLang = CLangC | CLangRefC

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
extractValue _ (CFStruct x xs)  varName = assert_total $ idris_crash ("INTERNAL ERROR: Struct access not implemented: " ++ varName)
extractValue _ (CFUser x xs)    varName = "(IDRIS2RC2_Value*)" ++ varName
extractValue _ n _ = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

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
packCFType CFGCPtr         varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
packCFType CFBuffer        varName = "idris2rc2_mkBuffer(" ++ varName ++ ")"
packCFType CFWorld         _       = "(IDRIS2RC2_Value *)NULL"
packCFType (CFFun x y)     varName = "makeFunction(" ++ varName ++ ")"
packCFType (CFIORes x)     varName = packCFType x varName
packCFType (CFStruct x xs) varName = "makeStruct(" ++ varName ++ ")"
packCFType (CFUser x xs)   varName = varName
packCFType n _ = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

discardLastArgument : List ty -> List ty
discardLastArgument [] = []
discardLastArgument xs@(_ :: _) = init xs

additionalFFIStub : Name -> List CFType -> CFType -> String
additionalFFIStub name argTypes (CFIORes retType) = additionalFFIStub name (discardLastArgument argTypes) retType
additionalFFIStub name argTypes retType =
    cTypeOfCFType retType ++
    " (*" ++ cName name ++ ")(" ++
    (concat $ intersperse ", " $ map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"

-- Accepted FFI tags, in priority order. "RefC" is accepted (and treated as
-- directly callable, not stubbed) because prelude/base/contrib bake a
-- handful of load-bearing low-level primitives (fastPack, fastConcat,
-- fastUnpack, string iterators) into %foreign/%transform pairs hardcoded
-- to the "RefC" tag; our own runtime provides matching C symbols for
-- those so we can reuse the declarations as-is instead of forking prelude.
ffiTags : List String
ffiTags = ["RC2", "RefC", "C"]

createCFunctions : {auto c : Ref Ctxt Defs}
                -> {auto a : Ref ArgCounter Nat}
                -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                -> {auto f : Ref FunctionDefinitions (List String)}
                -> {auto oft : Ref OutfileText Output}
                -> {auto il : Ref IndentLevel Nat}
                -> {auto h : Ref HeaderFiles (SortedSet String)}
                -> Name
                -> RCDef
                -> Core ()
createCFunctions n (MkRCFun args isLoop body) = do
    let nargs = length args
    let fn = "IDRIS2RC2_Value *\{cName !(getFullName n)}"
            ++ (if nargs == 0 then "(void)"
               else if nargs > MaxExtractFunArgs then "(IDRIS2RC2_Value *var_arglist[\{show nargs}])"
               else ("\n(\n" ++ (showSep "\n" $ addCommaToList (map (\i =>  "  IDRIS2RC2_Value * var_" ++ (show i)) args))) ++ "\n)")
    update FunctionDefinitions $ \otherDefs => (fn ++ ";\n") :: otherDefs

    emit EmptyFC fn
    emit EmptyFC "{"
    increaseIndentation
    when (nargs > MaxExtractFunArgs) $ do
      _ <- foldlC (\i, j => do
         emit EmptyFC "IDRIS2RC2_Value *var_\{show j} = var_arglist[\{show i}];"
         pure $ i + 1) 0 args
      pure ()
    -- Populated incrementally as each RLet is emitted below (its Rep is
    -- already decided and stored on the node by Compiler.RC2.RC; this map
    -- just lets *use* sites, which only have a bare RCLocal id, look it
    -- back up).
    _ <- newRef RepMap (the (SortedMap Int Rep) empty)
    -- Populated instead of RepMap+a declaration for any RLet whose value
    -- is a bare literal -- see InlineMap's own comment.
    _ <- newRef InlineMap (the (SortedMap Int String) empty)
    -- Only actually consulted if isLoop (by tryEmitSelfTailCall), but
    -- cheap enough to always set -- see FunctionArgs' own comment.
    _ <- newRef FunctionArgs args
    -- `isLoop` (Compiler.RC2.Loop) is the only thing that decides
    -- whether this label exists -- Emit.idr doesn't re-derive it by
    -- scanning `body` itself.
    when isLoop $ emit EmptyFC "loop:;"
    -- emitInto's own tryEmitSelfTailCall-first protocol handles a
    -- self-tail-call body correctly on its own (goto, no return); for
    -- anything else, SinkReturn makes every reachable tail leaf --
    -- including inside a nested RCmpCase/RConCase/RConstCase -- emit its
    -- own `return` directly, no intermediate switchReturnVar anywhere.
    emitInto EmptyFC SinkReturn InTailPosition body
    decreaseIndentation
    emit EmptyFC  "}\n"
    emit EmptyFC  ""
    pure ()

createCFunctions n (MkRCCon Nothing _ _) = do
  let n' = cName n
  update FunctionDefinitions $ \otherDefs => "char const idris2rc2_constr_\{n'}[];" :: otherDefs
  emit EmptyFC "char const idris2rc2_constr_\{n'}[] = \{cStringQuoted $ show n};"
  pure ()

createCFunctions n (MkRCCon tag arity nt) = do
  emit EmptyFC $ ( "// \{show n} Constructor tag " ++ show tag ++ " arity " ++ show arity)

createCFunctions n (MkRCForeign ccs fargs ret) = do
  case parseCC ffiTags ccs of
      Just (lang, fctForeignName :: extLibOpts) => do
          let isStandardFFI = elem lang ffiTags
          let cLang = if lang == "RefC" then CLangRefC else CLangC
          let fctName = if isStandardFFI
                           then UN $ Basic $ fctForeignName
                           else NS (mkNamespace lang) n
          if isStandardFFI
             then case extLibOpts of
                      [lib, header] => update HeaderFiles $ insert header
                      _ => pure ()
             else emit EmptyFC $ additionalFFIStub fctName fargs ret
          let fnDef = "IDRIS2RC2_Value *" ++ (cName n) ++ "(" ++ showSep ", " (replicate (length fargs) "IDRIS2RC2_Value *") ++ ");"
          update FunctionDefinitions $ \otherDefs => (fnDef ++ "\n") :: otherDefs
          typeVarNameArgList <- createFFIArgList fargs

          emitFDef n typeVarNameArgList
          emit EmptyFC "{"
          increaseIndentation
          emit EmptyFC $ " // ffi call to " ++ cName fctName
          let removeVarsArgList = removeVars ((\(_, varName, _) => varName) <$> typeVarNameArgList)
          case ret of
              CFIORes CFUnit => do
                  emit EmptyFC $ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC "return NULL;"
              CFIORes ret => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC $ "return (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"
              _ => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue cLang vt vn) typeVarNameArgList)
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC $ "return (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"

          decreaseIndentation
          emit EmptyFC "}"
      _ => throw $ InternalError "[rc2] FFI not found for \{cName n}"

createCFunctions n (MkRCError exp) = throw $ InternalError "[rc2] Error with expression"

header : {auto f : Ref FunctionDefinitions (List String)}
      -> {auto o : Ref OutfileText Output}
      -> {auto il : Ref IndentLevel Nat}
      -> {auto h : Ref HeaderFiles (SortedSet String)}
      -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
      -> Core ()
header = do
    let initLines = """
      #include <idris2rc2_runtime.h>
      /* \{ generatedString "rc2" } */

      """
    let headerFiles = Prelude.toList !(get HeaderFiles)
    fns <- get FunctionDefinitions
    update OutfileText $ appendL $
        [initLines] ++
        map (\h => "#include <\{h}>\n") headerFiles ++
        ["\n// function definitions"] ++
        fns ++
        ["\n// constant value definitions"] ++
        map (uncurry genConstant) (SortedMap.toList !(get ConstDef))
  where
    go : ConstDef -> String -> String -> String -> String
    go cdef ty tag v =
      "static IDRIS2RC2_\{ty} const \{constantName cdef}"
        ++ " = { IDRIS2RC2_STOCKVAL(IDRIS2RC2_TAG_\{tag}), \{v} };"
    genConstant : Constant -> ConstDef -> String
    genConstant c cdef = case c of
      I x   => go cdef "Int64" "INT64" (showIntMin x)
      I64 x => go cdef "Int64" "INT64" (showInt64Min x)
      B64 x => go cdef "Bits64" "BITS64" "UINT64_C(\{show x})"
      Db x  => go cdef "Double" "DOUBLE" (show x)
      Str x => go cdef "String" "STRING" (cStringQuoted x)
      _ => "/* bad constant */"

footer : {auto il : Ref IndentLevel Nat}
      -> {auto f : Ref OutfileText Output}
      -> {auto h : Ref HeaderFiles (SortedSet String)}
      -> Core ()
footer = do
    emit EmptyFC """

      // main function
      int main(int argc, char *argv[])
      {
          \{ ifThenElse (contains "idris_support.h" !(get HeaderFiles))
                        "idris2_setArgs(argc, argv);"
                        ""
          }
          IDRIS2RC2_Value *mainExprVal = __mainExpression_0();
          idris2rc2_trampoline(mainExprVal);
          return 0;
      }
      """

export
generateCSourceFile : {auto c : Ref Ctxt Defs}
                   -> List (Name, RCDef)
                   -> (outn : String)
                   -> Core ()
generateCSourceFile defs outn =
  do _ <- newRef ArgCounter 0
     _ <- newRef FunctionDefinitions []
     _ <- newRef ConstDef Data.SortedMap.empty
     _ <- newRef OutfileText DList.Nil
     _ <- newRef HeaderFiles empty
     _ <- newRef IndentLevel 0
     traverse_ (uncurry createCFunctions) defs
     header
     footer
     fileContent <- get OutfileText
     let code = fastConcat (map (++ "\n") (reify fileContent))

     coreLift_ $ writeFile outn code
     log "compiler.refc" 10 $ "Generated C file " ++ outn
