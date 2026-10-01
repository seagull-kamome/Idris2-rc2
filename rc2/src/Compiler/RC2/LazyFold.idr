||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
|||
||| A local lazy value forced exactly once needs no cell: `let c = delay
||| thunk caps` whose only use is one `force c` becomes a call of `thunk`
||| at that force. Runs before RC annotation (no ownership yet) and before
||| loop conversion (a force inside a loop could otherwise run many times
||| for one binding). See doc/lazy-memoization.md, "`ConstFold`".
module Compiler.RC2.LazyFold

import Compiler.RC2.RCExp

import Core.TT

import Data.List

||| `e` with its one `force` of `c` replaced by a call of `thunk` on
||| `caps`, or `Nothing` if that use isn't a `force`.
replaceForce : Int -> Name -> List RCLocal -> RCExp -> Maybe RCExp
replaceForce c thunk caps e@(RForce fc _ v _) =
    if v == RCLoc c then Just (RAppName fc Nothing thunk caps) else Nothing
replaceForce c thunk caps (RLet fc var rep value body) =
    if countUsesR (RCLoc c) value > 0
       then (\v' => RLet fc var rep v' body) <$> replaceForce c thunk caps value
       else RLet fc var rep value <$> replaceForce c thunk caps body
replaceForce c thunk caps (RConCase fc sc alts mDef) =
    case break (\(MkRConAlt _ _ _ _ b) => countUsesR (RCLoc c) b > 0) alts of
         (before, MkRConAlt n ci tag as b :: after) =>
             (\b' => RConCase fc sc (before ++ MkRConAlt n ci tag as b' :: after) mDef) <$> replaceForce c thunk caps b
         (_, []) => RConCase fc sc alts . Just <$> (mDef >>= replaceForce c thunk caps)
replaceForce c thunk caps (RConstCase fc sc alts mDef) =
    case break (\(MkRConstAlt _ b) => countUsesR (RCLoc c) b > 0) alts of
         (before, MkRConstAlt k b :: after) =>
             (\b' => RConstCase fc sc (before ++ MkRConstAlt k b' :: after) mDef) <$> replaceForce c thunk caps b
         (_, []) => RConstCase fc sc alts . Just <$> (mDef >>= replaceForce c thunk caps)
replaceForce c thunk caps (RCmpCase fc op args pd t f) =
    if countUsesR (RCLoc c) t > 0
       then (\t' => RCmpCase fc op args pd t' f) <$> replaceForce c thunk caps t
       else RCmpCase fc op args pd t <$> replaceForce c thunk caps f
replaceForce _ _ _ _ = Nothing

||| Folds every single-force local `delay` in `e`.
export
foldSingleForce : RCExp -> RCExp
foldSingleForce (RLet fc c rep d@(RDelay _ _ thunk caps) body) =
    let body' = foldSingleForce body
    in if countUsesR (RCLoc c) body' == 1
          then case replaceForce c thunk caps body' of
                    Just b => b
                    Nothing => RLet fc c rep d body'
          else RLet fc c rep d body'
foldSingleForce e = mapChildren foldSingleForce e

export
foldSingleForceDef : RCDef -> RCDef
foldSingleForceDef (MkRCFun args r w body) = MkRCFun args r w (foldSingleForce body)
foldSingleForceDef d = d
