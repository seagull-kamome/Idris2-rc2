||| Blanks out a bound variable id to `deadId` (`0`) -- `Compiler.RC2.Util`'s own
||| `VarId` counter starts at 1 specifically so `0` is never a genuine
||| variable id anywhere in the program, see that module's own doc
||| comment -- wherever it turns out to be referenced nowhere at all in
||| its own binding's body: not read, not even dropped.
|||
||| Currently `RConAlt`'s own destructured fields (see
||| `rc2/doc/dead-vars.md` for the motivating case), and, before that,
||| `let x = <constant>` with the `dup`s and `drop`s of `x`
||| (`propagateConstAliases`, "Constant aliases" there). Written generally
||| enough -- the module's own name, `eraseDeadVars`'s own whole-tree
||| structural walk -- to grow into whatever other binding site turns
||| out to need the same treatment later, without needing a rename.
|||
||| It fires for a *native*-classified field (never drop-tracked at all,
||| see `Compiler.RC2.RC`'s own `definitionNatives`) whose one and only
||| use got optimised away by a later pass, and also for the ordinary
||| "record pattern match, only using some fields" case: for a
||| non-reuse-eligible match, the fields kept get an explicit `dup` and
||| the *whole* scrutinee gets one plain `drop` afterward, relying on
||| that drop's recursive teardown to release the rest, so
||| `annotate`'s per-field `RDrop` does not survive to Emit. The
||| `freeLocalsR`-over-the-final-body check below doesn't care *why* a
||| field ended up unreferenced, only whether it is.
|||
||| Runs after `Compiler.RC2.DupMerge` and `Compiler.RC2.LeafTail`: every pass that renames or freshens a
||| variable id (`Compiler.RC2.Loop`/`MutualLoop`/`LateInline`/
||| `SpecClosure`/`DualABI`) has already had its turn by then, so a `0`
||| placed here is never at risk of being renamed into a genuine id
||| afterward. Disable with `--directive nodeadvars`, or only the constant
||| aliases with `--directive noconstalias`.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.DeadVars

import Compiler.RC2.RCExp
import Compiler.RC2.Rewrite
import Compiler.RC2.Types

import Core.TT

import Data.List
import Data.Maybe
import Data.SortedMap
import Data.SortedSet

%default covering

||| `args`, but with every entry `used` doesn't contain -- genuinely
||| referenced nowhere in the definition, not even by an `RDrop` --
||| replaced by `0`.
|||
||| `used` is `RCExp.mentionedLocals` over the *whole* definition,
||| computed once by `applyDeadVars` below, after the constant aliases are
||| propagated (that pass rewrites uses), rather than per alt. Asking
||| per alt instead (`freeLocalsR` of that alt's own body) re-walks everything below
||| each alt once per level of case nesting, which real pattern
||| matching produces a lot of, and dominates the pass's own time.
||| One whole-definition set answers the same question because every
||| local id within a definition is unique (see `mentionedLocals`'s own
||| doc comment), and erasing a field only ever rewrites a *binder*,
||| never a use, so no erasure this pass performs can invalidate the
||| set it started from.
eraseDeadConAltFields : SortedSet RCLocal -> List Int -> List Int
eraseDeadConAltFields used args =
    map (\i => if contains (RCLoc i) used then i else deadId) args

eraseDeadVars : SortedSet RCLocal -> RCExp -> RCExp
eraseDeadVars used (RLet fc var rep value body) =
    RLet fc var rep (eraseDeadVars used value) (eraseDeadVars used body)
eraseDeadVars used (RCmpCase fc op args postDrop t f) =
    RCmpCase fc op args postDrop (eraseDeadVars used t) (eraseDeadVars used f)
eraseDeadVars used (RConCase fc sc alts mDef) =
    RConCase fc sc
      (map (\(MkRConAlt n ci tag args body) =>
              MkRConAlt n ci tag (eraseDeadConAltFields used args) (eraseDeadVars used body)) alts)
      (map (eraseDeadVars used) mDef)
eraseDeadVars used (RConstCase fc sc alts mDef) =
    RConstCase fc sc (map (\(MkRConstAlt c body) => MkRConstAlt c (eraseDeadVars used body)) alts)
      (map (eraseDeadVars used) mDef)
eraseDeadVars used (RLoop {sameLen} fc loopParams initial prologueDrop body) =
    RLoop fc loopParams initial prologueDrop (eraseDeadVars used body)
eraseDeadVars used (RDup fc v extra body) = RDup fc v extra (eraseDeadVars used body)
eraseDeadVars used (RDrop fc vs body) = RDrop fc vs (eraseDeadVars used body)
eraseDeadVars used (RFree fc v body) = RFree fc v (eraseDeadVars used body)
eraseDeadVars used (RReleaseReuse fc v body) = RReleaseReuse fc v (eraseDeadVars used body)
eraseDeadVars used (RReuseOffer fc sc dupOnShared dropOnUnique body) =
    RReuseOffer fc sc dupOnShared dropOnUnique (eraseDeadVars used body)
eraseDeadVars used (RMemoize fc n rep body) = RMemoize fc n rep (eraseDeadVars used body)
-- Every other constructor is a leaf as far as this walk is concerned
-- (no RConAlt reachable inside one without going through an RCExp
-- child already covered above).
eraseDeadVars _ e = e

||| A constant whose every read is NULL, an immediate or an immortal static,
||| so reading it needs no `dup` and dropping it does nothing. A `Double`, an
||| `Int64`/`Integer` outside the immediate range and a `Bits64` above 2^63 are
||| native literals that `rcVarToBoxedC` boxes with a fresh allocation at every
||| read: a variable bound to one owns a cell and must keep its `dup`s and
||| `drop`s. See `rc2/doc/dead-vars.md`, "Constant aliases".
safeConst : RCLocal -> Bool
safeConst (RCLoc _) = False
safeConst (RCConst c) = case c of
    BI x => immInt64 x
    I x => immInt64 (cast x)
    I64 x => immInt64 (cast x)
    B64 x => x < 9223372036854775808
    Db _ => False
    _ => True
safeConst _ = True

||| A `let` of this `Rep` reads the same wherever its constant is read instead.
||| A pointer is held natively as an `IDRIS2RC2_Raw *`, and boxing it
||| (`idris2rc2_mkPtr`) gives a tagged word, so a null pointer reads as that
||| word when boxed, where the constant `RCNull` reads as a plain `NULL`.
plainRep : Rep -> Bool
plainRep RBoxed = True
plainRep (RNative (TPrim _)) = True
plainRep (RInlineNative (TPrim _)) = True
plainRep _ = False

isConstLocal : RCLocal -> Bool
isConstLocal (RCLoc _) = False
isConstLocal _ = True

||| The locals a node reads in a position that needs a variable and cannot
||| take a constant: a `case` scrutinee, a cell or struct that is written or
||| read, a reuse token, a forced or applied value. A loop parameter shares
||| its id with the variable that starts it, so that variable stays too.
needsVariable : RCExp -> List RCLocal
needsVariable (RConCase _ sc _ _) = [sc]
needsVariable (RConstCase _ sc _ _) = [sc]
needsVariable (RStructGet _ sv _ _) = [sv]
needsVariable (RStructSet _ sv _ _ _) = [sv]
needsVariable (RFill _ cell _ _ _) = [cell]
needsVariable (RForce _ _ v _) = [v]
needsVariable (RApp _ _ c _) = [c]
needsVariable (RReuseOffer _ sc ds us _) = sc :: ds ++ us
needsVariable (RReleaseReuse _ v _) = [v]
needsVariable (RCon _ _ _ _ _ reuseFrom) = toList reuseFrom
needsVariable (RLoop _ ps _ _ _) = map (RCLoc . fst) ps
needsVariable _ = []

||| Every `let x = <safe constant>` of `e`, and every local read where a
||| variable is needed.
collectAliases : RCExp -> (List (Int, RCLocal), List RCLocal)
collectAliases e =
    let (as, bs) = unzip (map collectAliases (children e))
        own = case e of
                   RLet _ x rep (RV _ c) _ => if plainRep rep && safeConst c then [(x, c)] else []
                   _ => []
    in (own ++ concat as, needsVariable e ++ concat bs)

||| `e` without the aliases `ren` names, their `let`s removed.
dropAliasLets : SortedMap Int RCLocal -> RCExp -> RCExp
dropAliasLets ren e =
    case mapChildren (dropAliasLets ren) e of
         e'@(RLet _ x _ (RV _ _) body) => if isJust (lookup x ren) then body else e'
         e' => e'

||| The `dup`s, `drop`s and `free`s that read a constant, and the constants
||| in the `postDrop` lists, removed: they do nothing, and `Emit` reads those
||| lists as variables only.
dropConstOwnership : RCExp -> RCExp
dropConstOwnership e = clean (mapChildren dropConstOwnership e)
  where
    keep : List RCLocal -> List RCLocal
    keep = filter (not . isConstLocal)

    clean : RCExp -> RCExp
    clean (RDup fc v extra k) = if isConstLocal v then k else RDup fc v extra k
    clean (RFree fc v k) = if isConstLocal v then k else RFree fc v k
    clean (RDrop fc vs k) = case keep vs of
                                 [] => k
                                 vs' => RDrop fc vs' k
    clean (ROp fc lz op args pd) = ROp fc lz op args (keep pd)
    clean (RExtPrim fc lz p args pd) = RExtPrim fc lz p args (keep pd)
    clean (RStructGet fc sv sf pd) = RStructGet fc sv sf (keep pd)
    clean (RStructSet fc sv sf value pd) = RStructSet fc sv sf value (keep pd)
    clean (RFill fc cell k value pd) = RFill fc cell k value (keep pd)
    clean (RForce fc lr v pd) = RForce fc lr v (keep pd)
    clean (RCmpCase fc op args pd t f) = RCmpCase fc op args (keep pd) t f
    clean (RAppNameRep {sameLen} fc n argReps retRep pd args) = RAppNameRep fc n argReps retRep (keep pd) args
    clean (RAppFFIInline fc ccs fargs ret pd args) = RAppFFIInline fc ccs fargs ret (keep pd) args
    clean (RLoopContinue fc args pd) = RLoopContinue fc args (keep pd)
    clean (RLoop {sameLen} fc ps initial pd k) = RLoop fc ps initial (keep pd) k
    clean e' = e'

||| The ids that occur more than once in `ids`.
duplicateIds : List Int -> SortedSet Int
duplicateIds ids = snd (foldl (\(seen, dups), x => if contains x seen then (seen, insert x dups) else (insert x seen, dups))
                             (the (SortedSet Int) empty, the (SortedSet Int) empty) ids)

||| Replaces each variable bound to a safe constant by the constant, removes
||| its `let` and its `dup`s and `drop`s. A variable read where one is needed
||| keeps its `let`. Repeated, since replacing one alias can make another
||| `let` a constant. See `rc2/doc/dead-vars.md`, "Constant aliases".
propagateConstAliases : RCExp -> RCExp
propagateConstAliases = go (the Nat 3)
  where
    go : Nat -> RCExp -> RCExp
    go Z e = e
    go (S k) e =
        let (aliases, blocked) = collectAliases e
            blockedIds = SortedSet.fromList (mapMaybe (\l => case l of
                                                                  RCLoc i => Just i
                                                                  _ => Nothing) blocked)
            ids = map fst aliases
            twice = duplicateIds ids
            ren = SortedMap.fromList (filter (\(x, _) => not (contains x blockedIds || contains x twice)) aliases)
        in if null ren
              then e
              else go k (dropConstOwnership
                           (mapLocalsRCExp (\l => case l of
                                                      RCLoc i => fromMaybe l (lookup i ren)
                                                      _ => l) id
                                           (dropAliasLets ren e)))

||| Apply dead-variable erasure to one top-level definition, after the
||| constant aliases are propagated when `constAlias` holds.
export
applyDeadVars : (constAlias : Bool) -> RCDef -> RCDef
applyDeadVars ca (MkRCFun args retRep isWorker body) =
    let body' = if ca then propagateConstAliases body else body
    in MkRCFun args retRep isWorker (eraseDeadVars (mentionedLocals body') body')
applyDeadVars ca (MkRCError body) =
    let body' = if ca then propagateConstAliases body else body
    in MkRCError (eraseDeadVars (mentionedLocals body') body')
applyDeadVars _ d@(MkRCCon _ _ _) = d
applyDeadVars _ d@(MkRCForeign _ _ _) = d
