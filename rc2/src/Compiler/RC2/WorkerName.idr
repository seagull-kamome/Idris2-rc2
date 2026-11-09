||| How rc2 names the functions it synthesises: the tag of a `MutualLoop`-
||| merged function and the prefixes of the dual-ABI workers. The passes that
||| make the names and those that recognise them read the same constants.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.WorkerName

import Core.TT

import Data.String

%default total

||| The `MN` string of a function `Compiler.RC2.MutualLoop` merges a group
||| into: the producer (`MutualLoop`'s `freshName`) and `isMutualLoopMerged`
||| both read this, so they cannot drift apart.
export
mutualLoopTag : String
mutualLoopTag = "rc2_mutualLoop"

||| The prefix of an ordinary dual-ABI worker's name (`DualABI.freshName`), and
||| of an FFI worker's. `isMutualLoopWorker` recognises a worker by it.
export
workerPrefix, ffiWorkerPrefix : String
workerPrefix = "idris2rc2_worker_"
ffiWorkerPrefix = "idris2rc2_ffiworker_"

||| True for a name `Compiler.RC2.MutualLoop` itself synthesised (its
||| own merged function). Must never get a dual-ABI worker of its own --
||| a slot genuinely native for one group member can receive a literal
||| `RCNull` from a smaller-arity member's own caller. See
||| `rc2/doc/dual-abi.md`'s "A finding that changed Stage 3's own plan"
||| for the full story (the per-member *wrapper* functions need no such
||| exclusion -- their own trivial forwarding body already has nothing
||| eligible). A module of its own so that
||| `Compiler.RC2.CalleeTable` and `Loop` can use it without importing
||| `DualABI` (which imports `Loop`).
export
isMutualLoopMerged : Name -> Bool
isMutualLoopMerged (MN s _) = s == mutualLoopTag
isMutualLoopMerged _ = False

||| A struct-return worker synthesised for a `MutualLoop`-merged function
||| (`Compiler.RC2.DualABI.applyStructReturn`, `freshName`'s
||| `idris2rc2_worker_` + the merged function's C name). It is as
||| file-local as the merged function it stands for, so it shares its
||| `static` storage class.
|||
||| The worker's `MN` string is `workerPrefix` ++ the merged function's C name,
||| which `Emit.Util.cName` renders `<mutualLoopTag>_<id>` (both parts are plain
||| identifier characters, so `cCleanString` leaves them alone).
export
isMutualLoopWorker : Name -> Bool
isMutualLoopWorker (MN s _) = isPrefixOf (workerPrefix ++ mutualLoopTag ++ "_") s
isMutualLoopWorker _ = False
