||| Replaces the tail-recursive list functions that upstream's `%transform` rules put
||| in (`tailRecAppend`, `mapTR`, `filterTR`, `mapMaybeTR`: two passes and an
||| intermediate list each) by naive definitions of rc2's own, which `Compiler.RC2.Trmc`
||| turns into one loop. Off by default: `--directive listdivert` turns it on. With
||| `--directive listfuse` too, a `map`, `filter` or `mapMaybe` of the result of another, and
||| a `++` of such a call, become one loop with no list between them. See
||| `rc2/doc/list-divert.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ListDivert

import Core.CompileExpr
import Core.Context
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.String
import Data.Vect

%default covering

||| The functions rc2 defines in place of upstream's.
data Diverted = DAppend | DMap | DFilter | DMapMaybe

divertedName : Diverted -> Name
divertedName DAppend = MN "rc2_append" 0
divertedName DMap = MN "rc2_map" 0
divertedName DFilter = MN "rc2_filter" 0
divertedName DMapMaybe = MN "rc2_mapMaybe" 0

divertedKey : Diverted -> String
divertedKey DAppend = "append"
divertedKey DMap = "map"
divertedKey DFilter = "filter"
divertedKey DMapMaybe = "mapMaybe"

||| One stage of a fused loop: what one of the three element-wise functions does to an element.
data Kind = KMap | KFilter | KMapMaybe

kindCode : Kind -> Char
kindCode KMap = 'm'
kindCode KFilter = 'f'
kindCode KMapMaybe = 'j'

kindOf : Char -> Maybe Kind
kindOf 'm' = Just KMap
kindOf 'f' = Just KFilter
kindOf 'j' = Just KMapMaybe
kindOf _ = Nothing

||| The most stages one fused loop has.
maxStages : Nat
maxStages = 6

fusedPrefix : String
fusedPrefix = "rc2_fuse_"

||| The fused loop of these stages, first applied first; `True`: it ends in a given list
||| (`xs ++ ys`) instead of `[]`.
fusedName : List Kind -> Bool -> Name
fusedName ks withTail = MN (fusedPrefix ++ pack (map kindCode ks) ++ (if withTail then "_t" else "")) 0

decodeFused : Name -> Maybe (List Kind, Bool)
decodeFused (MN s 0) =
    if isPrefixOf fusedPrefix s
       then let rest = unpack (substr (length fusedPrefix) (length s) s)
                (codes, suffix) = span (/= '_') rest
            in case the (Maybe (List Kind)) (traverse kindOf codes) of
                    Just ks => if null ks then Nothing else Just (ks, suffix == ['_', 't'])
                    Nothing => Nothing
       else Nothing
decodeFused _ = Nothing

||| A consumer of a list that a chain can feed without the list being built.
data Consumer = CFoldl | CFoldr | CLength

consumerTag : Consumer -> String
consumerTag CFoldl = "foldl"
consumerTag CFoldr = "foldr"
consumerTag CLength = "length"

||| The loop of a consumer over the chain of these stages, `rc2_foldl_mf`.
consumerName : Consumer -> List Kind -> Name
consumerName c ks = MN ("rc2_" ++ consumerTag c ++ "_" ++ pack (map kindCode ks)) 0

||| A definition the program needs.
data Wanted = WDiv Diverted | WFuse (List Kind) Bool | WConsume Consumer (List Kind)

||| The definitions the rewritten calls name, by name.
Used : Type
Used = SortedMap String Wanted

noUsed : Used
noUsed = SortedMap.empty

unionUsed : Used -> Used -> Used
unionUsed = mergeLeft

allDiverted : List Diverted
allDiverted = [DAppend, DMap, DFilter, DMapMaybe]

isFun : String -> Name -> Bool
isFun s n = show n == s

||| `[]` (also `Lin`, the same constructor).
isNil : NamedCExp -> Bool
isNil (NmCon _ _ NIL _ []) = True
isNil _ = False

||| The call of a diverted function the upstream call `f args` is, if any:
||| `reverseOnto ys (reverseOnto [] xs)` is `tailRecAppend xs ys` inlined;
||| `mapAppend [] f xs` is `mapTR f xs`, and the same for `filter` and `mapMaybe`.
divert : FC -> Name -> List NamedCExp -> Maybe (Diverted, List NamedCExp)
divert fc f args = case args of
    -- `tailRecAppend xs ys`, or what the inliner leaves of it: `reverseOnto ys (reverseOnto [] xs)`
    -- or `reverseOnto ys (reverse xs)`. One alternative for every two-argument call: a `case`
    -- takes the first alternative that matches, so these cannot be three.
    [a, b] =>
        if isFun "Prelude.Types.List.tailRecAppend" f then Just (DAppend, [a, b])
        else if isFun "Prelude.Types.List.reverseOnto" f
           then case b of
                     NmApp _ (NmRef _ g) [z, xs] =>
                         if isFun "Prelude.Types.List.reverseOnto" g && isNil z then Just (DAppend, [xs, a]) else Nothing
                     NmApp _ (NmRef _ g) [xs] =>
                         if isFun "Prelude.Types.List.reverse" g then Just (DAppend, [xs, a]) else Nothing
                     _ => Nothing
           else Nothing
    [z, g, xs] =>
        if not (isNil z) then Nothing
        else if isFun "Prelude.Types.List.mapAppend" f then Just (DMap, [g, xs])
        else if isFun "Prelude.Types.List.filterAppend" f then Just (DFilter, [g, xs])
        else if isFun "Prelude.Types.List.mapMaybeAppend" f then Just (DMapMaybe, [g, xs])
        else Nothing
    _ => Nothing

||| A call of the diverted functions, as the stages it applies to a list: innermost first.
record Chain where
  constructor MkChain
  stages : List (Kind, NamedCExp)
  list : NamedCExp
  ||| `xs ++ ys`: the list the result ends in
  end : Maybe NamedCExp

||| What `e` is as a chain: a call of `rc2_map`, `rc2_filter`, `rc2_mapMaybe`, of a fused
||| loop already made, or of `rc2_append` with such a call as its first argument.
parseChain : NamedCExp -> Maybe Chain
parseChain (NmApp _ (NmRef _ n) args) =
    case (args, stageOf n) of
         ([f, xs], Just k) => Just (MkChain (inner xs ++ [(k, f)]) (listOf xs) Nothing)
         ([a, ys], _) => if n == divertedName DAppend then appended a ys else fused n args
         _ => fused n args
  where
    stageOf : Name -> Maybe Kind
    stageOf m = if m == divertedName DMap then Just KMap
                else if m == divertedName DFilter then Just KFilter
                else if m == divertedName DMapMaybe then Just KMapMaybe
                else Nothing

    -- The first argument of a stage is its own chain, if it is one without an end.
    chainOf : NamedCExp -> Maybe Chain
    chainOf xs = case parseChain xs of
                      Just c => if isJust c.end then Nothing else Just c
                      Nothing => Nothing

    inner : NamedCExp -> List (Kind, NamedCExp)
    inner xs = maybe [] (.stages) (chainOf xs)

    listOf : NamedCExp -> NamedCExp
    listOf xs = maybe xs (.list) (chainOf xs)

    appended : NamedCExp -> NamedCExp -> Maybe Chain
    appended a ys = case chainOf a of
                         Just c => Just ({ end := Just ys } c)
                         Nothing => Nothing

    fused : Name -> List NamedCExp -> Maybe Chain
    fused m as = case decodeFused m of
                      Nothing => Nothing
                      Just (ks, withTail) =>
                          let (stageArgs, rest) = splitAt (length ks) as
                          in case (rest, withTail) of
                                  ([xs], False) => Just (MkChain (zip ks stageArgs) xs Nothing)
                                  ([xs, ys], True) => Just (MkChain (zip ks stageArgs) xs (Just ys))
                                  _ => Nothing
parseChain _ = Nothing

||| The call of one fused loop for `c`, when that saves a list: two stages or more, or one
||| and an end.
fuseChain : FC -> FC -> Chain -> Maybe (NamedCExp, Used)
fuseChain fc rfc c =
    let ks = map fst c.stages
        n = length ks
    in if n == 0 || n > maxStages || (n < 2 && isNothing c.end)
          then Nothing
          else let withTail = isJust c.end
                   name = fusedName ks withTail
               in Just (NmApp fc (NmRef rfc name) (map snd c.stages ++ [c.list] ++ maybe [] pure c.end),
                        SortedMap.singleton (show name) (WFuse ks withTail))

||| `foldl`, `foldr` or `length` of the list a chain makes, as a call of the loop that does both.
consume : FC -> FC -> Name -> List NamedCExp -> Maybe (NamedCExp, Used)
consume fc rfc f args = case args of
    [g, z, xs] =>
        if isFun "Prelude.Types.foldl" f then go CFoldl [g, z] xs
        else if isFun "Prelude.Types.foldr" f then go CFoldr [g, z] xs
        else Nothing
    [n, xs] => if isFun "Prelude.Types.List.lengthPlus" f then go CLength [n] xs else Nothing
    _ => Nothing
  where
    go : Consumer -> List NamedCExp -> NamedCExp -> Maybe (NamedCExp, Used)
    go c own xs = case parseChain xs of
        Just ch =>
            let ks = map fst ch.stages
            in if isJust ch.end || null ks || length ks > maxStages
                  then Nothing
                  else Just (NmApp fc (NmRef rfc (consumerName c ks)) (map snd ch.stages ++ own ++ [ch.list]),
                             SortedMap.singleton (show (consumerName c ks)) (WConsume c ks))
        Nothing => Nothing

||| The direct subexpressions of `e`.
subs : NamedCExp -> List NamedCExp
subs (NmLet _ _ v b) = [v, b]
subs (NmApp _ f as) = f :: as
subs (NmLam _ _ b) = [b]
subs (NmCon _ _ _ _ as) = as
subs (NmOp _ _ as) = toList as
subs (NmExtPrim _ _ as) = as
subs (NmForce _ _ t) = [t]
subs (NmDelay _ _ t) = [t]
subs (NmConCase _ sc alts def) = sc :: map (\(MkNConAlt _ _ _ _ b) => b) alts ++ maybe [] pure def
subs (NmConstCase _ sc alts def) = sc :: map (\(MkNConstAlt _ b) => b) alts ++ maybe [] pure def
subs _ = []

||| Whether the local `x` is read anywhere in `e`.
mentions : Name -> NamedCExp -> Bool
mentions x (NmLocal _ y) = x == y
mentions x e = any (mentions x) (subs e)

||| What the call `f args` (the arguments already rewritten) becomes: a diverted upstream call, a
||| fused loop for a chain of rc2's own, or a consumer's loop; `Nothing` when it stays as it is.
tryCall : (fuse : Bool) -> FC -> FC -> Name -> List NamedCExp -> Maybe (NamedCExp, Used)
tryCall fuse fc rfc f args =
    case divert fc f args of
         Just (d, dargs) =>
             let call' = NmApp fc (NmRef rfc (divertedName d)) dargs
                 s' = SortedMap.singleton (divertedKey d) (WDiv d)
             in case the (Maybe (NamedCExp, Used)) (if fuse then parseChain call' >>= fuseChain fc rfc else Nothing) of
                     Just (fused, u) => Just (fused, unionUsed s' u)
                     Nothing => Just (call', s')
         Nothing =>
             if not fuse then Nothing
             else case the (Maybe (NamedCExp, Used)) (parseChain (NmApp fc (NmRef rfc f) args) >>= fuseChain fc rfc) of
                       Just r => Just r
                       Nothing => consume fc rfc f args

||| `let x = e in call [.., x]` where nothing else reads `x`: the call with `e` for its last
||| argument (the list), when that is a call to rewrite.
letCall : (fuse : Bool) -> Name -> NamedCExp -> NamedCExp -> Maybe (NamedCExp, Used)
letCall fuse x v (NmApp fc (NmRef rfc f) args) =
    if not fuse then Nothing else
    case reverse args of
         (NmLocal _ y :: backFront) =>
             let front = reverse backFront
             in if x == y && not (any (mentions x) front) then tryCall fuse fc rfc f (front ++ [v]) else Nothing
         _ => Nothing
letCall _ _ _ _ = Nothing

||| `e` with every upstream call made a call of the diverted function, and the set
||| of those used.
divertCalls : (fuse : Bool) -> NamedCExp -> (NamedCExp, Used)
divertCalls fuse = go
  where
   mutual
    goList : List NamedCExp -> (List NamedCExp, Used)
    goList es = foldr (\e, (acc, s) => let (e', s') = go e in (e' :: acc, unionUsed s s')) (the (List NamedCExp) [], noUsed) es

    go : NamedCExp -> (NamedCExp, Used)
    go (NmApp fc (NmRef rfc f) args) =
        let (args', s) = goList args
        in case tryCall fuse fc rfc f args' of
                Just (e', u) => (e', unionUsed s u)
                Nothing => (NmApp fc (NmRef rfc f) args', s)
    go (NmApp fc g args) = let (g', s1) = go g; (args', s2) = goList args in (NmApp fc g' args', unionUsed s1 s2)
    go (NmLam fc x b) = let (b', s) = go b in (NmLam fc x b', s)
    go (NmLet fc x v b) =
        let (v', s1) = go v
            (b', s2) = go b
        in case letCall fuse x v' b' of
                Just (fused, u) => (fused, unionUsed (unionUsed s1 s2) u)
                Nothing => (NmLet fc x v' b', unionUsed s1 s2)
    go (NmCon fc n ci t args) = let (args', s) = goList args in (NmCon fc n ci t args', s)
    go (NmOp fc op args) =
        let (args', s) = goList (toList args)
        in (maybe (NmOp fc op args) (NmOp fc op) (toVectExact args'), s)
    go (NmExtPrim fc p args) = let (args', s) = goList args in (NmExtPrim fc p args', s)
    go (NmForce fc lr t) = let (t', s) = go t in (NmForce fc lr t', s)
    go (NmDelay fc lr t) = let (t', s) = go t in (NmDelay fc lr t', s)
    go (NmConCase fc sc alts def) =
        let (sc', s0) = go sc
            (alts', s1) = foldr (\(MkNConAlt n ci t as b), (acc, s) => let (b', s') = go b in (MkNConAlt n ci t as b' :: acc, unionUsed s s')) (the (List NamedConAlt) [], s0) alts
            (def', s2) = the (Maybe NamedCExp, Used) $ case def of
                              Just d => let (d', s') = go d in (Just d', unionUsed s1 s')
                              Nothing => (Nothing, s1)
        in (NmConCase fc sc' alts' def', s2)
    go (NmConstCase fc sc alts def) =
        let (sc', s0) = go sc
            (alts', s1) = foldr (\(MkNConstAlt c b), (acc, s) => let (b', s') = go b in (MkNConstAlt c b' :: acc, unionUsed s s')) (the (List NamedConstAlt) [], s0) alts
            (def', s2) = the (Maybe NamedCExp, Used) $ case def of
                              Just d => let (d', s') = go d in (Just d', unionUsed s1 s')
                              Nothing => (Nothing, s1)
        in (NmConstCase fc sc' alts' def', s2)
    go e = (e, noUsed)

    toVectExact : {n : Nat} -> List NamedCExp -> Maybe (Vect n NamedCExp)
    toVectExact {n} xs = toVect n xs

-- The naive definitions, in the shape `Compiler.RC2.Trmc` turns into a loop: the
-- recursive call is the last field of the `::` it builds.
builtin : String -> Name
builtin s = NS (mkNamespace "_builtin") (UN (Basic s))

local : String -> Name
local s = MN s 0

var : String -> NamedCExp
var s = NmLocal emptyFC (local s)

nil : NamedCExp
nil = NmCon emptyFC (builtin "NIL") NIL (Just 0) []

cons : NamedCExp -> NamedCExp -> NamedCExp
cons x xs = NmCon emptyFC (builtin "CONS") CONS (Just 1) [x, xs]

call : Name -> List NamedCExp -> NamedCExp
call n args = NmApp emptyFC (NmRef emptyFC n) args

||| `case xs of [] => onNil; x :: rest => onCons`, `x` and `rest` the locals named.
listCase : NamedCExp -> NamedCExp -> NamedCExp -> NamedCExp
listCase xs onNil onCons =
    NmConCase emptyFC xs
        [ MkNConAlt (builtin "NIL") NIL (Just 0) [] onNil
        , MkNConAlt (builtin "CONS") CONS (Just 1) [local "x", local "rest"] onCons ]
        Nothing

definition : Diverted -> NamedDef
definition DAppend =
    MkNmFun [local "xs", local "ys"] $
        listCase (var "xs") (var "ys") (cons (var "x") (call (divertedName DAppend) [var "rest", var "ys"]))
definition DMap =
    MkNmFun [local "f", local "xs"] $
        listCase (var "xs") nil (cons (NmApp emptyFC (var "f") [var "x"]) (call (divertedName DMap) [var "f", var "rest"]))
definition DFilter =
    MkNmFun [local "p", local "xs"] $
        listCase (var "xs") nil $
            NmConstCase emptyFC (NmApp emptyFC (var "p") [var "x"])
                -- a Bool is a `B8` constant (upstream's `Compiler.Opts.Constructor.enumTag`)
                [ MkNConstAlt (B8 1) (cons (var "x") (call (divertedName DFilter) [var "p", var "rest"]))
                , MkNConstAlt (B8 0) (call (divertedName DFilter) [var "p", var "rest"]) ]
                Nothing
definition DMapMaybe =
    MkNmFun [local "f", local "xs"] $
        listCase (var "xs") nil $
            NmConCase emptyFC (NmApp emptyFC (var "f") [var "x"])
                [ MkNConAlt (builtin "JUST") JUST (Just 1) [local "v"] (cons (var "v") (call (divertedName DMapMaybe) [var "f", var "rest"]))
                , MkNConAlt (builtin "NOTHING") NOTHING (Just 0) [] (call (divertedName DMapMaybe) [var "f", var "rest"]) ]
                Nothing

||| `[0, 1, ...]`, as many as `ks`.
indices : List Kind -> List Nat
indices ks = go 0 ks
  where
    go : Nat -> List Kind -> List Nat
    go _ [] = []
    go i (_ :: rest) = i :: go (S i) rest

stageName : Nat -> String
stageName i = "f" ++ show i

||| The loop over a chain: `name`, with the stage functions, `extra` parameters, and the list
||| `xs`. One element goes through the stages in turn; a stage that drops it, or the list
||| ending, leaves the rest to `skip` (the call for the rest of the list), and one that
||| emits it makes `emit v`. For a `++` the recursive call is the last field of the `::` that
||| `Compiler.RC2.Trmc` needs.
loopDefinition : List Kind -> (extra : List String) -> (onNil : NamedCExp) -> (emit : NamedCExp -> NamedCExp) -> (skip : NamedCExp) -> NamedDef
loopDefinition ks extra onNil emit skip =
    MkNmFun (map (local . stageName) (indices ks) ++ map local extra ++ [local "xs"]) $
        listCase (var "xs") onNil (build 0 ks (var "x"))
  where
    build : Nat -> List Kind -> NamedCExp -> NamedCExp
    build _ [] v = emit v
    build i (KMap :: more) v =
        NmLet emptyFC (local ("v" ++ show i)) (NmApp emptyFC (var (stageName i)) [v])
              (build (S i) more (var ("v" ++ show i)))
    build i (KFilter :: more) v =
        NmConstCase emptyFC (NmApp emptyFC (var (stageName i)) [v])
            -- a Bool is a `B8` constant (upstream's `Compiler.Opts.Constructor.enumTag`)
            [ MkNConstAlt (B8 1) (build (S i) more v)
            , MkNConstAlt (B8 0) skip ]
            Nothing
    build i (KMapMaybe :: more) v =
        NmConCase emptyFC (NmApp emptyFC (var (stageName i)) [v])
            [ MkNConAlt (builtin "JUST") JUST (Just 1) [local ("w" ++ show i)] (build (S i) more (var ("w" ++ show i)))
            , MkNConAlt (builtin "NOTHING") NOTHING (Just 0) [] skip ]
            Nothing

||| The loop of a fused chain: the stage functions, the list, and for `xs ++ ys` that list too.
fusedDefinition : List Kind -> Bool -> NamedDef
fusedDefinition ks withTail =
    let name = fusedName ks withTail
        fs = map (var . stageName) (indices ks)
        end = if withTail then [var "ys"] else []
        recur = call name (fs ++ [var "rest"] ++ end)
    in case loopDefinition ks [] (if withTail then var "ys" else nil) (\v => cons v recur) recur of
            MkNmFun args body => MkNmFun (if withTail then args ++ [local "ys"] else args) body
            other => other

||| The loop of a consumer over a chain.
consumerDefinition : Consumer -> List Kind -> NamedDef
consumerDefinition c ks =
    let name = consumerName c ks
        fs = map (var . stageName) (indices ks)
        recur = \own => call name (fs ++ own ++ [var "rest"])
    in case c of
            CFoldl => loopDefinition ks ["g", "acc"] (var "acc")
                          (\v => recur [var "g", NmApp emptyFC (NmApp emptyFC (var "g") [var "acc"]) [v]])
                          (recur [var "g", var "acc"])
            CFoldr => loopDefinition ks ["g", "z"] (var "z")
                          (\v => NmApp emptyFC (NmApp emptyFC (var "g") [v]) [recur [var "g", var "z"]])
                          (recur [var "g", var "z"])
            CLength => loopDefinition ks ["n"] (var "n")
                          (\v => recur [NmOp emptyFC (Add IntegerType) [var "n", NmPrimVal emptyFC (BI 1)]])
                          (recur [var "n"])

wantedName : Wanted -> Name
wantedName (WDiv d) = divertedName d
wantedName (WFuse ks t) = fusedName ks t
wantedName (WConsume c ks) = consumerName c ks

wantedDefinition : Wanted -> NamedDef
wantedDefinition (WDiv d) = definition d
wantedDefinition (WFuse ks t) = fusedDefinition ks t
wantedDefinition (WConsume c ks) = consumerDefinition c ks

||| Every program definition rewritten, and the diverted functions that are called
||| added (each calls itself, so its own body needs no rewriting).
export
applyListDivert : (fuse : Bool) -> Maybe NamedCExp -> List (Name, FC, NamedDef) -> (Maybe NamedCExp, List (Name, FC, NamedDef))
applyListDivert fuse main defs =
    let (main', s0) = the (Maybe NamedCExp, Used) $ case main of
                           Just m => let (m', s) = divertCalls fuse m in (Just m', s)
                           Nothing => (Nothing, noUsed)
        (defs', used) = foldr (\(n, fc, d), (acc, s) => let (d', s') = rewriteDef d in ((n, fc, d') :: acc, unionUsed s s')) (the (List (Name, FC, NamedDef)) [], s0) defs
        have = SortedSet.fromList (map (\(n, _, _) => n) defs)
        -- a second run (after inlining) finds the definitions of the first
        added = [ (wantedName w, emptyFC, wantedDefinition w) | (_, w) <- SortedMap.toList used, not (contains (wantedName w) have) ]
    in (main', defs' ++ added)
  where
    rewriteDef : NamedDef -> (NamedDef, Used)
    rewriteDef (MkNmFun args b) = let (b', s) = divertCalls fuse b in (MkNmFun args b', s)
    rewriteDef (MkNmError b) = let (b', s) = divertCalls fuse b in (MkNmError b', s)
    rewriteDef d = (d, noUsed)
