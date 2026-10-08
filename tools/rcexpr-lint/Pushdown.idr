module Pushdown

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Push-down statistics over a parsed `.rcexpr` dump (`rcexpr-lint
-- --pushdown-stats`): how many `dup`/`drop` operations that rc2's passes
-- (`RC.annotate`, `Sink`, `DupMerge`, ...) could still have moved into the
-- `case` arms that need them, or cancelled. Read-only and purely
-- syntactic; the definition of every count, and its limits, are in
-- `tools/rcexpr-lint/README.md` ("Push-down statistics").
--
-- One walk per definition collects `Ev` events (one per pattern place,
-- tagged with whether it sits inside a `loop`); `renderPushdown` then
-- folds them into the table. A pattern check only looks along the
-- straight-line chain below its starting node (and, per candidate, at
-- each arm once), never at the whole definition, so the cost stays
-- close to a plain parse + walk.

import Language.RCExpr.AST

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.String

%default covering

-------------------------------------------------------------------------------
-- What a node itself mentions

maybeToList : Maybe a -> List a
maybeToList Nothing = []
maybeToList (Just x) = [x]

||| Does the arithmetic `op` named by the dump string consume its boxed operands
||| (`Emit.Util.isReuseConsumingOp`)? Its `postDrop` is then ignored by `Emit`:
||| a `dup` in front of it is a real reference handed over, not a read.
||| `Div` is consuming for `Int`/`Int64`/`Bits64` but not for `Integer`.
consumingOp : String -> Bool
consumingOp name = any test [("Integer", False), ("Int64", True), ("Int", True), ("Bits64", True)]
  where
    test : (String, Bool) -> Bool
    test (ty, divToo) =
        isSuffixOf ty name
          && (let hd = strSubstr 0 (cast (length name) - cast (length ty)) name
              in elem hd ["+", "-", "*", "%", "and ", "or ", "xor ", "shl ", "shr ", "neg "] || (divToo && hd == "/"))

||| The locals one node names directly, by role. Sub-expressions are not
||| included. An operand that also appears in the node's own `postDrop`
||| list (`op`, `callRep`, FFI) is a read, not a consumption: the
||| `postDrop` entry is the node's way of releasing it.
record Own where
  constructor MkOwn
  consumes, reads, drops, dups : List RCLocal

noOwn : Own
noOwn = MkOwn [] [] [] []

splitPost : List RCLocal -> List RCLocal -> (List RCLocal, List RCLocal)
splitPost pd as = (filter (\a => not (elem a pd)) as, filter (\a => elem a pd) as)

own : RCExp -> Own
own (RV l) = { consumes := [l] } noOwn
own (RCall _ _ as) = { consumes := as } noOwn
own (RCallRep _ _ pd as) = let (c, r) = splitPost pd as in MkOwn c r pd []
own (RCallFFI _ pd as) = let (c, r) = splitPost pd as in MkOwn c r pd []
own (RPartial _ _ as) = { consumes := as } noOwn
own (RApply _ f as) = { consumes := f :: as } noOwn
own (RLetIn _ _ _ _) = noOwn
own (RConstruct _ _ as r) = { consumes := as ++ maybeToList r } noOwn
own (RRetPackNode _ _ as) = { consumes := as } noOwn
own (ROpNode _ o as pd) = if consumingOp o then { consumes := as } noOwn else MkOwn [] as pd []
own (RExtPrimNode _ _ as pd) = MkOwn [] as pd []
own (RStructGetNode s _ pd) = MkOwn [] [s] pd []
own (RStructSetNode s _ v pd) = MkOwn [] [s, v] pd []
own (RFillNode c _ v pd) = MkOwn [v] [c] pd []
own (RCmp _ as pd _ _) = MkOwn [] as pd []
own (RConCaseNode s _ _) = { reads := [s] } noOwn
own (RConstCaseNode s _ _) = { reads := [s] } noOwn
own (RPrim _) = noOwn
own RErasedNode = noOwn
own (RCrashNode _) = noOwn
own (RDupNode v _ _) = { dups := [v] } noOwn
own (RDropNode vs _) = { drops := vs } noOwn
own (RFreeNode v _) = { drops := [v] } noOwn
own (RReleaseReuseNode v _) = { consumes := [v] } noOwn
own (RReuseOfferNode sc dos dru _) = MkOwn (sc :: dos) [] dru []
own (RLoopNode _ ini pd _) = MkOwn ini [] pd []
own (RLoopContinueNode as pd) = MkOwn as [] pd []
own (RMemoizeNode _ _ _) = noOwn
own (RDelayNode _ _ cs) = { consumes := cs } noOwn
own (RForceNode _ v pd) = MkOwn [] [v] pd []

count : RCLocal -> List RCLocal -> Nat
count l xs = length (filter (== l) xs)

mentionsOwn : RCLocal -> Own -> Bool
mentionsOwn l o = elem l o.consumes || elem l o.reads || elem l o.drops || elem l o.dups

||| The bodies of a branching node (every arm; the default last).
arms : RCExp -> Maybe (List RCExp)
arms (RCmp _ _ _ t f) = Just [t, f]
arms (RConCaseNode _ alts d) = Just (map (\a => a.altBody) alts ++ maybeToList d)
arms (RConstCaseNode _ alts d) = Just (map (\a => a.altBody) alts ++ maybeToList d)
arms _ = Nothing

||| The single continuation of a non-branching, non-`let` node.
single : RCExp -> Maybe RCExp
single (RDupNode _ _ b) = Just b
single (RDropNode _ b) = Just b
single (RFreeNode _ b) = Just b
single (RReleaseReuseNode _ b) = Just b
single (RReuseOfferNode _ _ _ b) = Just b
single (RLoopNode _ _ _ b) = Just b
single (RMemoizeNode _ _ b) = Just b
single _ = Nothing

kids : RCExp -> List RCExp
kids (RLetIn _ _ v b) = [v, b]
kids e = case arms e of
              Just as => as
              Nothing => maybeToList (single e)

mentions : RCLocal -> RCExp -> Bool
mentions l e = mentionsOwn l (own e) || any (mentions l) (kids e)

anyNode : (RCExp -> Bool) -> RCExp -> Bool
anyNode p e = p e || any (anyNode p) (kids e)

-------------------------------------------------------------------------------
-- What a whole arm does to one local

big : Nat
big = 1000000

||| Over every path of an expression: is the local consumed, or merely
||| read (a `dup` counts as a read); and the least number of times it is
||| dropped along any path (`big` when every path ends in a `crash`).
record Info where
  constructor MkInfo
  consumed, read : Bool
  drops : Nat

seqI : Info -> Info -> Info
seqI a b = MkInfo (a.consumed || b.consumed) (a.read || b.read)
                  (if a.drops >= big || b.drops >= big then big else a.drops + b.drops)

altI : Info -> Info -> Info
altI a b = MkInfo (a.consumed || b.consumed) (a.read || b.read) (min a.drops b.drops)

info : RCLocal -> RCExp -> Info
info l e =
    let o = own e
        here = MkInfo (elem l o.consumes) (elem l o.reads || elem l o.dups) (count l o.drops)
    in case e of
            RCrashNode _ => MkInfo False False big
            RLetIn _ _ val body => seqI here (seqI (info l val) (info l body))
            _ => case arms e of
                      Just (a :: as) => seqI here (foldl (\acc, x => altI acc (info l x)) (info l a) as)
                      Just [] => here
                      Nothing => case single e of
                                      Just b => seqI here (info l b)
                                      Nothing => here

-------------------------------------------------------------------------------
-- Events

||| One pattern place found in a definition.
record Ev where
  constructor MkEv
  key : String
  defn : String
  loop : Bool
  ||| operations removed (or, for the census kinds, taking part)
  ops : Integer
  ||| a second kind-specific figure, see the README table
  extra : Integer
  snippet : Lazy (List String)

record Ctx where
  constructor MkCtx
  defName : String
  inLoop : Bool
  fields : SortedSet Int

-------------------------------------------------------------------------------
-- Compact rendering, for the sample snippets

showLs : List RCLocal -> String
showLs ls = "[" ++ joinBy ", " (map show ls) ++ "]"

brief : RCExp -> String
brief (RV l) = show l
brief (RCall _ n as) = "call " ++ n ++ " " ++ showLs as
brief (RCallRep n _ pd as) = "callRep " ++ n ++ " " ++ showLs as ++ " postDrop=" ++ showLs pd
brief (RCallFFI _ pd as) = "callFFI " ++ showLs as ++ " postDrop=" ++ showLs pd
brief (RPartial n _ as) = "partial " ++ n ++ " " ++ showLs as
brief (RApply _ f as) = "apply " ++ show f ++ " " ++ showLs as
brief (RLetIn v _ _ _) = "let v" ++ show v
brief (RConstruct n _ as r) = "con " ++ n ++ " " ++ showLs as ++ maybe "" (\x => " reuse=" ++ show x) r
brief (RRetPackNode n _ as) = "retpack " ++ n ++ " " ++ showLs as
brief (ROpNode _ o as pd) = "op " ++ o ++ " " ++ showLs as ++ " postDrop=" ++ showLs pd
brief (RExtPrimNode _ o as pd) = "extprim " ++ o ++ " " ++ showLs as ++ " postDrop=" ++ showLs pd
brief (RStructGetNode s f pd) = "structGet " ++ show s ++ " " ++ f ++ " postDrop=" ++ showLs pd
brief (RStructSetNode s f v pd) = "structSet " ++ show s ++ " " ++ f ++ " " ++ show v ++ " postDrop=" ++ showLs pd
brief (RFillNode c f v pd) = "fill " ++ show c ++ " " ++ f ++ " " ++ show v ++ " postDrop=" ++ showLs pd
brief (RCmp o as pd _ _) = "cmp " ++ o ++ " " ++ showLs as ++ " postDrop=" ++ showLs pd ++ " ..."
brief (RConCaseNode s _ _) = "case " ++ show s ++ " ..."
brief (RConstCaseNode s _ _) = "case " ++ show s ++ " (const) ..."
brief (RPrim c) = "prim " ++ c
brief RErasedNode = "[__]"
brief (RCrashNode _) = "crash"
brief (RDupNode v n _) = "dup " ++ show v ++ (if n == 1 then "" else " x" ++ show n)
brief (RDropNode vs _) = "drop " ++ showLs vs
brief (RFreeNode v _) = "free " ++ show v
brief (RReleaseReuseNode v _) = "releaseReuse " ++ show v
brief (RReuseOfferNode sc dos dru _) = "reuseOffer " ++ show sc ++ " dupOnShared=" ++ showLs dos ++ " dropOnUnique=" ++ showLs dru
brief (RLoopNode _ ini _ _) = "loop initial=" ++ showLs ini
brief (RLoopContinueNode as pd) = "continue " ++ showLs as ++ " postDrop=" ++ showLs pd
brief (RMemoizeNode n _ _) = "memoize " ++ n
brief (RDelayNode _ t cs) = "delay " ++ t ++ " " ++ showLs cs
brief (RForceNode _ v pd) = "force " ++ show v ++ " postDrop=" ++ showLs pd

||| The first `fuel` nodes of the straight-line chain, a `let`'s value
||| indented under it.
heads : Nat -> RCExp -> List String
heads Z _ = ["..."]
heads (S k) e@(RLetIn v _ val b) =
    ("let v" ++ show v ++ " =") :: map ("  " ++) (heads (min 3 k) val) ++ heads k b
heads (S k) e = case single e of
                     Just b => brief e :: heads k b
                     Nothing => [brief e]

-------------------------------------------------------------------------------
-- (A) a dup above a case, cancelled by a drop in some arms

||| The `case`/`cmp` reached from `e` along its straight-line chain
||| without the local being mentioned on the way, and whether some drop
||| of another local happened on the way. `allowScrut`: the local may be
||| the case's own scrutinee / compared operand.
chainToCase : RCLocal -> Bool -> Bool -> RCExp -> Maybe (RCExp, Bool)
chainToCase l allowScrut dropped e = case e of
    RConCaseNode s _ _ => if allowScrut || s /= l then Just (e, dropped) else Nothing
    RConstCaseNode s _ _ => if allowScrut || s /= l then Just (e, dropped) else Nothing
    RCmp _ as pd _ _ => if elem l pd || (not allowScrut && elem l as) then Nothing else Just (e, dropped)
    RLetIn _ _ v b => if mentions l v then Nothing
                      else chainToCase l allowScrut (dropped || anyNode (\n => not (null (own n).drops)) v) b
    RLoopNode _ _ _ _ => Nothing
    _ => case single e of
              Just b => if mentionsOwn l (own e) then Nothing
                        else chainToCase l allowScrut (dropped || not (null (own e).drops)) b
              Nothing => Nothing

data ArmA = NeutralA | CancelA Nat | NeedA

||| `fld`: the local is a `case` field that owns nothing of its own
||| (so a read after the parent is dropped would be unsafe, and an arm
||| that merely reads it is not "unused").
classA : Bool -> Nat -> Info -> ArmA
classA fld n i =
    if i.drops >= big && not i.consumed && not i.read then NeutralA
    else if not i.consumed && (not fld || not i.read) && i.drops >= 1 then CancelA (min n i.drops)
    else NeedA

||| The arms of a branching node, with the fields each one binds.
armsWithArgs : RCExp -> List (RCExp, List Int)
armsWithArgs (RConCaseNode _ alts d) =
    map (\(MkRConAlt _ _ _ as b) => (b, as)) alts ++ map (\b => (b, [])) (maybeToList d)
armsWithArgs e = map (\b => (b, [])) (fromMaybe [] (arms e))

||| For a `dup l` that is cancelled in an arm of the `case` on `l` itself:
||| the arm must not read one of the alt's fields (which borrow from `l`)
||| after it dropped `l`, unless that field was `dup`'d first -- then the
||| extra reference is what keeps the field alive and the dup is needed.
fieldsSafe : RCLocal -> List Int -> RCExp -> Bool
fieldsSafe l args e = go [] e
  where
    headDups : RCExp -> List Int
    headDups (RDupNode (RVar w) _ b) = w :: headDups b
    headDups (RDupNode _ _ b) = headDups b
    headDups (RDropNode _ b) = headDups b
    headDups _ = []

    unprotected : List Int -> RCExp -> Bool
    unprotected prot rest = any (\f => not (elem f prot) && mentions (RVar f) rest) args

    go : List Int -> RCExp -> Bool
    go prot (RDropNode vs b) = if elem l vs then not (unprotected prot b) else go prot b
    go prot (RDupNode (RVar w) _ b) = go (w :: prot) b
    go prot (RLetIn _ _ val b) = go (headDups val ++ prot) b
    go prot x = case single x of
                     Just b => if elem l (own x).drops then not (unprotected prot b) else go prot b
                     Nothing => True

||| The first nodes of each arm of the case a pattern-A dup reaches, for the
||| sample listing (so a reader sees which arms keep and which cancel).
armSnips : List (RCExp, List Int) -> List String
armSnips arms = concat (zipWith (\i, (b, as) => ("  arm " ++ show i ++ " fields=" ++ show as) :: map ("    " ++) (heads 4 b)) (the (List Nat) [0 .. 99]) arms)

||| Is the rest of the chain only `dup`/`drop` nodes up to a `case`? Then the
||| whole run can move into the arms with nothing in between that could
||| observe or consume (a `let` value, a `cmp` with a `postDrop`).
adjacentRun : RCExp -> Bool
adjacentRun (RDupNode _ _ b) = adjacentRun b
adjacentRun (RDropNode _ b) = adjacentRun b
adjacentRun (RConCaseNode _ _ _) = True
adjacentRun (RConstCaseNode _ _ _) = True
adjacentRun _ = False

ruleA : Ctx -> RCExp -> List Ev -> List Ev
ruleA c e@(RDupNode (RVar v) n body) acc =
    let l = RVar v
    in case chainToCase l True False body of
            Nothing => acc
            Just (cs, dropped) =>
              let fld = contains v c.fields
                  nN = integerToNat (cast n)
                  onSelf = case cs of
                                RConCaseNode s _ _ => s == l
                                _ => False
                  classify : (RCExp, List Int) -> ArmA
                  classify (b, as) = case classA fld nN (info l b) of
                                          CancelA m => if fld && onSelf && not (fieldsSafe l as b) then NeedA else CancelA m
                                          k => k
                  classes = map classify (armsWithArgs cs)
                  cancels = mapMaybe (\k => case k of
                                                 CancelA m => Just m
                                                 _ => Nothing) classes
                  needs = length (filter (\k => case k of
                                                     NeedA => True
                                                     _ => False) classes)
                  sumC = the Integer (cast (sum cancels))
                  net = cast nN - cast nN * cast needs + sumC
              in if null cancels then acc
                 else MkEv ((if needs == 0 then "A/needed by no arm" else "A/needed by some arm")
                              ++ (if fld && dropped then ", field: a drop sits between" else "")
                              ++ (if adjacentRun body then ", adjacent run" else ", past a let or cmp"))
                           c.defName c.inLoop net
                           (cast (length cancels)) (heads 6 e ++ armSnips (armsWithArgs cs)) :: acc
ruleA _ _ acc = acc

-------------------------------------------------------------------------------
-- (B) dup ... drop of the same local, straight line

||| `Stop dn pd`: the chain ends; `Cont dn pd nrem passed`: it fell
||| through (only meaningful inside a `let` value, to go on with the
||| body). `dn` counts pairs closed by a `drop` node, `pd` the ones
||| closed by a `postDrop` list riding on another node (one label per
||| pair, the kind of that node).
data St = Stop Nat (List String) | Cont Nat (List String) Nat Bool

||| Walk the straight-line chain after `dup l xN`, counting the entries
||| of `l` dropped without anything in between consuming `l`. Plain
||| reads (`op`, `cmp` operands, ...) do not need the extra reference and
||| are passed. For a case field (`fld`), a read after another drop has
||| passed is not (the parent may be gone).
nodeLabel : RCExp -> String
nodeLabel (ROpNode _ _ _ _) = "op"
nodeLabel (RExtPrimNode _ _ _ _) = "extprim"
nodeLabel (RCallRep _ _ _ _) = "callRep"
nodeLabel (RCallFFI _ _ _) = "FFI call"
nodeLabel (RLoopContinueNode _ _) = "continue"
nodeLabel _ = "other node"

scanB : RCLocal -> Bool -> Nat -> List String -> Nat -> Bool -> RCExp -> St
scanB l fld dn pd nrem passed e =
    if nrem == 0 then Stop dn pd else
    case e of
         RDupNode w _ b => if w == l then Stop dn pd else scanB l fld dn pd nrem passed b
         RDropNode vs b =>
             let k = count l vs
             in if k > 0 then (let t = min k nrem in scanB l fld (dn + t) pd (minus nrem t) passed b)
                else scanB l fld dn pd nrem True b
         RLetIn _ _ val b =>
             if not (mentions l val) then scanB l fld dn pd nrem passed b
             else case scanB l fld dn pd nrem passed val of
                       Cont d p n q => scanB l fld d p n q b
                       Stop d p => Stop d p
         RConCaseNode _ _ _ => Stop dn pd
         RConstCaseNode _ _ _ => Stop dn pd
         RCmp _ _ _ _ _ => Stop dn pd
         RLoopNode _ _ _ _ => Stop dn pd
         RMemoizeNode _ _ b => scanB l fld dn pd nrem passed b
         _ =>
           let o = own e
           in if elem l o.consumes then Stop dn pd
              else if (elem l o.reads || elem l o.dups) && fld && passed then Stop dn pd
              else
                let k = min (count l o.drops) nrem
                    p' = passed || not (null (filter (/= l) o.drops))
                in case single e of
                        Just b => scanB l fld dn (replicate k (nodeLabel e) ++ pd) (minus nrem k) p' b
                        Nothing => Cont dn (replicate k (nodeLabel e) ++ pd) (minus nrem k) p'

ruleB : Ctx -> RCExp -> List Ev -> List Ev
ruleB c e@(RDupNode (RVar v) n body) acc =
    let l = RVar v
        fld = contains v c.fields
        (dn, pd) = case scanB l fld 0 [] (integerToNat (cast n)) False body of
                        Stop d p => (d, p)
                        Cont d p _ _ => (d, p)
        mk : String -> Nat -> List Ev -> List Ev
        mk k f a = if f == 0 then a else MkEv k c.defName c.inLoop (2 * cast f) (cast f) (heads 7 e) :: a
        labels = foldl (\m, x => insertWith (+) x (the Nat 1) m) (the (SortedMap String Nat) empty) pd
    in foldl (\a, kv => mk ("B/closed by a postDrop on " ++ fst kv) (snd kv) a)
             (mk "B/closed by a drop node" dn acc) (SortedMap.toList labels)
ruleB _ _ acc = acc

-------------------------------------------------------------------------------
-- (C) a let that a case does not need on every arm

||| What a `let` value computes, by what `Sink.sinkEligible` accepts:
||| `con` (fresh), `op`, `call` (`call`/`callRep`) are eligible when the
||| `let` is immediately followed by the branch; the rest never are.
valKind : RCExp -> String
valKind e = case e of
    RDupNode _ _ b => valKind b
    RDropNode _ b => valKind b
    RFreeNode _ b => valKind b
    RReleaseReuseNode _ b => valKind b
    RConstruct _ _ _ Nothing => "con"
    RConstruct _ _ _ (Just _) => "con with reuse"
    _ => other e
  where
    other : RCExp -> String
    other (ROpNode False _ _ _) = "op"
    other (ROpNode True _ _ _) = "lazy op"
    other (RCall False _ _) = "call"
    other (RCall True _ _) = "lazy call"
    other (RCallRep _ _ _ _) = "call"
    other (RPartial _ _ _) = "partial"
    other (RDelayNode _ _ _) = "delay"
    other (RApply _ _ _) = "apply"
    other (RV _) = "alias"
    other (RPrim _) = "constant"
    other RErasedNode = "constant"
    other (RRetPackNode _ _ _) = "retpack"
    other (RFillNode _ _ _ _) = "fill"
    other (RCallFFI _ _ _) = "ffi"
    other (RExtPrimNode _ _ _ _) = "extprim"
    other (RStructGetNode _ _ _) = "structGet"
    other (RForceNode _ _ _) = "force"
    other (RLetIn _ _ _ _) = "nested let value"
    other (RConCaseNode _ _ _) = "branch value"
    other (RConstCaseNode _ _ _) = "branch value"
    other (RCmp _ _ _ _ _) = "branch value"
    other (RLoopNode _ _ _ _) = "loop value"
    other _ = "other"

data ArmC = NeutralC | UnusedC Nat | UsedC | OtherC

classC : Info -> ArmC
classC i =
    if i.drops >= big && not i.consumed && not i.read then NeutralC
    else if i.consumed || i.read then UsedC
    else if i.drops >= 1 then UnusedC i.drops
    else OtherC

leadDupN : RCExp -> Nat
leadDupN (RDupNode _ n b) = integerToNat (cast n) + leadDupN b
leadDupN (RDropNode _ b) = leadDupN b
leadDupN _ = 0

||| Operands the `let` value consumes without a leading `dup` protecting
||| them, any of which the branch itself mentions (`Sink.addOperandDrops`
||| gives up then).
blocked : RCExp -> RCExp -> Bool
blocked val cs = go [] val
  where
    go : List RCLocal -> RCExp -> Bool
    go dupd (RDupNode w _ b) = go (w :: dupd) b
    go dupd (RDropNode _ b) = go dupd b
    go dupd (RFreeNode _ b) = go dupd b
    go dupd (RReleaseReuseNode _ b) = go dupd b
    go dupd t = let o = own t
                in any (\x => not (elem x dupd) && mentions x cs) (o.consumes ++ o.reads)

||| The first thing on the straight-line chain that mentions `l` is a
||| `drop` node naming it: the `let` is dead (what remains is its drop).
firstMentionIsDrop : RCLocal -> RCExp -> Bool
firstMentionIsDrop l e = case e of
    RDropNode vs b => elem l vs || firstMentionIsDrop l b
    RLetIn _ _ v b => not (mentions l v) && firstMentionIsDrop l b
    RLoopNode _ _ _ _ => False
    _ => case single e of
              Just b => not (mentionsOwn l (own e)) && firstMentionIsDrop l b
              Nothing => False

ruleC : Ctx -> RCExp -> List Ev -> List Ev
ruleC c e@(RLetIn v Boxed val body) acc =
    let l = RVar v
    in case chainToCase l False False body of
            Nothing => if firstMentionIsDrop l body && not (elem (valKind val) ["constant", "fill"])
                          then (let kind = valKind val
                                    lead = if elem kind ["con", "partial", "delay", "alias", "constant", "retpack"] then leadDupN val else 0
                                in MkEv ("C0/" ++ kind) c.defName c.inLoop (cast (1 + lead)) 1 (heads 6 e) :: acc)
                          else acc
            Just (cs, _) =>
              let cls = map (classC . info l) (fromMaybe [] (arms cs))
                  unusedDrops = sum (mapMaybe (\k => case k of
                                                          UnusedC n => Just n
                                                          _ => Nothing) cls)
                  count' : (ArmC -> Bool) -> Nat
                  count' p = length (filter p cls)
                  nUnused = count' (\k => case k of
                                               UnusedC _ => True
                                               _ => False)
                  nUsed = count' (\k => case k of
                                             UsedC => True
                                             _ => False)
                  nOther = count' (\k => case k of
                                              OtherC => True
                                              _ => False)
                  kind = valKind val
                  pureKind = elem kind ["con", "partial", "delay", "alias", "constant", "retpack"]
                  lead = if pureKind then leadDupN val else 0
                  elig = if not (elem kind ["con", "op", "call"]) then "kind Sink never takes"
                         else if isNothing (arms body) then "eligible kind, a let that is not sunk sits in between"
                         else if blocked val cs then "eligible, adjacent, an operand is also used by the branch (Sink bails)"
                         else "eligible, adjacent, no visible obstacle"
                  mk : String -> Nat -> Ev
                  mk k removed = MkEv k c.defName c.inLoop (cast removed) (cast nUnused) (heads 6 e)
              in if nUsed == 0 && nOther == 0 && nUnused >= 1 then mk ("C1/" ++ kind) (unusedDrops + lead) :: acc
                 else if nUsed == 1 && nOther == 0 && nUnused >= 1 then mk ("C2/" ++ elig ++ ", " ++ kind) unusedDrops :: acc
                 else acc
ruleC _ _ acc = acc

-------------------------------------------------------------------------------
-- (D) field dups, then the parent dropped

||| Field dups (of the alt's own fields) found along the chain up to a
||| `drop` of the parent `p`, which must not be mentioned before it.
scanD : RCLocal -> SortedSet Int -> Nat -> RCExp -> Maybe Nat
scanD p fs acc e = case e of
    RDupNode (RVar w) n b =>
        if contains w fs then scanD p fs (acc + integerToNat (cast n)) b else scanD p fs acc b
    RDupNode w _ b => if w == p then Nothing else scanD p fs acc b
    RDropNode vs b => if elem p vs then (if acc > 0 then Just acc else Nothing) else scanD p fs acc b
    RLetIn _ _ val b => if mentions p val then Nothing else scanD p fs (acc + headFieldDups val) b
    RFreeNode w b => if w == p then Nothing else scanD p fs acc b
    RReleaseReuseNode w b => if w == p then Nothing else scanD p fs acc b
    RReuseOfferNode _ _ _ b => if mentionsOwn p (own e) then Nothing else scanD p fs acc b
    RMemoizeNode _ _ b => scanD p fs acc b
    _ => let o = own e
         in if acc > 0 && elem p o.drops && not (elem p o.consumes) && not (elem p o.reads) && isNothing (arms e)
               then Just acc else Nothing
  where
    headFieldDups : RCExp -> Nat
    headFieldDups (RDupNode (RVar w) n b) = (if contains w fs then integerToNat (cast n) else 0) + headFieldDups b
    headFieldDups (RDupNode _ _ b) = headFieldDups b
    headFieldDups (RDropNode _ b) = headFieldDups b
    headFieldDups _ = 0

||| `Just k`: the chain reaches a `reuseOffer` of `p` carrying `k` `dupOnShared` fields.
offerDups : RCLocal -> RCExp -> Maybe Nat
offerDups p e = case e of
    RReuseOfferNode sc dos _ b => if sc == p then Just (length dos) else offerDups p b
    RLetIn _ _ _ b => offerDups p b
    _ => single e >>= offerDups p

ruleD : Ctx -> RCExp -> List Ev -> List Ev
ruleD c (RConCaseNode p@(RVar _) alts _) acc = foldl alt acc alts
  where
    alt : List Ev -> RConAlt -> List Ev
    alt a (MkRConAlt cn _ _ args body) =
        let fs = SortedSet.fromList args
            hdr = ("case " ++ show p ++ " of " ++ cn ++ " " ++ show args ++ " ->") :: map ("  " ++) (heads 6 body)
        in if null args then a else
           case offerDups p body of
                Just k => MkEv "D0/parent reuseOffer'd (already unique-aware)" c.defName c.inLoop (cast k) 1 hdr :: a
                Nothing => case scanD p fs 0 body of
                                Nothing => a
                                Just k =>
                                  let fresh = anyNode (\n => case n of
                                                                  RConstruct _ _ _ Nothing => True
                                                                  _ => False) body
                                  in MkEv (if fresh then "D/arm builds a fresh con" else "D/arm builds no con")
                                          c.defName c.inLoop (cast k) 1 hdr :: a
ruleD _ _ acc = acc

-------------------------------------------------------------------------------
-- (E) census: drops at the start of an arm

leadDrops : RCExp -> Nat
leadDrops (RDropNode vs b) = length vs + leadDrops b
leadDrops _ = 0

ruleE : Ctx -> RCExp -> List Ev -> List Ev
ruleE c e acc = case arms e of
    Nothing => acc
    Just as => foldl (\a, arm => let n = leadDrops arm
                                 in if n == 0 then a else MkEv "E" c.defName c.inLoop (cast n) 0 [] :: a) acc as

-------------------------------------------------------------------------------
-- The walk

tally : Ctx -> RCExp -> List Ev -> List Ev
tally c e acc =
    let o = own e
        nd = case e of
                  RDupNode _ n _ => cast {to = Integer} n
                  _ => 0
        nr = case e of
                  RFreeNode _ _ => 0
                  _ => cast {to = Integer} (length o.drops)
        a1 = if nd > 0 then MkEv "T/dup" c.defName c.inLoop nd 0 [] :: acc else acc
    in if nr > 0 then MkEv "T/drop" c.defName c.inLoop nr 0 [] :: a1 else a1

go : Ctx -> List Ev -> RCExp -> List Ev
go c acc e =
    let acc1 = ruleE c e (ruleD c e (ruleC c e (ruleB c e (ruleA c e (tally c e acc)))))
    in case e of
            RLetIn _ _ v b => go c (go c acc1 v) b
            RLoopNode _ _ _ b => go ({ inLoop := True } c) acc1 b
            RConCaseNode _ alts d =>
                let acc2 = foldl (\a, (MkRConAlt _ _ _ args b) => go ({ fields $= union (SortedSet.fromList args) } c) a b) acc1 alts
                in maybe acc2 (go c acc2) d
            RConstCaseNode _ alts d =>
                let acc2 = foldl (\a, (MkRConstAlt _ b) => go c a b) acc1 alts
                in maybe acc2 (go c acc2) d
            RCmp _ _ _ t f => go c (go c acc1 t) f
            _ => maybe acc1 (go c acc1) (single e)

-------------------------------------------------------------------------------
-- Report

record Agg where
  constructor MkAgg
  places, placesLoop : Nat
  ops, opsLoop, extra : Integer

zeroAgg : Agg
zeroAgg = MkAgg 0 0 0 0 0

addAgg : Ev -> Agg -> Agg
addAgg ev a =
    MkAgg (S a.places) (if ev.loop then S a.placesLoop else a.placesLoop)
          (a.ops + ev.ops) (if ev.loop then a.opsLoop + ev.ops else a.opsLoop) (a.extra + ev.extra)

plus : Agg -> Agg -> Agg
plus a b = MkAgg (a.places + b.places) (a.placesLoop + b.placesLoop) (a.ops + b.ops) (a.opsLoop + b.opsLoop) (a.extra + b.extra)

groupOf : String -> String
groupOf k = fst (break (== '/') k)

pct : Integer -> Integer -> String
pct n t =
    if t == 0 then "n/a"
    else if n < 0 then "-" ++ pct (negate n) t
    else let m = (n * 1000) `div` t
         in show (m `div` 10) ++ "." ++ show (m `mod` 10) ++ "%"

groupInfo : List (String, String, String)
groupInfo =
    [ ("A", "(A) dup above a case, cancelled by a drop in some arm", "net static ops; cancelling arms")
    , ("B", "(B) dup ... drop of the same local, straight line", "ops = 2 x pairs; pairs")
    , ("C0", "(C0) let dead on a straight line: its first mention is its drop", "ops removable; 1")
    , ("C1", "(C1) let dropped on every arm of the case after it", "ops removable; arms")
    , ("C2", "(C2) let read by exactly one arm, dropped on the rest", "drops removable; unused arms")
    , ("D", "(D) field dup(s), then the parent dropped", "field dups; parent drops")
    , ("D0", "(D0) context: parent reuseOffer'd instead", "dupOnShared fields; arms")
    , ("E", "(E) census: drops at the start of an arm", "entries")
    ]

fmtRow : Integer -> Integer -> String -> Agg -> String -> String
fmtRow t tl label a ex =
    padRight 58 ' ' label ++ padLeft 8 ' ' (show a.places) ++ padLeft 8 ' ' (show a.placesLoop)
        ++ padLeft 9 ' ' (show a.ops) ++ padLeft 8 ' ' (pct a.ops t)
        ++ padLeft 9 ' ' (show a.opsLoop) ++ padLeft 8 ' ' (pct a.opsLoop tl)
        ++ padLeft 9 ' ' ex

evenly : Nat -> List a -> List a
evenly k xs =
    let n = length xs
    in if n <= k then xs
       else mapMaybe (\i => getAt (integerToNat (div (cast {to = Integer} (i * n)) (cast {to = Integer} k))) xs) [0 .. minus k 1]

topDefs : Nat -> List Ev -> List (String, Integer)
topDefs k evs =
    let m = foldl (\acc, ev => insertWith (+) ev.defn ev.ops acc) (the (SortedMap String Integer) empty) evs
    in take k (sortBy (\a, b => compare (snd b) (snd a)) (SortedMap.toList m))

groupRows : Integer -> Integer -> SortedMap String Agg -> (String, String, String) -> List String
groupRows t tl byKey (g, label, _) =
    let kvs = filter (\kv => groupOf (fst kv) == g) (SortedMap.toList byKey)
        tot = foldl (\a, kv => plus a (snd kv)) zeroAgg kvs
        sub = \kv => "      " ++ fmtRow t tl (strSubstr (cast (length g + 1)) (cast (length (fst kv))) (fst kv)) (snd kv) (show (snd kv).extra)
    in ("  " ++ fmtRow t tl label tot (show tot.extra))
         :: (if any (\kv => isInfixOf "/" (fst kv)) kvs then map sub kvs else [])

export
pushdownStats : RCProgram -> List String
pushdownStats prog =
    let evs = reverse (foldl walkDef [] prog)
        byKey = foldl (\m, ev => insert ev.key (addAgg ev (fromMaybe zeroAgg (lookup ev.key m))) m)
                      (the (SortedMap String Agg) empty) evs
        tdup = fromMaybe zeroAgg (lookup "T/dup" byKey)
        tdrop = fromMaybe zeroAgg (lookup "T/drop" byKey)
        t = tdup.ops + tdrop.ops
        tl = tdup.opsLoop + tdrop.opsLoop
        header = [ "pushdown statistics (static places in the final IR, not executions; see README \"Push-down statistics\"):"
                 , "  all dup/drop operations " ++ show t ++ " (dup " ++ show tdup.ops ++ ", drop-type " ++ show tdrop.ops
                       ++ "); inside loops " ++ show tl ++ " (" ++ pct tl t ++ ")"
                 , "  " ++ padRight 58 ' ' "kind" ++ padLeft 8 ' ' "places" ++ padLeft 8 ' ' "in loop" ++ padLeft 9 ' ' "ops"
                       ++ padLeft 8 ' ' "%all" ++ padLeft 9 ' ' "ops loop" ++ padLeft 8 ' ' "%loop" ++ padLeft 9 ' ' "extra"
                 ]
        keysOf = \g => filter (\kv => groupOf (fst kv) == g) (SortedMap.toList byKey)
        rows = concatMap (groupRows t tl byKey) groupInfo
        eAgg = foldl (\a, kv => plus a (snd kv)) zeroAgg (filter (\kv => groupOf (fst kv) == "E") (SortedMap.toList byKey))
        eLine = ["  (E) is " ++ pct eAgg.ops tdrop.ops ++ " of all " ++ show tdrop.ops ++ " drop-type entries ("
                    ++ pct eAgg.opsLoop tdrop.opsLoop ++ " of those inside loops)"]
        legend = ["  columns per kind (ops / extra): " ++ joinBy "; " (map (\(g, _, d) => g ++ ": " ++ d) groupInfo)]
        perGroup = \g => filter (\ev => groupOf ev.key == g) evs
        tops = concatMap (\(g, k) =>
                   let es = perGroup g
                   in if null es then [] else
                      ("  top " ++ show k ++ " definitions, " ++ g ++ " (ops):")
                        :: map (\(d, n) => "    " ++ padLeft 6 ' ' (show n) ++ "  " ++ d) (topDefs k es))
                 [("A", 8), ("B", 15), ("C0", 8), ("C1", 8), ("C2", 8), ("D", 8)]
        samples = concatMap (\(k, n) =>
                      let es = filter (\ev => not (null (force ev.snippet)) && (if isPrefixOf "A/" k then k == ev.key else isPrefixOf k ev.key)) evs
                      in if null es then [] else
                         ("  " ++ show n ++ " sample places, " ++ k ++ ":")
                           :: concatMap (\ev => ("    " ++ ev.defn ++ "  [" ++ ev.key ++ "]")
                                                  :: map ("      " ++) (force ev.snippet)) (evenly n es))
                    [ ("A/needed by no arm, adjacent run", 3), ("A/needed by some arm, adjacent run", 3), ("A/needed by no arm, past a let or cmp", 2), ("A/needed by some arm, past a let or cmp", 2)
                    , ("A/needed by no arm, field: a drop sits between, adjacent run", 6), ("A/needed by some arm, field: a drop sits between, adjacent run", 8)
                    , ("A/needed by some arm, field: a drop sits between, past a let or cmp", 3)
                    , ("B/closed by a postDrop on op", 2), ("B/closed by a postDrop on extprim", 1), ("B/closed by a postDrop on callRep", 2), ("B/closed by a drop node", 1)
                    , ("C0/alias", 3), ("C0/nested", 2), ("C0/other", 2), ("C1", 3), ("C2/eligible, adjacent, no visible", 4), ("C2/eligible, adjacent, an operand", 2), ("C2/eligible kind", 2), ("C2/kind Sink never takes", 2)
                    , ("D/", 3), ("D0", 1) ]
    in header ++ rows ++ eLine ++ legend ++ tops ++ samples
  where
    walkDef : List Ev -> (String, RCDef) -> List Ev
    walkDef acc (name, RCFun _ _ _ body) = go (MkCtx name False empty) acc body
    walkDef acc (name, RCErrorDef body) = go (MkCtx name False empty) acc body
    walkDef acc _ = acc
