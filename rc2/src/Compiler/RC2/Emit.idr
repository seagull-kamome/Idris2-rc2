module Compiler.RC2.Emit

-- RCExp -> C. Purely mechanical: every ownership decision (dup/drop/free,
-- and what to drop and when) and every native-vs-boxed representation
-- decision was already made by Compiler.RC2.RC during the Lifted -> RCExp
-- conversion, and is baked into the tree as data (explicit RDup/RDrop/
-- RFree nodes, RLet's Rep field). This module never (re)analyses either of
-- those; it just maintains a small incrementally-built `RepMap` so that a
-- *use* of a local (which only carries its RCLocal id) can look back up
-- the Rep its binding RLet already decided. Every local variable use
-- (RV, and every RCLocal appearing as a call/constructor/op argument) is
-- lowered as-is, with no per-use dup decision: any refcount adjustment a
-- use needs has already been made explicit as a wrapping RDup/RDrop/RFree
-- node earlier in the tree, which this module just lowers to the matching
-- runtime call. The only thing this module still *decides* is the
-- constructor-reuse-in-place optimization (see RCExp.idr's module note) --
-- it locally tracks a reuse map exactly as RC2's Stage 0 emission walk
-- did, just now reading candidate drop lists off of RDrop nodes instead of
-- computing them itself.

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

-- Raw C expression for a native-eligible PrimFn, given each operand's
-- already-native-or-unboxed C expression string.
nativeOpExpr : {0 arity : Nat} -> PrimFn arity -> Vect arity String -> String
nativeOpExpr (Add ty)    [x, y] = "(" ++ x ++ " + " ++ y ++ ")"
nativeOpExpr (Sub ty)    [x, y] = "(" ++ x ++ " - " ++ y ++ ")"
nativeOpExpr (Mul ty)    [x, y] = "(" ++ x ++ " * " ++ y ++ ")"
nativeOpExpr (Div ty)    [x, y] =
    if isSigned ty then "idris2rc2_ediv_i" ++ bits ty ++ "(" ++ x ++ ", " ++ y ++ ")"
                   else "(" ++ x ++ " / " ++ y ++ ")"
  where
    bits : PrimType -> String
    bits IntType = "64"; bits Int8Type = "8"; bits Int16Type = "16"
    bits Int32Type = "32"; bits Int64Type = "64"; bits _ = "64"
nativeOpExpr (Mod ty)    [x, y] =
    if isSigned ty then "idris2rc2_emod_i" ++ bits ty ++ "(" ++ x ++ ", " ++ y ++ ")"
                   else "(" ++ x ++ " % " ++ y ++ ")"
  where
    bits : PrimType -> String
    bits IntType = "64"; bits Int8Type = "8"; bits Int16Type = "16"
    bits Int32Type = "32"; bits Int64Type = "64"; bits _ = "64"
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

-- A native op's operands all share its own `ty` except Cast's single
-- argument, whose *source* type is the op's own `i`, not the result
-- type `ty`. Shared by emitNativeValue's ROp case and
-- tryInlineNativeOp, which both need to render an ROp's operands.
opArgTyFor : PrimType -> PrimFn arity -> PrimType
opArgTyFor _ (Cast i _) = i
opArgTyFor ty _ = ty

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
data EnvTracker : Type where
data FunctionDefinitions : Type where
data IndentLevel : Type where
data HeaderFiles : Type where
data RepMap : Type where
-- Native-rep locals whose defining expression is safe and worthwhile to
-- splice directly into their (sole) use site instead of ever being
-- declared as a C variable at all -- holds the already-rendered C
-- expression text, keyed by local id. Two cases populate this:
--   1. A bare literal (Compiler.RC2.RC's Phase 1 binds *every*
--      non-trivial operand -- including literal constants -- to a fresh
--      let, purely for ANF shape; there's no sharing/evaluation-order
--      reason to actually declare a C variable for a literal).
--   2. A native op with *no* Boxed operands (see `tryInlineNativeOp`)
--      that's used exactly once. Restricting to zero Boxed operands is
--      what makes this always safe to defer: every value such an op
--      reads is either another already-computed, stable native local
--      (a declared `var_N`, or itself a further InlineMap entry, so
--      transitively still never a Boxed read) or a literal -- nothing
--      that a dup/drop anywhere else in the function could invalidate
--      by the time the deferred read actually happens. Restricting to
--      exactly one use is what keeps this free -- inlining a multi-use
--      value would duplicate its computation.
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

ReuseMap = SortedMap Name String

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
                RBoxed => nativeUnbox ty (varName l)

-- if the constructor is unique use it, otherwise add it to should drop vars and create null constructor
addReuseConstructor : {auto a : Ref ArgCounter Nat}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> ReuseMap
                    -> String
                    -> Name
                    -> List String
                    -> SortedSet Name
                    -> List String
                    -> SortedMap Name String
                    -> Core (List String, SortedMap Name String)
addReuseConstructor reuseMap sc conName conArgs consts shouldDrop actualReuseConsts =
    if (isNothing $ SortedMap.lookup conName reuseMap)
       && contains conName consts
       && (isJust $ find (== sc) shouldDrop) then do
        let constr = "constructor_" ++ !(getNextCounter)
        emit EmptyFC $ "IDRIS2RC2_Constructor* " ++ constr ++ " = NULL;"
        emit EmptyFC $ "if (idris2rc2_isUnique(" ++ sc ++ ")) {"
        increaseIndentation
        emit EmptyFC $ constr ++ " = (IDRIS2RC2_Constructor*)" ++ sc ++ ";"
        decreaseIndentation
        emit EmptyFC "}"
        emit EmptyFC "else {"
        increaseIndentation
        dupVars (conArgs \\ shouldDrop)
        removeVars [sc]
        decreaseIndentation
        emit EmptyFC "}"
        pure (shouldDrop \\ (sc :: conArgs), insert conName constr actualReuseConsts)
    else do
        dupVars $ conArgs \\ shouldDrop
        pure (shouldDrop \\ conArgs, actualReuseConsts)

dropUnusedReuseCons : ReuseMap -> SortedSet Name -> (List String, ReuseMap)
dropUnusedReuseCons reuseMap usedCons =
    let dropReuseMap = differenceMap reuseMap usedCons in
    let actualReuseMap = intersectionMap reuseMap usedCons in
    (values dropReuseMap, actualReuseMap)

data TailPositionStatus = InTailPosition | NotInTailPosition

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
    let nargs = length args
    emit fc "IDRIS2RC2_Value *\{closure} = (IDRIS2RC2_Value *)idris2rc2_mkClosure((IDRIS2RC2_Value *(*)())\{cName n}, \{show $ nargs + missing}, \{show nargs});"
    let arglist = "((IDRIS2RC2_Closure*)\{closure})->args"
    _ <- foldlC (\k, v => do
        vStr <- rcVarToBoxedC v
        emit EmptyFC $ "\{arglist}[\{show k}] = \{vStr};"
        pure (S k)) 0 args
    pure closure

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

||| Native locals have no refcount at all -- filter them out of any drop
||| list RC.idr produced (it only ever reasons about Boxed ownership).
||| A local not (yet) present in RepMap is a function argument (only
||| RLet-bound locals are ever recorded there) and is always Boxed.
keepBoxedLocals : {auto r : Ref RepMap (SortedMap Int Rep)} -> List RCLocal -> Core (List RCLocal)
keepBoxedLocals locs = do
    reps <- get RepMap
    pure $ filter (isBoxed reps) locs
  where
    isBoxed : SortedMap Int Rep -> RCLocal -> Bool
    isBoxed reps RCNull = False
    -- Always native by construction (RC.idr's bindOne only ever
    -- produces RCConst for a litRep-covered literal) -- never Boxed.
    isBoxed reps (RCConst _) = False
    isBoxed reps (RCLoc i) = case SortedMap.lookup i reps of
                                  Just (RNative _) => False
                                  _ => True

||| If `value` is a native op with no Boxed operands at all and `var` is
||| referenced exactly once in `body`, renders its expression and
||| registers it in InlineMap instead of returning it for the caller to
||| declare as a C variable, returning True. Otherwise leaves InlineMap
||| untouched and returns False, so the caller declares `var` normally.
||| See InlineMap's own module comment for why "no Boxed operands" is
||| exactly the condition that makes deferring this op's evaluation to
||| its (single) later use site always safe, and why "exactly one use"
||| is what keeps it free of any recomputation cost.
tryInlineNativeOp : {auto r : Ref RepMap (SortedMap Int Rep)}
                  -> {auto lm : Ref InlineMap (SortedMap Int String)}
                  -> PrimType -> Int -> RCExp -> RCExp -> Core Bool
tryInlineNativeOp ty var (ROp fc _ op args) body = do
    boxedArgs <- keepBoxedLocals (toList args)
    case boxedArgs of
         [] => if countUsesR (RCLoc var) body == 1
                  then do
                      argStrs <- rc2traverseVect (\v => rcVarToNativeC (opArgTyFor ty op) v) args
                      update InlineMap (insert var (nativeOpExpr op argStrs))
                      pure True
                  else pure False
         _ :: _ => pure False
tryInlineNativeOp _ _ _ _ = pure False

mutual
    ||| A case branch (or default) with no reuse candidate: just emit the
    ||| (reuse-map-narrowed) drops RC.idr already decided on, then the
    ||| body. Mirrors RC2/RefC's `concaseBody`.
    plainBranch : {auto a : Ref ArgCounter Nat}
                 -> {auto e : Ref EnvTracker ReuseMap}
                 -> {auto oft : Ref OutfileText Output}
                 -> {auto il : Ref IndentLevel Nat}
                 -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                 -> {auto r : Ref RepMap (SortedMap Int Rep)}
                 -> {auto lm : Ref InlineMap (SortedMap Int String)}
                 -> ReuseMap -> String -> RCExp -> TailPositionStatus
                 -> Core ()
    plainBranch reuseMap returnvar body tailPosition = do
        let (shouldDrop0, body') = peelDrop body
        shouldDrop <- keepBoxedLocals shouldDrop0
        let usedCons = usedConstructorsR body'
        let (dropReuseCons, actualReuseMap) = dropUnusedReuseCons reuseMap usedCons
        removeVars (varName <$> shouldDrop)
        removeReuseConstructors dropReuseCons
        put EnvTracker actualReuseMap
        emit emptyFC "\{returnvar} = \{!(emitRC body' tailPosition)};"

    ||| A matched-constructor case branch: as `plainBranch`, but also lets
    ||| the scrutinee's storage (`sc'`, just matched as constructor `name`)
    ||| be recycled in-place for a same-shaped constructor built later in
    ||| the body, if it turns out to be uniquely referenced at runtime.
    reusableBranch : {auto a : Ref ArgCounter Nat}
                    -> {auto e : Ref EnvTracker ReuseMap}
                    -> {auto oft : Ref OutfileText Output}
                    -> {auto il : Ref IndentLevel Nat}
                    -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                    -> {auto r : Ref RepMap (SortedMap Int Rep)}
                    -> {auto lm : Ref InlineMap (SortedMap Int String)}
                    -> ReuseMap -> String -> Name -> List Int -> String -> RCExp -> TailPositionStatus
                    -> Core ()
    reusableBranch reuseMap sc' name args returnvar body tailPosition = do
        let (shouldDrop0raw, body') = peelDrop body
        shouldDrop0 <- keepBoxedLocals shouldDrop0raw
        let usedCons = usedConstructorsR body'
        let (dropReuseCons, actualReuseMap0) = dropUnusedReuseCons reuseMap usedCons
        (shouldDrop, actualReuseMap) <-
            addReuseConstructor reuseMap sc' name (varName . RCLoc <$> args) usedCons (varName <$> shouldDrop0) actualReuseMap0
        removeVars shouldDrop
        removeReuseConstructors dropReuseCons
        put EnvTracker actualReuseMap
        emit emptyFC "\{returnvar} = \{!(emitRC body' tailPosition)};"

    emitRC : {auto a : Ref ArgCounter Nat}
           -> {auto oft : Ref OutfileText Output}
           -> {auto il : Ref IndentLevel Nat}
           -> {auto e : Ref EnvTracker ReuseMap}
           -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
           -> {auto r : Ref RepMap (SortedMap Int Rep)}
           -> {auto lm : Ref InlineMap (SortedMap Int String)}
           -> RCExp
           -> TailPositionStatus
           -> Core String

    emitRC (RV fc v) _ = rcVarToBoxedC v
    emitRC (RAppName fc _ n args) tailPosition = do
        let nargs = length args
        case tailPosition of
            InTailPosition => makeClosure fc n args 0
            _ => if nargs > MaxExtractFunArgs
                then pure "idris2rc2_trampoline(\{!(makeClosure fc n args 0)})"
                else do
                    argStrs <- traverse rcVarToBoxedC args
                    pure "idris2rc2_trampoline(\{cName n}(\{concat $ intersperse ", " argStrs}))"

    emitRC (RUnderApp fc n missing args) _ = makeClosure fc n args missing
    emitRC (RApp fc _ closure arg) tailPosition = do
       closureStr <- rcVarToBoxedC closure
       argStr <- rcVarToBoxedC arg
       pure $ (case tailPosition of
           NotInTailPosition => "idris2rc2_applyClosure"
           InTailPosition    => "idris2rc2_tailcallApplyClosure") ++ "(\{closureStr}, \{argStr})"

    emitRC (RLet fc var rep value body) tailPosition = do
        -- `rep` was already decided by Compiler.RC2.RC during the Lifted ->
        -- RCExp conversion and is carried directly on this node; record it
        -- so later *uses* of `var` (which only have its RCLocal id, not
        -- this node) can look it up via repOfLocal/rcVarToBoxedC/etc.
        -- If `var` turned out dead, Compiler.RC2.RC already wrapped `body`
        -- in an RDrop/RFree for it directly (see RCExp.idr's module note)
        -- -- there is no separate flag to check here, the ordinary RDrop/
        -- RFree cases below pick it up naturally.
        update RepMap (insert var rep)
        case (rep, value) of
             -- A bare literal never needs an actual C variable -- there's
             -- no shared/reused computation or evaluation-order reason to
             -- name it, only Compiler.RC2.RC's ANF normalisation binding
             -- *every* non-trivial operand uniformly. Record it in
             -- InlineMap and skip declaring `var` at all; every use inlines
             -- the literal text directly (see rcVarToNativeC/
             -- rcVarToBoxedC).
             (RNative _, RPrimVal _ c) => do
                 update InlineMap (insert var (nativeLitExpr c))
                 emitRC body tailPosition
             (RNative ty, _) => do
                 -- Native path: `value` is ROp here (RPrimVal is handled
                 -- above), possibly interspersed with RDup/RDrop/RFree
                 -- wrapping one of *its own* boxed operands -- see
                 -- emitNativeValue. First see if it's a single-use,
                 -- no-Boxed-operands op that can be spliced into its use
                 -- site instead (tryInlineNativeOp); if not, this is an
                 -- ordinary raw C scalar declaration -- no dup/drop/free,
                 -- no heap allocation, for `var` itself either way.
                 inlined <- tryInlineNativeOp ty var value body
                 if inlined
                    then emitRC body tailPosition
                    else do
                        (valStr, pending) <- emitNativeValue ty value
                        emit fc $ "\{nativeCType ty} var_\{show var} = \{valStr};"
                        removeVars $ map varName pending
                        emitRC body tailPosition
             (RBoxed, _) => do
                 outerReuseMap <- get EnvTracker
                 let usedCons = usedConstructorsR value
                 put EnvTracker (outerReuseMap `intersectionMap` usedCons)
                 valStr <- emitRC value NotInTailPosition
                 emit fc $ "IDRIS2RC2_Value * var_\{show var} = \{valStr};"
                 put EnvTracker (outerReuseMap `differenceMap` usedCons)
                 emitRC body tailPosition

    emitRC (RCon fc n coninfo tag args) _ = do
        if coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
            then pure "(NULL /* \{show n} */)"
            else do
                reuseMap <- get EnvTracker
                let createNewConstructor = " = idris2rc2_newConstructor("
                                 ++ (show (length args))
                                 ++ ", "  ++ maybe "-1" show tag  ++ ");"

                emit fc " // constructor \{show n}"
                constr <- case SortedMap.lookup n reuseMap of
                    Just constr => do
                        emit fc "if (! \{constr}) {"
                        increaseIndentation
                        emit fc $ constr ++ createNewConstructor
                        decreaseIndentation
                        emit fc "}"
                        pure constr
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

    emitRC (ROp fc _ op args) _ = do
        -- Reached only when Compiler.RC2.Types decided this op's result
        -- stays Boxed (comparisons, or a non-numeric op) -- operands may
        -- still individually be native locals (e.g. a comparison over an
        -- earlier native arithmetic chain), hence the Rep-aware boxing.
        argStrs <- rc2traverseVect rcVarToBoxedC args
        let resultVar = "primVar_" ++ !(getNextCounter)
        emit fc $ "IDRIS2RC2_Value *" ++ resultVar ++ " = " ++ cOp op argStrs ++ ";"
        -- Ops don't take ownership of their operands (they only read
        -- them); the operands are always dead here regardless of whether
        -- Compiler.RC2.RC's `annotate` moved them in (owned) or wrapped
        -- them in a preceding RDup (borrowed), so this drop is purely
        -- mechanical -- no ownership decision is being made here. Native
        -- locals are skipped: they have no refcount, and `rcVarToBoxedC`
        -- above already boxed a *fresh*, independent copy for the call
        -- rather than reading `var_N` itself.
        boxedArgs <- keepBoxedLocals (toList args)
        removeVars $ map varName boxedArgs
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

    emitRC (RConCase fc sc alts mDef) tailPosition = do
        let sc' = varName sc
        switchReturnVar <- getNewVarThatWillNotBeFreedAtEndOfBlock
        emit fc "IDRIS2RC2_Value * \{switchReturnVar} = NULL;"
        reuseMap <- get EnvTracker -- captured once; every branch starts from this same snapshot
        _ <- foldlC (\els, (MkRConAlt name coninfo tag args body) => do
            let erased = coninfo == NIL || coninfo == NOTHING || coninfo == ZERO || coninfo == UNIT
            if erased then emit emptyFC "\{els}if (NULL == \{sc'} /* \{show name} \{show coninfo} */) {"
                else if coninfo == CONS || coninfo == JUST || coninfo == SUCC
                then emit emptyFC "\{els}if (NULL != \{sc'} /* \{show name} \{show coninfo} */) {"
                else do
                    case tag of
                        Nothing   => emit emptyFC "\{els}if (! strcmp(((IDRIS2RC2_Constructor *)\{sc'})->name, idris2rc2_constr_\{cName name})) {"
                        Just tag' => emit emptyFC "\{els}if (((IDRIS2RC2_Constructor *)\{sc'})->tag == \{show tag'} /* \{show name} */) {"

            increaseIndentation
            _ <- foldlC (\k, arg => do
                emit emptyFC "IDRIS2RC2_Value *var_\{show arg} = ((IDRIS2RC2_Constructor*)\{sc'})->args[\{show k}];"
                pure (S k) ) 0 args
            reusableBranch reuseMap sc' name args switchReturnVar body tailPosition
            decreaseIndentation
            pure "} else ") "" alts

        case mDef of
            Nothing => pure ()
            Just body => do
                emit emptyFC "} else {"
                increaseIndentation
                plainBranch reuseMap switchReturnVar body tailPosition
                decreaseIndentation
        emit emptyFC "}"
        pure switchReturnVar

    emitRC (RConstCase fc sc alts def) tailPosition = do
        let sc' = varName sc
        switchReturnVar <- getNewVarThatWillNotBeFreedAtEndOfBlock
        emit fc "IDRIS2RC2_Value *\{switchReturnVar} = NULL;"
        reuseMap <- get EnvTracker
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
                    plainBranch reuseMap switchReturnVar body tailPosition
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
                    plainBranch reuseMap switchReturnVar body tailPosition
                    decreaseIndentation
                    pure "} else ") "" alts
                pure ()

        case def of
            Nothing => pure ()
            Just body => do
                emit emptyFC "} else {"
                increaseIndentation
                plainBranch reuseMap switchReturnVar body tailPosition
                decreaseIndentation
        emit emptyFC "}"
        pure switchReturnVar

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
    emitRC (RDrop fc locs cont) tailPosition = do
        boxedLocs <- keepBoxedLocals locs
        let shouldDrop = varName <$> boxedLocs
        reuseMap <- get EnvTracker
        let usedCons = usedConstructorsR cont
        let (dropReuseCons, actualReuseMap) = dropUnusedReuseCons reuseMap usedCons
        removeReuseConstructors dropReuseCons
        removeVars shouldDrop
        put EnvTracker actualReuseMap
        emitRC cont tailPosition
    emitRC (RDup fc loc cont) tailPosition = do
        dupVars [varName loc]
        emitRC cont tailPosition
    emitRC (RFree fc loc cont) tailPosition = do
        freeVars [varName loc]
        emitRC cont tailPosition

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
                     -> {auto e : Ref EnvTracker ReuseMap}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> {auto lm : Ref InlineMap (SortedMap Int String)}
                     -> PrimType -> RCExp -> Core (String, List RCLocal)
    emitNativeValue ty (ROp fc _ op args) = do
        argStrs <- rc2traverseVect (\v => rcVarToNativeC (opArgTyFor ty op) v) args
        -- Mirrors emitRC's boxed-ROp case: every op unconditionally drops
        -- whichever of its operands are Boxed once it's done reading
        -- them, regardless of whether `annotate` dup'd them (borrowed) or
        -- moved them in (owned) -- see that case's comment ("this drop is
        -- purely mechanical -- no ownership decision is being made
        -- here"). A native-result op still reads Boxed operands (via
        -- rcVarToNativeC's unboxing above) and owes them that exact same
        -- cleanup; omitting it entirely was a real bug -- every Boxed
        -- operand `annotate` treated as owned/consumed (as opposed to
        -- dup'd for a later reuse) leaked one reference, since nothing
        -- else was ever going to drop it. The caller drops the ones we
        -- report back here once it's done with the expression string.
        boxedArgs <- keepBoxedLocals (toList args)
        pure (nativeOpExpr op argStrs, boxedArgs)
    emitNativeValue ty (RPrimVal fc c) = pure (nativeLitExpr c, [])
    -- RC.idr's own ANF-normalisation wraps any non-trivial operand (e.g. a
    -- literal) in a synthetic RLet before the "real" ROp/RPrimVal --
    -- declare it (native or boxed, whichever Compiler.RC2.Types decided)
    -- and keep unwinding to find the tail expression. This synthetic
    -- let's own value gets its pending-drop list (if any) discharged
    -- right here, immediately after its own declaration statement; only
    -- `body`'s eventual tail-op pending list is returned onward.
    emitNativeValue ty (RLet fc var rep value body) = do
        update RepMap (insert var rep)
        case (rep, value) of
             -- Same literal-inlining as emitRC's RLet case above -- most
             -- of these synthetic lets *are* one (e.g. the `2` in `d * 2`).
             (RNative _, RPrimVal _ c) => update InlineMap (insert var (nativeLitExpr c))
             (RNative ty', _) => do
                 -- Same op-inlining as emitRC's RLet case above -- a
                 -- synthetic operand-let is used exactly once by
                 -- construction (it exists solely to hold that one
                 -- operand), so this fires for every such let whose op
                 -- itself has no Boxed operands.
                 inlined <- tryInlineNativeOp ty' var value body
                 unless inlined $ do
                     (valStr, pending) <- emitNativeValue ty' value
                     emit fc $ "\{nativeCType ty'} var_\{show var} = \{valStr};"
                     removeVars $ map varName pending
             (RBoxed, _) => do
                 outerReuseMap <- get EnvTracker
                 let usedCons = usedConstructorsR value
                 put EnvTracker (outerReuseMap `intersectionMap` usedCons)
                 valStr <- emitRC value NotInTailPosition
                 emit fc $ "IDRIS2RC2_Value * var_\{show var} = \{valStr};"
                 put EnvTracker (outerReuseMap `differenceMap` usedCons)
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
        boxedLocs <- keepBoxedLocals locs
        removeVars (varName <$> boxedLocs)
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
createCFunctions n (MkRCFun args body) = do
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
    _ <- newRef EnvTracker (the ReuseMap empty)
    -- Populated incrementally as each RLet is emitted below (its Rep is
    -- already decided and stored on the node by Compiler.RC2.RC; this map
    -- just lets *use* sites, which only have a bare RCLocal id, look it
    -- back up).
    _ <- newRef RepMap (the (SortedMap Int Rep) empty)
    -- Populated instead of RepMap+a declaration for any RLet whose value
    -- is a bare literal -- see InlineMap's own comment.
    _ <- newRef InlineMap (the (SortedMap Int String) empty)
    emit EmptyFC $ "return \{!(emitRC body InTailPosition)};"
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
