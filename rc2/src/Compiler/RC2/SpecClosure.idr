||| Speculative, profitability-gated closure-argument specialization.
||| Design, motivation, and the reasoning behind every non-obvious
||| choice below live in `rc2/doc/speculative-closure-specialization.md`
||| (its own "Internal structure" section maps directly onto this
||| module's own functions) -- this file only comments *how*, not *why*.
||| Disable with `--directive nospecclosure`. Its own whole-pass-level
||| timing/count diagnostics (`applySpecClosure`'s own
||| `maybeLogTimeOver`) only print with `--directive timing`.
|||
||| A second, sibling pass lives in this module's own lower half:
||| `applySpecConstCon`, which specializes on a *constant-constructor*
||| argument (an interface dictionary) rather than a closure one. It
||| shares this module's structural helpers and pipeline position but
||| is a separate stage, disabled separately with
||| `--directive nospecconstcon`; see
||| `rc2/doc/constant-constructor-specialization.md`.
module Compiler.RC2.SpecClosure

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.ConstFold
import Compiler.RC2.Emit.Util
import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.Context
import Core.Context.Log
import Core.Core
import Core.FC
import Core.Options
import Core.TT

import Data.DPair
import Data.List
import Data.List1
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

------------------------------------------------------------------------
-- Shared structural recursion over this pass's own RCExp subset --
-- see the doc's "Internal structure" section, "Shared structural
-- recursion" paragraph.
------------------------------------------------------------------------

mapAlt : (RCExp -> RCExp) -> RConAlt -> RConAlt
mapAlt f (MkRConAlt n ci tag as body) = MkRConAlt n ci tag as (f body)

mapConstAlt : (RCExp -> RCExp) -> RConstAlt -> RConstAlt
mapConstAlt f (MkRConstAlt c body) = MkRConstAlt c (f body)

||| Rebuild `e` by applying `f` to each immediate child.
mapSubExprs : (RCExp -> RCExp) -> RCExp -> RCExp
mapSubExprs f (RLet fc var rep value body) = RLet fc var rep (f value) (f body)
mapSubExprs f (RCmpCase fc op args postDrop t fa) = RCmpCase fc op args postDrop (f t) (f fa)
mapSubExprs f (RConCase fc sc alts mDef) = RConCase fc sc (map (mapAlt f) alts) (map f mDef)
mapSubExprs f (RConstCase fc sc alts mDef) = RConstCase fc sc (map (mapConstAlt f) alts) (map f mDef)
mapSubExprs _ e = e

||| Combine `f`'s result over each immediate child of `e` with `op`;
||| `z` both for a childless leaf and as the fold seed.
foldSubExprs : (a -> a -> a) -> a -> (RCExp -> a) -> RCExp -> a
foldSubExprs op _ f (RLet _ _ _ value body) = f value `op` f body
foldSubExprs op _ f (RCmpCase _ _ _ _ t fa) = f t `op` f fa
foldSubExprs op z f (RConCase _ _ alts mDef) = foldr op (maybe z f mDef) (map (\(MkRConAlt _ _ _ _ b) => f b) alts)
foldSubExprs op z f (RConstCase _ _ alts mDef) = foldr op (maybe z f mDef) (map (\(MkRConstAlt _ b) => f b) alts)
foldSubExprs _ z _ _ = z

------------------------------------------------------------------------
-- Step 1: whole-program call-site discovery
------------------------------------------------------------------------

||| See the doc's "Internal structure" -> "Records" paragraph.
record KnownClosure where
  constructor MkKnownClosure
  target : Name
  missing : Nat
  capturedArgs : List RCLocal

||| One call site passing a `KnownClosure` at argument `argPos` of a
||| call to `callee`.
record Opportunity where
  constructor MkOpportunity
  callee : Name
  argPos : Nat
  closure : KnownClosure

||| See the doc's "Internal structure" -> "Records" paragraph.
Bound : Type
Bound = SortedMap Int KnownClosure

||| See the doc's "Internal structure" -> "Finding a known closure at a
||| use site" paragraph.
lookupKnown : Bound -> RCLocal -> Maybe KnownClosure
lookupKnown bound (RCLoc i) = lookup i bound
lookupKnown _ (RCConstClosure n missing) = Just (MkKnownClosure n missing [])
lookupKnown _ _ = Nothing

||| Every `Opportunity` in `e`, given `bound` from enclosing `RLet`s.
collectOpportunities : Bound -> RCExp -> List Opportunity
collectOpportunities bound (RLet _ var _ value body) =
    let bound' = case value of
                      RUnderApp _ n missing capturedArgs => insert var (MkKnownClosure n missing capturedArgs) bound
                      _ => bound
    in collectOpportunities bound value ++ collectOpportunities bound' body
collectOpportunities bound (RAppName _ _ callee args) =
    mapMaybe (\(i, a) => map (MkOpportunity callee i) (lookupKnown bound a)) (zip [0 .. length args] args)
collectOpportunities bound e = foldSubExprs (++) [] (collectOpportunities bound) e

------------------------------------------------------------------------
-- Step 1 (continued): is the parameter actually used only via `apply`
-- (possibly chained, possibly also passed through to self-recursion)?
------------------------------------------------------------------------

||| See the doc's "Internal structure" -> "Chain detection" paragraph,
||| and `doc/rapp-nary-closure-apply.md`'s own "A free simplification
||| this exposed" section for why this only *partly* collapsed once
||| `RApp` itself gained a `List RCLocal` args field: a source-level
||| `v x y` now reaches here as one `RApp v [x, y]` node already
||| (`Compiler.RC2.RC`'s `collectAppChain` merges it at Phase 1), so
||| the exact-match case below is now the common one -- but a genuinely
||| let-bound intermediate partial application (`let partial = v x in
||| ... partial y ...`, two syntactically separate applications in the
||| source) still reaches here as two distinct `RApp` nodes threaded by
||| an `RLet`, each contributing however many args *its own* hop
||| carries (no longer always exactly one), so the chained case still
||| has real work to do.
chainArgs : RCLocal -> Nat -> RCExp -> Maybe (List RCLocal)
chainArgs v missing (RLet _ t _ (RApp _ _ c args) cont) =
    if c == v && length args < missing
       then (\rest => forget args ++ rest) <$> chainArgs (RCLoc t) (missing `minus` length args) cont
       else Nothing
chainArgs v missing (RApp _ _ c args) =
    if c == v && length args == missing then Just (forget args) else Nothing
chainArgs _ _ _ = Nothing

||| See the doc's "Internal structure" -> "Self-recursive passthrough"
||| paragraph.
selfPassthroughOccurrences : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Nat
selfPassthroughOccurrences v callee argPos (RAppName _ _ n args) =
    if n == callee && getAt argPos args == Just v then 1 else 0
selfPassthroughOccurrences v callee argPos e = foldSubExprs (+) 0 (selfPassthroughOccurrences v callee argPos) e

||| The `missing`-long apply chains rooted at `v` in `e`.
chainCount : RCLocal -> Nat -> RCExp -> Nat
chainCount v missing e = (if isJust (chainArgs v missing e) then 1 else 0) + foldSubExprs (+) 0 (chainCount v missing) e

||| Every position at which `e` passes `v` on to a call other than
||| `callee`'s own self passthrough at `argPos`: to another function, or
||| to `callee` at another position. See the doc's "Transitive
||| specialisation" -> "Forwarding as a third kind of use".
forwardSites : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> List (Name, Nat)
forwardSites v callee argPos (RAppName _ _ n args) =
    mapMaybe (\(q, a) => if a == v && not (n == callee && q == argPos) then Just (n, q) else Nothing)
             (zip [0 .. length args] args)
forwardSites v callee argPos e = foldSubExprs (++) [] (forwardSites v callee argPos) e

||| `Just` the forwarding sites of `v` if every use of it in `e` is a
||| `missing`-long apply chain, a self passthrough or a forwarding site,
||| with at most one chain and at least one chain or forwarding site;
||| `Nothing` otherwise. More than one chain is refused to bound code
||| size (doc's "Transitive specialisation" -> "Results").
paramUses : RCLocal -> Nat -> (callee : Name) -> (argPos : Nat) -> RCExp -> Maybe (List (Name, Nat))
paramUses v missing callee argPos e =
    let chains = chainCount v missing e
        fwds = forwardSites v callee argPos e
        accounted = chains + selfPassthroughOccurrences v callee argPos e + length fwds
    in if accounted == countUsesR v e && not (chains > 1) && (chains > 0 || not (null fwds)) then Just fwds else Nothing

------------------------------------------------------------------------
-- Step 2: speculative clone + rewrite, one attempt per distinct
-- (callee, argPos, target, missing) key -- see the doc's "The proposed
-- rc2-native design" -> "2. Speculative clone + re-fold" for why
-- `capturedArgs`'s own values aren't part of that key.
------------------------------------------------------------------------

||| Rewrites the `missing`-long apply chain rooted at `paramVar` into a
||| direct call to `targetName`, fed `capturedParams` followed by the
||| chain's own applied arguments, in order.
rewriteApply : (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteApply paramVar targetName missing capturedParams = go
  where
    go : RCExp -> RCExp
    go e = case chainArgs (RCLoc paramVar) missing e of
                Just args => RAppName EmptyFC Nothing targetName (map RCLoc capturedParams ++ args)
                Nothing => mapSubExprs go e

||| See the doc's "Internal structure" -> "Self-recursive passthrough"
||| paragraph.
rewriteSelfCall : (callee : Name) -> (argPos : Nat) -> (paramVar : Int) -> (cloneName : Name) -> (capturedParams : List Int) -> RCExp -> RCExp
rewriteSelfCall callee argPos paramVar cloneName capturedParams = go
  where
    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        if n == callee && getAt argPos args == Just (RCLoc paramVar)
           then case splitAt argPos args of
                     (before, _ :: after) => RAppName fc lazy cloneName (before ++ map RCLoc capturedParams ++ after)
                     _ => RAppName fc lazy n args
           else RAppName fc lazy n args
    go e = mapSubExprs go e

||| Builds one specialized clone of `g` (`callee`; `paramVar`: the
||| `Int` id of its closure parameter at `argPos`) for one `(targetName,
||| missing, capturedCount)` triple -- see the doc's "Internal
||| structure" -> "Profitability + redirection" paragraph for
||| `capturedCount`'s own provenance. Not re-folded here --
||| `applySpecClosure` does that once, after this returns.
|||
||| `capturedParams`'s own fresh ids come from the shared, whole-
||| compile `VarId` counter (`Compiler.RC2.Util`) -- guaranteed not to
||| collide with `g`'s own existing ids (or anything else in the
||| program) without needing to scan `g`'s body for its current
||| highest id first, unlike `cloneId` (`FreshId`, a *name*-numbering
||| counter, disjoint from `VarId`'s var-id numbering -- see that
||| type's own doc comment for why the two stay separate).
buildClone : {auto fr : Ref FreshId Int} -> {auto v : Ref VarId Int}
          -> (callee : Name) -> (argPos : Nat)
          -> (paramVar : Int) -> (targetName : Name) -> (missing : Nat) -> (capturedCount : Nat)
          -> (args : List (Int, Rep)) -> (retRep : Rep) -> (body : RCExp)
          -> Core (Name, RCDef)
buildClone callee argPos paramVar targetName missing capturedCount args retRep body = do
    cloneId <- freshId
    capturedParams <- traverse (const freshVarId) (replicate capturedCount ())
    -- Embeds `callee`'s own mangled name (`cName`, exported by
    -- `Compiler.RC2.Emit.Util` for exactly this reuse) the same way
    -- `Compiler.RC2.DualABI`'s own `freshName` already does for a
    -- worker's own name -- a `dumprcexpr`/generated-`.c` reader sees
    -- which original function a given clone specializes on sight,
    -- rather than only an opaque counter.
    let cloneName = MN ("rc2_specClosure_" ++ cName callee) cloneId
    let args' = concatMap (\(i, r) => if i == paramVar
                                          then map (\p => (p, RBoxed)) capturedParams
                                          else [(i, r)]) args
    let body' = rewriteSelfCall callee argPos paramVar cloneName capturedParams
                    (rewriteApply paramVar targetName missing capturedParams body)
    -- Each forwarding site now passes a known closure instead of the
    -- parameter, so that the redirect can send it to that callee's own
    -- clone: the constant itself, or a closure over the captured
    -- parameters, bound once at entry and dropped again by
    -- `dropDeadEntryClosure` once every site is redirected.
    fwdVar <- freshVarId
    let known = if capturedCount == 0 then RCConstClosure targetName missing else RCLoc fwdVar
        body'' = rewriteForward known body'
        body''' = if countUsesR (RCLoc fwdVar) body'' > 0
                     then RLet EmptyFC fwdVar RBoxed (RUnderApp EmptyFC targetName missing (map RCLoc capturedParams)) body''
                     else body''
    pure (cloneName, MkRCFun args' retRep False body''')
  where
    rewriteForward : RCLocal -> RCExp -> RCExp
    rewriteForward known (RAppName fc lazy n as) =
        RAppName fc lazy n (map (\a => if a == RCLoc paramVar then known else a) as)
    rewriteForward known e = mapSubExprs (rewriteForward known) e

------------------------------------------------------------------------
-- Step 3: profitability check + call-site redirection
------------------------------------------------------------------------

||| `True` iff `e` still references `paramVar` -- see the doc's "The
||| proposed rc2-native design" -> "3. Profitability check" section.
stillAppliesParam : Int -> RCExp -> Bool
stillAppliesParam paramVar e = countUsesR (RCLoc paramVar) e > 0

||| Drops the closure `buildClone` binds at a clone's entry for its
||| forwarding sites, once the redirect has sent all of them to clones.
dropDeadEntryClosure : RCDef -> RCDef
dropDeadEntryClosure d@(MkRCFun as r w (RLet _ v _ (RUnderApp _ _ _ _) body)) =
    if countUsesR (RCLoc v) body == 0 then MkRCFun as r w body else d
dropDeadEntryClosure d = d

||| One accepted clone: redirect a call to `callee` at `argPos` to
||| `cloneName` whenever the bound closure there resolves to `target`.
RedirectEntry : Type
RedirectEntry = (Nat, Name, Name)

||| All accepted clones, keyed by `callee` -- built once across every
||| specialization key and applied in a single whole-program pass (see
||| `applySpecClosure`'s own doc comment for why this replaced a
||| per-key `redirectCallSites` call).
RedirectTable : Type
RedirectTable = SortedMap Name (List RedirectEntry)

||| See the doc's "Internal structure" -> "Profitability +
||| redirection" paragraph. Generalized to consult every accepted
||| clone for `callee` in one pass, since a given call site's bound
||| closure can match at most one of them.
redirectCallSitesTable : RedirectTable -> RCExp -> RCExp
redirectCallSitesTable table = goBound empty
  where
    tryEntries : Bound -> FC -> Maybe LazyReason -> Name -> List RCLocal -> List RedirectEntry -> RCExp
    tryEntries bound fc lazy n args [] = RAppName fc lazy n args
    tryEntries bound fc lazy n args ((argPos, target, cloneName) :: rest) =
        case splitAt argPos args of
             (before, a :: after) =>
                 case lookupKnown bound a of
                      Just (MkKnownClosure t _ capturedArgs) =>
                          if t == target
                             then RAppName fc lazy cloneName (before ++ capturedArgs ++ after)
                             else tryEntries bound fc lazy n args rest
                      Nothing => tryEntries bound fc lazy n args rest
             _ => tryEntries bound fc lazy n args rest

    goBound : Bound -> RCExp -> RCExp
    goBound bound (RLet fc var rep value body) =
        let bound' = case value of
                          RUnderApp _ n missing capturedArgs => insert var (MkKnownClosure n missing capturedArgs) bound
                          _ => bound
        in RLet fc var rep (goBound bound value) (goBound bound' body)
    goBound bound (RAppName fc lazy n args) =
        case lookup n table of
             Nothing => RAppName fc lazy n args
             Just entries => tryEntries bound fc lazy n args entries
    goBound bound e = mapSubExprs (goBound bound) e

------------------------------------------------------------------------
-- Whole-program entry point
------------------------------------------------------------------------

||| One round of speculative closure-argument specialization, driven to a
||| fixpoint by `applySpecRounds`. `prevTable`/`done` carry the clones
||| kept in earlier rounds: their keys are not rebuilt, and the table is
||| applied again so a call site a new clone exposes is redirected too.
|||
||| Both the CAF table and call-site redirection are computed *once*
||| over the whole program -- `rebuildCafTable defs` up front, and a
||| `RedirectTable` accumulated across every key and applied in a
||| single final `redirectCallSitesTable` pass -- rather than once per
||| distinct specialization key. An earlier version rebuilt the CAF
||| table from, and redirected call sites across, the entire
||| accumulated definitions list on *every accepted key*: an
||| `O(distinct keys x program size)` cost that made this pass
||| impractically slow on a program the size of `idris2-lsp` (many
||| thousands of definitions, plausibly many distinct closure-argument
||| keys). This version is `O(program size)` overall (plus a small
||| `O(distinct keys)` for table bookkeeping). Reusing `defs`'s own CAF
||| facts (rather than each clone's) is correctness-equivalent: a
||| fresh clone's body only ever calls `target` (already known),
||| itself (already resolved via `rewriteSelfCall`), or whatever `g`'s
||| original body already called -- never another just-built clone
||| from an earlier key in the same pass.
|||
||| Diagnostic instrumentation below (`logTimeOver` at threshold 0, so
||| it would print unconditionally if reached at all) is now just the
||| four whole-pass-level lines -- collect+group, the opportunity/key/
||| def counts, the single `rebuildCafTable`, and the single final
||| redirect pass -- since those are each `O(program size)` at most
||| once per round. The earlier per-key `tryOneKey`/`buildClone+fold`
||| lines (one pair per distinct specialization key, unbounded on a
||| program the size of `idris2-lsp`) were removed once the
||| `O(distinct keys x program size)` slowdown they were added to
||| diagnose was confirmed fixed. Originally left unconditional
||| (bypassing `--timing`/log-level entirely) since that diagnosis was
||| still ongoing; now gated behind `maybeLogTimeOver`'s own
||| `--directive timing` check below, same as every other pass' own
||| `logTime` calls, since that investigation concluded and these lines
||| were just unconditional noise on every single build otherwise.
maybeLogTimeOver : Bool -> Integer -> Core String -> Core a -> Core a
maybeLogTimeOver True nsecs str act = logTimeOver nsecs str act
maybeLogTimeOver False _ _ act = act

||| A specialisation key: callee, argument position, target, missing.
SpecKey : Type
SpecKey = (Name, Nat, Name, Nat)

||| One clone built for `key`, and the keys of the clones its forwarding
||| sites need (doc's "Transitive specialisation" -> "Acceptance").
record Built where
  constructor MkBuilt
  key : SpecKey
  name : Name
  def : RCDef
  needs : List SpecKey
  chains : Nat

applySpecClosure : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> {auto fr : Ref FreshId Int}
                 -> RedirectTable -> SortedSet SpecKey -> List (Name, RCDef)
                 -> Core (List (Name, RCDef), RedirectTable, SortedSet SpecKey, Nat)
applySpecClosure prevTable done defs = do
    timingEnabled <- elem "timing" <$> getDirectives (Other "rc2")
    keys <- maybeLogTimeOver timingEnabled 0 (pure "rc2: SpecClosure: collect+group opportunities")
             (pure (filter (\(k, _) => not (contains k done)) (SortedMap.toList byKey)))
    when timingEnabled $
      coreLift $ putStrLn $ "TIMING rc2: SpecClosure: " ++ show (sum (map (length . snd) keys)) ++ " opportunities, "
                             ++ show (length keys) ++ " distinct keys, " ++ show (length defs) ++ " defs"
    caf <- maybeLogTimeOver timingEnabled 0 (pure ("rc2: SpecClosure: rebuildCafTable (" ++ show (length defs) ++ " defs, once)"))
             (pure (rebuildCafTable defs))
    built <- buildAll defOf caf done [] (map (\(k, opps) => (k, capturedOf opps)) keys)
    let accepted = acceptClosed done built
    when timingEnabled $
      coreLift $ putStrLn $ "TIMING rc2: SpecClosure: " ++ show (length built) ++ " clones built, "
                             ++ show (length accepted) ++ " accepted"
                             ++ " (" ++ show (length (filter (not . null . (.needs)) accepted)) ++ " forwarding, "
                             ++ show (length (filter (\b => null b.needs && b.chains > 1) accepted)) ++ " applying more than once)"
    let table = foldl (\t, b => let (callee, argPos, target, _) = b.key
                                in insertWith (++) callee [(argPos, target, b.name)] t)
                      prevTable accepted
    let done' = foldl (\s, b => insert b.key s) done accepted
    -- `newClones ++ defs`, not `defs ++ newClones`: matches the
    -- ordering the old per-key-accumulated `accDefs` produced (each
    -- accepted clone prepended, original defs at the tail), so
    -- emission's own ArgCounter-derived temp-variable numbering is
    -- unaffected by this refactor.
    out <- maybeLogTimeOver timingEnabled 0 (pure ("rc2: SpecClosure: redirectAll (" ++ show (length defs + length accepted) ++ " defs, once)"))
      (pure $ map (\b => (b.name, dropDeadEntryClosure (redirectDef table b.def))) accepted
              ++ map (\(n, d) => (n, redirectDef table d)) defs)
    pure (out, table, done', length accepted)
  where
    redirectDef : RedirectTable -> RCDef -> RCDef
    redirectDef table (MkRCFun a r w body) = MkRCFun a r w (redirectCallSitesTable table body)
    redirectDef _ d = d

    -- Referenced exactly once, at the `buildAll defOf ...` call above,
    -- which then threads it as a parameter. That is load-bearing, not
    -- style: a `where` definition is lambda-lifted into a function of
    -- the enclosing pattern variables it mentions, so every *further*
    -- reference here would rebuild the whole map. See
    -- `applySpecConstCon`'s own `defOf` for what that costs when the
    -- reference sits inside the per-key loop instead.
    defOf : SortedMap Name RCDef
    defOf = SortedMap.fromList defs
    -- `missing` is part of the key, not just `target` (doc's own
    -- "Internal structure" -> "Records" paragraph).
    addOpp : SortedMap SpecKey (List Opportunity) -> Opportunity -> SortedMap SpecKey (List Opportunity)
    addOpp acc opp = insertWith (++) (opp.callee, opp.argPos, opp.closure.target, opp.closure.missing) [opp] acc

    -- Groups each definition's own opportunities into the map as they
    -- are collected, rather than flattening them into one list first
    -- (`concatMap`, the obvious spelling): `concat` left-nests `++`, so
    -- every definition's list gets copied past the whole prefix built
    -- so far. Measured on `idris2-lsp` (32.4k definitions, 12.2k
    -- opportunities): ~0.9s of this pass's own time went there. Same
    -- trap, and same fix, as `Compiler.RC2.LateInline`'s own `analyse`.
    byKey : SortedMap SpecKey (List Opportunity)
    byKey = foldl (\acc, (_, d) => case d of
                        MkRCFun _ _ _ body => foldl addOpp acc (collectOpportunities empty body)
                        _ => acc)
                  (the (SortedMap SpecKey (List Opportunity)) empty) defs

    capturedOf : List Opportunity -> Nat
    capturedOf (o :: _) = length o.closure.capturedArgs
    capturedOf [] = 0

    rebuildCafTable : List (Name, RCDef) -> CafTable
    rebuildCafTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

    ||| Builds one clone for one key and checks that its parameter is
    ||| gone once folded; `Nothing` if the parameter is used some other
    ||| way, or survives. `caf` is the whole-program CAF table, built
    ||| once by the caller (see `applySpecClosure`'s own doc comment).
    tryOneKey : SortedMap Name RCDef -> CafTable -> SpecKey -> Nat -> Core (Maybe Built)
    tryOneKey defOf caf k@(callee, argPos, target, missing) capturedCount =
        case lookup callee defOf of
             Just (MkRCFun args retRep _ body) =>
                 case getAt argPos args of
                      Just (paramVar, _) =>
                          case paramUses (RCLoc paramVar) missing callee argPos body of
                               Nothing => pure Nothing
                               Just fwds => do
                                   (cloneName, unfoldedDef) <- buildClone callee argPos paramVar target missing capturedCount args retRep body
                                   let MkRCFun a r w foldedBody = foldConstDef True caf unfoldedDef
                                       | _ => pure Nothing
                                   pure $ if stillAppliesParam paramVar foldedBody
                                             then Nothing
                                             else Just (MkBuilt k cloneName (MkRCFun a r w foldedBody)
                                                                (map (\(h, q) => (h, q, target, missing)) fwds)
                                                                (chainCount (RCLoc paramVar) missing body))
                      Nothing => pure Nothing
             _ => pure Nothing

    -- A work list: every clone's forwarding sites add the keys of the
    -- clones they need, each key built at most once. `Core` has no
    -- `Monad` instance, so this is a manual loop rather than a fold.
    buildAll : SortedMap Name RCDef -> CafTable -> SortedSet SpecKey -> List Built -> List (SpecKey, Nat)
            -> Core (List Built)
    buildAll _ _ _ acc [] = pure acc
    buildAll defOf caf seen acc ((k, captured) :: rest) =
        if contains k seen
           then buildAll defOf caf seen acc rest
           else do
               mBuilt <- tryOneKey defOf caf k captured
               case mBuilt of
                    Nothing => buildAll defOf caf (insert k seen) acc rest
                    Just b => buildAll defOf caf (insert k seen) (b :: acc) (map (, captured) b.needs ++ rest)

    ||| The greatest subset of `bs` in which every clone's forwarding
    ||| sites find the clones they need.
    acceptClosed : SortedSet SpecKey -> List Built -> List Built
    acceptClosed done bs =
        let keys = the (SortedSet SpecKey) (fromList (map (.key) bs))
            bs' = filter (\b => all (\k => contains k keys || contains k done) b.needs) bs
        in if length bs' == length bs then bs else acceptClosed done bs'

------------------------------------------------------------------------
-- Constant-constructor argument specialization
--
-- The sibling of everything above, aimed at the one remaining
-- structurally-resolvable source of boxed `idris2rc2_applyClosure`
-- dispatch: an interface dictionary. There the specialized parameter
-- isn't a closure that gets *applied*, it's a record that gets
-- *destructured*, so none of the machinery above recognises it:
--
--   def Prelude.Types.elemBy (args= [v10077, v10078, v10079])
--     case v10077 of                                    -- destructure
--       MkFoldable [record] args= [_, _, _, _, _, v10085] ->
--         apply v10085 [..., v10087]                    -- boxed dispatch
--
-- Nothing new is needed downstream -- only getting the constant to the
-- callee's own body. `Compiler.RC2.ConstFold` then folds the `case`
-- away against it, binds each alt field to the corresponding constant,
-- and (since each method field is an `RCConstClosure`) rewrites every
-- `apply` of one into a direct `RAppName` call. That is why this needs
-- no `rewriteApply` analogue at all: seeding the fold IS the rewrite.
--
-- Steps 1-3 deliberately mirror the closure case above, so its own
-- profitability discipline carries over unchanged. See
-- `rc2/doc/constant-constructor-specialization.md` for the design, the
-- measured opportunity, and why this pass was once rejected outright
-- over a cost that turned out not to be its own.
------------------------------------------------------------------------

||| One call site passing constant constructor `value` at argument
||| `argPos` of a call to `callee`.
record ConstOpportunity where
  constructor MkConstOpportunity
  callee : Name
  argPos : Nat
  value : RCLocal

||| Every `ConstOpportunity` in `e`. Unlike `collectOpportunities`
||| above there is no `Bound` to thread: `ConstFold` has already run to
||| a fixpoint over the whole program by the time this pass does, so a
||| constant argument is already spelled out as an `RCConstCon` right
||| at the call site, never still behind an `RLet`.
collectConstOpportunities : RCExp -> List ConstOpportunity
collectConstOpportunities (RAppName _ _ callee args) =
    mapMaybe (\(i, a) => case a of
                              RCConstCon {} => Just (MkConstOpportunity callee i a)
                              _ => Nothing)
             (zip [0 .. length args] args)
collectConstOpportunities e = foldSubExprs (++) [] collectConstOpportunities e

||| Occurrences of `p` sitting in an `RConCase`'s own scrutinee
||| position, anywhere in `e`.
scrutineeUses : RCLocal -> RCExp -> Nat
scrutineeUses p e@(RConCase _ sc _ _) =
    (if sc == p then 1 else 0) + foldSubExprs (+) 0 (scrutineeUses p) e
scrutineeUses p e = foldSubExprs (+) 0 (scrutineeUses p) e

||| `Just` the forwarding sites of `p` iff every occurrence of it in `e`
||| is an `RConCase` scrutinee, a passthrough of `p` at the *same*
||| argument position of a self-recursive call to `callee`, or a
||| *forwarding site* (`forwardSites`: handed to a parameter of some
||| other call), and there is at least one scrutinee or forwarding
||| site. Anything else -- stored into a constructor or closure capture,
||| returned, used by an `RUnderApp` -- means substituting the constant
||| would duplicate it into positions the fold can't collapse, so the
||| clone would be a second copy of the same work rather than a
||| specialization; that stays excluded. The "at least one" half is the
||| same economy: a parameter only carried along its own recursion has
||| nothing to resolve.
|||
||| Discounting the self-passthrough is what reaches the common
||| dictionary shape -- a recursive `go` carrying its dictionary along
||| on every step. Nothing extra is needed to keep such a clone
||| consistent: the seeded fold substitutes the constant into the
||| self-call too, leaving it calling the *generic* callee with the
||| constant spelled out, and the whole-program `redirectConstCallSites`
||| sweep at the end runs over the clones as well as the originals, so
||| that call matches this very key's own redirect entry and becomes a
||| call to the clone itself.
|||
||| The forwarding sites are what make the specialization transitive:
||| after the seeded fold each is a call spelling the same constant at
||| another function's parameter, i.e. exactly another key, which
||| `applySpecConstCon` then builds in turn. See the doc's "Transitive
||| specialisation". The closure half's `paramUses` is the model.
|||
||| Note this pass runs *before* `Compiler.RC2.RC`'s own `annotate`, so
||| there are no `RDup`/`RDrop` occurrences to discount yet.
constParamUses : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Maybe (List (Name, Nat))
constParamUses p callee argPos e =
    let uses = countUsesR p e
        scrut = scrutineeUses p e
        passthrough = selfPassthroughOccurrences p callee argPos e
        fwds = forwardSites p callee argPos e
    in if uses == scrut + passthrough + length fwds && (scrut > 0 || not (null fwds))
          then Just fwds
          else Nothing

||| Occurrences of `p` stored into a constructor or closure capture.
||| Measurement only (`--directive timing`).
storedUses : RCLocal -> RCExp -> Nat
storedUses p e@(RCon _ _ _ _ args _) = count (== p) args + foldSubExprs (+) 0 (storedUses p) e
storedUses p e@(RUnderApp _ _ _ args) = count (== p) args + foldSubExprs (+) 0 (storedUses p) e
storedUses p e = foldSubExprs (+) 0 (storedUses p) e

||| Why `paramIsScrutineeOnly` failed, as a bucket index, for the
||| `--directive timing` breakdown only: 0 forward-only with scrutinee,
||| 1 forward-only without scrutinee, 2 forward mixed with stored or
||| other, 3 stored (no forward), 4 other escaping (no forward, no
||| store), 5 no scrutinee and no other use, 6 anything else.
gateFailBucket : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> Nat
gateFailBucket p callee argPos e =
    let uses = countUsesR p e
        scrut = scrutineeUses p e
        pass = selfPassthroughOccurrences p callee argPos e
        fwd = length (forwardSites p callee argPos e)
        stored = storedUses p e
        rest = minus uses (scrut + pass + fwd)
    in if fwd > 0 then (if rest == 0 then (if scrut > 0 then 0 else 1) else 2)
       else if stored > 0 then 3
       else if rest > 0 then 4
       else if scrut == 0 then 5
       else 6

bump : Nat -> List Nat -> List Nat
bump i = zipWith (\j, n => if j == i then S n else n) [0 .. 8]

||| Total `RApp` (boxed closure dispatch) nodes in `e` -- the
||| profitability measure for this half of the pass.
countApps : RCExp -> Nat
countApps e@(RApp {}) = 1 + foldSubExprs (+) 0 countApps e
countApps e = foldSubExprs (+) 0 countApps e

||| `countApps` over a whole definition.
defApps : RCDef -> Nat
defApps (MkRCFun _ _ _ body) = countApps body
defApps (MkRCError body) = countApps body
defApps _ = 0

||| A constant-constructor specialisation key: callee, argument
||| position, the constant passed there.
ConstKey : Type
ConstKey = (Name, Nat, RCLocal)

||| One clone built for `key`. `own` says it removed an `RApp` by
||| itself (the profitability gate); `needs` are the keys of the
||| clones its forwarding sites call, read off the *folded* body.
record ConstBuilt where
  constructor MkConstBuilt
  key : ConstKey
  name : Name
  def : RCDef
  own : Bool
  needs : List ConstKey

||| The keys a folded clone body still asks for: every call that spells
||| `value` at a parameter position, bar the clone's own self-call at
||| `argPos` (that one is this very key). Deduplicated.
constNeeds : RCLocal -> (callee : Name) -> (argPos : Nat) -> RCExp -> List ConstKey
constNeeds value callee argPos body =
    SortedSet.toList (the (SortedSet ConstKey) (fromList (go body)))
  where
    go : RCExp -> List ConstKey
    go (RAppName _ _ n args) =
        mapMaybe (\(q, a) => if a == value && not (n == callee && q == argPos) then Just (n, q, value) else Nothing)
                 (zip [0 .. length args] args)
    go e = foldSubExprs (++) [] go e

||| What attempting one key produced: `Left bucket` when the gate
||| refused it (`gateFailBucket`, `7` for a missing parameter, `8` for a
||| callee that is not a plain function), `Right Nothing` when it
||| passed but the clone is worth nothing, else the built clone.
ConstTry : Type
ConstTry = Either Nat (Maybe ConstBuilt)

||| Clone `callee` with its `argPos` parameter dropped from the
||| signature and its id seeded to `value` for the fold. The body is
||| handed over unchanged -- `foldConstDefWith` does the substitution,
||| the `case` collapse and the `apply`-to-`call` rewrite in one go.
|||
||| The clone is kept (pending `acceptConst`) if it holds strictly fewer
||| `RApp` nodes than the original, or if it forwards the constant on
||| to other keys (`needs`). The latter is the transitive case: its
||| worth is only the clones it reaches.
tryConstKey : {auto fr : Ref FreshId Int}
           -> SortedMap Name RCDef -> CafTable -> ConstKey -> Core ConstTry
tryConstKey defOf caf key@(callee, argPos, value) =
    case lookup callee defOf of
         Just (MkRCFun args retRep False body) =>
             case getAt argPos args of
                  Nothing => pure (Left 7)
                  Just (paramVar, _) =>
                      case constParamUses (RCLoc paramVar) callee argPos body of
                           Nothing => pure (Left (gateFailBucket (RCLoc paramVar) callee argPos body))
                           Just _ => do
                               cloneId <- freshId
                               -- Same naming scheme as `buildClone` above, with
                               -- its own prefix so the two are told apart on sight
                               -- in a `dumprcexpr`/generated-`.c` read.
                               let cloneName = MN ("rc2_specConst_" ++ cName callee) cloneId
                               let args' = filter (\(i, _) => i /= paramVar) args
                               let folded = foldConstDefWith caf [(paramVar, value)] (MkRCFun args' retRep False body)
                               let own = defApps folded < countApps body
                               let needs = case folded of
                                                MkRCFun _ _ _ fb => constNeeds value callee argPos fb
                                                _ => []
                               pure $ Right $ if own || not (null needs)
                                                 then Just (MkConstBuilt key cloneName folded own needs)
                                                 else Nothing
         -- A worker (`isWorker`) can't exist yet at this point in
         -- the pipeline, and anything that isn't a plain function
         -- has no parameter to specialize.
         _ => pure (Left 8)

||| Everything the work list threads: keys already attempted, clones
||| built, and the counters for `--directive timing`.
record ConstState where
  constructor MkConstState
  seen : SortedSet ConstKey
  built : List ConstBuilt
  gatePassed : Nat
  buckets : List Nat
  transitive : Nat

||| The work list: every built clone's `needs` are queued, each key is
||| attempted at most once (memoised in `seen`, failures included), so
||| the chain is built transitively and the loop terminates. `initial`
||| is the set of keys that had a call site of their own, to count the
||| ones only reached by forwarding. Passed in, never a `where` binding
||| -- see the doc's "The `where`-clause trap".
buildConstAll : {auto fr : Ref FreshId Int}
             -> SortedMap Name RCDef -> CafTable -> SortedSet ConstKey
             -> ConstState -> List ConstKey -> Core ConstState
buildConstAll _ _ _ st [] = pure st
buildConstAll defOf caf initial st (k :: rest) =
    if contains k st.seen
       then buildConstAll defOf caf initial st rest
       else do
           r <- tryConstKey defOf caf k
           let seen' = insert k st.seen
           let trans' = if contains k initial then st.transitive else S st.transitive
           case r of
                Left b => buildConstAll defOf caf initial
                            ({ seen := seen', buckets $= bump b, transitive := trans' } st) rest
                Right Nothing => buildConstAll defOf caf initial
                                   ({ seen := seen', gatePassed $= S, transitive := trans' } st) rest
                Right (Just b) => buildConstAll defOf caf initial
                                    ({ seen := seen', gatePassed $= S, transitive := trans'
                                     , built $= (b ::) } st) (b.needs ++ rest)

||| The greatest subset of `bs` that is worth keeping and closed: a
||| clone stays if it is profitable on its own (`own` -- its forwarded
||| calls then simply stay calls to the generic callee with the
||| constant spelled out, which is correct), or if it is a pure
||| forwarder whose every need is itself accepted. The forwarders are
||| first cut down to the *useful* ones -- those that reach a
||| profitable clone, least fixpoint -- so a cycle of mutually
||| forwarding clones, none profitable, cannot justify itself.
acceptConst : SortedSet ConstKey -> List ConstBuilt -> List ConstBuilt
acceptConst done bs = closed (useful (filter (.own) bs) (filter (not . (.own)) bs))
  where
    keysOf : List ConstBuilt -> SortedSet ConstKey
    keysOf xs = fromList (map (.key) xs)

    useful : List ConstBuilt -> List ConstBuilt -> List ConstBuilt
    useful acc pending =
        let ks = keysOf acc
            (hit, miss) = partition (\b => any (\k => contains k ks) b.needs) pending
        in if null hit then acc else useful (hit ++ acc) miss

    closed : List ConstBuilt -> List ConstBuilt
    closed xs =
        let ks = keysOf xs
            xs' = filter (\b => b.own || all (\k => contains k ks || contains k done) b.needs) xs
        in if length xs' == length xs then xs else closed xs'

||| One accepted constant-constructor clone: redirect a call to
||| `callee` to `cloneName`, dropping argument `argPos`, whenever the
||| argument there is exactly `value`.
ConstRedirectEntry : Type
ConstRedirectEntry = (Nat, RCLocal, Name)

ConstRedirectTable : Type
ConstRedirectTable = SortedMap Name (List ConstRedirectEntry)

redirectConstCallSites : ConstRedirectTable -> RCExp -> RCExp
redirectConstCallSites table = go
  where
    tryEntries : FC -> Maybe LazyReason -> Name -> List RCLocal -> List ConstRedirectEntry -> RCExp
    tryEntries fc lazy n args [] = RAppName fc lazy n args
    tryEntries fc lazy n args ((argPos, value, cloneName) :: rest) =
        case splitAt argPos args of
             (before, a :: after) =>
                 if a == value
                    then RAppName fc lazy cloneName (before ++ after)
                    else tryEntries fc lazy n args rest
             _ => tryEntries fc lazy n args rest

    go : RCExp -> RCExp
    go (RAppName fc lazy n args) =
        case lookup n table of
             Nothing => RAppName fc lazy n args
             Just entries => tryEntries fc lazy n args entries
    go e = mapSubExprs go e

||| One round of constant-constructor argument specialization, run
||| straight after `applySpecClosure` within each round of
||| `applySpecRounds` (same `prevTable`/`done` threading). Structured exactly like it: group call sites by
||| `(callee, argPos, value)`, attempt one memoized clone per distinct
||| key, accumulate a redirect table, and apply it in a single
||| whole-program pass at the end.
applySpecConstCon : {auto c : Ref Ctxt Defs} -> {auto fr : Ref FreshId Int}
                  -> ConstRedirectTable -> SortedSet ConstKey -> List (Name, RCDef)
                  -> Core (List (Name, RCDef), ConstRedirectTable, SortedSet ConstKey, Nat)
applySpecConstCon prevTable done defs = do
    timingEnabled <- elem "timing" <$> getDirectives (Other "rc2")
    let keys = filter (\(k, _) => not (contains k done)) (SortedMap.toList byKey)
    when timingEnabled $
      coreLift $ putStrLn $ "TIMING rc2: SpecConstCon: " ++ show (length keys)
                             ++ " distinct keys, " ++ show (length defs) ++ " defs"
    let caf = rebuildCafTable defs
    -- Bound in the body, ONCE, and threaded into `buildConstAll` as a
    -- parameter -- deliberately NOT a `where` clause. A `where`
    -- definition is lambda-lifted into a function of whatever
    -- enclosing pattern variables it mentions, so a nullary-looking
    -- `defOf = SortedMap.fromList defs` there is really `defOf defs`,
    -- rebuilt from scratch at *every* use. The per-key lookup runs
    -- once per key, so writing it that way cost ~1600 rebuilds of a
    -- 38k-entry map: 103s of a 131s whole-`idris2-lsp` build, against
    -- 0.01s once hoisted. That single difference is what made this
    -- pass look unaffordable and get reverted the first time round.
    -- The same goes for `initial` below.
    let defOf : SortedMap Name RCDef := SortedMap.fromList defs
    let initial : SortedSet ConstKey := fromList (map fst keys)
    st <- buildConstAll defOf caf initial
            (MkConstState done [] 0 (replicate 9 0) 0) (map fst keys)
    let accepted = acceptConst done st.built
    let table = foldl (\t, b => let (callee, argPos, value) = b.key
                                in insertWith (++) callee [(argPos, value, b.name)] t)
                      prevTable accepted
    let done' = foldl (\s, b => insert b.key s) done accepted
    -- The two gates separately, because they fail for different
    -- reasons and only the breakdown says where the remaining yield
    -- is: the use gate (`constParamUses`) rejects a dictionary that is
    -- stored or escapes, while the profitability gate rejects a clone
    -- that folded the `case` away but left the dispatch somewhere the
    -- fold couldn't reach.
    when timingEnabled $ do
      coreLift $ putStrLn $ "TIMING rc2: SpecConstCon: " ++ show st.gatePassed
                             ++ " keys past the use gate, "
                             ++ show (length accepted) ++ " clones kept"
      coreLift $ putStrLn $ "TIMING rc2: SpecConstCon: " ++ show st.transitive
                             ++ " keys reached only by forwarding, "
                             ++ show (length st.built) ++ " clones built, "
                             ++ show (length accepted) ++ " accepted, "
                             ++ show (length (filter (not . (.own)) accepted)) ++ " pure forwarders accepted"
      coreLift $ putStrLn $ "TIMING rc2: SpecConstCon: gate-fail buckets [fwdOnly+scrut, fwdOnly-noscrut, fwdMixed, stored, otherEscape, noScrutNoUse, else, noParam, notPlainFun] = "
                             ++ show st.buckets
    pure (map (\(n, d) => (n, case d of
                                    MkRCFun a r w body => MkRCFun a r w (redirectConstCallSites table body)
                                    d' => d'))
               (map (\b => (b.name, b.def)) accepted ++ defs), table, done', length accepted)
  where
    addOpp : SortedMap ConstKey () -> ConstOpportunity -> SortedMap ConstKey ()
    addOpp acc opp = insert (opp.callee, opp.argPos, opp.value) () acc

    -- Only the distinct keys matter here (unlike the closure case,
    -- where one representative opportunity carries the captured-arg
    -- count), so this groups into a set rather than a list-valued map
    -- -- and, same trap as above, folds into it per definition instead
    -- of flattening every definition's own list together first.
    byKey : SortedMap ConstKey ()
    byKey = foldl (\acc, (_, d) => case d of
                        MkRCFun _ _ _ body => foldl addOpp acc (collectConstOpportunities body)
                        _ => acc)
                  (the (SortedMap ConstKey ()) empty) defs

    rebuildCafTable : List (Name, RCDef) -> CafTable
    rebuildCafTable = foldl (\tbl, (n, d) => maybe tbl (\v => insert n v tbl) (cafValueOf d)) empty

------------------------------------------------------------------------
-- Fixpoint driver
------------------------------------------------------------------------

||| Total `RCExp` nodes in `e`; only used for the `--directive timing`
||| per-round size line.
nodeCount : RCExp -> Nat
nodeCount e = S (foldSubExprs (+) 0 nodeCount e)

||| Everything the round loop threads from one round to the next: the
||| redirect tables and kept-key sets of both halves (so a clone kept in
||| an earlier round is neither rebuilt nor left unredirected at a call
||| site a later clone exposes), and the program itself.
record SpecState where
  constructor MkSpecState
  closureTable : RedirectTable
  closureDone : SortedSet SpecKey
  constTable : ConstRedirectTable
  constDone : SortedSet ConstKey
  prog : List (Name, RCDef)

||| Safety bound on the rounds below, not the expected path: a round
||| that keeps no new clone ends the loop. `idris2-lsp` keeps clones in
||| rounds 1-4 and none in round 5, so 8 leaves three rounds of margin
||| over the observed convergence; see the docs' "Iteration" sections.
specMaxRounds : Nat
specMaxRounds = 8

specLoop : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int} -> {auto fr : Ref FreshId Int}
        -> (closureOn : Bool) -> (constOn : Bool) -> (timing : Bool) -> (round : Nat) -> (fuel : Nat)
        -> SpecState -> Core (List (Name, RCDef))
specLoop _ _ _ _ Z st = pure st.prog
specLoop closureOn constOn timing round (S fuel) st = do
    r1 <- if closureOn then applySpecClosure st.closureTable st.closureDone st.prog
                                     else pure (st.prog, st.closureTable, st.closureDone, 0)
    let (p1, ct, cd, k1) = the (List (Name, RCDef), RedirectTable, SortedSet SpecKey, Nat) r1
    r2 <- if constOn then applySpecConstCon st.constTable st.constDone p1
                                   else pure (p1, st.constTable, st.constDone, 0)
    let (p2, kt, kd, k2) = the (List (Name, RCDef), ConstRedirectTable, SortedSet ConstKey, Nat) r2
    when timing $
      coreLift $ putStrLn $ "TIMING rc2: SpecRound " ++ show round ++ ": " ++ show k1 ++ " closure clones kept, "
                             ++ show k2 ++ " const-con clones kept, " ++ show (length p2) ++ " defs ("
                             ++ show (minus (length p2) (length st.prog)) ++ " new), "
                             ++ show (sum (map (\(_, d) => case d of
                                                             MkRCFun _ _ _ b => nodeCount b
                                                             _ => 0) p2)) ++ " nodes"
    if k1 + k2 == 0
       then pure p2
       else specLoop closureOn constOn timing (S round) fuel (MkSpecState ct cd kt kd p2)

||| Closure-argument then constant-constructor specialization, repeated
||| until a round keeps no new clone (at most `specMaxRounds` rounds),
||| since a kept clone's own body can expose a key for either half.
||| `FreshId` is bracketed once here, so clone names never repeat across
||| rounds. Each half is skipped when its flag is `False`
||| (`nospecclosure` / `nospecconstcon`).
export
applySpecRounds : {auto c : Ref Ctxt Defs} -> {auto v : Ref VarId Int}
               -> (closureOn : Bool) -> (constOn : Bool) -> List (Name, RCDef) -> Core (List (Name, RCDef))
applySpecRounds closureOn constOn defs = do
    _ <- newRef FreshId 0
    timing <- elem "timing" <$> getDirectives (Other "rc2")
    specLoop closureOn constOn timing 1 specMaxRounds (MkSpecState empty empty empty empty defs)
