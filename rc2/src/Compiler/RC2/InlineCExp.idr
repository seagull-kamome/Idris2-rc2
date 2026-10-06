||| rc2's whole-program inlining, on the named case trees before lambda
||| lifting. Criterion A: a small, call-free function's body replaces
||| every saturated call to it, so `Compiler.RC2.RC`'s comparison fusion
||| sees through an interface method such as `Ord Int`'s `<=`. Criterion
||| B: a loop-free function called once is spliced there, so a
||| constructor it returns meets the caller's `case`. Then the
||| case-of-case collapse, for the nesting a splice leaves in a scrutinee.
||| Design: `rc2/doc/inlining.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.InlineCExp

import Compiler.RC2.ConstFold
import Compiler.RC2.MutualLoop

import Core.CompileExpr
import Core.Context
import Core.Core
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

-------------------------------------------------------------------------------
-- Eligibility

smallBodyThreshold : Nat
smallBodyThreshold = 24

-- What lambda lifting turns into a call, a closure or an application is
-- a call here, so a call-free body lifts to itself.
isCallFree : NamedCExp -> Bool
isCallFree (NmLocal _ _) = True
isCallFree (NmLet _ _ val sc) = isCallFree val && isCallFree sc
isCallFree (NmCon _ _ _ _ args) = all isCallFree args
isCallFree (NmOp _ _ args) = all isCallFree (toList args)
isCallFree (NmConCase _ sc alts def) =
    isCallFree sc && all (\(MkNConAlt _ _ _ _ b) => isCallFree b) alts && maybe True isCallFree def
isCallFree (NmConstCase _ sc alts def) =
    isCallFree sc && all (\(MkNConstAlt _ b) => isCallFree b) alts && maybe True isCallFree def
isCallFree (NmPrimVal _ _) = True
isCallFree (NmErased _) = True
isCallFree (NmCrash _ _) = True
isCallFree _ = False

-- Only ever applied to a call-free body, where it counts what its lifted
-- form would.
sizeOf : NamedCExp -> Nat
sizeOf (NmLet _ _ val sc) = 1 + sizeOf val + sizeOf sc
sizeOf (NmCon _ _ _ _ args) = 1 + sum (map sizeOf args)
sizeOf (NmOp _ _ args) = 1 + sum (toList (map sizeOf args))
sizeOf (NmConCase _ sc alts def) =
    1 + sizeOf sc + sum (map (\(MkNConAlt _ _ _ _ b) => sizeOf b) alts) + maybe 0 sizeOf def
sizeOf (NmConstCase _ sc alts def) =
    1 + sizeOf sc + sum (map (\(MkNConstAlt _ b) => sizeOf b) alts) + maybe 0 sizeOf def
sizeOf _ = 1

record Eligible where
  constructor MkEligible
  params : List Name
  body : NamedCExp

-- The bound for a body that became call-free only through its own
-- Criterion A rewrite; `inlining.md`, "Eligibility: Criterion A".
delegatingThreshold : Nat
delegatingThreshold = 20

-- `orig` is the body before, `b` the body after the callee's own rewrite.
-- A function on a call cycle keeps a call to a cycle member, never in the
-- map, so `b` is not call-free.
smallCallFree : NamedCExp -> NamedCExp -> Bool
smallCallFree orig b = isCallFree b && sizeOf b <= (if isCallFree orig then smallBodyThreshold else delegatingThreshold)

-- All-literal arguments with a `Double` among them would reach gcc as a
-- constant expression it can reject under `-Werror=overflow`
-- (`inlining.md`, "The `allLiteralArgs` guard").
allLiteralArgs : List NamedCExp -> Bool
allLiteralArgs [] = False
allLiteralArgs args = all isPrimVal args && any unfoldable args
  where
    isPrimVal : NamedCExp -> Bool
    isPrimVal (NmPrimVal _ _) = True
    isPrimVal _ = False
    unfoldable : NamedCExp -> Bool
    unfoldable (NmPrimVal _ c) = not (safeConst c)
    unfoldable _ = False

-------------------------------------------------------------------------------
-- Splicing

data Fresh : Type where

fresh : {auto f : Ref Fresh Int} -> String -> Core Name
fresh hint = do
    i <- get Fresh
    put Fresh (i + 1)
    pure (MN hint i)

-- Every binder of the copy gets a new name: the lifter resolves a name to
-- its innermost binder, so a capture would silently read the wrong one.
copy : {auto f : Ref Fresh Int} -> SortedMap Name NamedCExp -> NamedCExp -> Core NamedCExp
copy env e@(NmLocal _ x) = pure (fromMaybe e (lookup x env))
copy env (NmLam fc x sc) = do
    x' <- fresh "rc2inl"
    NmLam fc x' <$> copy (insert x (NmLocal fc x') env) sc
copy env (NmLet fc x val sc) = do
    x' <- fresh "rc2inl"
    pure $ NmLet fc x' !(copy env val) !(copy (insert x (NmLocal fc x') env) sc)
copy env (NmApp fc g args) = NmApp fc <$> copy env g <*> traverse (copy env) args
copy env (NmCon fc n ci t args) = NmCon fc n ci t <$> traverse (copy env) args
copy env (NmOp fc op args) = NmOp fc op <$> traverseVect args
  where
    traverseVect : Vect k NamedCExp -> Core (Vect k NamedCExp)
    traverseVect [] = pure []
    traverseVect (a :: as) = pure $ !(copy env a) :: !(traverseVect as)
copy env (NmExtPrim fc p args) = NmExtPrim fc p <$> traverse (copy env) args
copy env (NmForce fc lr t) = NmForce fc lr <$> copy env t
copy env (NmDelay fc lr t) = NmDelay fc lr <$> copy env t
copy env (NmConCase fc sc alts def) =
    pure $ NmConCase fc !(copy env sc) !(traverse alt alts) !(traverseOpt (copy env) def)
  where
    alt : NamedConAlt -> Core NamedConAlt
    alt (MkNConAlt n ci t args b) = do
        args' <- traverse (const (fresh "rc2inl")) args
        let env' = foldl (\m, (a, a') => insert a (NmLocal fc a') m) env (zip args args')
        MkNConAlt n ci t args' <$> copy env' b
copy env (NmConstCase fc sc alts def) =
    pure $ NmConstCase fc !(copy env sc) !(traverse alt alts) !(traverseOpt (copy env) def)
  where
    alt : NamedConstAlt -> Core NamedConstAlt
    alt (MkNConstAlt c b) = MkNConstAlt c <$> copy env b
copy _ e = pure e

-- A non-atomic argument is bound by a `let` first, so it is evaluated
-- once, before the body, as the call evaluated it.
splice : {auto f : Ref Fresh Int} -> FC -> Eligible -> List NamedCExp -> Core NamedCExp
splice fc (MkEligible ps b) args = go (zip ps args) empty
  where
    atomic : NamedCExp -> Bool
    atomic (NmLocal _ _) = True
    atomic (NmPrimVal _ _) = True
    atomic (NmErased _) = True
    atomic _ = False

    go : List (Name, NamedCExp) -> SortedMap Name NamedCExp -> Core NamedCExp
    go [] env = copy env b
    go ((p, a) :: rest) env =
        if atomic a
           then go rest (insert p a env)
           else do
             x <- fresh "rc2inlArg"
             NmLet fc x a <$> go rest (insert p (NmLocal fc x) env)

-------------------------------------------------------------------------------
-- The rewrite

mutual
  inline : {auto f : Ref Fresh Int} -> SortedMap Name Eligible -> NamedCExp -> Core NamedCExp
  inline elig (NmApp fc (NmRef rfc n) args) = do
      args' <- traverse (inline elig) args
      callTo elig fc n args' (NmApp fc (NmRef rfc n) args')
  inline elig e@(NmRef fc n) = callTo elig fc n [] e
  inline elig e@(NmForce fc lr (NmRef rfc n)) = callTo elig fc n [NmErased fc] e
  inline elig (NmApp fc g args) = NmApp fc <$> inline elig g <*> traverse (inline elig) args
  inline elig (NmLam fc x sc) = NmLam fc x <$> inline elig sc
  inline elig (NmLet fc x val sc) = NmLet fc x <$> inline elig val <*> inline elig sc
  inline elig (NmCon fc n ci t args) = NmCon fc n ci t <$> traverse (inline elig) args
  inline elig (NmOp fc op args) = NmOp fc op <$> traverseVect args
    where
      traverseVect : Vect k NamedCExp -> Core (Vect k NamedCExp)
      traverseVect [] = pure []
      traverseVect (a :: as) = pure $ !(inline elig a) :: !(traverseVect as)
  inline elig (NmExtPrim fc p args) = NmExtPrim fc p <$> traverse (inline elig) args
  inline elig (NmForce fc lr t) = NmForce fc lr <$> inline elig t
  inline elig (NmDelay fc lr t) = NmDelay fc lr <$> inline elig t
  inline elig (NmConCase fc sc alts def) =
      pure $ NmConCase fc !(inline elig sc)
                !(traverse (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as <$> inline elig b) alts)
                !(traverseOpt (inline elig) def)
  inline elig (NmConstCase fc sc alts def) =
      pure $ NmConstCase fc !(inline elig sc)
                !(traverse (\(MkNConstAlt c b) => MkNConstAlt c <$> inline elig b) alts)
                !(traverseOpt (inline elig) def)
  inline _ e = pure e

  -- `Force` of a name lifts to a call of it with an erased argument, so
  -- it is inlined as that call.
  callTo : {auto f : Ref Fresh Int} -> SortedMap Name Eligible -> FC -> Name -> List NamedCExp -> NamedCExp -> Core NamedCExp
  callTo elig fc n args orig = case lookup n elig of
      Just e => if length (params e) == length args && not (allLiteralArgs args)
                   then splice fc e args
                   else pure orig
      Nothing => pure orig

-------------------------------------------------------------------------------
-- Criterion B: a loop-free function with exactly one call, whole-program

-- Every name the body calls, once per call: every `NmRef` lifts to a
-- call, in a lambda too.
calledNames : NamedCExp -> List Name
calledNames = go []
  where
    go : List Name -> NamedCExp -> List Name
    go acc (NmRef _ n) = n :: acc
    go acc (NmLam _ _ b) = go acc b
    go acc (NmLet _ _ v b) = go (go acc v) b
    go acc (NmApp _ g args) = foldl go (go acc g) args
    go acc (NmCon _ _ _ _ args) = foldl go acc args
    go acc (NmOp _ _ args) = foldl go acc (toList args)
    go acc (NmExtPrim _ _ args) = foldl go acc args
    go acc (NmForce _ _ t) = go acc t
    go acc (NmDelay _ _ t) = go acc t
    go acc (NmConCase _ sc alts def) =
        maybe id (flip go) def (foldl (\a, (MkNConAlt _ _ _ _ b) => go a b) (go acc sc) alts)
    go acc (NmConstCase _ sc alts def) =
        maybe id (flip go) def (foldl (\a, (MkNConstAlt _ b) => go a b) (go acc sc) alts)
    go acc _ = acc

defCalls : NamedDef -> List Name
defCalls (MkNmFun _ b) = calledNames b
defCalls (MkNmError b) = calledNames b
defCalls _ = []

-- Called once in the whole program, in no call cycle (a self-call
-- included), and taking arguments: a CAF is evaluated once however
-- often it is referenced.
singleCallerCallees : SortedMap Name NamedDef -> SortedMap Name (List Name) -> List (List Name) -> SortedSet Name
singleCallerCallees defOf callees sccs =
    let counts : SortedMap Name Nat :=
            foldl (\acc, ns => foldl (\m, n => insert n (1 + fromMaybe 0 (lookup n m)) m) acc ns)
                  (the (SortedMap Name Nat) empty) (values callees)
        cyclic : SortedSet Name :=
            foldl (\acc, scc => case scc of
                                     [_] => acc
                                     _ => foldl (flip insert) acc scc)
                  (the (SortedSet Name) empty) sccs
    in fromList $ mapMaybe (\(n, k) => if k == 1 && ok cyclic n then Just n else Nothing) (SortedMap.toList counts)
  where
    ok : SortedSet Name -> Name -> Bool
    ok cyclic n = case lookup n defOf of
        Just (MkNmFun (_ :: _) _) => not (contains n cyclic) && not (elem n (fromMaybe [] (lookup n callees)))
        _ => False

-------------------------------------------------------------------------------
-- Case-of-case collapse
--
-- A splice into a scrutinee leaves `case (case x of ...) of alts`, which
-- `Compiler.RC2.RC`'s `tryFuseCompare` doesn't recognise; one `case`
-- over `x`, `alts` copied into each inner branch, is what lets it fuse.
-- Ported from upstream `Compiler.CaseOpts`; names need no re-indexing
-- when `alts` move under an inner branch's binders, since those are
-- distinct from every name in scope. Design, the size budget and its
-- bookkeeping: `rc2/doc/inlining.md`, "Case-of-case collapse".

-- Unlike `sizeOf` above, for any tree: a lambda counts its body, which
-- a copy duplicates.
treeSize : NamedCExp -> Nat
treeSize (NmLam _ _ b) = 1 + treeSize b
treeSize (NmLet _ _ v b) = 1 + treeSize v + treeSize b
treeSize (NmApp _ g args) = 1 + treeSize g + sum (map treeSize args)
treeSize (NmCon _ _ _ _ args) = 1 + sum (map treeSize args)
treeSize (NmOp _ _ args) = 1 + sum (toList (map treeSize args))
treeSize (NmExtPrim _ _ args) = 1 + sum (map treeSize args)
treeSize (NmForce _ _ t) = 1 + treeSize t
treeSize (NmDelay _ _ t) = 1 + treeSize t
treeSize (NmConCase _ sc alts def) =
    1 + treeSize sc + sum (map (\(MkNConAlt _ _ _ _ b) => treeSize b) alts) + maybe 0 treeSize def
treeSize (NmConstCase _ sc alts def) =
    1 + treeSize sc + sum (map (\(MkNConstAlt _ b) => treeSize b) alts) + maybe 0 treeSize def
treeSize _ = 1

conAltsSize : List NamedConAlt -> Nat
conAltsSize = foldl (\acc, (MkNConAlt _ _ _ _ b) => acc + treeSize b) 0

constAltsSize : List NamedConstAlt -> Nat
constAltsSize = foldl (\acc, (MkNConstAlt _ b) => acc + treeSize b) 0

record Sized where
  constructor MkSized
  szOf : Nat
  valOf : NamedCExp

-- The candidate, its size, and the size of its own alternatives and
-- default (what a collapse copies).
record Collapse where
  constructor MkCollapse
  totalSize : Nat
  branchesSize : Nat
  tree : NamedCExp

caseOfCaseSizeBudget : Nat
caseOfCaseSizeBudget = 200

tryCaseOfCase : Collapse -> Maybe Collapse
tryCaseOfCase (MkCollapse _ outerSize (NmConCase fc (NmConCase fc' x xalts xdef) alts def)) =
    let copies : Nat = length xalts + maybe 0 (const 1) xdef in
    if canCollapse xalts xdef && copies * outerSize <= caseOfCaseSizeBudget
       then let nb : Nat = conAltsSize xalts + maybe 0 treeSize xdef + copies * (1 + outerSize)
            in Just (MkCollapse (1 + treeSize x + nb) nb
                       (NmConCase fc' x (map (\(MkNConAlt n ci t as b) => MkNConAlt n ci t as (NmConCase fc b alts def)) xalts)
                                        (map (\b => NmConCase fc b alts def) xdef)))
       else Nothing
  where
    isCon : NamedCExp -> Bool
    isCon (NmCon {}) = True
    isCon _ = False
    canCollapse : List NamedConAlt -> Maybe NamedCExp -> Bool
    canCollapse [] _ = True
    canCollapse [_] Nothing = True
    canCollapse xs mdef = all (\(MkNConAlt _ _ _ _ b) => isCon b) xs && maybe True isCon mdef
tryCaseOfCase (MkCollapse _ outerSize (NmConstCase fc (NmConstCase fc' x xalts xdef) alts def)) =
    let copies : Nat = length xalts + maybe 0 (const 1) xdef in
    if canCollapse xalts xdef && copies * outerSize <= caseOfCaseSizeBudget
       then let nb : Nat = constAltsSize xalts + maybe 0 treeSize xdef + copies * (1 + outerSize)
            in Just (MkCollapse (1 + treeSize x + nb) nb
                       (NmConstCase fc' x (map (\(MkNConstAlt c b) => MkNConstAlt c (NmConstCase fc b alts def)) xalts)
                                          (map (\b => NmConstCase fc b alts def) xdef)))
       else Nothing
  where
    isConst : NamedCExp -> Bool
    isConst (NmPrimVal {}) = True
    isConst _ = False
    canCollapse : List NamedConstAlt -> Maybe NamedCExp -> Bool
    canCollapse [] _ = True
    canCollapse [_] Nothing = True
    canCollapse xs mdef = all (\(MkNConstAlt _ b) => isConst b) xs && maybe True isConst mdef
tryCaseOfCase _ = Nothing

-- At most 5 collapses at one node, as upstream's `caseOfCase`.
caseOfCaseHere : Collapse -> Collapse
caseOfCaseHere = go 5
  where
    go : Nat -> Collapse -> Collapse
    go Z st = st
    go (S k) st = maybe st (go k) (tryCaseOfCase st)

-- Bottom-up, sizes carried along instead of re-counted at every node.
collapse : NamedCExp -> Sized
collapse (NmLam fc x b) = let b' = collapse b in MkSized (1 + szOf b') (NmLam fc x (valOf b'))
collapse (NmLet fc x v b) =
    let v' = collapse v
        b' = collapse b
    in MkSized (1 + szOf v' + szOf b') (NmLet fc x (valOf v') (valOf b'))
collapse (NmApp fc g args) =
    let g' = collapse g
        args' = map collapse args
    in MkSized (1 + szOf g' + sum (map szOf args')) (NmApp fc (valOf g') (map valOf args'))
collapse (NmCon fc n ci t args) =
    let args' = map collapse args in MkSized (1 + sum (map szOf args')) (NmCon fc n ci t (map valOf args'))
collapse (NmOp fc op args) =
    let args' = map collapse args in MkSized (1 + sum (toList (map szOf args'))) (NmOp fc op (map valOf args'))
collapse (NmExtPrim fc p args) =
    let args' = map collapse args in MkSized (1 + sum (map szOf args')) (NmExtPrim fc p (map valOf args'))
collapse (NmForce fc lr t) = let t' = collapse t in MkSized (1 + szOf t') (NmForce fc lr (valOf t'))
collapse (NmDelay fc lr t) = let t' = collapse t in MkSized (1 + szOf t') (NmDelay fc lr (valOf t'))
collapse (NmConCase fc sc alts def) =
    let sc' = collapse sc
        alts' = map (\(MkNConAlt n ci t as b) => let b' = collapse b in (szOf b', MkNConAlt n ci t as (valOf b'))) alts
        def' = map collapse def
        outer = sum (map fst alts') + maybe 0 szOf def'
        final = caseOfCaseHere (MkCollapse (1 + szOf sc' + outer) outer
                                  (NmConCase fc (valOf sc') (map snd alts') (map valOf def')))
    in MkSized (totalSize final) (tree final)
collapse (NmConstCase fc sc alts def) =
    let sc' = collapse sc
        alts' = map (\(MkNConstAlt c b) => let b' = collapse b in (szOf b', MkNConstAlt c (valOf b'))) alts
        def' = map collapse def
        outer = sum (map fst alts') + maybe 0 szOf def'
        final = caseOfCaseHere (MkCollapse (1 + szOf sc' + outer) outer
                                  (NmConstCase fc (valOf sc') (map snd alts') (map valOf def')))
    in MkSized (totalSize final) (tree final)
collapse e = MkSized 1 e

-------------------------------------------------------------------------------
-- The pass

||| Criteria A and B over `main` and every definition. Definitions are
||| rewritten callees first, so a Criterion B callee is spliced with its
||| own calls already inlined; a Criterion A callee is judged on its
||| rewritten body, call-free once its callees are in, so no second pass.
||| With `keep`, a whole-program compile, a Criterion B callee
||| left with no call is dropped unless `keep` has it (an `%export`):
||| lifted, it would only duplicate the lambdas now lifted in its caller
||| until `Compiler.RC2.DeadCode` removes it.
export
inlineCExp : (keep : Maybe (SortedSet Name)) -> Maybe NamedCExp -> List (Name, FC, NamedDef) ->
             Core (Maybe NamedCExp, List (Name, FC, NamedDef))
inlineCExp keep main defs = do
    f <- newRef Fresh 0
    let mainName = MN "__mainExpression" 0
        allDefs : List (Name, NamedDef) := mainDef mainName main ++ map (\(n, _, d) => (n, d)) defs
        defOf : SortedMap Name NamedDef := fromList allDefs
        callees : SortedMap Name (List Name) := map defCalls defOf
        sccs = tarjanSCCs (map SortedSet.fromList callees)
        single = singleCallerCallees defOf callees sccs
    done <- rewriteAll defOf single empty empty (calleesFirst sccs)
    let final = \n, d => fromMaybe d (lookup n done)
        called : SortedSet Name := foldl (\s, d => foldl (flip insert) s (defCalls d)) empty (values done)
        gone = \n => maybe False (\k => contains n single && not (contains n called) && not (contains n k)) keep
    pure ( map (\m => case final mainName (MkNmFun [] m) of
                           MkNmFun _ b => b
                           _ => m) main
         , mapMaybe (\(n, fc, d) => if gone n then Nothing else Just (n, fc, final n d)) defs )
  where
    mainDef : Name -> Maybe NamedCExp -> List (Name, NamedDef)
    mainDef _ Nothing = []
    mainDef n (Just m) = [(n, MkNmFun [] m)]

    calleesFirst : List (List Name) -> List Name
    calleesFirst = foldl (\acc, scc => foldl (flip (::)) acc scc) []

    rewriteDef : {auto f : Ref Fresh Int} -> SortedMap Name Eligible -> NamedDef -> Core NamedDef
    rewriteDef elig (MkNmFun args b) = MkNmFun args . valOf . collapse <$> inline elig b
    rewriteDef elig (MkNmError b) = MkNmError . valOf . collapse <$> inline elig b
    rewriteDef _ d = pure d

    origBody : NamedDef -> NamedCExp
    origBody (MkNmFun _ o) = o
    origBody (MkNmError o) = o
    origBody _ = NmErased emptyFC

    rewriteAll : {auto f : Ref Fresh Int} -> SortedMap Name NamedDef -> SortedSet Name -> SortedMap Name Eligible
              -> SortedMap Name NamedDef -> List Name -> Core (SortedMap Name NamedDef)
    rewriteAll _ _ _ done [] = pure done
    rewriteAll defOf single elig done (n :: ns) = case lookup n defOf of
        Nothing => rewriteAll defOf single elig done ns
        Just d => do
            d' <- rewriteDef elig d
            let elig' = case d' of
                             MkNmFun args b => if smallCallFree (origBody d) b || contains n single then insert n (MkEligible args b) elig else elig
                             _ => elig
            rewriteAll defOf single elig' (insert n d' done) ns
