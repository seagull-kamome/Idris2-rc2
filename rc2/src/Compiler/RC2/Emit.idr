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

escapeChar : Char -> String
escapeChar c = if isAlphaNum c || isNL c
                  then show c
                  else "(char)" ++ show (ord c)

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
repOfLocal (RCLoc i) = do
    reps <- get RepMap
    pure $ fromMaybe RBoxed (SortedMap.lookup i reps)

||| RCLocal -> C, Rep-aware: a bare use of `l` if it's already Boxed, or a
||| fresh box of its native value otherwise (natives have no refcount, so
||| boxing them here always allocates an independent fresh value -- there
||| is no borrow/move distinction to make). Any dup this use needed was
||| already made explicit as a wrapping RDup node earlier in the tree (see
||| the module note), so this never dups on its own.
rcVarToBoxedC : {auto r : Ref RepMap (SortedMap Int Rep)} -> RCLocal -> Core String
rcVarToBoxedC l = do
    rep <- repOfLocal l
    pure $ case rep of
                RNative ty => nativeMk ty (varName l)
                RBoxed => varName l

||| The C expression to use for `l` as an operand of a native op expecting
||| type `ty`: the raw variable if it's already native, or an inline
||| unboxing extraction if it's boxed. Never dups/drops -- reading a value
||| for a native op doesn't take ownership either way.
rcVarToNativeC : {auto r : Ref RepMap (SortedMap Int Rep)} -> PrimType -> RCLocal -> Core String
rcVarToNativeC ty l = do
    rep <- repOfLocal l
    pure $ case rep of
                RNative _ => varName l
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
    isBoxed reps (RCLoc i) = case SortedMap.lookup i reps of
                                  Just (RNative _) => False
                                  _ => True

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
        case rep of
             RNative ty => do
                 -- Native path: `value` is always ROp or RPrimVal (the
                 -- only shapes Compiler.RC2.Types ever marks Native),
                 -- possibly interspersed with RDup/RDrop/RFree wrapping
                 -- one of *its own* boxed operands -- see emitNativeValue.
                 -- Either way this is a raw C scalar declaration -- no
                 -- dup/drop/free, no heap allocation, for `var` itself.
                 valStr <- emitNativeValue ty value
                 emit fc $ "\{nativeCType ty} var_\{show var} = \{valStr};"
                 emitRC body tailPosition
             RBoxed => do
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
                emit emptyFC "int64_t \{tmpint} = idris2rc2_extractInt(\{sc'});"
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
    emitNativeValue : {auto a : Ref ArgCounter Nat}
                     -> {auto oft : Ref OutfileText Output}
                     -> {auto il : Ref IndentLevel Nat}
                     -> {auto e : Ref EnvTracker ReuseMap}
                     -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
                     -> {auto r : Ref RepMap (SortedMap Int Rep)}
                     -> PrimType -> RCExp -> Core String
    emitNativeValue ty (ROp fc _ op args) = do
        argStrs <- rc2traverseVect (\v => rcVarToNativeC (opArgTy ty op) v) args
        pure $ nativeOpExpr op argStrs
      where
        -- All operands share `ty` except Cast's single argument, whose
        -- *source* type is the op's own `i`, not the result type `ty`.
        opArgTy : PrimType -> PrimFn arity -> PrimType
        opArgTy _ (Cast i _) = i
        opArgTy ty _ = ty
    emitNativeValue ty (RPrimVal fc c) = pure $ nativeLitExpr c
    -- RC.idr's own ANF-normalisation wraps any non-trivial operand (e.g. a
    -- literal) in a synthetic RLet before the "real" ROp/RPrimVal --
    -- declare it (native or boxed, whichever Compiler.RC2.Types decided)
    -- and keep unwinding to find the tail expression.
    emitNativeValue ty (RLet fc var rep value body) = do
        update RepMap (insert var rep)
        case rep of
             RNative ty' => do
                 valStr <- emitNativeValue ty' value
                 emit fc $ "\{nativeCType ty'} var_\{show var} = \{valStr};"
             RBoxed => do
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

extractValue : (cfType:CFType) -> (varName:String) -> String
extractValue CFUnit           varName = "NULL"
extractValue CFInt            varName = "(idris2rc2_to_i64(" ++ varName ++ "))"
extractValue CFInt8           varName = "(idris2rc2_to_i8(" ++ varName ++ "))"
extractValue CFInt16          varName = "(idris2rc2_to_i16(" ++ varName ++ "))"
extractValue CFInt32          varName = "(idris2rc2_to_i32(" ++ varName ++ "))"
extractValue CFInt64          varName = "(idris2rc2_to_i64(" ++ varName ++ "))"
extractValue CFUnsigned8      varName = "(idris2rc2_to_u8(" ++ varName ++ "))"
extractValue CFUnsigned16     varName = "(idris2rc2_to_u16(" ++ varName ++ "))"
extractValue CFUnsigned32     varName = "(idris2rc2_to_u32(" ++ varName ++ "))"
extractValue CFUnsigned64     varName = "(idris2rc2_to_u64(" ++ varName ++ "))"
extractValue CFString         varName = "((IDRIS2RC2_String*)" ++ varName ++ ")->str"
extractValue CFDouble         varName = "(idris2rc2_to_double(" ++ varName ++ "))"
extractValue CFChar           varName = "((char)idris2rc2_to_char(" ++ varName ++ "))"
extractValue CFPtr            varName = "((IDRIS2RC2_Pointer*)" ++ varName ++ ")->p"
extractValue CFGCPtr          varName = "((IDRIS2RC2_GCPointer*)" ++ varName ++ ")->p->p"
extractValue CFBuffer         varName = "((IDRIS2RC2_Buffer*)" ++ varName ++ ")"
extractValue CFWorld          _       = "(IDRIS2RC2_Value *)NULL"
extractValue (CFFun x y)      varName = "(IDRIS2RC2_Closure*)" ++ varName
extractValue (CFIORes x)      varName = extractValue x varName
extractValue (CFStruct x xs)  varName = assert_total $ idris_crash ("INTERNAL ERROR: Struct access not implemented: " ++ varName)
extractValue (CFUser x xs)    varName = "(IDRIS2RC2_Value*)" ++ varName
extractValue n _ = assert_total $ idris_crash ("INTERNAL ERROR: Unknown FFI type in rc2 backend: " ++ show n)

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
packCFType CFBuffer        varName = "idris2rc2_mkPointer(" ++ varName ++ ")"
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
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC "return NULL;"
              CFIORes ret => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue vt vn) (discardLastArgument typeVarNameArgList))
                              ++ ");"
                  removeVarsArgList
                  emit EmptyFC $ "return (IDRIS2RC2_Value*)" ++ packCFType ret "retVal" ++ ";"
              _ => do
                  emit EmptyFC $ cTypeOfCFType ret ++ " retVal = " ++ cName fctName
                              ++ "("
                              ++ showSep ", " (map (\(_, vn, vt) => extractValue vt vn) typeVarNameArgList)
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
