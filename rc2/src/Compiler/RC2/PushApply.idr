||| Pushing an `apply` into the tails of the value it applies.
||| `let v = <branching value> in apply v args`, where `v` is read by nothing
||| else and a tail of the value builds a partial application or is a constant
||| closure, becomes the branching value with the `apply` moved into each
||| tail. A tail that builds a closure is then applied at once, which
||| `Compiler.RC2.ConstFold` turns into a call: the closure is never built.
||| This is what `when c act` leaves behind once `when` is spliced:
||| `case c of 1 -> force act; 0 -> pure ()`, applied to the world. It runs
||| in the early inline, before RC annotation and loop conversion, so no
||| `dup`/`drop` and no `RLoop` is in the way. See `rc2/doc/inlining.md`,
||| "Pushing an apply into the tails". Disable with `--directive nopushapply`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.PushApply

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Core

import Data.List1

%default covering

||| Whether pushing is worth the copies of the `apply`: the value has two to
||| eight tails, and at least one builds a `partial` or is a constant closure.
||| A `force` is not enough on its own: only a `force` of a local `delay` folds,
||| and only next to a closure does the push pay for the copies.
||| One pass, counting tails as it goes (a `RCrash` tail is not one).
profitable : RCExp -> Bool
profitable value =
    let (n, closure) = scan value
    in n >= 2 && n <= maxTails && closure
  where
    maxTails : Nat
    maxTails = 8

    scan : RCExp -> (Nat, Bool)
    scan e = case tailChildren e of
        Just cs => foldl (\(n, g), (n', g') => (n + n', g || g')) (0, False) (map scan cs)
        Nothing => case e of
            RCrash {} => (0, False)
            RUnderApp {} => (1, True)
            RV _ (RCConstClosure {}) => (1, True)
            _ => (1, False)

||| `apply args` at every tail of `e`: straight onto a local, after a fresh
||| `let` for any other value; a `RCrash` tail stays as it is.
pushInto : {auto v : Ref VarId Int} -> FC -> Maybe LazyReason -> List1 RCLocal -> RCExp -> Core RCExp
pushInto fc lazy args e =
    case traverseTailChildren @{Applicative.CORE} (pushInto fc lazy args) e of
         Just pushed => pushed
         Nothing => leaf e
  where
    leaf : RCExp -> Core RCExp
    leaf c@(RCrash {}) = pure c
    leaf (RV _ l@(RCLoc _)) = pure (RApp fc lazy l args)
    leaf tail = do
        t <- freshVarId
        pure (RLet fc t RBoxed tail (RApp fc lazy (RCLoc t) args))

export
pushApply : {auto v : Ref VarId Int} -> RCExp -> Core RCExp
pushApply (RLet fc x RBoxed value body@(RApp afc lazy (RCLoc x') args)) = do
    value' <- pushApply value
    -- One use in all of `body` is the callee itself; `x` among `args` would
    -- be left unbound by the push.
    if x' == x && countUsesR (RCLoc x) body == 1 && profitable value'
       then pushInto afc lazy args value'
       else pure (RLet fc x RBoxed value' body)
pushApply e = traverseChildren @{Applicative.CORE} pushApply e

export
pushApplyDef : {auto v : Ref VarId Int} -> RCDef -> Core RCDef
pushApplyDef (MkRCFun a r w b) = MkRCFun a r w <$> pushApply b
pushApplyDef d = pure d
