||| Producer flow over a `--directive dumprcexpr` dump: what can reach each
||| local, parameter and result, solved over the whole program's call sites,
||| checked against the representation rc2 chose.
|||
||| Every other check in this tool takes rc2's representation decisions as
||| given (a `Native` local is untracked, a `u:`-case scrutinee is
||| refcount-free). This one re-derives them from producers instead: a
||| literal, a constructor, a closure, a string op, the result of a known
||| function, the arguments of a known call site. Where a pointer reaches a
||| slot rc2 holds as a scalar, or a heap value built at run time reaches a
||| local rc2 holds without a reference count, that is reported: the class of
||| rc2 #343 and of the two reference-counting rules
||| (`Types.typedConstScrutinees`, `RC.alwaysUnboxedBoxedLocalsR`).
|||
||| The domain is a set of producer kinds, or Top. Top never reports (a
||| field read from a constructor, an `apply`'s result, an FFI result, a
||| parameter of a function reached through a closure), so the check can
||| miss a conflict but each report names a producer that is really there.
||| One cell per local, parameter and result (never per allocation site);
||| the lattice has ten kinds, so the fixpoint is reached in a few rounds.
|||
||| This module was licensed by BSD3. see LICENSE file for detail.
module Flow

import Language.RCExpr.AST
import Leak

import Data.List
import Data.List1
import Data.Maybe
import Data.SortedMap
import Data.SortedSet
import Data.String

%default covering

-- The kinds. `string`/`constructor`/`closure` are pointers built at run
-- time; `string literal`/`constant constructor`/`constant closure` are
-- pointers to immortal data (wrong in a scalar slot, harmless without a
-- reference count).
public export
data AV = Top | Some (SortedSet String)

export
Eq AV where
  Top == Top = True
  Some a == Some b = Prelude.toList a == Prelude.toList b
  _ == _ = False

bot : AV
bot = Some empty

one : String -> AV
one k = Some (singleton k)

lub : AV -> AV -> AV
lub Top _ = Top
lub _ Top = Top
lub (Some a) (Some b) = Some (union a b)

joinAll : List AV -> AV
joinAll = foldl lub bot

runtimeHeap : List String
runtimeHeap = ["string", "constructor", "closure"]

pointerKinds : List String
pointerKinds = runtimeHeap ++ ["string literal", "constant constructor", "constant closure"]

kindsIn : List String -> AV -> List String
kindsIn _ Top = []
kindsIn ks (Some s) = filter (\k => contains k s) ks

-- A native type held in a C scalar, not a pointer (`Erased`/`%World` hold
-- nothing at all and are not checked).
scalarNative : String -> Bool
scalarNative t = hasUnboxedType t && not (isInfixOf "Erased" t) && not (isInfixOf "%World" t)
                 || any (\n => isInfixOf n t) ["Int64", "Bits64", "Double", "Int "]
                 || isSuffixOf " Int" t

literal : String -> AV
literal s = case unpack s of
    ('"' :: _) => one "string literal"
    ('\'' :: _) => one "char"
    (c :: _) => if isDigit c || c == '-' then one "number" else Top
    [] => Top

localValue : SortedMap Int AV -> RCLocal -> AV
localValue env (RVar v) = fromMaybe Top (lookup v env)
localValue _ RUnderscore = bot
localValue _ RNull = one "null"
localValue _ (RConst s) = literal s
-- Told apart by what comes before the first `(`, as `Show RCLocal` writes
-- them: `#f/2~closure` and `#f/2~closure(caps)` a constant closure (a
-- static, `doc/static-closures.md`), `#C@1(args)` a constant constructor
-- (whose args may hold constant closures), `#C@1` a tag-only one.
localValue _ (ROpaqueCon s) =
    let head = fst (break (== '(') s) in
    if isSuffixOf "~closure" head then one "constant closure"
    else if head /= s then one "constant constructor" else one "null"

stringOp : String -> Bool
stringOp op = op == "++" || (isPrefixOf "cast-" op && isSuffixOf "-String" op)
              || elem op ["op_strtail", "op_strcons", "op_strappend", "op_strreverse", "op_strsubstr"]

opValue : String -> AV
opValue op =
    if stringOp op then one "string"
    else if isPrefixOf "<" op || isPrefixOf ">" op || isPrefixOf "==" op then one "immediate"
    else if op == "op_strlen" || op == "op_strhead" || op == "op_strindex" then one "immediate"
    else byResult (if isPrefixOf "cast-" op then lastPart op else op)
  where
    small : List String
    small = ["Bits8", "Bits16", "Bits32", "Int8", "Int16", "Int32", "Char"]
    wide : List String
    wide = ["Integer", "Int64", "Bits64", "Int", "Double"]
    lastPart : String -> String
    lastPart o = pack (reverse (takeWhile (/= '-') (reverse (unpack o))))
    byResult : String -> AV
    byResult t = if any (\x => isSuffixOf x t) small then one "immediate"
                 else if any (\x => isSuffixOf x t) wide then one "number"
                 else Top

-- The closures and partial applications in a constant: `#{f:0}/2~closure([...])`.
closureNames : String -> List String
closureNames s =
    let toks = forget (split (\c => elem c (unpack "#()[], ")) s)
    in mapMaybe nameOf toks
  where
    nameOf : String -> Maybe String
    nameOf t = if isSuffixOf "~closure" t
                  then let cs = unpack t
                           rev = reverse cs
                           afterSlash = drop 1 (dropWhile (/= '/') rev)
                       in Just (pack (reverse afterSlash))
                  else Nothing

------------------------------------------------------------------------------
-- One walk of a definition: the value of each local, what it passes to each
-- call site, the value it returns, and the reports.

record Walk where
  constructor MkWalk
  locals : SortedMap Int AV
  calls  : List (String, List AV)
  issues : List String
  refs   : List String        -- functions reached through a closure

note : String -> Walk -> Walk
note s w = { issues $= (s ::) } w

callArgs : String -> List AV -> Walk -> Walk
callArgs n as w = { calls $= ((n, as) ::) } w

refsOf : RCLocal -> List String
refsOf (ROpaqueCon s) = closureNames s
refsOf _ = []

addRefs : List RCLocal -> Walk -> Walk
addRefs ls w = { refs $= (concatMap refsOf ls ++) } w

quads : List String -> List RCLocal -> List AV -> List (Nat, String, RCLocal, AV)
quads ts ls as = go 0 ts ls as
  where
    go : Nat -> List String -> List RCLocal -> List AV -> List (Nat, String, RCLocal, AV)
    go i (t :: ts') (l :: ls') (a :: as') = (i, t, l, a) :: go (S i) ts' ls' as'
    go _ _ _ _ = []

showKinds : List String -> String
showKinds = joinBy " or "

mutual
  -- `results`: the value each known function returns (Nothing: not a function
  -- of this program, so Top).
  val : String -> SortedMap String AV -> Walk -> RCExp -> (Walk, AV)
  val d rs w (RV l) = (addRefs [l] w, localValue w.locals l)
  val d rs w (RCall _ n args) =
      let w1 = addRefs args w
      in (callArgs n (map (localValue w1.locals) args) w1, fromMaybe Top (lookup n rs))
  val d rs w (RCallRep n sig _ args) =
      let w1 = addRefs args w
          avs = map (localValue w1.locals) args
          w2 = foldl (\acc, (i, t, l, a) =>
                        let ks = kindsIn pointerKinds a in
                        if scalarNative t && not (null ks)
                           then note (d ++ ": " ++ show l ++ " can hold a " ++ showKinds ks ++ " but is passed as " ++ t
                                      ++ " (callRep " ++ n ++ " argument " ++ show i ++ ")") acc
                           else acc)
                     w1 (quads (sigReps sig) args avs)
      in (callArgs n avs w2, fromMaybe Top (lookup n rs))
  val d rs w (RCallFFI _ _ args) = (addRefs args w, Top)
  val d rs w (RPartial n _ args) = ({ refs $= (n ::) } (addRefs args w), one "closure")
  val d rs w (RApply _ f args) = (addRefs (f :: args) w, Top)
  val d rs w (RLetIn v rep value body) =
      let (w1, a) = val d rs w value
          w2 = case rep of
                    NativeRep t => let ks = kindsIn pointerKinds a in
                                   if scalarNative t && not (null ks)
                                      then note (d ++ ": v" ++ show v ++ " is " ++ t ++ " but can hold a " ++ showKinds ks) w1
                                      else w1
                    Boxed => w1
      in val d rs ({ locals $= insert v a } w2) body
  val d rs w (RConstruct _ _ args _) = (addRefs args w, if null args then one "null" else one "constructor")
  val d rs w (RRetPackNode _ _ args) = (addRefs args w, Top)
  val d rs w (RStackConNode _ _ args) = (addRefs args w, one "constant constructor")
  val d rs w (ROpNode _ op args _) = (addRefs args w, opValue op)
  val d rs w (RExtPrimNode _ _ args _) = (addRefs args w, Top)
  val d rs w (RStructGetNode _ _ _) = (w, Top)
  val d rs w (RStructSetNode _ _ _ _) = (w, Top)
  val d rs w (RFillNode _ _ _ _) = (w, Top)
  val d rs w (RCmp _ _ _ t f) =
      let (w1, a) = val d rs w t
          (w2, b) = val d rs w1 f
      in (w2, lub a b)
  val d rs w (RConCaseNode _ alts mDef) =
      let (w1, as) = foldl (\(acc, vs), alt =>
                              let acc' = { locals $= \m => foldl (\m', x => insert x Top m') m alt.args } acc
                                  (acc'', a) = val d rs acc' alt.altBody
                              in (acc'', a :: vs)) (w, the (List AV) []) alts
          (w2, dv) = maybe (w1, bot) (val d rs w1) mDef
      in (w2, joinAll (dv :: as))
  val d rs w (RConstCaseNode _ alts mDef) =
      let (w1, as) = foldl (\(acc, vs), alt => let (acc', a) = val d rs acc alt.altBody in (acc', a :: vs)) (w, the (List AV) []) alts
          (w2, dv) = maybe (w1, bot) (val d rs w1) mDef
      in (w2, joinAll (dv :: as))
  val d rs w (RPrim c) = (w, literal c)
  val d rs w RErasedNode = (w, one "null")
  val d rs w (RCrashNode _) = (w, bot)
  val d rs w (RDupNode _ _ b) = val d rs w b
  val d rs w (RDropNode _ b) = val d rs w b
  val d rs w (RFreeNode _ b) = val d rs w b
  val d rs w (RReleaseReuseNode _ b) = val d rs w b
  val d rs w (RReuseOfferNode _ _ _ b) = val d rs w b
  val d rs w (RLoopNode ps initial _ b) =
      let w1 = { locals $= \m => foldl (\m', (x, _) => insert x Top m') m ps } (addRefs initial w)
          (w2, _) = val d rs w1 b
      in (w2, Top)
  val d rs w (RLoopContinueNode args _) = (addRefs args w, bot)
  val d rs w (RJoinNode _ ps scope b) =
      let (w1, a) = val d rs w scope
          (w2, c) = val d rs ({ locals $= \m => foldl (\m', (x, _) => insert x Top m') m ps } w1) b
      in (w2, lub a c)
  val d rs w (RJumpNode _ args) = (addRefs args w, bot)
  val d rs w (RMemoizeNode _ _ b) = val d rs w b
  val d rs w (RDelayNode _ _ caps) = (addRefs caps w, one "constructor")
  val d rs w (RForceNode _ _ _) = (w, Top)

------------------------------------------------------------------------------
-- The whole program: a fixpoint over parameters and results.

record State where
  constructor MkState
  params  : SortedMap String (List AV)
  results : SortedMap String AV

joinArgs : List AV -> List AV -> List AV
joinArgs [] bs = bs
joinArgs as [] = as
joinArgs (a :: as) (b :: bs) = lub a b :: joinArgs as bs

funs : RCProgram -> List (String, List (Int, RRep), RRep, RCExp)
funs prog = mapMaybe (\(n, d) => case d of
                                      RCFun args r _ body => Just (n, args, r, body)
                                      _ => Nothing) prog

-- Functions with no caller in the dump, or reached through a closure or a
-- partial application: their parameters can be anything.
roots : RCProgram -> SortedSet String
roots prog =
    let fs = funs prog
        w0 = MkWalk empty [] [] []
        ws = map (\(n, _, _, body) => fst (val n empty w0 body)) fs
        called = foldl (\acc, w => foldl (\acc', (c, _) => insert c acc') acc w.calls) (the (SortedSet String) empty) ws
        closed = foldl (\acc, w => foldl (flip insert) acc (refs w)) (the (SortedSet String) empty) ws
    in fromList (map (\(n, _, _, _) => n) (filter (\(n, _, _, _) => not (contains n called) || contains n closed) fs))

envOf : State -> SortedSet String -> String -> List (Int, RRep) -> SortedMap Int AV
envOf st rts n args =
    let flows = if contains n rts then map (const Top) args else fromMaybe [] (lookup n st.params)
        vals = zipWith (\_, a => a) args (flows ++ replicate (length args) bot)
    in fromList (zip (map fst args) vals)

retValue : RRep -> AV -> AV
retValue (NativeRep t) a = if scalarNative t then one "immediate" else a
retValue Boxed a = a

step : SortedSet String -> List (String, List (Int, RRep), RRep, RCExp) -> State -> State
step rts fs st =
    foldl (\acc, (n, args, r, body) =>
             let (w, a) = val n st.results (MkWalk (envOf st rts n args) [] [] []) body
                 ps = foldl (\m, (c, as) => insert c (joinArgs as (fromMaybe [] (lookup c m))) m) acc.params w.calls
             in MkState ps (insert n (lub (retValue r a) (fromMaybe bot (lookup n acc.results))) acc.results))
          st fs

-- Every function of the program starts at bottom (it returns nothing yet);
-- a name not in the dump stays absent, so its result is Top.
initialResults : List (String, List (Int, RRep), RRep, RCExp) -> SortedMap String AV
initialResults fs = fromList (map (\(n, _, _, _) => (n, bot)) fs)

stable : State -> State -> Bool
stable a b = SortedMap.toList a.results == SortedMap.toList b.results
             && SortedMap.toList a.params == SortedMap.toList b.params

solve : Nat -> SortedSet String -> List (String, List (Int, RRep), RRep, RCExp) -> State -> (Nat, State)
solve Z _ _ st = (Z, st)
solve (S k) rts fs st = let st' = step rts fs st in
                        if stable st st' then (S k, st) else solve k rts fs st'

------------------------------------------------------------------------------
-- What the dump does with a local's count: the ids it dups or drops, and how
-- often each is consumed (passed, stored, returned, an op's operand).

vars : List RCLocal -> List Int
vars = mapMaybe (\l => case l of RVar v => Just v; _ => Nothing)

mutual
  rcOps : RCExp -> List Int
  rcOps (RDupNode l _ b) = vars [l] ++ rcOps b
  rcOps (RDropNode ls b) = vars ls ++ rcOps b
  rcOps (RFreeNode l b) = vars [l] ++ rcOps b
  rcOps (RReleaseReuseNode l b) = vars [l] ++ rcOps b
  rcOps (RReuseOfferNode l ds us b) = vars (l :: ds ++ us) ++ rcOps b
  rcOps (RCallRep _ _ pd _) = vars pd
  rcOps (RCallFFI _ pd _) = vars pd
  rcOps (ROpNode _ _ _ pd) = vars pd
  rcOps (RExtPrimNode _ _ _ pd) = vars pd
  rcOps (RForceNode _ _ pd) = vars pd
  rcOps (RLetIn _ _ v b) = rcOps v ++ rcOps b
  rcOps (RCmp _ _ pd t f) = vars pd ++ rcOps t ++ rcOps f
  rcOps (RConCaseNode _ alts d) = concatMap (\a => rcOps a.altBody) alts ++ maybe [] rcOps d
  rcOps (RConstCaseNode _ alts d) = concatMap (\a => rcOps a.altBody) alts ++ maybe [] rcOps d
  rcOps (RLoopNode _ _ pd b) = vars pd ++ rcOps b
  rcOps (RLoopContinueNode _ pd) = vars pd
  rcOps (RJoinNode _ _ s b) = rcOps s ++ rcOps b
  rcOps (RMemoizeNode _ _ b) = rcOps b
  rcOps _ = []

  -- The most consuming uses of a local on one path (branches: the larger).
  consumes : Int -> RCExp -> Nat
  consumes v (RV l) = count v [l]
  consumes v (RCall _ _ as) = count v as
  consumes v (RCallRep _ _ _ as) = count v as
  consumes v (RCallFFI _ _ as) = count v as
  consumes v (RPartial _ _ as) = count v as
  consumes v (RApply _ f as) = count v (f :: as)
  consumes v (RConstruct _ _ as _) = count v as
  consumes v (RRetPackNode _ _ as) = count v as
  consumes v (ROpNode _ _ as _) = count v as
  consumes v (RLetIn _ _ x b) = consumes v x + consumes v b
  consumes v (RCmp _ _ _ t f) = max (consumes v t) (consumes v f)
  consumes v (RConCaseNode _ alts d) = foldl max (maybe 0 (consumes v) d) (map (\a => consumes v a.altBody) alts)
  consumes v (RConstCaseNode _ alts d) = foldl max (maybe 0 (consumes v) d) (map (\a => consumes v a.altBody) alts)
  consumes v (RDupNode _ _ b) = consumes v b
  consumes v (RDropNode _ b) = consumes v b
  consumes v (RFreeNode _ b) = consumes v b
  consumes v (RReleaseReuseNode _ b) = consumes v b
  consumes v (RReuseOfferNode _ _ _ b) = consumes v b
  consumes v (RLoopNode _ i _ b) = count v i + consumes v b
  consumes v (RLoopContinueNode as _) = count v as
  consumes v (RJoinNode _ _ s _) = consumes v s
  consumes v (RJumpNode _ as) = count v as
  consumes v (RMemoizeNode _ _ b) = consumes v b
  consumes v (RDelayNode _ _ cs) = count v cs
  consumes _ _ = 0

  count : Int -> List RCLocal -> Nat
  count v ls = length (filter (== RVar v) ls)


||| The reports, and the number of rounds the fixpoint took.
||| `concatMap` over a list as long as the program: `List`'s own is quadratic
||| (code-style-Idris2.md).
concatMapL : (a -> List b) -> List a -> List b
concatMapL f xs = reverse (foldl (\acc, x => reverseOnto acc (f x)) [] xs)

||| The most rounds `solve` runs; `flowProgram` returning this many rounds
||| means no fixpoint was reached.
export
flowRoundLimit : Nat
flowRoundLimit = 100

export
flowProgram : RCProgram -> (Nat, List String)
flowProgram prog =
    let fs = funs prog
        rts = roots prog
        limit = flowRoundLimit
        (left, st) = solve limit rts fs (MkState empty (initialResults fs))
        reports = concatMapL (\(n, args, r, body) =>
                    let env = envOf st rts n args
                        (w, _) = val n st.results (MkWalk env [] [] []) body
                        paramIssues = mapMaybe (\(v, rep) => case rep of
                                         NativeRep t => let ks = kindsIn pointerKinds (fromMaybe Top (lookup v env)) in
                                                        if scalarNative t && not (null ks)
                                                           then Just (n ++ ": parameter v" ++ show v ++ " is " ++ t ++ " but a caller passes a " ++ showKinds ks)
                                                           else Nothing
                                         Boxed => Nothing) args
                        counted = fromList (rcOps body)
                        exempt = filter (\v => not (contains v counted) && consumes v body >= 2) (Prelude.toList (exemptLocals body))
                        rcIssues = mapMaybe (\v => let ks = kindsIn runtimeHeap (fromMaybe Top (lookup v w.locals)) in
                                                   if null ks then Nothing
                                                   else Just (n ++ ": v" ++ show v ++ " is held without a reference count (a `u:` case or an immediate op reads it) but a " ++ showKinds ks ++ " built at run time reaches it"))
                                            exempt
                    in reverse w.issues ++ paramIssues ++ rcIssues) fs
    in (minus limit left, reports)

showAV : AV -> String
showAV Top = "Top"
showAV (Some s) = "{" ++ joinBy ", " (Prelude.toList s) ++ "}"

||| For debugging: each function's parameters as solved, and its exempt locals.
export
flowDebug : RCProgram -> List String
flowDebug prog =
    let fs = funs prog
        rts = roots prog
        (_, st) = solve flowRoundLimit rts fs (MkState empty (initialResults fs))
    in concatMapL (\(n, args, r, body) =>
         let env = envOf st rts n args
             (w, _) = val n st.results (MkWalk env [] [] []) body
         in [n ++ (if contains n rts then " (root)" else "") ++ " params " ++ joinBy ", " (map (\(v, _) => "v" ++ show v ++ "=" ++ showAV (fromMaybe Top (lookup v env))) args)
             ++ " exempt " ++ joinBy ", " (map (\v => "v" ++ show v ++ "=" ++ showAV (fromMaybe Top (lookup v w.locals))) (Prelude.toList (exemptLocals body)))]) fs

-- What flow proves about a value: anything (Top), a pointer can reach it, only
-- scalars reach it (immediates, chars, enum constants), or numbers too (an
-- Integer may be a heap bignum, so not a scalar by itself).
flowClass : AV -> String
flowClass Top = "top"
flowClass a@(Some s) =
    if not (null (kindsIn pointerKinds a)) then "pointer"
    else if null (Prelude.toList s) then "none"
    else if all (\k => elem k ["immediate", "char", "null"]) (Prelude.toList s) then "scalar"
    else "numeric"

||| Parameter counts by the representation rc2 chose (worker or not) and what
||| flow proves; then the conflicts.
export
flowStats : RCProgram -> List String
flowStats prog =
    let fs = mapMaybe (\(n, d) => case d of
                                       RCFun args r w body => Just (n, args, w)
                                       _ => Nothing) prog
        rts = roots prog
        (rounds, st) = solve flowRoundLimit rts (funs prog) (MkState empty (initialResults (funs prog)))
        rows = concatMapL (\(n, args, w) =>
                 let env = envOf st rts n args in
                 map (\(v, rep) => ((if w then "worker " else "entry  ") ++ repClass rep, flowClass (fromMaybe Top (lookup v env)))) args) fs
        tally = foldl (\m, k => insert k (S (fromMaybe 0 (lookup k m))) m) (the (SortedMap (String, String) Nat) empty) rows
    in ("fixpoint rounds " ++ show (minus flowRoundLimit rounds) ++ ", functions " ++ show (length fs) ++ ", roots " ++ show (length (Prelude.toList rts)))
       :: map (\((r, c), k) => r ++ " | " ++ c ++ " | " ++ show k) (SortedMap.toList tally)
  where
    repClass : RRep -> String
    repClass Boxed = "Boxed"
    repClass (NativeRep t) = if scalarNative t then "scalar" else if isInfixOf "Erased" t || isInfixOf "%World" t then "erased/world" else "native-other"

||| One line per parameter: function, position, representation, flow class.
export
flowParams : RCProgram -> List String
flowParams prog =
    let rts = roots prog
        fs = funs prog
        (_, st) = solve flowRoundLimit rts fs (MkState empty (initialResults fs))
    in concatMapL (\(n, args, _, _) =>
         let env = envOf st rts n args in
         zipWith (\i, (v, rep) => n ++ "\t" ++ show i ++ "\t" ++ show rep ++ "\t" ++ flowClass (fromMaybe Top (lookup v env)))
                 [the Nat 0 .. length args] args) fs
