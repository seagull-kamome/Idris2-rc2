module Compiler.RC2.LeafTail

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A tail call to a *leaf* function is made directly instead of through a
-- closure that the caller returns for the nearest trampoline to run.
-- A leaf function is one with no tail call that can leave work behind:
-- every tail of its body builds a value, or tail-calls another leaf.
-- Its call returns after a bounded amount of work of its own, so calling
-- it from a tail position cannot grow the C stack without bound, which is
-- all the closure was for. `Control.Task`'s `>>=`, a forwarder of `bind`,
-- is such a function. See `rc2/doc/leaf-tail-calls.md`. Disable with
-- `--directive noleaftail`.

import Compiler.RC2.RCExp
import Compiler.RC2.Util

import Core.Context

import Data.SortedSet

%default covering

||| The callees of the tail positions of `e` if all of them are values or
||| calls; `Nothing` if one is anything that can leave work behind (an
||| `apply`, a worker call, a loop, a force).
tailCalls : RCExp -> Maybe (List Name)
tailCalls (RAppName _ _ n _) = Just [n]
tailCalls (RV {}) = Just []
tailCalls (RCon {}) = Just []
tailCalls (RUnderApp {}) = Just []
tailCalls (ROp {}) = Just []
tailCalls (RPrimVal {}) = Just []
tailCalls (RErased {}) = Just []
tailCalls (RCrash {}) = Just []
tailCalls (RExtPrim {}) = Just []
tailCalls e = tailChildren e >>= \cs => concat <$> Prelude.traverse tailCalls cs

||| The functions whose tails are values or calls of functions in the set:
||| the least fixpoint, so a cycle of tail calls is never in it.
leafSet : List (Name, RCDef) -> SortedSet Name
leafSet defs = grow empty candidates
  where
    candidates : List (Name, List Name)
    candidates = mapMaybe cand defs
      where
        cand : (Name, RCDef) -> Maybe (Name, List Name)
        cand (n, MkRCFun (_ :: _) RBoxed False body) = (\cs => (n, cs)) <$> tailCalls body
        cand _ = Nothing

    grow : SortedSet Name -> List (Name, List Name) -> SortedSet Name
    grow acc cs =
        let (ready, rest) = partition (\(_, callees) => all (\c => contains c acc) callees) cs
        in if null ready then acc else grow (foldl (\s, (n, _) => insert n s) acc ready) rest

||| `e` with each tail call of a leaf made through a `let`, which `Emit`
||| renders as a plain call. Loops are left alone.
rewriteTails : {auto v : Ref VarId Int} -> SortedSet Name -> RCExp -> Core RCExp
rewriteTails leaves = go
  where
    go : RCExp -> Core RCExp
    go e@(RAppName fc lz n args) =
        if contains n leaves
           then do x <- freshVarId
                   pure (RLet fc x RBoxed e (RV fc (RCLoc x)))
           else pure e
    go (RLet fc x r val b) = RLet fc x r val <$> go b
    go (RDup fc l k b) = RDup fc l k <$> go b
    go (RDrop fc ls b) = RDrop fc ls <$> go b
    go (RFree fc l b) = RFree fc l <$> go b
    go (RReleaseReuse fc l b) = RReleaseReuse fc l <$> go b
    go (RReuseOffer fc sc d u b) = RReuseOffer fc sc d u <$> go b
    go (RCmpCase fc op xs pd t f) = RCmpCase fc op xs pd <$> go t <*> go f
    go (RConCase fc sc alts def) =
        RConCase fc sc <$> traverse goAlt alts <*> traverseOpt go def
      where
        goAlt : RConAlt -> Core RConAlt
        goAlt (MkRConAlt n ci tag as b) = MkRConAlt n ci tag as <$> go b
    go (RConstCase fc sc alts def) =
        RConstCase fc sc <$> traverse goAlt alts <*> traverseOpt go def
      where
        goAlt : RConstAlt -> Core RConstAlt
        goAlt (MkRConstAlt c b) = MkRConstAlt c <$> go b
    go e = pure e

||| Make the tail calls of leaves direct in every definition.
export
applyLeafTail : {auto v : Ref VarId Int} -> List (Name, RCDef) -> Core (List (Name, RCDef))
applyLeafTail defs =
    let leaves = leafSet defs
    in if null (Prelude.toList leaves) then pure defs
       else traverse (\(n, d) => case d of
                                      MkRCFun as RBoxed False body => (\b => (n, MkRCFun as RBoxed False b)) <$> rewriteTails leaves body
                                      _ => pure (n, d)) defs
