||| What each callee reads natively per argument position, by callee name: the table that lets a caller decide a
||| native argument is safe to pass. See `rc2/doc/dual-abi.md`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.CalleeTable

import Compiler.RC2.NativeUse
import Compiler.RC2.RCExp
import Compiler.RC2.ForeignSpec
import Compiler.RC2.Types
import Compiler.RC2.Util

import Core.CompileExpr
import Core.TT

import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.Vect

%default covering

||| What each position of a callee reads natively, by callee name.
public export
CalleeTable : Type
CalleeTable = SortedMap Name (List (Maybe NativeTy))

||| Every `MkRCFun` parameter's `PrimType` eligibility, exactly as
||| `nativeArgType` decides it, positionally aligned with `args`.
primCallee : RCDef -> Maybe (List (Maybe NativeTy))
primCallee (MkRCFun args _ _ body) =
    let found = nativeArgTypeBatch (map fst args) body
    in Just (map (\(p, _) => TPrim <$> lookup p found) args)
primCallee _ = Nothing

||| The native positions of a usable `%foreign` declaration: the scalars
||| `cfTypeNative` reads natively, and the raw pointers (`doc/native-pointer.md`).
foreignCallee : RCDef -> Maybe (List (Maybe NativeTy))
foreignCallee (MkRCForeign ccs fargs _) =
    let ps = map cfTypeNativeTy fargs
    in if foreignUsable ccs && any isJust ps then Just ps else Nothing
foreignCallee _ = Nothing

||| `Just ty` per position of `table`'s callee `n`, for the walk below.
tableLookup : CalleeTable -> Name -> Maybe (List (Maybe NativeTy))
tableLookup table n = lookup n table

||| Every native type at which each of `tracked`'s ids is fed as a direct,
||| saturated call argument to a callee `callee` says reads that position
||| natively (a call argument, unlike an `ROp` operand, is not tied to the
||| enclosing `RLet`'s type). One walk for the whole set, so a definition
||| with many parameters costs one pass. Not folded into `nativeArgTypesFor`:
||| `ConAltNative` and `DualABI` reuse that and must not gain this implicitly.
||| `Compiler.RC2.DualABI` asks the same question of its worker table.
export covering
callArgNativeReadsFor : (Name -> Maybe (List (Maybe NativeTy))) -> SortedSet Int -> RCExp -> SortedMap Int (SortedSet NativeTy)
callArgNativeReadsFor callee tracked e = go e
  where
    go : RCExp -> SortedMap Int (SortedSet NativeTy)
    go (RLet _ _ _ value body) = go value `unionMaps` go body
    go (RCmpCase _ _ _ _ t f) = go t `unionMaps` go f
    go (RConCase _ _ alts mDef) =
        concatMaps (map (\(MkRConAlt _ _ _ _ body) => go body) alts) `unionMaps` maybe empty go mDef
    go (RConstCase _ _ alts mDef) =
        concatMaps (map (\(MkRConstAlt _ body) => go body) alts) `unionMaps` maybe empty go mDef
    go (RLoop _ _ _ _ body) = go body
    go (RDup _ _ _ cont) = go cont
    go (RDrop _ _ cont) = go cont
    go (RFree _ _ cont) = go cont
    go (RReleaseReuse _ _ cont) = go cont
    go (RReuseOffer _ _ _ _ cont) = go cont
    go (RAppName _ _ n args) =
        case callee n of
             Just tys => if length args == length tys
                            then foldr (\(a, mty), acc => maybe acc (\ty => addTracked tracked a ty acc) mty) empty (zip args tys)
                            else empty
             Nothing => empty
    go _ = empty

||| The native type of each parameter among `argIds` that `body` reads at one
||| type only, as call arguments at the positions of `table`.
export covering
callNativeParams : CalleeTable -> List Int -> RCExp -> SortedMap Int NativeTy
callNativeParams table argIds body =
    let found = callArgNativeReadsFor (tableLookup table) (SortedSet.fromList argIds) body
    in SortedMap.fromList (mapMaybe (\p => case map Prelude.toList (lookup p found) of
                                                 Just [ty] => Just (p, ty)
                                                 _ => Nothing) argIds)

||| The parameters among `argIds` that `body` reads only as a raw pointer:
||| every use is a call argument at a `TPtr` position of `table`.
export covering
ptrParams : CalleeTable -> List Int -> RCExp -> SortedSet Int
ptrParams table argIds body =
    SortedSet.fromList (map fst (filter (\(_, ty) => ty == TPtr) (SortedMap.toList (callNativeParams table argIds body))))

||| Pointer positions only: the `%foreign` declarations', plus every ordinary
||| function's pointer parameters, found by a fixed number of rounds so a
||| pointer passed on through a chain of functions is found at each link.
export covering
ptrCalleeTable : List (Name, RCDef) -> CalleeTable
ptrCalleeTable defs = go (the Nat 4) foreignEntries
  where
    foreignEntries : CalleeTable
    foreignEntries = fromList (mapMaybe (\(n, d) => map (n,) (foreignCallee d)) defs)

    entryOf : CalleeTable -> (Name, RCDef) -> Maybe (Name, List (Maybe NativeTy))
    entryOf table (n, MkRCFun args _ False body) =
        let ps = ptrParams table (map fst args) body
        in if null (Prelude.toList ps)
              then Nothing
              else Just (n, map (\(p, _) => if contains p ps then Just TPtr else Nothing) args)
    entryOf _ _ = Nothing

    go : Nat -> CalleeTable -> CalleeTable
    go Z table = table
    go (S k) table = go k (mergeWith const (fromList (mapMaybe (entryOf table) defs)) foreignEntries)

||| Whole-program table built once from the post-MutualLoop/pre-Loop def
||| list, threaded into every applyLoop call. A position is `TPrim` where the
||| callee's own body reads that parameter as an `ROp`/`RCmpCase` operand
||| (from that one body alone, never another entry), `TPtr` where it is a
||| raw pointer (`ptrCalleeTable`). MutualLoop-merged dispatchers are
||| excluded via isMutualLoopMerged (never a valid call target).
export covering
buildCalleeTable : List (Name, RCDef) -> CalleeTable
buildCalleeTable defs =
    mergeWith (zipWith (\a, b => a <|> b))
      (fromList $ mapMaybe (\(n, d) => if isMutualLoopMerged n then Nothing else map (n,) (primCallee d)) defs)
      (ptrCalleeTable defs)

||| The single native type at which parameter `p` is read: as an operand, or
||| fed to a callee `table` says reads that position natively (a scalar or a
||| raw pointer) -- `Nothing` for no reads, or conflicting ones. The class
||| `MutualLoop` shares slots by, so it must be the very question `applyLoop`
||| asks of each member.
export covering
callArgOrOpNativeTy : CalleeTable -> Int -> RCExp -> Maybe NativeTy
callArgOrOpNativeTy table p body =
    let calls = maybe empty id (lookup p (callArgNativeReadsFor (tableLookup table) (SortedSet.singleton p) body))
        ops = SortedSet.fromList (map TPrim (Prelude.toList (nativeArgTypes p body)))
    in case Prelude.toList (ops `union` calls) of
            [ty] => Just ty
            _ => Nothing
