module Lint

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Ownership-anomaly checker over `Language.RCExpr.AST`'s parsed
-- `.rcexpr` tree: flags a `Boxed` local read (or dropped) again after
-- its owned reference count already reached zero -- the exact bug
-- class `Compiler.RC2.Sink` had (three separate root causes, all
-- fixed in this session's own history), found there by hours of
-- manual dump-tracing. This module exists so that class of bug is
-- caught mechanically instead. Tool-specific logic (unlike
-- `Language.RCExpr.AST`/`Lexer`/`Parser`, which live in `rc2base`
-- itself as reusable library modules) -- lives alongside
-- `RcexprLint.idr`, not installed as a library.
--
-- Scope: one check only, a bounded, well-defined dataflow problem --
-- walks each `def`'s body maintaining a live-reference count per
-- `Boxed` local, starting from the def's own `args=[...]` (non-
-- `Boxed`/non-`RVar` locals are never tracked, they have no refcount
-- to drop). `dup`/`drop`/`free`/`releaseReuse`/every `postDrop=`
-- adjust a local's count; any other read of a `Boxed` local already
-- at zero is a use-after-free, any drop of one already at zero is a
-- double-drop. Branches (`cmp`/`case`) fork the count map into each
-- arm independently and never merge afterward -- correct for this
-- check's purpose, an anomaly inside one arm doesn't depend on what
-- the other arm did, and this round doesn't attempt the bigger
-- problem (full-path enumeration/merging) leak detection or cross-arm
-- consistency would need.
--
-- Known imprecision: a `case`-alt's own bound variables (`RConAlt`'s
-- `args : List Int`) have no `Rep` in this dump at all (`Pretty.idr`
-- never prints one for them -- `Compiler.RC2.RCExp.RConAlt` itself
-- doesn't carry one either, the field's real type lives only in the
-- constructor's own type information, which isn't part of this
-- grammar). Treated as `Boxed` with an initial count of 1 -- the
-- common case for a normalized RC tree -- rather than left untracked,
-- since rc2's own `Reuse`/annotation passes always insert an explicit
-- `dup`/`drop`/use for a genuinely boxed field; an occasional false
-- positive here (a field that's actually native) is easier to notice
-- and dismiss by hand than a silently-skipped real bug would be.

import Language.RCExpr.AST

import Data.List
import Data.SortedMap

%default covering

public export
data AnomalyKind = UseAfterFree | DoubleDrop

public export
Show AnomalyKind where
  show UseAfterFree = "use-after-free"
  show DoubleDrop = "double-drop"

public export
record Anomaly where
  constructor MkAnomaly
  defName : String
  kind    : AnomalyKind
  var     : Int
  context : String

public export
Show Anomaly where
  show a = a.defName ++ ": v" ++ show a.var ++ " " ++ show a.kind ++ " (" ++ a.context ++ ")"

||| Live-reference count per tracked (`Boxed`) local. A local absent
||| from this map is either never `Boxed` or out of scope -- never
||| checked either way (`checkRead`/`doDrop` both treat "absent" as
||| "not tracked", not as zero).
OwnState : Type
OwnState = SortedMap Int Nat

isBoxedRep : RRep -> Bool
isBoxedRep Boxed = True
isBoxedRep (NativeRep _) = False

checkRead : String -> String -> OwnState -> RCLocal -> List Anomaly
checkRead defName ctx st (RVar i) = case lookup i st of
    Just Z => [MkAnomaly defName UseAfterFree i ctx]
    _ => []
checkRead _ _ _ _ = []

checkReads : String -> String -> OwnState -> List RCLocal -> List Anomaly
checkReads defName ctx st = concatMap (checkRead defName ctx st)

doDrop : String -> String -> (OwnState, List Anomaly) -> RCLocal -> (OwnState, List Anomaly)
doDrop defName ctx (st, anomalies) (RVar i) = case lookup i st of
    Nothing => (st, anomalies)
    Just Z => (st, anomalies ++ [MkAnomaly defName DoubleDrop i ctx])
    Just (S n) => (insert i n st, anomalies)
doDrop _ _ acc _ = acc

doDrops : String -> String -> OwnState -> List RCLocal -> (OwnState, List Anomaly)
doDrops defName ctx st vars = foldl (doDrop defName ctx) (st, []) vars

||| `RDupNode`'s own `count` is already the *total* number of extra
||| references gained (`Pretty.idr`'s `dup v` -> 1, `dup v xN` -> N,
||| `Language.RCExpr.Parser.dupG`'s own reading of that) -- added
||| straight to the tracked count.
doDup : OwnState -> RCLocal -> Int -> OwnState
doDup st (RVar i) n = case lookup i st of
    Nothing => st
    Just c => insert i (c + integerToNat (cast n)) st
doDup st _ _ = st

mutual
  walk : String -> OwnState -> RCExp -> (OwnState, List Anomaly)
  walk dn st (RV loc) = (st, checkRead dn "RV" st loc)
  walk dn st (RCall _ _ args) = (st, checkReads dn "call" st args)
  walk dn st (RCallRep _ _ postDrop args) =
      let readAs = checkReads dn "callRep args" st args
          (st', dropAs) = doDrops dn "callRep postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RCallFFI _ postDrop args) =
      let readAs = checkReads dn "callFFIInline args" st args
          (st', dropAs) = doDrops dn "callFFIInline postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RPartial _ _ args) = (st, checkReads dn "partial" st args)
  walk dn st (RApply _ c args) =
      (st, checkRead dn "apply target" st c ++ checkReads dn "apply args" st args)
  walk dn st (RLetIn var rep value body) =
      let (stAfterValue, valueAs) = walk dn st value
          stWithVar = if isBoxedRep rep then insert var 1 stAfterValue else stAfterValue
          (stFinal, bodyAs) = walk dn stWithVar body
      in (stFinal, valueAs ++ bodyAs)
  walk dn st (RConstruct _ _ args reuseFrom) =
      (st, checkReads dn "con args" st args
             ++ maybe [] (checkRead dn "con reuse" st) reuseFrom)
  walk dn st (ROpNode _ _ args postDrop) =
      let readAs = checkReads dn "op args" st args
          (st', dropAs) = doDrops dn "op postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RExtPrimNode _ _ args postDrop) =
      let readAs = checkReads dn "extprim args" st args
          (st', dropAs) = doDrops dn "extprim postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RStructGetNode sv _ postDrop) =
      let readAs = checkRead dn "structGet" st sv
          (st', dropAs) = doDrops dn "structGet postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RStructSetNode sv _ value postDrop) =
      let readAs = checkRead dn "structSet target" st sv ++ checkRead dn "structSet value" st value
          (st', dropAs) = doDrops dn "structSet postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RCmp _ args postDrop whenTrue whenFalse) =
      let readAs = checkReads dn "cmp args" st args
          (stAfterDrop, dropAs) = doDrops dn "cmp postDrop" st postDrop
          (_, trueAs) = walk dn stAfterDrop whenTrue
          (_, falseAs) = walk dn stAfterDrop whenFalse
      in (stAfterDrop, readAs ++ dropAs ++ trueAs ++ falseAs)
  walk dn st (RConCaseNode sc alts mDef) =
      let readAs = checkRead dn "case scrutinee" st sc
          altsAs = concatMap (walkConAlt dn st) alts
          defAs = maybe [] (\b => snd (walk dn st b)) mDef
      in (st, readAs ++ altsAs ++ defAs)
  walk dn st (RConstCaseNode sc alts mDef) =
      let readAs = checkRead dn "case scrutinee" st sc
          altsAs = concatMap (\a => snd (walk dn st a.altBody)) alts
          defAs = maybe [] (\b => snd (walk dn st b)) mDef
      in (st, readAs ++ altsAs ++ defAs)
  walk dn st (RPrim _) = (st, [])
  walk dn st RErasedNode = (st, [])
  walk dn st (RCrashNode _) = (st, [])
  walk dn st (RDupNode var count body) =
      let st' = doDup st var count
      in walk dn st' body
  walk dn st (RDropNode vars body) =
      let (st', dropAs) = doDrops dn "drop" st vars
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, dropAs ++ bodyAs)
  walk dn st (RFreeNode var body) =
      let (st', dropAs) = doDrop dn "free" (st, []) var
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, dropAs ++ bodyAs)
  walk dn st (RReleaseReuseNode var body) =
      let (st', dropAs) = doDrop dn "releaseReuse" (st, []) var
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, dropAs ++ bodyAs)
  walk dn st (RReuseOfferNode sc dupOnShared dropOnUnique body) =
      let readAs = checkRead dn "reuseOffer scrutinee" st sc ++ checkReads dn "reuseOffer dupOnShared" st dupOnShared
          (st', dropAs) = doDrops dn "reuseOffer dropOnUnique" st dropOnUnique
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, readAs ++ dropAs ++ bodyAs)
  walk dn st (RLoopNode params initial prologueDrop body) =
      let readAs = checkReads dn "loop initial" st initial
          (stAfterDrop, dropAs) = doDrops dn "loop prologueDrop" st prologueDrop
          -- Loop params (fresh `Boxed`-or-not locals rebound each
          -- iteration) get the same treatment as a con-alt's own
          -- bound vars -- see this module's own top-of-file note.
          stWithParams = foldl (\s, (i, r) => if isBoxedRep r then insert i 1 s else s) stAfterDrop params
          (stFinal, bodyAs) = walk dn stWithParams body
      in (stFinal, readAs ++ dropAs ++ bodyAs)
  walk dn st (RLoopContinueNode args postDrop) =
      let readAs = checkReads dn "continue loop args" st args
          (st', dropAs) = doDrops dn "continue loop postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RMemoizeNode _ _ body) = walk dn st body

  walkConAlt : String -> OwnState -> RConAlt -> List Anomaly
  walkConAlt dn st alt =
      let stWithArgs = foldl (\s, i => insert i 1 s) st alt.args
      in snd (walk dn stWithArgs alt.altBody)

||| One `def`'s own anomalies, starting from its own `args=[...]`
||| (`Boxed` args get an initial live count of 1; a `RCErrorDef`/
||| `RCCon`/`RCForeign` has no `args` to seed from -- an error def's
||| own free variables are simply never tracked, `RCCon`/`RCForeign`
||| have no body to walk at all).
export
lintDef : String -> RCDef -> List Anomaly
lintDef name (RCFun args _ _ body) =
    let initial = foldl (\s, (i, r) => if isBoxedRep r then insert i 1 s else s) (the OwnState empty) args
    in snd (walk name initial body)
lintDef name (RCErrorDef body) = snd (walk name (the OwnState empty) body)
lintDef _ (RCCon _ _ _) = []
lintDef _ (RCForeign _) = []

||| Every anomaly across a whole parsed program, in `def` order.
export
lintProgram : RCProgram -> List Anomaly
lintProgram = concatMap (\(name, def) => lintDef name def)
