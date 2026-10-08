module Borrow

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Borrow-inference opportunity statistics over a parsed `.rcexpr`
-- dump (`rcexpr-lint --borrow-stats`): which `Boxed` parameters could be
-- passed borrowed instead of owned, and what that would do to the
-- number of `dup`/`drop` operations. Definition, rules and the exact
-- counting are in `tools/rcexpr-lint/README.md` ("Borrow statistics").
--
-- The facts come from `Leak`'s walk (`leakEvents`): every reference
-- spent, with what spent it, and every `dup`. Per definition they are
-- reduced to a summary per parameter; the greatest fixpoint over the
-- call graph and the totals are then computed from the summaries alone,
-- never from the tree again.

import Language.RCExpr.AST
import Leak
import Lint
import Metrics

import Data.Bits
import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.String

%default covering

-------------------------------------------------------------------------------
-- Reasons

-- bit numbers, in priority order: the first set bit is the reported reason
reasonNames : List String
reasonNames =
    [ "stored (constructor/closure/lazy cell)"
    , "returned"
    , "reused (reuse token)"
    , "passed to an owned position"
    , "passed to apply/unknown/FFI"
    , "loop-carried"
    , "argument of a non-loop tail call"
    ]

bitStored, bitReturned, bitReused, bitOwned, bitApply, bitLoop, bitTail : Int
bitStored = 1
bitReturned = 2
bitReused = 4
bitOwned = 8
bitApply = 16
bitLoop = 32
bitTail = 64

||| What an event forbids, for the parameter it spends.
reasonOf : Consumer -> Int
reasonOf (ByStore _) = bitStored
reasonOf ByReturn = bitReturned
reasonOf ByReuse = bitReused
reasonOf (ByApply _) = bitApply
reasonOf (ByLoop True) = 0
reasonOf (ByLoop False) = bitLoop
reasonOf ByDrop = 0
reasonOf (ByAlias _) = 0
reasonOf (ByCall _ _ tail) = if tail then bitTail else 0

reasonBits : List Int
reasonBits = [bitStored, bitReturned, bitReused, bitOwned, bitApply, bitLoop, bitTail]

||| Index into `reasonNames` of the highest-priority reason in `r`.
firstReason : Int -> Maybe Nat
firstReason r = fst <$> find (\(_, b) => (r .&. b) /= 0) (zip [0 .. length reasonBits] reasonBits)

-------------------------------------------------------------------------------
-- Per-definition summaries

||| One `Boxed`, refcounted parameter.
record PInfo where
  constructor MkPInfo
  reasons : Int
  deps : List (String, Nat)
  drops, dropsLoop, dups, dupsLoop : Nat

emptyP : PInfo
emptyP = MkPInfo 0 [] 0 0 0 0

||| A call that passes a reference it owns to a program definition.
record Site where
  constructor MkSite
  callee : String
  pos : Nat
  ||| the caller still owns references to the argument after the call
  spare : Bool
  field : Bool
  loop : Bool
  tail : Bool
  ||| the caller's own parameter the argument comes from, if any
  argRoot : Maybe Int

record DInfo where
  constructor MkDInfo
  ||| index into the program's definitions, for the compact keys below
  ident : Int
  name : String
  paramVars : List (Nat, Int)
  params : SortedMap Int PInfo
  sites : List Site

rootOf : SortedMap Int Int -> Int -> Int
rootOf m v = go (the Nat 50) v
  where
    go : Nat -> Int -> Int
    go Z x = x
    go (S k) x = case lookup x m of
        Just y => if y == x then x else go k y
        Nothing => x

addReason : Int -> Int -> SortedMap Int PInfo -> SortedMap Int PInfo
addReason v r = mapAt v (\p => { reasons := p.reasons .|. r } p)
  where
    mapAt : Int -> (PInfo -> PInfo) -> SortedMap Int PInfo -> SortedMap Int PInfo
    mapAt k f m = case lookup k m of
        Just p => insert k (f p) m
        Nothing => m

summarize : (String, RCDef) -> Maybe DInfo
summarize (name, def@(RCFun args _ _ body)) =
    let exempt = leakExempt body
        eligible = mapMaybe (\(k, (v, r)) => case r of
                                                  Boxed => if contains v exempt then Nothing else Just (k, v)
                                                  _ => Nothing) (zip [0 .. length args] args)
        evs = leakEvents (name, def)
        aliases = foldl (\m, a => case a.kind of
                                       Spent (ByAlias w) _ _ _ => insert w a.var m
                                       _ => m) (the (SortedMap Int Int) empty) evs
        start = foldl (\m, (_, v) => insert v emptyP m) (the (SortedMap Int PInfo) empty) eligible
        (ps, sites) = foldl (step aliases) (start, []) evs
    in Just (MkDInfo 0 name eligible ps sites)
  where
    step : SortedMap Int Int -> (SortedMap Int PInfo, List Site) -> Anomaly -> (SortedMap Int PInfo, List Site)
    step al (ps, ss) a = case a.kind of
        Duped n inLoop =>
            let r = rootOf al a.var
            in case lookup r ps of
                    Just p => (insert r ({ dups $= (+ cast n), dupsLoop $= (+ (if inLoop then cast n else 0)) } p) ps, ss)
                    Nothing => (ps, ss)
        Spent how after isField inLoop =>
            let r = rootOf al a.var
                mp = lookup r ps
                ps1 = case how of
                           ByDrop => maybe ps (\p => insert r ({ drops $= S, dropsLoop $= (+ (if inLoop then 1 else 0)) } p) ps) mp
                           ByCall callee k False => maybe ps (\p => insert r ({ deps $= ((callee, k) ::) } p) ps) mp
                           _ => addReason r (reasonOf how) ps
                ss1 = case how of
                           ByCall callee k tail =>
                               MkSite callee k (after > 0) isField inLoop tail (if isJust mp then Just r else Nothing) :: ss
                           _ => ss
            in (ps1, ss1)
        _ => (ps, ss)
summarize _ = Nothing

-------------------------------------------------------------------------------
-- Names reached other than by a direct call

||| `Name` of every `#Name/n~closure` inside the text of a constant local.
closureNames : String -> List String
closureNames s = mapMaybe nameBefore (drop 1 (splitOn "#" s))
  where
    splitOn : String -> String -> List String
    splitOn sep str = map pack (go (unpack sep) [] [] (unpack str))
      where
        go : List Char -> List Char -> List (List Char) -> List Char -> List (List Char)
        go _ cur acc [] = reverse (reverse cur :: acc)
        go sepc cur acc cs@(c :: rest) =
            if isPrefixOf sepc cs
               then go sepc [] (reverse cur :: acc) (drop (length sepc) cs)
               else go sepc (c :: cur) acc rest

    nameBefore : String -> Maybe String
    nameBefore piece =
        let cs = unpack piece
        in case breakOnClosure cs [] of
                Nothing => Nothing
                Just before => Just (pack (dropTrailingCount before))
      where
        breakOnClosure : List Char -> List Char -> Maybe (List Char)
        breakOnClosure cs acc =
            if isPrefixOf (unpack "~closure") cs then Just (reverse acc)
            else case cs of
                      [] => Nothing
                      (c :: rest) => breakOnClosure rest (c :: acc)
        dropTrailingCount : List Char -> List Char
        dropTrailingCount cs =
            let r = reverse cs
                rest = dropWhile isDigit r
            in case rest of
                    ('/' :: more) => reverse more
                    _ => cs

localRefs : RCLocal -> SortedSet String -> SortedSet String
localRefs (ROpaqueCon s) acc = foldl (flip insert) acc (closureNames s)
localRefs _ acc = acc

localsRefs : List RCLocal -> SortedSet String -> SortedSet String
localsRefs ls acc = foldl (\a, l => localRefs l a) acc ls

indirect : SortedSet String -> RCExp -> SortedSet String
indirect acc (RV l) = localRefs l acc
indirect acc (RCall _ _ args) = localsRefs args acc
indirect acc (RCallRep _ _ _ args) = localsRefs args acc
indirect acc (RCallFFI _ _ args) = localsRefs args acc
indirect acc (RPartial n _ args) = localsRefs args (insert n acc)
indirect acc (RDelayNode _ thunk caps) = localsRefs caps (insert thunk acc)
indirect acc (RApply _ c args) = localsRefs (c :: args) acc
indirect acc (RLetIn _ _ value body) = indirect (indirect acc value) body
indirect acc (RConstruct _ _ args r) = localsRefs args (maybe acc (\l => localRefs l acc) r)
indirect acc (RRetPackNode _ _ fs) = localsRefs fs acc
indirect acc (ROpNode _ _ args _) = localsRefs args acc
indirect acc (RExtPrimNode _ _ args _) = localsRefs args acc
indirect acc (RForceNode _ _ _) = acc
indirect acc (RStructGetNode _ _ _) = acc
indirect acc (RStructSetNode _ _ v _) = localRefs v acc
indirect acc (RFillNode _ _ v _) = localRefs v acc
indirect acc (RCmp _ args _ t f) = indirect (indirect (localsRefs args acc) t) f
indirect acc (RConCaseNode _ alts mDef) =
    let acc' = foldl (\a, alt => indirect a alt.altBody) acc alts
    in maybe acc' (indirect acc') mDef
indirect acc (RConstCaseNode _ alts mDef) =
    let acc' = foldl (\a, alt => indirect a alt.altBody) acc alts
    in maybe acc' (indirect acc') mDef
indirect acc (RPrim _) = acc
indirect acc RErasedNode = acc
indirect acc (RCrashNode _) = acc
indirect acc (RDupNode _ _ body) = indirect acc body
indirect acc (RDropNode _ body) = indirect acc body
indirect acc (RFreeNode _ body) = indirect acc body
indirect acc (RReleaseReuseNode _ body) = indirect acc body
indirect acc (RReuseOfferNode _ _ _ body) = indirect acc body
indirect acc (RLoopNode _ initial _ body) = indirect (localsRefs initial acc) body
indirect acc (RLoopContinueNode args _) = localsRefs args acc
indirect acc (RMemoizeNode _ _ body) = indirect acc body

indirectDef : SortedSet String -> (String, RCDef) -> SortedSet String
indirectDef acc (_, RCFun _ _ _ body) = indirect acc body
indirectDef acc (_, RCErrorDef body) = indirect acc body
indirectDef acc _ = acc

-------------------------------------------------------------------------------
-- The fixpoint and the totals

||| Parameters that cannot be borrowed, starting from those with a
||| reason of their own and spreading to whoever passes them on to one
||| (greatest fixpoint: a cycle of calls that only pass parameters along
||| stays borrowable).
spread : SortedMap Int (List Int) -> SortedSet Int -> List Int -> SortedSet Int
spread _ bad [] = bad
spread rev bad (k :: rest) =
    let users = fromMaybe [] (lookup k rev)
        fresh = filter (\u => not (contains u bad)) users
    in spread rev (foldl (flip insert) bad fresh) (fresh ++ rest)

record Totals where
  constructor MkTotals
  calleeDrops, calleeDropsLoop, calleeDups, calleeDupsLoop : Nat
  callerDups, callerDupsLoop, fieldDups, fieldDupsLoop, addedDrops, addedDropsLoop, addedTail : Nat

zeroTotals : Totals
zeroTotals = MkTotals 0 0 0 0 0 0 0 0 0 0 0

addT : Totals -> Totals -> Totals
addT a b = MkTotals (a.calleeDrops + b.calleeDrops) (a.calleeDropsLoop + b.calleeDropsLoop)
                    (a.calleeDups + b.calleeDups) (a.calleeDupsLoop + b.calleeDupsLoop)
                    (a.callerDups + b.callerDups) (a.callerDupsLoop + b.callerDupsLoop)
                    (a.fieldDups + b.fieldDups) (a.fieldDupsLoop + b.fieldDupsLoop)
                    (a.addedDrops + b.addedDrops) (a.addedDropsLoop + b.addedDropsLoop) (a.addedTail + b.addedTail)

net : Totals -> Int
net t = cast (t.calleeDrops + t.calleeDups + t.callerDups) - cast t.addedDrops

pct : Nat -> Nat -> String
pct n d = if d == 0 then "-" else
    let tenths = (cast n * 1000) `div` cast d
    in show (tenths `div` 10) ++ "." ++ show (tenths `mod` 10) ++ "%"

rowI : String -> Int -> String -> String
rowI label n detail = "  " ++ padRight 44 ' ' label ++ padLeft 9 ' ' (show n) ++ (if detail == "" then "" else "  " ++ detail)

row : String -> Nat -> String -> String
row label n detail = rowI label (cast n) detail

pctI : Int -> Nat -> String
pctI n d = if n < 0 then "-" ++ pct (cast (negate n)) d else pct (cast n) d

||| A parameter after dependencies are resolved: position, variable,
||| reasons of its own, dependencies on other definitions' parameters.
record RParam where
  constructor MkRParam
  pos : Nat
  reasons : Int
  deps : List Int

record RDef where
  constructor MkRDef
  info : DInfo
  rparams : List RParam

||| A definition's parameter, as one number (parameters per definition are far below 1024).
Key : Type
Key = Int

keyOf : Int -> Nat -> Key
keyOf ident pos = ident * 1024 + cast pos

||| The program's `fun` definitions, numbered in order.
definitionIds : RCProgram -> SortedMap String Int
definitionIds prog = fst (foldl add (empty, 0) prog)
  where
    add : (SortedMap String Int, Int) -> (String, RCDef) -> (SortedMap String Int, Int)
    add (m, n) (name, RCFun _ _ _ _) = (insert name n m, n + 1)
    add acc _ = acc

resolveParam : SortedMap String Int -> SortedSet Key -> DInfo -> (Nat, Int) -> RParam
resolveParam ids elig d (k, v) = case lookup v d.params of
    Nothing => MkRParam k 0 []
    Just p => foldl step (MkRParam k p.reasons []) p.deps
  where
    step : RParam -> (String, Nat) -> RParam
    step rp (callee, pos) = case lookup callee ids of
        Nothing => { reasons := rp.reasons .|. bitApply } rp
        Just i => let key = keyOf i pos
                  in if contains key elig then { deps $= (key ::) } rp else rp

resolveDef : SortedMap String Int -> SortedSet Key -> DInfo -> RDef
resolveDef ids elig d = MkRDef d (map (resolveParam ids elig d) d.paramVars)

eligibleKeys : List DInfo -> SortedSet Key
eligibleKeys = foldl (\s, d => foldl (\s', kv => insert (keyOf d.ident (fst kv)) s') s d.paramVars) empty

localBad : List RDef -> SortedSet Key
localBad = foldl (\s, rd => foldl (\s', rp => if rp.reasons /= 0 then insert (keyOf rd.info.ident rp.pos) s' else s') s rd.rparams) empty

reverseDeps : List RDef -> SortedMap Key (List Key)
reverseDeps = foldl addDef empty
  where
    addDep : Key -> SortedMap Key (List Key) -> Key -> SortedMap Key (List Key)
    addDep user m dep = insertWith (++) dep [user] m

    addDef : SortedMap Key (List Key) -> RDef -> SortedMap Key (List Key)
    addDef m rd = foldl (\m', rp => foldl (addDep (keyOf rd.info.ident rp.pos)) m' rp.deps) m rd.rparams

effects : SortedMap String Int -> (Key -> Bool) -> DInfo -> (String, Totals)
effects ids borrowable d =
    let own = foldl calleeSide zeroTotals d.paramVars
    in (d.name, foldl callerSide own d.sites)
  where
    calleeSide : Totals -> (Nat, Int) -> Totals
    calleeSide t (k, v) =
        if not (borrowable (keyOf d.ident k)) then t
        else case lookup v d.params of
                  Just p => { calleeDrops $= (+ p.drops), calleeDropsLoop $= (+ p.dropsLoop)
                            , calleeDups $= (+ p.dups), calleeDupsLoop $= (+ p.dupsLoop) } t
                  Nothing => t

    -- the caller's own parameter `v` is itself borrowed: passing it on
    -- costs nothing either way (its operations are already counted)
    borrowedHere : Int -> Bool
    borrowedHere v = any (\kv => snd kv == v && borrowable (keyOf d.ident (fst kv))) d.paramVars

    loopN : Bool -> Nat
    loopN b = if b then 1 else 0

    calleeBorrowable : Site -> Bool
    calleeBorrowable s = case lookup s.callee ids of
        Just i => borrowable (keyOf i s.pos)
        Nothing => False

    callerSide : Totals -> Site -> Totals
    callerSide t s =
        if not (calleeBorrowable s) || maybe False borrowedHere s.argRoot then t
        else if s.field then { fieldDups $= S, fieldDupsLoop $= (+ loopN s.loop) } t
        else if s.spare then { callerDups $= S, callerDupsLoop $= (+ loopN s.loop) } t
        else { addedDrops $= S, addedDropsLoop $= (+ loopN s.loop), addedTail $= (+ loopN s.tail) } t

popCountR : Int -> Nat
popCountR r = length (filter (\b => (r .&. b) /= 0) reasonBits)

histogram : List Int -> SortedMap Nat Nat
histogram = foldl (\m, r => insertWith (+) (fromMaybe 99 (firstReason r)) 1 m) empty

||| The report, one line per entry.
export
borrowStats : RCProgram -> List String
borrowStats prog =
    let ids = definitionIds prog
        infos = mapMaybe (\nd => map (\d => { ident := fromMaybe (-1) (lookup d.name ids) } d) (summarize nd)) prog
        indirectNames = foldl indirectDef (the (SortedSet String) empty) prog
        elig = eligibleKeys infos
        rdefs = map (resolveDef ids elig) infos
        initialBad = localBad rdefs
        bad = spread (reverseDeps rdefs) initialBad (SortedSet.toList initialBad)
    in render ids infos indirectNames elig bad rdefs
  where
    render : SortedMap String Int -> List DInfo -> SortedSet String -> SortedSet Key -> SortedSet Key -> List RDef -> List String
    render ids infos indirectNames elig bad rdefs =
        let borrowable : Key -> Bool
            borrowable key = contains key elig && not (contains key bad)
            totalParams = length (SortedSet.toList elig)
            okParams = minus totalParams (length (SortedSet.toList bad))
            rejected = foldr (\rd, acc => mapMaybe (rejectedReason rd) rd.rparams ++ acc) [] rdefs
            multiple = length (filter (\r => popCountR r > 1) rejected)
            hasBorrowable = \d => any (\kv => borrowable (keyOf d.ident (fst kv))) d.paramVars
            wrappers = length (filter (\d => contains d.name indirectNames && hasBorrowable d) infos)
            defsWithBorrow = length (filter hasBorrowable infos)
            perDef = map (effects ids borrowable) infos
            totals = foldl (\t, nt => addT t (snd nt)) zeroTotals perDef
            m = metricsOf prog
            totalOps = m.dupCount + m.dropCount + m.postDrops
            removed = totals.calleeDrops + totals.calleeDups + totals.callerDups
            netOps = the Int (cast removed) - cast totals.addedDrops
            removedLoop = totals.calleeDropsLoop + totals.calleeDupsLoop + totals.callerDupsLoop
        in [ "borrow statistics (places in the IR, not executions; evaluated on the final IR):"
           , row "definitions with Boxed refcounted parameters" (length (filter (\d => not (null d.paramVars)) infos)) ""
           , row "Boxed refcounted parameters" totalParams ""
           , row "  borrowable" okParams (pct okParams totalParams ++ " of parameters")
           , row "  definitions with at least one borrowable" defsWithBorrow ""
           , row "  of those, referenced indirectly (need an owned wrapper)" wrappers "closure/partial/lazy thunk/constant closure"
           , "  reasons a parameter is not borrowable (first matching; a parameter counts once):"
           ] ++ map histLine (SortedMap.toList (histogram rejected)) ++
           [ row "    more than one reason" multiple "(also counted above under its first reason)"
           , "  effect of borrowing every borrowable parameter (dup/drop operations):"
           , row "    callee drops removed" totals.calleeDrops ("in loops " ++ show totals.calleeDropsLoop)
           , row "    callee dups removed" totals.calleeDups ("in loops " ++ show totals.calleeDupsLoop)
           , row "    caller dups removed (argument still used later)" totals.callerDups ("in loops " ++ show totals.callerDupsLoop)
           , row "    caller drops added (the call was the last use)" totals.addedDrops ("in loops " ++ show totals.addedDropsLoop)
           , row "      of which tail calls (stop being tail calls)" totals.addedTail ""
           , rowI "    net operations removed" netOps
                 (pctI netOps totalOps ++ " of " ++ show totalOps ++ " dup/drop operations; in loops "
                    ++ show (cast {to = Int} removedLoop - cast totals.addedDropsLoop))
           , row "  not counted: dups of a case field passed borrowed" totals.fieldDups
                 ("in loops " ++ show totals.fieldDupsLoop ++ "; needs the parent kept alive until the call")
           , "  top 20 definitions by net operations removed (callee side for its parameters, caller side for its calls):"
           ] ++ top20 perDef
      where
        rejectedReason : RDef -> RParam -> Maybe Int
        rejectedReason rd rp =
            if not (contains (keyOf rd.info.ident rp.pos) bad) then Nothing
            else Just (if any (\dep => contains dep bad) rp.deps then rp.reasons .|. bitOwned else rp.reasons)

        histLine : (Nat, Nat) -> String
        histLine (i, n) = row ("    " ++ fromMaybe "?" (getAt i reasonNames)) n ""

        top20 : List (String, Totals) -> List String
        top20 perDef =
            let ranked = take 20 (sortBy (\a, b => compare (net (snd b)) (net (snd a))) (filter (\nt => net (snd nt) /= 0) perDef))
            in map (\nt => "    " ++ padLeft 6 ' ' (show (net (snd nt))) ++ "  " ++ fst nt) ranked

-------------------------------------------------------------------------------
-- Tail-blocked parameters: balance over all call sites

||| A call site with the caller's parameter and the callee's parameter it
||| connects (both as keys; the target only when it is a counted parameter).
record SiteRec where
  constructor MkSiteRec
  callerKey : Maybe Key
  target : Maybe Key
  site : Site

||| A parameter whose only blocker is being an argument of a non-loop tail call.
record Cand where
  constructor MkCand
  key : Key
  name : String
  pos : Nat
  info : PInfo

||| The components of one balance; the `L` fields are the in-loop shares.
record Parts where
  constructor MkParts
  cd, cu, kd, cr, ad, tl : Int
  cdL, cuL, kdL, crL, adL, tlL : Int

zeroP : Parts
zeroP = MkParts 0 0 0 0 0 0 0 0 0 0 0 0

addP : Parts -> Parts -> Parts
addP a b = MkParts (a.cd + b.cd) (a.cu + b.cu) (a.kd + b.kd) (a.cr + b.cr) (a.ad + b.ad) (a.tl + b.tl)
                   (a.cdL + b.cdL) (a.cuL + b.cuL) (a.kdL + b.kdL) (a.crL + b.crL) (a.adL + b.adL) (a.tlL + b.tlL)

-- model A: a tail site costs one added drop; model B: it costs nothing (owned entry)
netA, netB, netAL, netBL : Parts -> Int
netA p = p.cd + p.cu + p.kd + p.cr - p.ad - p.tl
netB p = p.cd + p.cu + p.kd + p.cr - p.ad
netAL p = p.cdL + p.cuL + p.kdL + p.crL - p.adL - p.tlL
netBL p = p.cdL + p.cuL + p.kdL + p.crL - p.adL

b2i : Bool -> Int
b2i b = if b then 1 else 0

||| The balance of lifting one candidate, given which parameters are
||| borrowed in the hypothetical world (`cur`) and which targets are
||| borrowable in the real one (`now`).
partsOf : (Key -> Bool) -> (Key -> Bool) -> SortedMap Key (List SiteRec) -> SortedMap Key (List SiteRec) -> Cand -> Parts
partsOf cur now inc out c =
    let own = { cd := cast c.info.drops, cdL := cast c.info.dropsLoop
              , cu := cast c.info.dups, cuL := cast c.info.dupsLoop } zeroP
        withIn = foldl incoming own (fromMaybe [] (lookup c.key inc))
    in foldl outgoing withIn (fromMaybe [] (lookup c.key out))
  where
    incoming : Parts -> SiteRec -> Parts
    incoming t r =
        let l = b2i r.site.loop
        in if maybe False cur r.callerKey then t
           else if r.site.field then t
           else if r.site.spare then { kd $= (+ 1), kdL $= (+ l) } t
           else if r.site.tail then { tl $= (+ 1), tlL $= (+ l) } t
           else { ad $= (+ 1), adL $= (+ l) } t

    -- what the real world books for this site today, which stops once the
    -- candidate is borrowed: a drop added (credit), or a dup removed (loss)
    outgoing : Parts -> SiteRec -> Parts
    outgoing t r = case r.target of
        Just k =>
            let l = b2i r.site.loop
            in if not (now k) || r.site.field then t
               else if r.site.spare then { cr $= (subtract 1), crL $= (subtract l) } t
               else { cr $= (+ 1), crL $= (+ l) } t
        Nothing => t

||| Every outgoing tail target is borrowable now or lifted too.
tailOk : (Key -> Bool) -> (Key -> Bool) -> SortedMap Key (List SiteRec) -> Cand -> Bool
tailOk cur now out c = all ok (fromMaybe [] (lookup c.key out))
  where
    ok : SiteRec -> Bool
    ok r = case r.target of
        Just k => not r.site.tail || now k || cur k
        Nothing => True

keepWhile : Nat -> (SortedSet Key -> Key -> Bool) -> List Cand -> SortedSet Key -> SortedSet Key
keepWhile Z _ _ s = s
keepWhile (S fuel) keep cands s =
    -- removals take effect immediately, so chains settle in few passes
    let s1 = foldl (\a, c => if contains c.key a && not (keep a c.key) then delete c.key a else a) s cands
    in if length (SortedSet.toList s1) == length (SortedSet.toList s) then s else keepWhile fuel keep cands s1

bucketOf : Int -> String
bucketOf n =
    if n <= -3 then "<= -3" else if n < 0 then show n else if n == 0 then "0"
    else if n <= 2 then show n else if n <= 5 then "3..5" else if n <= 10 then "6..10" else ">= 11"

bucketOrder : List String
bucketOrder = ["<= -3", "-2", "-1", "0", "1", "2", "3..5", "6..10", ">= 11"]

-- The helpers below take every large collection as an argument: a
-- `let`-bound collection used once inside a lambda would be rebuilt on
-- every call of that lambda.

indexBy : (SiteRec -> Maybe Key) -> SortedSet Key -> List SiteRec -> SortedMap Key (List SiteRec)
indexBy keyOfRec wanted = foldl add empty
  where
    add : SortedMap Key (List SiteRec) -> SiteRec -> SortedMap Key (List SiteRec)
    add m r = case keyOfRec r of
        Just k => if contains k wanted then insertWith (++) k [r] m else m
        Nothing => m

structKeep : (Key -> Bool) -> SortedMap Key (List SiteRec) -> SortedMap Key Cand -> SortedSet Key -> Key -> Bool
structKeep now out candMap s k = case lookup k candMap of
    Just c => tailOk (\x => contains x s) now out c
    Nothing => False

modelKeep : (Parts -> Int) -> (Key -> Bool) -> SortedMap Key (List SiteRec) -> SortedMap Key (List SiteRec)
         -> SortedMap Key Cand -> SortedSet Key -> Key -> Bool
modelKeep f now inc out candMap s k = case lookup k candMap of
    Just c => tailOk (\x => contains x s) now out c
              && f (partsOf (\x => now x || contains x s) now inc out c) > 0
    Nothing => False

finalPartsOf : (Key -> Bool) -> SortedMap Key (List SiteRec) -> SortedMap Key (List SiteRec) -> List Cand -> SortedSet Key -> List (Cand, Parts)
finalPartsOf now inc out cands s =
    map (\c => (c, partsOf (\x => now x || contains x s) now inc out c)) (filter (\c => contains c.key s) cands)

namesOf : List (Cand, Parts) -> SortedSet String
namesOf = foldl (\a, cp => insert (fst cp).name a) empty

overlapCount : SortedSet String -> SortedSet String -> Nat
overlapCount names existing = length (filter (\n => contains n existing) (SortedSet.toList names))

newWrapperCount : SortedSet String -> SortedSet String -> SortedSet String -> Nat
newWrapperCount names indirectNames existing =
    length (filter (\n => contains n indirectNames && not (contains n existing)) (SortedSet.toList names))

tailSitesOf : SortedMap Key (List SiteRec) -> List Cand -> List SiteRec
tailSitesOf out cands = filter (\r => r.site.tail) (concatMap (\c => fromMaybe [] (lookup c.key out)) cands)

classCountOf : (Key -> Bool) -> SortedSet Key -> List SiteRec -> Nat -> Nat
classCountOf now s sites i = length (filter (\r => classOf r == i) sites)
  where
    classOf : SiteRec -> Nat
    classOf r = case r.target of
        Nothing => 0
        Just k => if now k then 1 else if contains k s then 2 else 3

||| Definitions with a currently borrowable parameter that are also referenced indirectly.
wrapperSet : SortedSet String -> (Key -> Bool) -> List DInfo -> SortedSet String
wrapperSet indirectNames now = foldl add empty
  where
    add : SortedSet String -> DInfo -> SortedSet String
    add a d = if contains d.name indirectNames && any (\kv => now (keyOf d.ident (fst kv))) d.paramVars then insert d.name a else a

sumP : List (Cand, Parts) -> Parts
sumP = foldl (\a, cp => addP a (snd cp)) zeroP

hist : (Parts -> Int) -> List (Cand, Parts) -> List String
hist f cps =
    let hm = foldl (\mm, cp => insertWith (+) (bucketOf (f (snd cp))) (the Nat 1) mm) (the (SortedMap String Nat) empty) cps
    in map (\b => row ("    net " ++ b) (fromMaybe 0 (lookup b hm)) "") bucketOrder

top : (Parts -> Int) -> List (Cand, Parts) -> List String
top f cps =
    let ranked = take 15 (sortBy (\a, b => compare (f (snd b)) (f (snd a))) cps)
    in map (\cp => "    " ++ padLeft 6 ' ' (show (f (snd cp))) ++ "  " ++ (fst cp).name ++ " (parameter " ++ show (fst cp).pos ++ ")") ranked

positives : (Parts -> Int) -> List (Cand, Parts) -> Nat
positives f cps = length (filter (\cp => f (snd cp) > 0) cps)

sumNet : (Parts -> Int) -> List (Cand, Parts) -> Int
sumNet f cps = sum (map (f . snd) cps)

partsLines : String -> Parts -> List String
partsLines label p =
    [ "  " ++ label ++ " (components, ops / in loops):"
    , rowI "    callee drops removed" p.cd ("in loops " ++ show p.cdL)
    , rowI "    callee dups removed" p.cu ("in loops " ++ show p.cuL)
    , rowI "    caller dups removed (incoming sites)" p.kd ("in loops " ++ show p.kdL)
    , rowI "    credit: drops no longer added downstream" p.cr ("in loops " ++ show p.crL)
    , rowI "    caller drops added (non-tail incoming sites)" p.ad ("in loops " ++ show p.adL)
    , rowI "    incoming tail sites (A: +1 drop each; B: 0)" p.tl ("in loops " ++ show p.tlL)
    ]

mkRec : SortedMap String Int -> SortedSet Key -> DInfo -> Site -> SiteRec
mkRec ids elig d s =
    let ck = s.argRoot >>= \v => map (\kv => keyOf d.ident (fst kv)) (find (\kv => snd kv == v) d.paramVars)
        tk = lookup s.callee ids >>= \i => if contains (keyOf i s.pos) elig then Just (keyOf i s.pos) else Nothing
    in MkSiteRec ck tk s

||| (net, in-loop net) of `--borrow-stats` itself.
baseTotals : SortedMap String Int -> List DInfo -> (Key -> Bool) -> (Int, Int)
baseTotals ids infos borrowable =
    let t = foldl (\a, d => addT a (snd (effects ids borrowable d))) zeroTotals infos
        removed = t.calleeDrops + t.calleeDups + t.callerDups
        removedLoop = t.calleeDropsLoop + t.calleeDupsLoop + t.callerDupsLoop
    in (cast removed - cast t.addedDrops, cast removedLoop - cast t.addedDropsLoop)

||| `rcexpr-lint --borrow-tail-stats`: the parameters blocked only by being
||| an argument of a non-loop tail call, with their balance over all call sites.
export
borrowTailStats : RCProgram -> List String
borrowTailStats prog =
    let ids = definitionIds prog
        infos = mapMaybe (\nd => map (\d => { ident := fromMaybe (-1) (lookup d.name ids) } d) (summarize nd)) prog
        indirectNames = foldl indirectDef (the (SortedSet String) empty) prog
        elig = eligibleKeys infos
        rdefs = map (resolveDef ids elig) infos
        initialBad = localBad rdefs
        bad = spread (reverseDeps rdefs) initialBad (SortedSet.toList initialBad)
    in render ids infos indirectNames elig bad rdefs
  where
    render : SortedMap String Int -> List DInfo -> SortedSet String -> SortedSet Key -> SortedSet Key -> List RDef -> List String
    render ids infos indirectNames elig bad rdefs =
        let now = the (Key -> Bool) (\k => contains k elig && not (contains k bad))
            -- the reasons as `--borrow-stats` reports them
            reasonsOf = the (RDef -> RParam -> Int) (\rd, rp => if any (\dep => contains dep bad) rp.deps then rp.reasons .|. bitOwned else rp.reasons)
            blocked = foldr (\rd, acc => mapMaybe (\rp => if contains (keyOf rd.info.ident rp.pos) bad then Just (rd, rp) else Nothing) rd.rparams ++ acc) [] rdefs
            onlyTail = filter (\(rd, rp) => reasonsOf rd rp == bitTail) blocked
            mixedTail = filter (\(rd, rp) => let r = reasonsOf rd rp in (r .&. bitTail) /= 0 && r /= bitTail) blocked
            mkCand = the ((RDef, RParam) -> Maybe Cand) (\(rd, rp) => do
                (_, v) <- find (\kv => fst kv == rp.pos) rd.info.paramVars
                p <- lookup v rd.info.params
                pure (MkCand (keyOf rd.info.ident rp.pos) rd.info.name rp.pos p))
            cands = mapMaybe mkCand onlyTail
            s0 = foldl (\a, c => insert c.key a) (the (SortedSet Key) empty) cands
            siteRecs = concatMap (\d => map (mkRec ids elig d) d.sites) infos
            inc = indexBy (\r => r.target) s0 siteRecs
            out = indexBy (\r => r.callerKey) s0 siteRecs
            -- classes of the outgoing tail sites of the candidates
            tailSites = tailSitesOf out cands
            candMap = foldl (\mm, c => insert c.key c mm) (the (SortedMap Key Cand) empty) cands
            sStruct = keepWhile 200 (structKeep now out candMap) cands s0
            sA = keepWhile 200 (modelKeep netA now inc out candMap) cands sStruct
            sB = keepWhile 200 (modelKeep netB now inc out candMap) cands sStruct
            indep = finalPartsOf now inc out cands sStruct
            fa = finalPartsOf now inc out cands sA
            fb = finalPartsOf now inc out cands sB
            base = baseTotals ids infos now
            baseNet = fst base
            baseLoop = snd base
            m = metricsOf prog
            totalOps = m.dupCount + m.dropCount + m.postDrops
            existing = wrapperSet indirectNames now infos
            tailFnsB = namesOf (filter (\cp => (snd cp).tl > 0) fb)
            namesA = namesOf fa
            namesB = namesOf fb
            pa = sumP fa
            pb = sumP fb
        in [ "borrow tail statistics (places in the IR, not executions; evaluated on the final IR):"
           , row "blocked Boxed parameters" (length blocked) ""
           , row "  blocked ONLY by a non-loop tail-call argument" (length onlyTail) "(the histogram row of --borrow-stats)"
           , row "  blocked by it and by other reasons (stay excluded)" (length mixedTail) ""
           , "  outgoing tail sites of the only-tail set, by what they pass to:"
           , row "    a parameter that is borrowable now" (classCountOf now s0 tailSites 1) ""
           , row "    another only-tail parameter (chain)" (classCountOf now s0 tailSites 2) ""
           , row "    a parameter blocked by something else (owned)" (classCountOf now s0 tailSites 3) ""
           , row "    not a counted parameter" (classCountOf now s0 tailSites 0) ""
           , row "  only-tail parameters whose targets are all liftable" (length (SortedSet.toList sStruct)) "(structurally eligible; chains iterated)"
           , "  independent balance of the eligible ones (model A: tail site = +1 drop; model B: tail site free):"
           , row "    net-positive under A" (positives netA indep) ("sum of nets " ++ show (sumNet netA indep))
           , row "    net-positive under B" (positives netB indep) ("sum of nets " ++ show (sumNet netB indep))
           , "  joint result, keeping only net-positive ones until stable (chains re-checked):"
           , row "    model A: parameters lifted" (length fa) ""
           , rowI "    model A: net operations" (netA pa) ("in loops " ++ show (netAL pa))
           , row "    model B: parameters lifted" (length fb) ""
           , rowI "    model B: net operations" (netB pb) ("in loops " ++ show (netBL pb))
           , rowI "  current net (--borrow-stats)" baseNet (pctI baseNet totalOps ++ " of " ++ show totalOps ++ "; in loops " ++ show baseLoop)
           , rowI "  total with model A lifted" (baseNet + netA pa)
                 (pctI (baseNet + netA pa) totalOps ++ "; in loops " ++ show (baseLoop + netAL pa))
           , rowI "  total with model B lifted" (baseNet + netB pb)
                 (pctI (baseNet + netB pb) totalOps ++ "; in loops " ++ show (baseLoop + netBL pb))
           , "  model B owned entries:"
           , row "    functions with a tail site served by an owned entry" (length (SortedSet.toList tailFnsB)) ""
           , row "      of those already in the current wrapper set" (overlapCount tailFnsB existing)
                 ("current wrapper set " ++ show (length (SortedSet.toList existing)))
           , row "    lifted functions referenced indirectly, not yet wrapped" (newWrapperCount namesB indirectNames existing)
                 ("(A: " ++ show (newWrapperCount namesA indirectNames existing) ++ ")")
           ] ++ partsLines "model A" pa ++ partsLines "model B" pb ++
           [ "  histogram of the independent net per eligible parameter, model A:" ] ++ hist netA indep ++
           [ "  histogram, model B:" ] ++ hist netB indep ++
           [ "  top 15 lifted parameters, model A:" ] ++ top netA fa ++
           [ "  top 15 lifted parameters, model B:" ] ++ top netB fb
