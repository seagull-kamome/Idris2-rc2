||| Replaces a few upstream `%foreign` declarations by declarations of rc2's own
||| functions, once, when the program is turned into `RCDef`s. Everything after
||| that (the inliner, the dual ABI, the C emitter) sees an ordinary `RC2:`
||| declaration and needs to know nothing about the replacement.
|||
||| Why these functions are replaced, and how to add one: rc2/doc/fastpack-fix.md,
||| "What is replaced, and why".
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.ForeignDivert

import Compiler.RC2.RCExp

import Core.CompileExpr
import Core.TT

import Data.List

%default total

||| One replaced function: the module and base name of the upstream declaration,
||| the number of arguments it is declared with (the `%World` token of a `PrimIO`
||| included; a declaration with another number is not touched), and the rc2 C
||| function to call instead.
record Diverted where
  constructor MkDiverted
  modName : String
  baseName : String
  arity : Nat
  cFunction : String

||| The replaced functions. Two reasons (fastpack-fix.md): the result of
||| `fastPack`/`fastConcat` is a `char *` that the generic wrapper copies and
||| never frees (a leak); every other entry takes a String as a `char *`, or gives a
||| `char *` back, and loses the String's length at its first NUL byte.
diverted : List Diverted
diverted =
  [ MkDiverted "Prelude.Types" "fastPack" 1 "idris2rc2_fastPackFixed"
  , MkDiverted "Prelude.Types" "fastConcat" 1 "idris2rc2_fastConcatFixed"
  , MkDiverted "Prelude.Types" "fastUnpack" 1 "idris2rc2_fastUnpackFixed"
  , MkDiverted "Data.String.Iterator" "uncons" 2 "idris2rc2_stringIteratorNextFixed"
  , MkDiverted "Data.String.Iterator" "withIteratorString" 4 "idris2rc2_stringIteratorToStringFixed"
  , MkDiverted "Libraries.Data.String.Iterator" "uncons" 2 "idris2rc2_stringIteratorNextFixed"
  , MkDiverted "Libraries.Data.String.Iterator" "withIteratorString" 4 "idris2rc2_stringIteratorToStringFixed"
  , MkDiverted "Data.Buffer" "stringByteLength" 1 "idris2rc2_stringByteLengthFixed"
  , MkDiverted "Data.Buffer" "prim__setString" 4 "idris2rc2_setBufferStringFixed"
  , MkDiverted "Data.Buffer" "prim__getString" 4 "idris2rc2_getBufferStringFixed"
  ]

||| The C function that replaces the declaration `n`, if it is one of the list.
||| The full namespace is compared, not only the base name, so that a function of
||| the same name elsewhere is left alone.
export
divertedFunction : Name -> Nat -> Maybe String
divertedFunction (NS ns (UN (Basic f))) arity =
    map cFunction (find (\d => d.baseName == f && d.arity == arity && ns == mkNamespace d.modName) diverted)
divertedFunction _ _ = Nothing

||| An argument or a result that is passed on exactly as the boxed value it
||| already is: `CFUser` is the one `CFType` for which the wrapper neither converts
||| nor copies, and which the native-type passes never unbox.
opaque : CFType
opaque = CFUser (UN (Basic "RC2Value")) []

||| `d`, with its convention, argument types and result type replaced if it is
||| a declaration of the list. A `PrimIO` result stays a `PrimIO`, so the `%World`
||| token is still left out of the call, as for any other `PrimIO` declaration; the
||| replacement returns `NULL` for the unit.
export
divertForeign : Name -> RCDef -> RCDef
divertForeign n d@(MkRCForeign _ fargs ret) =
    case divertedFunction n (length fargs) of
         Nothing => d
         Just fn => MkRCForeign ["RC2:" ++ fn] (map (const opaque) fargs) (case ret of
                                                                            CFIORes _ => CFIORes opaque
                                                                            _ => opaque)
divertForeign _ d = d
