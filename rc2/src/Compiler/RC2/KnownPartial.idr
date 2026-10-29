||| Over-applying a locally built partial application, and the `let` that only
||| returns one. Spike for the tiny-callee inline.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.KnownPartial

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Core
import Core.Name

import Data.List
import Data.List1
import Data.SortedMap

%default covering

Known : Type
Known = SortedMap Int (Name, Nat, List RCLocal)

||| Before Phase 2 annotation. `let x = (let y = P in y)` becomes `let x = P`
||| for a partial `P`, and `apply x args` of a known partial with more
||| arguments than it misses becomes the call that saturates it followed by an
||| `apply` of the result to the rest. `ConstFold` takes it from there.
export
foldKnownPartials : {auto v : Ref VarId Int} -> RCExp -> Core RCExp
foldKnownPartials = go empty
  where
    go : Known -> RCExp -> Core RCExp
    go kp (RLet fc x rep (RLet _ y _ e@(RUnderApp {}) (RV _ (RCLoc y'))) body) =
        if y == y' then go kp (RLet fc x rep e body)
                   else traverseChildren @{Applicative.CORE} (go kp) (RLet fc x rep (RLet fc y RBoxed e (RV fc (RCLoc y'))) body)
    go kp (RLet fc x rep value@(RUnderApp _ n missing caps) body) =
        RLet fc x rep value <$> go (insert x (n, missing, caps) kp) body
    go kp e@(RApp fc lazy (RCLoc k) args) =
        case lookup k kp of
             Just (n, missing, caps) =>
                 let as = forget args in
                 if missing > 0 && length as > missing
                    then do
                        r <- freshVarId
                        case fromList (drop missing as) of
                             Just rest => pure $ RLet fc r RBoxed (RAppName fc lazy n (caps ++ take missing as))
                                                    (RApp fc lazy (RCLoc r) rest)
                             Nothing => pure e
                    else pure e
             Nothing => pure e
    go kp e = traverseChildren @{Applicative.CORE} (go kp) e
