module Compiler.RC2.Pretty

-- A human-readable, indented dump of the final RCExp tree -- after
-- Compiler.RC2.Reuse/MutualLoop/Loop have all run, i.e. exactly what
-- Compiler.RC2.Emit itself consumes -- written to a `.crexpr` file
-- alongside the generated `.c` file whenever the "dumprcexp" directive
-- is passed (`--directive dumprcexp`, see RC2.idr's `compileExpr`).
-- Purely a debugging aid, never read back by the compiler itself, so
-- its formatting choices favour readability over completeness -- FC
-- source spans are omitted entirely (RCExp.idr carries one on nearly
-- every node, but they're pure noise for this purpose), and every
-- constructor gets a short, deliberately terse keyword (`let`, `case`,
-- `dup`, `drop`, ...) rather than its actual Idris constructor name.

import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.TT

import Data.List
import Data.Vect

%default covering

indent : Nat -> String
indent n = pack (replicate (2 * n) ' ')

prettyRep : Rep -> String
prettyRep RBoxed = "Boxed"
prettyRep (RNative ty) = "Native " ++ show ty
prettyRep (RInlineNative ty) = "InlineNative " ++ show ty

lazyPrefix : Maybe LazyReason -> String
lazyPrefix Nothing = ""
lazyPrefix (Just r) = "~" ++ show r ++ " "

mutual
  prettyExp : Nat -> RCExp -> String
  prettyExp d (RV _ v) = indent d ++ show v ++ "\n"
  prettyExp d (RAppName _ lazy n args) =
      indent d ++ lazyPrefix lazy ++ "call " ++ show n ++ " " ++ show args ++ "\n"
  prettyExp d (RUnderApp _ n missing args) =
      indent d ++ "partial " ++ show n ++ " missing=" ++ show missing ++ " " ++ show args ++ "\n"
  prettyExp d (RApp _ lazy c a) =
      indent d ++ lazyPrefix lazy ++ "apply " ++ show c ++ " " ++ show a ++ "\n"
  prettyExp d (RLet _ var rep value body) =
      indent d ++ "let " ++ show (RCLoc var) ++ " : " ++ prettyRep rep ++ " =\n"
      ++ prettyExp (d + 1) value
      ++ prettyExp d body
  prettyExp d (RCon _ n ci tag args reuseFrom) =
      indent d ++ "con " ++ show n ++ " " ++ show ci ++ " tag=" ++ show tag
        ++ " " ++ show args
        ++ maybe "" (\r => " reuse=" ++ show r) reuseFrom ++ "\n"
  prettyExp d (ROp _ lazy op args postDrop) =
      indent d ++ lazyPrefix lazy ++ "op " ++ show op ++ " " ++ show (toList args)
        ++ (if postDrop == [] then "" else " postDrop=" ++ show postDrop) ++ "\n"
  prettyExp d (RExtPrim _ lazy p args) =
      indent d ++ lazyPrefix lazy ++ "extprim " ++ show p ++ " " ++ show args ++ "\n"
  prettyExp d (RCmpCase _ op args postDrop whenTrue whenFalse) =
      indent d ++ "cmp " ++ show op ++ " " ++ show (toList args)
        ++ (if postDrop == [] then "" else " postDrop=" ++ show postDrop) ++ "\n"
      ++ indent d ++ "then\n" ++ prettyExp (d + 1) whenTrue
      ++ indent d ++ "else\n" ++ prettyExp (d + 1) whenFalse
  prettyExp d (RConCase _ sc alts mDef) =
      indent d ++ "case " ++ show sc ++ " of\n"
      ++ fastConcat (map (prettyConAlt (d + 1)) alts)
      ++ maybe "" (\body => indent (d + 1) ++ "_ ->\n" ++ prettyExp (d + 2) body) mDef
  prettyExp d (RConstCase _ sc alts mDef) =
      indent d ++ "case " ++ show sc ++ " of\n"
      ++ fastConcat (map (prettyConstAlt (d + 1)) alts)
      ++ maybe "" (\body => indent (d + 1) ++ "_ ->\n" ++ prettyExp (d + 2) body) mDef
  prettyExp d (RPrimVal _ c) = indent d ++ show c ++ "\n"
  prettyExp d (RErased _) = indent d ++ "erased\n"
  prettyExp d (RCrash _ msg) = indent d ++ "crash " ++ show msg ++ "\n"
  prettyExp d (RDup _ v body) = indent d ++ "dup " ++ show v ++ "\n" ++ prettyExp d body
  prettyExp d (RDrop _ vs body) = indent d ++ "drop " ++ show vs ++ "\n" ++ prettyExp d body
  prettyExp d (RFree _ v body) = indent d ++ "free " ++ show v ++ "\n" ++ prettyExp d body
  prettyExp d (RReleaseReuse _ v body) = indent d ++ "releaseReuse " ++ show v ++ "\n" ++ prettyExp d body
  prettyExp d (RSelfTailCall _ args) = indent d ++ "tailcall self " ++ show args ++ "\n"

  prettyConAlt : Nat -> RConAlt -> String
  prettyConAlt d (MkRConAlt n ci tag args body offersReuse) =
      indent d ++ show n ++ " " ++ show ci ++ " tag=" ++ show tag
        ++ " args=" ++ show (map RCLoc args)
        ++ maybe "" (\r => " offersReuse=" ++ show r) offersReuse ++ " ->\n"
      ++ prettyExp (d + 1) body

  prettyConstAlt : Nat -> RConstAlt -> String
  prettyConstAlt d (MkRConstAlt c body) =
      indent d ++ show c ++ " ->\n" ++ prettyExp (d + 1) body

prettyDef : Name -> RCDef -> String
prettyDef n (MkRCFun args isLoop body) =
    "def " ++ show n ++ "  (fun args=" ++ show (map RCLoc args)
      ++ (if isLoop then " isLoop" else "") ++ ")\n"
    ++ prettyExp 1 body ++ "\n"
prettyDef n (MkRCCon tag arity nt) =
    "def " ++ show n ++ "  (con tag=" ++ show tag ++ " arity=" ++ show arity
      ++ " newtype=" ++ show nt ++ ")\n\n"
prettyDef n (MkRCForeign ccs fargs ret) =
    "def " ++ show n ++ "  (foreign " ++ show ccs ++ " " ++ show fargs
      ++ " -> " ++ show ret ++ ")\n\n"
prettyDef n (MkRCError err) =
    "def " ++ show n ++ "  (error)\n" ++ prettyExp 1 err ++ "\n"

||| The whole program's final RCExp, one `def` block per top-level
||| name, in the same order `Compiler.RC2.RC2.toRCDefs` produced them.
export
prettyProgram : List (Name, RCDef) -> String
prettyProgram defs = fastConcat (map (uncurry prettyDef) defs)
