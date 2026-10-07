module Leak

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Path-sensitive ownership balance over `Language.RCExpr.AST`'s parsed
-- `.rcexpr` tree: every owned reference a definition creates must be
-- consumed exactly once before each path ends. The rule list, the
-- consumption table and what is deliberately left unchecked are in
-- `tools/rcexpr-lint/README.md` ("The leak check").
--
-- One walk per definition, forking the state at `case`/`cmp` (the
-- state is a persistent map, so a fork is free). A `case`/`cmp` in
-- value position (the value of a `let`) is walked arm by arm and
-- the arms' end states are compared instead of walking the `let` body
-- once per arm, which would be exponential in the number of such
-- cases.
--
-- Not covered by `Lint`'s own use-after-free/double-drop walk, and
-- independent of it: this walk keeps its own `Boxed` ownership
-- counts and never reports those two anomalies.

import Language.RCExpr.AST
import Lint

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.String

%default covering

-------------------------------------------------------------------------------
-- State

||| Owned references per tracked local, the live reuse tokens, and the
||| sum of both (so "nothing is owed" is one comparison, not a scan).
record St where
  constructor MkSt
  owned   : SortedMap Int Int
  ||| the tracked locals that are `case` fields: consuming one that owns
  ||| nothing hands out a reference it only borrows from its scrutinee
  fields  : SortedSet Int
  tokens  : SortedSet Int
  pending : Int
  ||| references forgotten by `nullify`; `pending + nulled` is what
  ||| two paths that join must agree on
  nulled  : Int

||| Locals read from the enclosing scope at a `loop`'s top; `continue`
||| must hand every one of them back unchanged.
record LoopCtx where
  constructor MkLoopCtx
  baseline : Int
  nulled0 : Int
  snapshot : SortedMap Int Int
  snapTokens : SortedSet Int
  params : List (Int, RRep)
  ||| positions every `continue` hands back unchanged
  invariant : List Bool

record Env where
  constructor MkEnv
  defName : String
  ||| `Boxed` locals that never get a refcount operation
  ||| (`Compiler.RC2.RC.alwaysUnboxedBoxedLocalsR`); untracked.
  exempt : SortedSet Int
  retRep : RRep
  ||| `RetN` struct locals by rep text, to read a scrutinee's layout.
  reps : SortedMap Int String
  loop : Maybe LoopCtx
  ||| report every spend and `dup` as well (for `Borrow`)
  events : Bool
  inLoop : Bool

||| What `walk` is evaluating for: the function's own result (`Tail`:
||| every path must end owing nothing), or the value of a `let` of
||| the given representation (`Val`: the path continues).
data Mode = Tail | Val RRep

||| `out` is the state after a `Val` expression; `Nothing` for a
||| `Tail` walk and for a path that does not come back (`crash`,
||| `continue`).
record Res where
  constructor MkRes
  out : Maybe St
  finds : List Anomaly

isBoxedRep : RRep -> Bool
isBoxedRep Boxed = True
isBoxedRep (NativeRep _) = False

setOwned : Int -> Int -> St -> St
setOwned v n st = case lookup v st.owned of
    Nothing => { owned $= insert v n, pending $= (+ n) } st
    Just old => { owned $= insert v n, pending $= (+ (n - old)) } st

addRefs : Int -> Int -> St -> St
addRefs v n st = case lookup v st.owned of
    Nothing => st
    Just old => setOwned v (old + n) st

||| Give a freshly bound local its one reference, unless it is
||| untracked (exempt, or not `Boxed`).
bindOwned : Env -> RRep -> Int -> St -> St
bindOwned env rep v st =
    if isBoxedRep rep && v /= 0 && not (contains v env.exempt) then setOwned v 1 st else st

||| Whether `loc` is a tracked local still holding a reference.
hasOwnedRef : St -> RCLocal -> Bool
hasOwnedRef st (RVar v) = maybe False (> 0) (lookup v st.owned)
hasOwnedRef _ _ = False

untrack : Int -> St -> St
untrack v st = case lookup v st.owned of
    Nothing => st
    Just n => { owned $= delete v, pending $= (\p => p - n) } st

spendToken : Int -> St -> St
spendToken s st = { tokens $= delete s, pending $= (\p => p - 1) } st

noFinds : List Anomaly
noFinds = []

spent : Env -> St -> Consumer -> Int -> List Anomaly
spent env st how v =
    if env.events
       then [MkAnomaly env.defName (Spent how (fromMaybe 0 (lookup v st.owned)) (contains v st.fields) env.inLoop) v ""]
       else noFinds

consume1 : Env -> String -> Consumer -> RCLocal -> (St, List Anomaly) -> (St, List Anomaly)
consume1 env ctx how (RVar v) (st, fs) = case lookup v st.owned of
    Nothing => (st, fs)
    Just n => if n > 0
                 then (setOwned v (n - 1) st, spent env (setOwned v (n - 1) st) how v ++ fs)
                 else if contains v st.fields
                         then (st, MkAnomaly env.defName OverConsume v ctx :: fs)
                         else (st, fs)
consume1 _ _ _ _ acc = acc

consumeAll : Env -> String -> Consumer -> St -> List RCLocal -> (St, List Anomaly)
consumeAll env ctx how st locs = foldl (\acc, l => consume1 env ctx how l acc) (st, []) locs

||| `consumeAll` over the elements whose position `flags` marks `True`;
||| `how` is told the position.
consumeFlagged : Env -> String -> (Nat -> Consumer) -> St -> List Bool -> List RCLocal -> (St, List Anomaly)
consumeFlagged env ctx how st flags locs =
    foldl (\acc, (k, f, l) => if f then consume1 env ctx (how k) l acc else acc) (st, [])
          (zip [0 .. length locs] (zip flags locs))

||| Matching an erased constructor (see `RConAlt.conInfo`) proves the
||| scrutinee is NULL: whatever references the IR still counts for it
||| (annotate removes it from `owned` when it is dead, with no node
||| saying so) are of nothing.
nullify : RCLocal -> St -> St
nullify (RVar v) st = case lookup v st.owned of
    Just n => { owned $= delete v, pending $= (\p => p - n), nulled $= (+ n) } st
    Nothing => st
nullify _ st = st

-------------------------------------------------------------------------------
-- Text fields the parser keeps opaque

splitOnChar : Char -> List Char -> List (List Char)
splitOnChar sep cs = go [] [] cs
  where
    go : List Char -> List (List Char) -> List Char -> List (List Char)
    go cur acc [] = reverse (reverse cur :: acc)
    go cur acc (c :: rest) =
        if c == sep then go [] (reverse cur :: acc) rest else go (c :: cur) acc rest

||| Contents of the first `[...]` group of `cs` (quote-aware, nested
||| brackets balanced) and what follows it.
skipGroup : List Char -> Maybe (List Char, List Char)
skipGroup ('[' :: cs) = go 1 False False [] cs
  where
    go : Nat -> Bool -> Bool -> List Char -> List Char -> Maybe (List Char, List Char)
    go _ _ _ _ [] = Nothing
    go d q esc acc (c :: rest) =
        if q
           then (if esc then go d True False (c :: acc) rest
                 else if c == '\\' then go d True True (c :: acc) rest
                 else go d (c /= '"') False (c :: acc) rest)
           else (if c == '"' then go d True False (c :: acc) rest
                 else if c == '[' then go (S d) False False (c :: acc) rest
                 else if c == ']'
                      then (case d of
                                 S Z => Just (reverse acc, rest)
                                 S k => go k False False (c :: acc) rest
                                 Z => Nothing)
                      else go d False False (c :: acc) rest)
skipGroup _ = Nothing

||| The parameter reps of a `callRep` signature (`["Boxed", "Native Int"] ->
||| ...`).
sigReps : String -> List String
sigReps sig = case skipGroup (unpack sig) of
    Nothing => []
    Just (inner, _) => oddParts (splitOnChar '"' inner)
  where
    oddParts : List (List Char) -> List String
    oddParts (_ :: q :: rest) = pack q :: oddParts rest
    oddParts _ = []

||| Does a `callRep` consume the argument at each position (a `Boxed` parameter)?
sigBoxed : String -> List Bool
sigBoxed sig = map (== "Boxed") (sigReps sig)

||| Per argument of an inlined FFI call (`[ccs...] [Int, %World] -> ret`):
||| does the call itself consume it? Every type but the ones
||| `Compiler.RC2.Types.cfTypeNative` reads natively (those are
||| discharged through `postDrop`).
ffiBoxed : String -> List Bool
ffiBoxed desc = case skipGroup (unpack desc) of
    Nothing => []
    Just (_, rest) => case skipGroup (dropWhile (== ' ') rest) of
        Nothing => []
        Just (inner, _) => map (\t => not (elem (trim (pack t)) nativeCFTypes)) (splitTop inner)
  where
    nativeCFTypes : List String
    nativeCFTypes = ["Int", "Int_8", "Int_16", "Int_32", "Int_64", "Bits_8", "Bits_16", "Bits_32", "Bits_64", "Double", "Char"]

    splitTop : List Char -> List (List Char)
    splitTop cs = go (the Nat 0) [] [] cs
      where
        go : Nat -> List Char -> List (List Char) -> List Char -> List (List Char)
        go _ cur acc [] = reverse (reverse cur :: acc)
        go d cur acc (c :: rest) =
            if c == ',' && d == 0 then go d [] (reverse cur :: acc) rest
            else if c == '[' || c == '(' then go (S d) (c :: cur) acc rest
            else if c == ']' || c == ')' then go (minus d 1) (c :: cur) acc rest
            else go d (c :: cur) acc rest

isRetRep : String -> Bool
isRetRep s = isPrefixOf "Ret" s

||| Which fields of constructor `tag` a `RetN[:tag=f0,f1...]*` struct
||| carries natively (`True`), per its rep text. `[]` when the tag has
||| no entry: every field is `Boxed`.
retNativeFields : String -> String -> List Bool
retNativeFields rep tag = case words tag of
    ["Just", n] => case drop 1 (map pack (splitOnChar ':' (unpack rep))) of
        entries => fromMaybe [] (choose n entries)
    _ => []
  where
    choose : String -> List String -> Maybe (List Bool)
    choose _ [] = Nothing
    choose n (e :: es) = case splitOnChar '=' (unpack e) of
        [k, fs] => if pack k == n
                      then Just (map (\f => pack f /= "Boxed") (splitOnChar ',' fs))
                      else choose n es
        _ => choose n es

erasedInfo : String -> Bool
erasedInfo i = i == "nil" || i == "nothing" || i == "zero" || i == "unit"

-------------------------------------------------------------------------------
-- Locals with no refcount: `Boxed` operands at an always-unboxed type

||| Locals shown by their use to hold an always-unboxed value (`Char`,
||| `Int8`...: tagged, the refcount operations on them are no-ops, and
||| rc2 neither pairs nor omits them consistently). The evidence is any
||| of: a `let` bound directly to a comparison op (producer-side), an
||| op/cmp operand with no `postDrop` entry at such a type, a
||| `callRep` argument at a `Native` parameter of such a type with no
||| `postDrop` entry, a read into a `Native` local of such a type.
unboxedTypeNames : List String
unboxedTypeNames = ["Char", "Int8", "Int16", "Int32", "Bits8", "Bits16", "Bits32"]

occurrences : Int -> List RCLocal -> Nat
occurrences v ls = length (filter (== RVar v) ls)

||| Operands read at an always-unboxed `ty` and not discharged.
noteUndischarged : Bool -> List RCLocal -> List RCLocal -> SortedSet Int -> SortedSet Int
noteUndischarged typed args pd set =
    if not typed then set
    else foldl (\s, l => case l of
                              RVar v => if occurrences v args > occurrences v pd then insert v s else s
                              _ => s) set args

||| The comparison primitives (`<T`, `<=T`, `==T`, `>=T`, `>T`, as `Show
||| (PrimFn _)` prints them): their Boxed result is an `Int8` immediate, so
||| a local bound directly to one has no refcount operations either (the
||| producer-side rule of `Compiler.RC2.RC.alwaysUnboxedBoxedLocalsR`).
||| No other op's name starts with `<`, `>` or `==`.
isComparisonOp : String -> Bool
isComparisonOp op = isPrefixOf "<" op || isPrefixOf ">" op || isPrefixOf "==" op

||| `value` is a comparison op, possibly under the `dup`/`drop` of its
||| own operands that `annotate` wraps around it.
boundToComparison : RCExp -> Bool
boundToComparison (ROpNode False op _ _) = isComparisonOp op
boundToComparison (RDupNode _ _ body) = boundToComparison body
boundToComparison (RDropNode _ body) = boundToComparison body
boundToComparison _ = False

hasUnboxedType : String -> Bool
hasUnboxedType t = any (\n => isInfixOf n t) unboxedTypeNames

||| Every alt constant of a `case` carries the dump's `u:` mark (an
||| always-unboxed constant type, `Compiler.RC2.Pretty.immediateMark`): the
||| scrutinee holds a tagged immediate (`Compiler.RC2.RC.typedConstScrutinees`).
typedImmediateAlts : List RConstAlt -> Bool
typedImmediateAlts [] = False
typedImmediateAlts alts = all (\a => isPrefixOf "u:" a.constVal) alts

scanExp : SortedSet Int -> RCExp -> SortedSet Int
scanExp sc (RV _) = sc
scanExp sc (RCall _ _ _) = sc
scanExp sc (RCallRep _ sig pd args) =
    foldl (\s, (t, l) => if hasUnboxedType t then noteUndischarged True [l] pd s else s) sc
          (zip (sigReps sig) args)
scanExp sc (RCallFFI _ _ _) = sc
scanExp sc (RPartial _ _ _) = sc
scanExp sc (RDelayNode _ _ _) = sc
scanExp sc (RApply _ _ _) = sc
scanExp sc (RLetIn var rep value body) =
    let sc' = case (rep, value) of
                   (NativeRep t, RV (RVar x)) => if hasUnboxedType t then insert x sc else sc
                   (Boxed, _) => if boundToComparison value then insert var sc else sc
                   _ => sc
    in scanExp (scanExp sc' value) body
scanExp sc (RConstruct _ _ _ _) = sc
scanExp sc (RRetPackNode _ _ _) = sc
scanExp sc (ROpNode _ op args pd) = noteUndischarged (hasUnboxedType op) args pd sc
scanExp sc (RExtPrimNode _ _ _ _) = sc
scanExp sc (RForceNode _ _ _) = sc
scanExp sc (RStructGetNode _ _ _) = sc
scanExp sc (RStructSetNode _ _ _ _) = sc
scanExp sc (RFillNode _ _ _ _) = sc
scanExp sc (RCmp op args pd t f) = scanExp (scanExp (noteUndischarged (hasUnboxedType op) args pd sc) t) f
scanExp sc (RConCaseNode _ alts mDef) =
    let sc' = foldl (\s, a => scanExp s a.altBody) sc alts
    in maybe sc' (scanExp sc') mDef
scanExp sc (RConstCaseNode scrut alts mDef) =
    let sc0 = case scrut of
                   RVar v => if typedImmediateAlts alts then insert v sc else sc
                   _ => sc
        sc' = foldl (\s, a => scanExp s a.altBody) sc0 alts
    in maybe sc' (scanExp sc') mDef
scanExp sc (RPrim _) = sc
scanExp sc RErasedNode = sc
scanExp sc (RCrashNode _) = sc
scanExp sc (RDupNode _ _ body) = scanExp sc body
scanExp sc (RDropNode _ body) = scanExp sc body
scanExp sc (RFreeNode _ body) = scanExp sc body
scanExp sc (RReleaseReuseNode _ body) = scanExp sc body
scanExp sc (RReuseOfferNode _ _ _ body) = scanExp sc body
scanExp sc (RLoopNode _ _ _ body) = scanExp sc body
scanExp sc (RLoopContinueNode _ _) = sc
scanExp sc (RMemoizeNode _ _ body) = scanExp sc body

||| The argument lists of the `continue`s that jump to the loop whose
||| body is `e` (those of a nested `loop` belong to that one).
continueArgs : RCExp -> List (List RCLocal) -> List (List RCLocal)
continueArgs (RLetIn _ _ value body) acc = continueArgs body (continueArgs value acc)
continueArgs (RCmp _ _ _ t f) acc = continueArgs f (continueArgs t acc)
continueArgs (RConCaseNode _ alts mDef) acc =
    let acc' = foldl (\a, alt => continueArgs alt.altBody a) acc alts
    in maybe acc' (\d => continueArgs d acc') mDef
continueArgs (RConstCaseNode _ alts mDef) acc =
    let acc' = foldl (\a, alt => continueArgs alt.altBody a) acc alts
    in maybe acc' (\d => continueArgs d acc') mDef
continueArgs (RDupNode _ _ body) acc = continueArgs body acc
continueArgs (RDropNode _ body) acc = continueArgs body acc
continueArgs (RFreeNode _ body) acc = continueArgs body acc
continueArgs (RReleaseReuseNode _ body) acc = continueArgs body acc
continueArgs (RReuseOfferNode _ _ _ body) acc = continueArgs body acc
continueArgs (RMemoizeNode _ _ body) acc = continueArgs body acc
continueArgs (RLoopContinueNode args _) acc = args :: acc
continueArgs _ acc = acc

isConstLocal : RCLocal -> Bool
isConstLocal (RVar _) = False
isConstLocal _ = True

||| Loop parameter positions that get a constant (`[__]`, a literal) as
||| their value on some entry or `continue`: `MutualLoop` pads the
||| parameters of the member not running with such constants, so
||| whether the parameter owns a reference depends on the state tag.
padPositions : List RCLocal -> RCExp -> List Bool
padPositions initial body =
    foldl (\acc, args => zipWith (\a, b => a || b) acc (map isConstLocal args))
          (map isConstLocal initial) (continueArgs body [])

exemptLocals : RCExp -> SortedSet Int
exemptLocals = scanExp empty

-------------------------------------------------------------------------------
-- The walk

leakFindings : Env -> St -> String -> List Anomaly
leakFindings env st ctx =
    [MkAnomaly env.defName Leak v ctx | (v, n) <- SortedMap.toList st.owned, n > 0]
    ++ [MkAnomaly env.defName TokenLeak v ctx | v <- SortedSet.toList st.tokens]

||| End of a path: in `Tail` it must owe nothing; in `Val` the value
||| goes on to its `let`.
leaf : Env -> Mode -> St -> String -> List Anomaly -> Res
leaf env Tail st ctx fs =
    MkRes Nothing (fs ++ (if st.pending == 0 then [] else leakFindings env st ("path end: " ++ ctx)))
leaf _ (Val _) st _ fs = MkRes (Just st) fs

||| A value that is a constant (or erased): immortal, so a local bound
||| to it needs no consuming.
immortalValue : RCExp -> Bool
immortalValue (RV (RVar _)) = False
immortalValue (RV _) = True
immortalValue (RPrim _) = True
immortalValue RErasedNode = True
immortalValue _ = False

isTail : Mode -> Bool
isTail Tail = True
isTail _ = False

||| Loop parameter positions that every `continue` of `body` passes
||| unchanged (the parameter itself).
invariantPositions : List (Int, RRep) -> RCExp -> List Bool
invariantPositions params body =
    foldl (\acc, args => zipWith (\a, same => a && same) acc (zipWith (\(i, _), l => l == RVar i) params args))
          (map (const True) params) (continueArgs body [])

||| The local ids behind a list of values (`0` for a constant).
rootVars : List RCLocal -> List Int
rootVars = map (\l => case l of
                           RVar v => v
                           _ => 0)

destBoxed : Env -> Mode -> Bool
destBoxed env Tail = isBoxedRep env.retRep
destBoxed _ (Val r) = isBoxedRep r

||| Where two end states of one value-position branch differ.
differences : Env -> String -> St -> St -> List Anomaly
differences env ctx a b =
    let keys = SortedSet.toList (SortedSet.fromList (map fst (SortedMap.toList a.owned) ++ map fst (SortedMap.toList b.owned)))
        diffs = [MkAnomaly env.defName kind v (ctx ++ ": owns " ++ show x ++ " vs " ++ show y)
                | v <- keys
                , let x = fromMaybe 0 (lookup v a.owned)
                , let y = fromMaybe 0 (lookup v b.owned)
                , x /= y
                , let kind = if isPrefixOf "loop" ctx then LoopImbalance else BranchImbalance]
        toks = [MkAnomaly env.defName TokenLeak v (ctx ++ ": reuse token live on one side only")
               | v <- SortedSet.toList a.tokens ++ SortedSet.toList b.tokens
               , contains v a.tokens /= contains v b.tokens]
    in take 3 (diffs ++ toks)

combine : Env -> String -> Mode -> List Res -> Res
combine _ _ Tail rs = MkRes Nothing (foldr (\r, acc => r.finds ++ acc) [] rs)
combine env label (Val _) rs =
    let finds = foldr (\r, acc => r.finds ++ acc) [] rs
    in case mapMaybe (\r => r.out) rs of
            [] => MkRes Nothing finds
            lives@(s0 :: _) =>
                -- an erased alt's scrutinee may or may not be dead after the
                -- case (see `nullify`): the arms agree when some count in
                -- each arm's [pending, pending + nulled] range is common
                let hi = foldl (\m, s => max m s.pending) s0.pending lives
                    lo = foldl (\m, s => min m (s.pending + s.nulled)) (s0.pending + s0.nulled) lives
                    base = fromMaybe s0 (find (\s => s.pending == hi) lives)
                in if hi <= lo
                      then MkRes (Just base) finds
                      else case find (\s => s.pending + s.nulled < hi) lives of
                                Just b => MkRes (Just base) (finds ++ differences env ("branch at " ++ label) base b)
                                Nothing => MkRes (Just base) finds

||| `local` as a case scrutinee's field owner: a tracked `Boxed`
||| local lends its fields (they own nothing until dup'd); a `RetN`
||| struct local owns its `Boxed` fields outright.
bindFields : Env -> St -> RCLocal -> String -> List Int -> St
bindFields env st (RVar s) tag args = case lookup s st.owned of
    Just _ => foldl (\acc, a => if a == 0 || contains a env.exempt then acc
                                 else { fields $= insert a } (setOwned a 0 acc)) st args
    Nothing => case lookup s env.reps of
        Nothing => st
        Just rep =>
            let native = retNativeFields rep tag
            in foldl (\acc, (k, a) =>
                         if a == 0 || contains a env.exempt || fromMaybe False (getAt k native)
                            then acc else setOwned a 1 acc) st (zip [0 .. length args] args)
bindFields _ st _ _ _ = st

mutual
  walk : Env -> Mode -> St -> RCExp -> Res
  walk env m st (RV loc) =
      let (st', fs) = if destBoxed env m then consume1 env "RV" ByReturn loc (st, noFinds) else (st, noFinds)
      in leaf env m st' "return" fs
  walk env m st (RCall _ name args) =
      let (st', fs) = consumeFlagged env "call args" (\k => ByCall name k (isTail m)) st (map (const True) args) args
      in leaf env m st' ("call " ++ name) fs
  walk env m st (RCallRep name sig pd args) =
      let (st1, f1) = consumeFlagged env "callRep args" (\k => ByCall name k (isTail m)) st (sigBoxed sig) args
          (st2, f2) = consumeAll env "callRep postDrop" ByDrop st1 pd
      in leaf env m st2 ("callRep " ++ name) (f1 ++ f2)
  walk env m st (RCallFFI desc pd args) =
      let (st1, f1) = consumeFlagged env "callFFIInline args" (\_ => ByApply "ffi") st (ffiBoxed desc) args
          (st2, f2) = consumeAll env "callFFIInline postDrop" ByDrop st1 pd
      in leaf env m st2 "callFFIInline" (f1 ++ f2)
  walk env m st (RPartial name _ args) =
      let (st', fs) = consumeAll env "partial args" (ByStore "closure") st args
      in leaf env m st' ("partial " ++ name) fs
  walk env m st (RDelayNode _ _ caps) =
      let (st', fs) = consumeAll env "delay captures" (ByStore "lazy cell") st caps
      in leaf env m st' "delay" fs
  walk env m st (RApply _ c args) =
      let (st', fs) = consumeAll env "apply" (ByApply "apply") st (c :: args)
      in leaf env m st' "apply" fs
  walk env m st (RLetIn var rep (RV loc@(RVar x)) body) =
      if destBoxed env (Val rep)
         then let (st1, f1) = consume1 env "RV" (ByAlias var) loc (st, noFinds)
                  st2 = if contains x env.exempt then st1 else bindOwned env rep var st1
                  bres = walk env m st2 body
              in MkRes bres.out (f1 ++ bres.finds)
         else walkLet env m st var rep (RV loc) body
  walk env m st (RLetIn var rep value body) = walkLet env m st var rep value body
  walk env m st (RConstruct name _ args reuseFrom) =
      let (st1, f1) = consumeAll env "con args" (ByStore "constructor") st args
          (st2, f2) = case reuseFrom of
              Just (RVar s) => if contains s st1.tokens
                                  then (spendToken s st1, noFinds)
                                  else (st1, [MkAnomaly env.defName (Unknown "reuse without offer") s "con reuse"])
              _ => (st1, noFinds)
      in leaf env m st2 ("con " ++ name) (f1 ++ f2)
  walk env m st (RRetPackNode name _ fields) =
      let (st', fs) = consumeAll env "retpack fields" (ByStore "constructor") st fields
      in leaf env m st' ("retpack " ++ name) fs
  walk env m st (ROpNode _ op _ pd) =
      let (st', fs) = consumeAll env "op postDrop" ByDrop st pd
      in leaf env m st' ("op " ++ op) fs
  walk env m st (RExtPrimNode _ prim _ pd) =
      let (st', fs) = consumeAll env "extprim postDrop" ByDrop st pd
      in leaf env m st' ("extprim " ++ prim) fs
  walk env m st (RForceNode _ _ pd) =
      let (st', fs) = consumeAll env "force postDrop" ByDrop st pd
      in leaf env m st' "force" fs
  walk env m st (RStructGetNode _ _ pd) =
      let (st', fs) = consumeAll env "structGet postDrop" ByDrop st pd
      in leaf env m st' "structGet" fs
  walk env m st (RStructSetNode _ _ _ pd) =
      let (st', fs) = consumeAll env "structSet postDrop" ByDrop st pd
      in leaf env m st' "structSet" fs
  walk env m st (RFillNode _ _ value pd) =
      let (st1, f1) = consumeAll env "fill value" (ByStore "constructor") st [value]
          (st2, f2) = consumeAll env "fill postDrop" ByDrop st1 pd
      in leaf env m st2 "fill" (f1 ++ f2)
  walk env m st (RCmp _ _ pd whenTrue whenFalse) =
      let (st1, fs) = consumeAll env "cmp postDrop" ByDrop st pd
          r = combine env "cmp" m [walk env m st1 whenTrue, walk env m st1 whenFalse]
      in { finds := fs ++ r.finds } r
  walk env m st (RConCaseNode sc alts mDef) =
      let altRes = map (walkAlt env m st sc) alts
          defRes = maybe [] (\d => [walk env m st d]) mDef
      in combine env ("case " ++ show sc) m (altRes ++ defRes)
  walk env m st (RConstCaseNode sc alts mDef) =
      let altRes = map (\a => walk env m st a.altBody) alts
          defRes = maybe [] (\d => [walk env m st d]) mDef
      in combine env ("const case " ++ show sc) m (altRes ++ defRes)
  walk env m st (RPrim _) = leaf env m st "literal" []
  walk env m st RErasedNode = leaf env m st "erased" []
  walk _ _ _ (RCrashNode _) = MkRes Nothing []
  walk env m st (RDupNode v n body) = case v of
      RVar i => let r = walk env m (addRefs i (cast n) st) body
                in if env.events && isJust (lookup i st.owned)
                      then { finds := MkAnomaly env.defName (Duped (cast n) env.inLoop) i "" :: r.finds } r
                      else r
      _ => walk env m st body
  walk env m st (RDropNode vs body) =
      let (st', fs) = consumeAll env "drop" ByDrop st vs
          r = walk env m st' body
      in { finds := fs ++ r.finds } r
  walk env m st (RFreeNode v body) =
      let (st', fs) = consumeAll env "free" ByDrop st [v]
          r = walk env m st' body
      in { finds := fs ++ r.finds } r
  walk env m st (RReleaseReuseNode v body) = case v of
      RVar s => if contains s st.tokens
                   then walk env m (spendToken s st) body
                   else let (st', fs) = consumeAll env "releaseReuse" ByDrop st [v]
                            r = walk env m st' body
                        in { finds := MkAnomaly env.defName (Unknown "releaseReuse without offer") s "releaseReuse" :: fs ++ r.finds } r
      _ => walk env m st body
  walk env m st (RReuseOfferNode sc dupOnShared _ body) =
      let (st1, fs) = consumeAll env "reuseOffer" ByReuse st [sc]
          st2 = case sc of
                     RVar s => { tokens $= insert s, pending $= (+ 1) } st1
                     _ => st1
          st3 = foldl (\acc, d => case d of
                                       RVar i => addRefs i 1 acc
                                       _ => acc) st2 dupOnShared
          r = walk env m st3 body
      in { finds := fs ++ r.finds } r
  walk env m st (RLoopNode params initial pd body) =
      let pads = padPositions initial body
          padded = mapMaybe (\((i, r), a, pad) =>
                                if isBoxedRep r && (pad || not (hasOwnedRef st a)) then Just i else Nothing)
                            (zip params (zip initial pads))
          inv = invariantPositions params body
          (st1, f1) = consumeFlagged env "loop initial" (\k => ByLoop (fromMaybe False (getAt k inv))) st
                                     (map (isBoxedRep . snd) params) initial
          (st2, f2) = consumeAll env "loop prologueDrop" ByDrop st1 pd
          envP = { exempt $= (\ex => foldl (\e, i => insert i e) ex padded), inLoop := True } env
          st2' = foldl (\acc, i => untrack i acc) st2 padded
          (st3, f3) = rebirth envP st2' params
          env' = foldl (\e, (i, r) => case r of
                                           NativeRep s => if isRetRep s then { reps $= insert i s } e else e
                                           _ => e)
                       ({ loop := Just (MkLoopCtx st3.pending st3.nulled st3.owned st3.tokens params inv) } envP) params
          r = walk env' m st3 body
          aliases = if env.events
                       then mapMaybe (\((i, _), a, same) =>
                                         if same then Just (MkAnomaly env.defName (Spent (ByAlias i) 0 False env.inLoop) a "loop param")
                                                 else Nothing)
                                     (zip params (zip (rootVars initial) inv))
                       else noFinds
          untracked = map (\i => MkAnomaly env.defName (Unknown "loop parameter not tracked (constant or unowned argument)") i "loop") padded
      in { finds := untracked ++ aliases ++ f1 ++ f2 ++ f3 ++ r.finds } r
  walk env m st (RLoopContinueNode args pd) = case env.loop of
      Nothing => MkRes Nothing [MkAnomaly env.defName (Unknown "continue outside loop") 0 "continue"]
      Just lc =>
          let (st1, f1) = consumeFlagged env "continue args" (\k => ByLoop (fromMaybe False (getAt k lc.invariant))) st
                                         (map (isBoxedRep . snd) lc.params) args
              (st2, f2) = consumeAll env "continue postDrop" ByDrop st1 pd
              (st3, f3) = rebirth env st2 lc.params
              f4 = if st3.pending <= lc.baseline && lc.baseline <= st3.pending + (st3.nulled - lc.nulled0)
                      then []
                      else differences env "loop" st3 (MkSt lc.snapshot empty lc.snapTokens lc.baseline 0)
          in MkRes Nothing (f1 ++ f2 ++ f3 ++ f4)
  walk env m st (RMemoizeNode _ _ body) = walk env m st body

  walkLet : Env -> Mode -> St -> Int -> RRep -> RCExp -> RCExp -> Res
  walkLet env m st var rep value body =
      let vres = walk env (Val rep) st value
          env' = case rep of
                      NativeRep s => if isRetRep s then { reps $= insert var s } env else env
                      _ => env
      in case vres.out of
              Nothing => vres
              Just st1 =>
                  let st2 = if immortalValue value then st1 else bindOwned env rep var st1
                      bres = walk env' m st2 body
                  in MkRes bres.out (vres.finds ++ bres.finds)

  ||| A loop's own `Boxed` parameters take their value from the
  ||| `initial`/`continue` arguments: each starts an iteration owning
  ||| one reference, and must have spent the previous one.
  rebirth : Env -> St -> List (Int, RRep) -> (St, List Anomaly)
  rebirth env st params = foldl step (st, []) params
    where
      step : (St, List Anomaly) -> (Int, RRep) -> (St, List Anomaly)
      step (s, fs) (i, r) =
          if not (isBoxedRep r) || contains i env.exempt
             then (s, fs)
             else case lookup i s.owned of
                       Just n => if n > 0
                                    then (setOwned i 1 s, MkAnomaly env.defName Leak i "loop parameter not consumed before the next iteration" :: fs)
                                    else (setOwned i 1 s, fs)
                       Nothing => (setOwned i 1 s, fs)

  walkAlt : Env -> Mode -> St -> RCLocal -> RConAlt -> Res
  walkAlt env m st sc alt =
      let st1 = if erasedInfo alt.conInfo then nullify sc st else st
          st2 = bindFields env st1 sc alt.tag alt.args
      in walk env m st2 alt.altBody

-------------------------------------------------------------------------------
-- Entry points

dedupe : List Anomaly -> List Anomaly
dedupe as = go empty as
  where
    go : SortedSet String -> List Anomaly -> List Anomaly
    go _ [] = []
    go seen (a :: rest) = case a.kind of
        Spent _ _ _ _ => a :: go seen rest
        Duped _ _ => a :: go seen rest
        _ => let key = show a.kind ++ ":" ++ show a.var
             in if contains key seen then go seen rest else a :: go (insert key seen) rest

||| One `def`'s leak findings, starting from its own `args=[...]`.
export
leakDef : (wantEvents : Bool) -> String -> RCDef -> List Anomaly
leakDef wantEvents name (RCFun args retRep _ body) =
    let exempt = exemptLocals body
        env0 = MkEnv name exempt retRep empty Nothing wantEvents False
        env = foldl (\e, (i, r) => case r of
                                        NativeRep s => if isRetRep s then { reps $= insert i s } e else e
                                        _ => e) env0 args
        st0 = foldl (\s, (i, r) => bindOwned env r i s) (MkSt empty empty empty 0 0) args
    in dedupe (walk env Tail st0 body).finds
leakDef wantEvents name (RCErrorDef body) =
    dedupe (walk (MkEnv name (exemptLocals body) Boxed empty Nothing wantEvents False) Tail (MkSt empty empty empty 0 0) body).finds
leakDef _ _ (RCCon _ _ _) = []
leakDef _ _ (RCForeign _) = []

||| Every leak finding across a whole parsed program, in `def` order.
export
leakProgram : RCProgram -> List Anomaly
leakProgram = foldr (\(name, def), acc => leakDef False name def ++ acc) []

||| `leakProgram`, plus the spend/`dup` events `Borrow` is built from.
export
leakEvents : (String, RCDef) -> List Anomaly
leakEvents (name, def) = leakDef True name def

||| The `Boxed` locals of `body` that carry no refcount (see `Scan`).
export
leakExempt : RCExp -> SortedSet Int
leakExempt = exemptLocals
