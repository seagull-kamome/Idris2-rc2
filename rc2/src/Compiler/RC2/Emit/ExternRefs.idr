||| External-symbol reference walkers for incremental compilation.
||| Two `foldRCNamesD` (`Compiler.RC2.RCExp`) passes that collect the
||| symbols a translation unit's generated C references but may not
||| itself define -- untagged constructor names (dereferenced as
||| `idris2rc2_constr_<name>`) and directly-called / closure-built
||| function names. `Compiler.RC2.Emit.generateCSourceFile` turns their
||| union over a module's own `defs` into `extern` forward declarations.
||| Non-empty only under incremental compile (`Compiler.RC2.RC2`'s own
||| `incCompile`, where `defs` is a strict subset of the program); a
||| no-op set in whole-program mode, where `collectDeclarations` already
||| forward-declares every referenced symbol from that same `defs` list.
||| Lives here rather than in `Emit.idr` only to keep that module on
||| codegen -- pure analysis, no `Ref`s, nothing emitted.
module Compiler.RC2.Emit.ExternRefs
-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.RCExp

import Core.Name

import Data.SortedSet

%default covering

||| Every untagged constructor `Name` a def's own generated C
||| dereferences via `->name = idris2rc2_constr_<name>` -- both a
||| dynamic `RCon` construction (`Compiler.RC2.Emit`'s own
||| `createCFunctions` `RCon` case, `when (Nothing == tag) ...`) and a
||| `ConstFold`-folded `RCConstCon` literal
||| (`Emit.Util.boxedConstConExpr`'s own `nameField`) set this field
||| exactly when the constructor's own `tag` is `Nothing`. Whole-program
||| compilation never needs this -- every `MkRCCon` the program could
||| possibly reference already sits in the very same `defs` list
||| `collectDeclarations` forward-declares from -- only matters once a
||| module compiles against a strict subset of the program
||| (`Compiler.RC2.RC2`'s own `incCompile`, see
||| rc2/doc/incremental-compile.md), where the referenced constructor
||| may be owned by a module not present in `defs` at all (e.g.
||| `Prelude.Basics` references `Builtin.Void` this way with no
||| declaration anywhere in its own translation unit).
export
untaggedConstructorRefsD : RCDef -> SortedSet Name
untaggedConstructorRefsD =
    foldRCNamesD $ { onCon := \n, tag => maybe (singleton n) (const empty) tag } noRCNames

||| Every function `Name` a def's C references but might not define:
||| `RAppName` calls, `RUnderApp` closure builds, `RCConstClosure`s. A no-op
||| set in whole-program mode; matters once `defs` is one module's subset.
||| An `RAppName` carries the callee's true arity; a closure-value reference
||| gets 0 (consumed through an erased-signature cast). Why not bare K&R `()`
||| for all: C23 makes it `(void)`, so a 2-argument call is a hard error.
||| `generateCSourceFile` merges arities per name with `max`. See
||| `rc2/doc/incremental-compile.md`.
export
externalFunctionRefsD : RCDef -> List (Name, Nat)
externalFunctionRefsD =
    foldRCNamesD $ { onAppName      := \n, args => [(n, length args)]
                   , onUnderApp     := \n => [(n, 0)]
                   , onConstClosure := \n => [(n, 0)]
                   } noRCNames
