||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
|||
||| A 0-ary top-level definition whose body is a `Delay` needs no lazy
||| cell: every non-constant CAF is already memoized (`RMemoize`), so a
||| cell would memoize the same value twice. On the whole program, before
||| lifting: `x = Delay e` becomes `x = e`; `Force (x [])` becomes `x []`;
||| any other reference to `x`, a lazy value passed on unforced, becomes
||| `Delay (x [])`, so `e` is still not evaluated until something forces
||| it. See doc/lazy-memoization.md, "`Delay`".
module Compiler.RC2.LazyCaf

import Core.CompileExpr
import Core.FC
import Core.TT

import Data.List
import Data.SortedMap
import Data.Vect

export
applyLazyCaf : Maybe NamedCExp -> List (Name, FC, NamedDef) -> (Maybe NamedCExp, List (Name, FC, NamedDef))
applyLazyCaf main defs =
    let cafs = SortedMap.fromList (mapMaybe lazyCaf defs)
    in if null cafs then (main, defs)
       else (map (go cafs) main, map (rewriteDef cafs) defs)
  where
    lazyCaf : (Name, FC, NamedDef) -> Maybe (Name, LazyReason)
    lazyCaf (n, _, MkNmFun [] (NmDelay _ lr _)) = Just (n, lr)
    lazyCaf _ = Nothing

    mutual
      go : SortedMap Name LazyReason -> NamedCExp -> NamedCExp
      go cafs e@(NmForce fc lr (NmApp afc (NmRef rfc n) [])) =
          case lookup n cafs of
               Just _ => NmApp afc (NmRef rfc n) []
               Nothing => e
      go cafs e@(NmForce fc lr (NmRef rfc n)) =
          case lookup n cafs of
               Just _ => NmApp fc (NmRef rfc n) []
               Nothing => e
      go cafs e@(NmApp afc (NmRef rfc n) []) =
          case lookup n cafs of
               Just lr => NmDelay afc lr e
               Nothing => e
      go cafs e@(NmRef rfc n) =
          case lookup n cafs of
               Just lr => NmDelay rfc lr (NmApp rfc e [])
               Nothing => e
      go cafs (NmLam fc x b) = NmLam fc x (go cafs b)
      go cafs (NmLet fc x v b) = NmLet fc x (go cafs v) (go cafs b)
      go cafs (NmApp fc f args) = NmApp fc (go cafs f) (map (go cafs) args)
      go cafs (NmCon fc n ci tag args) = NmCon fc n ci tag (map (go cafs) args)
      go cafs (NmOp fc op args) = NmOp fc op (map (go cafs) args)
      go cafs (NmExtPrim fc p args) = NmExtPrim fc p (map (go cafs) args)
      go cafs (NmForce fc lr t) = NmForce fc lr (go cafs t)
      go cafs (NmDelay fc lr t) = NmDelay fc lr (go cafs t)
      go cafs (NmConCase fc sc alts def) =
          NmConCase fc (go cafs sc) (map (goConAlt cafs) alts) (map (go cafs) def)
      go cafs (NmConstCase fc sc alts def) =
          NmConstCase fc (go cafs sc) (map (goConstAlt cafs) alts) (map (go cafs) def)
      go _ e = e

      goConAlt : SortedMap Name LazyReason -> NamedConAlt -> NamedConAlt
      goConAlt cafs (MkNConAlt n ci tag args b) = MkNConAlt n ci tag args (go cafs b)

      goConstAlt : SortedMap Name LazyReason -> NamedConstAlt -> NamedConstAlt
      goConstAlt cafs (MkNConstAlt c b) = MkNConstAlt c (go cafs b)

    rewriteDef : SortedMap Name LazyReason -> (Name, FC, NamedDef) -> (Name, FC, NamedDef)
    -- Every such definition is in `cafs` (`lazyCaf`).
    rewriteDef cafs (n, fc, MkNmFun [] (NmDelay _ _ e)) = (n, fc, MkNmFun [] (go cafs e))
    rewriteDef cafs (n, fc, MkNmFun args body) = (n, fc, MkNmFun args (go cafs body))
    rewriteDef cafs (n, fc, MkNmError body) = (n, fc, MkNmError (go cafs body))
    rewriteDef _ d = d
