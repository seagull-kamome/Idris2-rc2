module Metrics

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Static counts over a parsed `.rcexpr` program: how many definitions
-- of each kind, and how many of each node that costs something at run
-- time (constructions, closures, calls, reference-count operations).
-- Every figure is a count of places in the IR, not of executions.
-- Meant for comparing two dumps of the same program, e.g. with and
-- without a pass.

import Language.RCExpr.AST

import Data.List
import Data.String

%default covering

public export
record Metrics where
  constructor MkMetrics
  funDefs, workerDefs, conDefs, foreignDefs, errorDefs : Nat
  cons, consReused, retpacks : Nat
  partials, applies : Nat
  calls, callReps, ffiCalls : Nat
  ops, extPrims : Nat
  boxedLets, nativeLets : Nat
  conCases, constCases, cmps : Nat
  dupNodes, dupCount : Nat
  dropNodes, dropCount, postDrops : Nat
  frees, reuseOffers, releaseReuses : Nat
  loops, continues, memoizes, crashes : Nat

emptyMetrics : Metrics
emptyMetrics = MkMetrics 0 0 0 0 0  0 0 0  0 0  0 0 0  0 0  0 0  0 0 0  0 0  0 0 0  0 0 0  0 0 0 0

isBoxed : RRep -> Bool
isBoxed Boxed = True
isBoxed _ = False

walk : Metrics -> RCExp -> Metrics
walk m (RV _) = m
walk m (RCall _ _ _) = { calls $= S } m
walk m (RCallRep _ _ pd _) = { callReps $= S, postDrops $= (+ length pd) } m
walk m (RCallFFI _ pd _) = { ffiCalls $= S, postDrops $= (+ length pd) } m
walk m (RPartial _ _ _) = { partials $= S } m
walk m (RApply _ _ _) = { applies $= S } m
walk m (RLetIn _ rep value body) =
    let m' = if isBoxed rep then { boxedLets $= S } m else { nativeLets $= S } m
    in walk (walk m' value) body
walk m (RConstruct _ _ _ reuseFrom) =
    { cons $= S, consReused $= (+ maybe 0 (const 1) reuseFrom) } m
walk m (RRetPackNode _ _ _) = { retpacks $= S } m
walk m (ROpNode _ _ _ pd) = { ops $= S, postDrops $= (+ length pd) } m
walk m (RExtPrimNode _ _ _ pd) = { extPrims $= S, postDrops $= (+ length pd) } m
walk m (RStructGetNode _ _ pd) = { postDrops $= (+ length pd) } m
walk m (RStructSetNode _ _ _ pd) = { postDrops $= (+ length pd) } m
walk m (RCmp _ _ pd t f) = walk (walk ({ cmps $= S, postDrops $= (+ length pd) } m) t) f
walk m (RConCaseNode _ alts mDef) =
    let m' = foldl (\acc, (MkRConAlt _ _ _ b) => walk acc b) (the Metrics ({ conCases $= S } m)) alts
    in maybe m' (walk m') mDef
walk m (RConstCaseNode _ alts mDef) =
    let m' = foldl (\acc, (MkRConstAlt _ b) => walk acc b) (the Metrics ({ constCases $= S } m)) alts
    in maybe m' (walk m') mDef
walk m (RPrim _) = m
walk m RErasedNode = m
walk m (RCrashNode _) = { crashes $= S } m
walk m (RDupNode _ count body) =
    walk ({ dupNodes $= S, dupCount $= (+ integerToNat (cast count)) } m) body
walk m (RDropNode vars body) = walk ({ dropNodes $= S, dropCount $= (+ length vars) } m) body
walk m (RFreeNode _ body) = walk ({ frees $= S } m) body
walk m (RReleaseReuseNode _ body) = walk ({ releaseReuses $= S } m) body
walk m (RReuseOfferNode _ _ dropOnUnique body) = walk ({ reuseOffers $= S, postDrops $= (+ length dropOnUnique) } m) body
walk m (RLoopNode _ _ prologueDrop body) = walk ({ loops $= S, postDrops $= (+ length prologueDrop) } m) body
walk m (RLoopContinueNode _ pd) = { continues $= S, postDrops $= (+ length pd) } m
walk m (RMemoizeNode _ _ body) = walk ({ memoizes $= S } m) body

countDef : Metrics -> RCDef -> Metrics
countDef m (RCFun _ _ isWorker body) =
    walk (if isWorker then { workerDefs $= S } m else { funDefs $= S } m) body
countDef m (RCCon _ _ _) = { conDefs $= S } m
countDef m (RCForeign _) = { foreignDefs $= S } m
countDef m (RCErrorDef body) = walk ({ errorDefs $= S } m) body

export
metricsOf : RCProgram -> Metrics
metricsOf = foldl (\m, (_, d) => countDef m d) emptyMetrics

||| One line per figure, label column padded so the numbers line up.
export
renderMetrics : Metrics -> List String
renderMetrics m =
    map row
      [ ("definitions", m.funDefs + m.workerDefs + m.conDefs + m.foreignDefs + m.errorDefs,
            "functions \{show m.funDefs}, workers \{show m.workerDefs}, constructors \{show m.conDefs}, foreign \{show m.foreignDefs}, error \{show m.errorDefs}")
      , ("con", m.cons, "fresh \{show (minus m.cons m.consReused)}, reusing a cell \{show m.consReused}")
      , ("retpack", m.retpacks, "constructors returned by value, no cell")
      , ("partial", m.partials, "closures built")
      , ("apply", m.applies, "closure calls")
      , ("call", m.calls + m.callReps + m.ffiCalls,
            "plain \{show m.calls}, callRep \{show m.callReps}, FFI inline \{show m.ffiCalls}")
      , ("op", m.ops + m.extPrims, "op \{show m.ops}, extprim \{show m.extPrims}")
      , ("let", m.boxedLets + m.nativeLets, "Boxed \{show m.boxedLets}, native \{show m.nativeLets}")
      , ("case", m.conCases + m.constCases + m.cmps,
            "constructor \{show m.conCases}, constant \{show m.constCases}, cmp \{show m.cmps}")
      , ("dup", m.dupCount, "increments, in \{show m.dupNodes} dup nodes")
      , ("drop", m.dropCount, "decrements, in \{show m.dropNodes} drop nodes")
      , ("postDrop", m.postDrops, "decrements attached to another node: postDrop, dropOnUnique, prologueDrop")
      , ("free", m.frees, "")
      , ("reuseOffer", m.reuseOffers, "releaseReuse \{show m.releaseReuses}")
      , ("loop", m.loops, "continue \{show m.continues}")
      , ("memoize", m.memoizes, "")
      , ("crash", m.crashes, "")
      ]
  where
    row : (String, Nat, String) -> String
    row (label, n, detail) =
        let base = "  " ++ padRight 12 ' ' label ++ padLeft 8 ' ' (show n)
        in if detail == "" then base else base ++ "  (" ++ detail ++ ")"
