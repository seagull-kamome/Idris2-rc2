||| Compares two `--directive dumprcexpr` dumps definition by definition,
||| so a change to rc2 can be checked against its expected effect even
||| where every variable id after the first changed node has shifted.
||| See `README.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.String

import System
import System.File

%default covering

-------------------------------------------------------------------------------
-- Normalization

isIdentChar : Char -> Bool
isIdentChar c = isAlphaNum c || c == '_' || c == '.' || c == '\''

||| Variables renamed `v0`, `v1`, ... in order of first appearance, the
||| state carried across the lines of one definition.
renumber : List String -> List String
renumber ls = reverse (snd (foldl line ((empty, 0), []) ls))
  where
    digitsOf : List Char -> (List Char, List Char)
    digitsOf = span isDigit

    go : (SortedMap String Nat, Nat) -> Maybe Char -> List Char -> SnocList Char
      -> ((SortedMap String Nat, Nat), SnocList Char)
    go st _ [] out = (st, out)
    go (m, n) prev ('v' :: rest) out =
        let (ds, after) = digitsOf rest
            boundaryBefore = maybe True (not . isIdentChar) prev
            boundaryAfter = case after of
                                 (c :: _) => not (isIdentChar c)
                                 [] => True
        in if boundaryBefore && boundaryAfter && not (null ds)
              then let key = pack ds
                       (k, st') = case lookup key m of
                                       Just k => (k, (m, n))
                                       Nothing => (n, (insert key n m, S n))
                   in go st' (Just '0') after (out <>< ('v' :: unpack (show k)))
              else go (m, n) (Just 'v') rest (out :< 'v')
    go st _ (c :: rest) out = go st (Just c) rest (out :< c)

    line : ((SortedMap String Nat, Nat), List String) -> String -> ((SortedMap String Nat, Nat), List String)
    line (st, acc) l = let (st', out) = go st Nothing (unpack l) [<] in (st', pack (cast out) :: acc)

||| Every `{name:N}` whose name rc2 generated (`rc2_...`, `idris2rc2_...`)
||| loses its counters: the `:N` and a trailing `_N` in the name. With
||| `loose`, every other `{name:N}` loses its `:N` too (lifted lambdas
||| renumbered by a change upstream of lifting).
normalizeNames : Bool -> String -> String
normalizeNames loose s = pack (cast (go [] (unpack s) [<]))
  where
    -- `starts` holds, innermost first, the output length at each open `{`.
    go : List Nat -> List Char -> SnocList Char -> SnocList Char
    go _ [] out = out
    go starts ('{' :: rest) out = go (length out :: starts) rest (out :< '{')
    go (st :: starts) (':' :: rest) out =
        case span isDigit rest of
             (ds@(_ :: _), '}' :: after) =>
                 let content = drop (S st) (cast {to = List Char} out)
                     generated = isPrefixOf (unpack "rc2_") content || isPrefixOf (unpack "idris2rc2_") content
                 in if generated
                       then go starts after (([<] <>< take (S st) (cast out)) <>< (stripCounter content ++ unpack ":*}"))
                       else if loose
                               then go starts after (out <>< unpack ":*}")
                               else go starts after (out <>< (':' :: ds ++ ['}']))
             _ => go (st :: starts) rest (out :< ':')
      where
        stripCounter : List Char -> List Char
        stripCounter cs = case break (== '_') (reverse cs) of
                               (ds@(_ :: _), '_' :: rest) => if all isDigit ds then reverse rest else cs
                               _ => cs
    go (_ :: starts) ('}' :: rest) out = go starts rest (out :< '}')
    go starts (c :: rest) out = go starts rest (out :< c)

-------------------------------------------------------------------------------
-- Reading a dump

||| `def NAME  (...)` starts a definition; lines before the first one
||| (the directive comment) belong to none.
splitDefs : List String -> List (String, List String)
splitDefs ls = reverse (close (foldl step (Nothing, []) ls))
  where
    nameOf : String -> String
    nameOf l = go [] (unpack (substr 4 (length l) l))
      where
        go : List Char -> List Char -> String
        go acc (' ' :: ' ' :: '(' :: _) = pack (reverse acc)
        go acc (c :: cs) = go (c :: acc) cs
        go acc [] = pack (reverse acc)

    close : (Maybe (String, List String), List (String, List String)) -> List (String, List String)
    close (Just (n, body), acc) = (n, reverse body) :: acc
    close (Nothing, acc) = acc

    step : (Maybe (String, List String), List (String, List String)) -> String
        -> (Maybe (String, List String), List (String, List String))
    step st l =
        if isPrefixOf "def " l
           then (Just (nameOf l, [l]), close st)
           else case st of
                     (Just (n, body), acc) => (Just (n, l :: body), acc)
                     (Nothing, acc) => (Nothing, acc)

||| Normalized definitions by normalized name; a name that normalizes to
||| one already seen gets `#2`, `#3`, ... in order.
normalizedDefs : Bool -> String -> SortedMap String (List String)
normalizedDefs loose content = fst (foldl add (empty, empty) (splitDefs (lines content)))
  where
    add : (SortedMap String (List String), SortedMap String Nat) -> (String, List String)
       -> (SortedMap String (List String), SortedMap String Nat)
    add (defs, seen) (n, body) =
        let n' = normalizeNames loose n
            k = fromMaybe 0 (lookup n' seen)
            key = if k == 0 then n' else n' ++ "#" ++ show (S k)
        in (insert key (renumber (map (normalizeNames loose) body)) defs, insert n' (S k) seen)

-------------------------------------------------------------------------------
-- Reporting

||| The lines of `a` and `b` between their common prefix and suffix, at
||| most `cap` of each.
hunk : Nat -> List String -> List String -> List String
hunk cap a b =
    let (pre, a1, b1) = dropCommon 0 a b
        (_, a2, b2) = dropCommon 0 (reverse a1) (reverse b1)
    in ("@@ line " ++ show (S pre)) :: (map ("- " ++) (take cap (reverse a2)) ++ map ("+ " ++) (take cap (reverse b2)))
  where
    dropCommon : Nat -> List String -> List String -> (Nat, List String, List String)
    dropCommon k (x :: xs) (y :: ys) = if x == y then dropCommon (S k) xs ys else (k, x :: xs, y :: ys)
    dropCommon k xs ys = (k, xs, ys)

record Options where
  constructor MkOptions
  loose : Bool
  showCount : Nat

usage : String
usage = "usage: rcexpr-diff [--loose] [--show K] A.rcexpr B.rcexpr"

run : Options -> String -> String -> IO ()
run opts pa pb = do
    Right ca <- readFile pa
      | Left err => fail ("could not read " ++ pa ++ ": " ++ show err)
    Right cb <- readFile pb
      | Left err => fail ("could not read " ++ pb ++ ": " ++ show err)
    let da = normalizedDefs (loose opts) ca
        db = normalizedDefs (loose opts) cb
        onlyA = filter (\n => isNothing (lookup n db)) (keys da)
        onlyB = filter (\n => isNothing (lookup n da)) (keys db)
        both = mapMaybe (\(n, a) => map (\b => (n, a, b)) (lookup n db)) (SortedMap.toList da)
        differ = filter (\(_, a, b) => a /= b) both
    putStrLn ("rcexpr-diff: " ++ show (minus (length both) (length differ)) ++ " same, "
              ++ show (length differ) ++ " differ, " ++ show (length onlyA) ++ " only in A, "
              ++ show (length onlyB) ++ " only in B")
    traverse_ (\(n, _, _) => putStrLn ("differ: " ++ n)) differ
    traverse_ (\n => putStrLn ("only in A: " ++ n)) onlyA
    traverse_ (\n => putStrLn ("only in B: " ++ n)) onlyB
    traverse_ (\(n, a, b) => do putStrLn ("=== " ++ n); traverse_ putStrLn (hunk 40 a b))
              (take (showCount opts) differ)
    if null differ && null onlyA && null onlyB then pure () else exitWith (ExitFailure 1)
  where
    fail : String -> IO ()
    fail msg = do
        putStrLn ("rcexpr-diff: " ++ msg)
        exitWith (ExitFailure 2)

main : IO ()
main = do
    args <- getArgs
    case parse (MkOptions False 0) (drop 1 args) of
         Just (opts, [a, b]) => run opts a b
         _ => do
             putStrLn usage
             exitWith (ExitFailure 2)
  where
    parse : Options -> List String -> Maybe (Options, List String)
    parse o ("--loose" :: rest) = parse ({ loose := True } o) rest
    parse o ("--show" :: k :: rest) = parsePositive {a = Nat} k >>= \n => parse ({ showCount := n } o) rest
    parse o rest = Just (o, rest)
