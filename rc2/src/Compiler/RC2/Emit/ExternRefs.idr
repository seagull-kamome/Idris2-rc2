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
||| may be owned by a module not present in `defs` at all. Found via a
||| real `--inc rc2` prelude rebuild: `Prelude.Basics` references
||| `Builtin.Void` this way with no declaration anywhere in its own
||| translation unit, a plain "undeclared identifier" C compile error.
export
untaggedConstructorRefsD : RCDef -> SortedSet Name
untaggedConstructorRefsD =
    foldRCNamesD $ { onCon := \n, tag => maybe (singleton n) (const empty) tag } noRCNames

||| Every function `Name` a def's own generated C references but might
||| not itself define -- a direct call (`RAppName`), a partial-
||| application closure build (`RUnderApp`), or a `ConstFold`-folded
||| zero-capture closure (`RCConstClosure`). Same story as
||| `untaggedConstructorRefsD` above: a no-op set in whole-program mode
||| (`collectDeclarations` already forward-declares every one of these
||| from that very same `defs` list), only populated once `defs` is a
||| single module's own subset. Confirmed for real via the same
||| `--inc rc2` prelude rebuild that found `untaggedConstructorRefsD`'s
||| own gap: e.g. `Prelude.Num` calls `Prelude.EqOrd`'s own comparison
||| functions directly by name, with nothing declaring them in
||| `Prelude.Num`'s own translation unit ("implicit declaration of
||| function" C errors).
|||
||| An `RAppName` reference carries the exact arity its saturated call
||| site uses (the callee's true arity), so the wrapper is declared
||| `IDRIS2RC2_Value *(...N boxed pointers...)`. A name referenced only
||| as a function-pointer *value* (`RUnderApp`/`RCConstClosure`) gets
||| arity 0 -- harmless, since such a reference is always consumed
||| through an explicit erased-signature cast anyway
||| (`Emit.Util`'s `(IDRIS2RC2_Value *(*)())` closure-struct field).
||| A bare K&R `()` declaration for every case was tried first and
||| broke on this toolchain's C-standard default (bare `()` == `(void)`,
||| a real C23 change): a 2-argument call to a name declared that way is
||| a hard "too many arguments" error. `generateCSourceFile`'s own call
||| site resolves the two arities for one name with `max`, so the real
||| arity always wins over the placeholder 0 regardless of sighting
||| order.
export
externalFunctionRefsD : RCDef -> List (Name, Nat)
externalFunctionRefsD =
    foldRCNamesD $ { onAppName      := \n, args => [(n, length args)]
                   , onUnderApp     := \n => [(n, 0)]
                   , onConstClosure := \n => [(n, 0)]
                   } noRCNames
