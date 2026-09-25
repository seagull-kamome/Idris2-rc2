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
-- grammar). Treated as `Boxed`, borrowing its scrutinee's reference
-- (`Entry`) -- the common case for a normalized RC tree -- rather than
-- left untracked; an occasional false positive here (a field that's
-- actually native, read after its scrutinee is dropped) is easier to
-- notice and dismiss by hand than a silently-skipped real bug would be.

import Language.RCExpr.AST

import Data.List
import Data.Maybe
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

||| One tracked (`Boxed`) local: the references it owns itself, and,
||| for a field bound by a `case` alt, the scrutinee it was taken from.
||| A field starts out owning nothing -- it borrows its scrutinee's own
||| reference, and stays readable only while that scrutinee (or,
||| transitively, *its* parent) is alive or it has been `dup`'d. This is
||| what rc2's own `annotate`/`Reuse` rely on: a field read after its
||| scrutinee is dropped needs a `dup` first.
record Entry where
  constructor MkEntry
  owned : Nat
  parent : Maybe Int

||| A local absent from this map is either never `Boxed` or out of
||| scope -- never checked either way (`checkRead`/`doDrop` both treat
||| "absent" as "not tracked", not as dead).
OwnState : Type
OwnState = SortedMap Int Entry

owning : Nat -> Entry
owning n = MkEntry n Nothing

||| Whether local `i` still has a reference to read through: its own, or
||| a live parent's. An untracked local always counts as alive.
alive : OwnState -> Int -> Bool
alive st i = case lookup i st of
    Nothing => True
    Just e => e.owned > 0 || maybe False (alive st) e.parent

isBoxedRep : RRep -> Bool
isBoxedRep Boxed = True
isBoxedRep (NativeRep _) = False

checkRead : String -> String -> OwnState -> RCLocal -> List Anomaly
checkRead defName ctx st (RVar i) =
    if alive st i then [] else [MkAnomaly defName UseAfterFree i ctx]
checkRead _ _ _ _ = []

checkReads : String -> String -> OwnState -> List RCLocal -> List Anomaly
checkReads defName ctx st = concatMap (checkRead defName ctx st)

||| A drop spends one of the local's own references. A field that owns
||| none cannot give one back even while its scrutinee is alive: that
||| would release a reference only the scrutinee holds.
doDrop : String -> String -> (OwnState, List Anomaly) -> RCLocal -> (OwnState, List Anomaly)
doDrop defName ctx (st, anomalies) (RVar i) = case lookup i st of
    Nothing => (st, anomalies)
    Just (MkEntry (S n) p) => (insert i (MkEntry n p) st, anomalies)
    Just (MkEntry Z _) => (st, anomalies ++ [MkAnomaly defName DoubleDrop i ctx])
doDrop _ _ acc _ = acc

doDrops : String -> String -> OwnState -> List RCLocal -> (OwnState, List Anomaly)
doDrops defName ctx st vars = foldl (doDrop defName ctx) (st, []) vars

||| `RDupNode`'s own `count` is already the *total* number of extra
||| references gained (`Pretty.idr`'s `dup v` -> 1, `dup v xN` -> N,
||| `Language.RCExpr.Parser.dupG`'s own reading of that). A dup reads
||| the local, so it has to be alive.
doDup : String -> OwnState -> RCLocal -> Int -> (OwnState, List Anomaly)
doDup defName st v@(RVar i) n = case lookup i st of
    Nothing => (st, [])
    Just e => ( insert i ({ owned $= (+ integerToNat (cast n)) } e) st
              , checkRead defName "dup" st v )
doDup _ st _ _ = (st, [])

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
          stWithVar = if isBoxedRep rep then insert var (owning 1) stAfterValue else stAfterValue
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
          altsAs = concatMap (walkConAlt dn st sc) alts
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
      let (st', dupAs) = doDup dn st var count
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, dupAs ++ bodyAs)
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
  -- Either path leaves every `dupOnShared` field owning one reference
  -- (dup'd on the shared path, handed over from the reserved cell on
  -- the unique one), and every `dropOnUnique` field owning none
  -- (handed over and dropped at once on the unique path, never
  -- acquired on the shared one).
  walk dn st (RReuseOfferNode sc dupOnShared dropOnUnique body) =
      let readAs = checkRead dn "reuseOffer scrutinee" st sc
                     ++ checkReads dn "reuseOffer dupOnShared" st dupOnShared
                     ++ checkReads dn "reuseOffer dropOnUnique" st dropOnUnique
          st' = foldl (\s, v => fst (doDup dn s v 1)) st dupOnShared
          (stFinal, bodyAs) = walk dn st' body
      in (stFinal, readAs ++ bodyAs)
  walk dn st (RLoopNode params initial prologueDrop body) =
      let readAs = checkReads dn "loop initial" st initial
          (stAfterDrop, dropAs) = doDrops dn "loop prologueDrop" st prologueDrop
          -- Loop params (fresh `Boxed`-or-not locals rebound each
          -- iteration) get the same treatment as a con-alt's own
          -- bound vars -- see this module's own top-of-file note.
          stWithParams = foldl (\s, (i, r) => if isBoxedRep r then insert i (owning 1) s else s) stAfterDrop params
          (stFinal, bodyAs) = walk dn stWithParams body
      in (stFinal, readAs ++ dropAs ++ bodyAs)
  walk dn st (RLoopContinueNode args postDrop) =
      let readAs = checkReads dn "continue loop args" st args
          (st', dropAs) = doDrops dn "continue loop postDrop" st postDrop
      in (st', readAs ++ dropAs)
  walk dn st (RMemoizeNode _ _ body) = walk dn st body

  -- A field borrows from a tracked scrutinee (see `Entry`); from an
  -- untracked one (a constant, or a local this walk never saw bound)
  -- it is assumed to own its reference, as before.
  walkConAlt : String -> OwnState -> RCLocal -> RConAlt -> List Anomaly
  walkConAlt dn st sc alt =
      let fieldEntry = case sc of
                            RVar s => if isJust (lookup s st) then MkEntry 0 (Just s) else owning 1
                            _ => owning 1
          stWithArgs = foldl (\s, i => insert i fieldEntry s) st alt.args
      in snd (walk dn stWithArgs alt.altBody)

||| One `def`'s own anomalies, starting from its own `args=[...]`
||| (`Boxed` args get an initial live count of 1; a `RCErrorDef`/
||| `RCCon`/`RCForeign` has no `args` to seed from -- an error def's
||| own free variables are simply never tracked, `RCCon`/`RCForeign`
||| have no body to walk at all).
export
lintDef : String -> RCDef -> List Anomaly
lintDef name (RCFun args _ _ body) =
    let initial = foldl (\s, (i, r) => if isBoxedRep r then insert i (owning 1) s else s) (the OwnState empty) args
    in snd (walk name initial body)
lintDef name (RCErrorDef body) = snd (walk name (the OwnState empty) body)
lintDef _ (RCCon _ _ _) = []
lintDef _ (RCForeign _) = []

||| Every anomaly across a whole parsed program, in `def` order.
export
lintProgram : RCProgram -> List Anomaly
lintProgram = concatMap (\(name, def) => lintDef name def)
