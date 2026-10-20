module Compiler.RC2.PtrParams

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Which parameters are raw C pointers, found from how the function body
-- uses them (doc/native-pointer.md): a parameter whose every use is a call
-- argument at a `TPtr` position of a `%foreign` declaration, or of another
-- function's pointer parameter. Shared by `Compiler.RC2.Loop` (loop
-- variables) and `Compiler.RC2.DualABI` (function parameters).

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.ForeignSpec

import Core.CompileExpr
import Core.Context
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet

%default covering

||| A `%foreign` argument's own `Rep`, as `ffiWorkerTable` gives it.
argRep : CFType -> Rep
argRep ty = maybe RBoxed RNative (cfTypeNativeTy ty)

||| `callArgNativeReads` for many ids at once: one walk of `e` instead of one
||| per id (a lambda-lifted function can have many parameters).
export
callArgNativeReadsFor : SortedMap Name (Name, List Rep, Rep, Bool) -> SortedSet Int -> RCExp -> SortedMap Int (SortedSet NativeTy)
callArgNativeReadsFor workers tracked e = go e
  where
    merge : SortedMap Int (SortedSet NativeTy) -> SortedMap Int (SortedSet NativeTy) -> SortedMap Int (SortedSet NativeTy)
    merge = SortedMap.mergeWith union

    mergeAll : List (SortedMap Int (SortedSet NativeTy)) -> SortedMap Int (SortedSet NativeTy)
    mergeAll = foldl merge empty

    reads : List RCLocal -> List Rep -> SortedMap Int (SortedSet NativeTy)
    reads args reps = foldl (\acc, (a, r) => case (a, r) of
                                                  (RCLoc i, RNative ty) => addRead i ty acc
                                                  (RCLoc i, RInlineNative ty) => addRead i ty acc
                                                  _ => acc) empty (zip args reps)
      where
        addRead : Int -> NativeTy -> SortedMap Int (SortedSet NativeTy) -> SortedMap Int (SortedSet NativeTy)
        addRead i ty acc = if contains i tracked then SortedMap.insertWith union i (SortedSet.singleton ty) acc else acc

    go : RCExp -> SortedMap Int (SortedSet NativeTy)
    go (RLet _ _ _ value body) = go value `merge` go body
    go (RCmpCase _ _ _ _ t f) = go t `merge` go f
    go (RConCase _ _ alts mDef) =
        mergeAll (map (\(MkRConAlt _ _ _ _ body) => go body) alts) `merge` maybe empty go mDef
    go (RConstCase _ _ alts mDef) =
        mergeAll (map (\(MkRConstAlt _ body) => go body) alts) `merge` maybe empty go mDef
    go (RLoop _ _ _ _ body) = go body
    go (RDup _ _ _ cont) = go cont
    go (RDrop _ _ cont) = go cont
    go (RFree _ _ cont) = go cont
    go (RReleaseReuse _ _ cont) = go cont
    go (RReuseOffer _ _ _ _ cont) = go cont
    go (RAppName _ _ n args) =
        case lookup n workers of
             Just (_, argReps, _, _) => if length args == length argReps then reads args argReps else empty
             Nothing => empty
    go _ = empty

||| The parameters among `argIds` that `body` reads only as a raw pointer:
||| each use is a call argument at a position `table` says is `TPtr`. Such a
||| parameter is promoted to a native `TPtr` (`doc/native-pointer.md`).
export
ptrParams : SortedMap Name (Name, List Rep, Rep, Bool) -> List Int -> RCExp -> SortedSet Int
ptrParams table argIds body =
    let found = callArgNativeReadsFor table (SortedSet.fromList argIds) body
    in fromList (filter (\p => maybe False (\tys => Prelude.toList tys == [TPtr]) (lookup p found)) argIds)

||| For every ordinary function with a pointer parameter, a table entry
||| marking that position `RNative TPtr`, on top of the `%foreign`
||| declarations' own. Repeated, so a pointer passed on through a chain of
||| functions is found at each link.
export
ptrParamTable : List (Name, RCDef) -> SortedMap Name (Name, List Rep, Rep, Bool)
ptrParamTable defs = go (the Nat 4) ffiEntries
  where
    ffiEntries : SortedMap Name (Name, List Rep, Rep, Bool)
    ffiEntries = fromList (mapMaybe ffiEntry defs)
      where
        ffiEntry : (Name, RCDef) -> Maybe (Name, (Name, List Rep, Rep, Bool))
        ffiEntry (n, MkRCForeign ccs fargs _) =
            if foreignUsable ccs && any (\t => cfTypeNativeTy t == Just TPtr) fargs
               then Just (n, (n, map argRep fargs, RBoxed, True))
               else Nothing
        ffiEntry _ = Nothing

    entryOf : SortedMap Name (Name, List Rep, Rep, Bool) -> (Name, RCDef) -> Maybe (Name, (Name, List Rep, Rep, Bool))
    entryOf table (n, MkRCFun args _ False body) =
        let ps = ptrParams table (map fst args) body
            reps = map (\(p, _) => if contains p ps then RNative TPtr else RBoxed) args
        in if null (Prelude.toList ps) then Nothing else Just (n, (n, reps, RBoxed, False))
    entryOf _ _ = Nothing

    go : Nat -> SortedMap Name (Name, List Rep, Rep, Bool) -> SortedMap Name (Name, List Rep, Rep, Bool)
    go Z table = table
    go (S k) table =
        let table' = mergeWith const (fromList (mapMaybe (entryOf table) defs)) ffiEntries
        in go k table'

