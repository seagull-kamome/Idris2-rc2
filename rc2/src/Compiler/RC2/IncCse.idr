||| Upstream's CSE for a module compiled on its own, which
||| `getIncCompileData` skips; the `csegen` names it makes are qualified by
||| the module's namespace. See `rc2/doc/incremental-compile.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.IncCse

import Compiler.Opts.CSE

import Core.CompileExpr
import Core.Context

import Data.Vect

%default covering

isCseName : Name -> Bool
isCseName (MN "csegen" _) = True
isCseName _ = False

qualify : Namespace -> Name -> Name
qualify ns n = if isCseName n then NS ns n else n

renameRefs : Namespace -> NamedCExp -> NamedCExp
renameRefs ns = go
  where
    go : NamedCExp -> NamedCExp
    go (NmRef fc n) = NmRef fc (qualify ns n)
    go (NmLam fc x b) = NmLam fc x (go b)
    go (NmLet fc x v b) = NmLet fc x (go v) (go b)
    go (NmApp fc f args) = NmApp fc (go f) (map go args)
    go (NmCon fc n ci t args) = NmCon fc n ci t (map go args)
    go (NmOp fc op args) = NmOp fc op (map go args)
    go (NmExtPrim fc p args) = NmExtPrim fc p (map go args)
    go (NmForce fc lr t) = NmForce fc lr (go t)
    go (NmDelay fc lr t) = NmDelay fc lr (go t)
    go (NmConCase fc sc alts def) =
        NmConCase fc (go sc) (map (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as (go b)) alts) (map go def)
    go (NmConstCase fc sc alts def) =
        NmConstCase fc (go sc) (map (\(MkNConstAlt c b) => MkNConstAlt c (go b)) alts) (map go def)
    go e = e

renameDef : Namespace -> NamedDef -> NamedDef
renameDef ns (MkNmFun args b) = MkNmFun args (renameRefs ns b)
renameDef ns (MkNmError b) = MkNmError (renameRefs ns b)
renameDef _ d = d

export
incrementalCse : {auto c : Ref Ctxt Defs} -> Namespace -> List (Name, FC, NamedDef) -> Core (List (Name, FC, NamedDef))
incrementalCse ns defs = do
    (cseDefs, _) <- cse (map (\(n, _, _) => n) defs) (the (CExp []) (CErased emptyFC))
    pure (map (\(n, fc, d) => (qualify ns n, fc, renameDef ns (forgetDef d))) cseDefs)
