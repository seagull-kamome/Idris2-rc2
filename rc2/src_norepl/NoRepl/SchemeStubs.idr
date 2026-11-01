||| What the Scheme evaluator of the compiler (`Core.SchemeEval`, reached from
||| the REPL's `Scheme` mode) calls on Chez Scheme. There is no Scheme here, so
||| each of these stops the program if it is ever called. See doc/norepl.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module NoRepl.SchemeStubs

import Libraries.Utils.Scheme

%foreign_impl Libraries.Utils.Scheme.prim__evalScheme
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim__evalOkay
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim__evalResult
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim__debugScheme
  "CExpr:abort(),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isNumber
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isInteger
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isFloat
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isChar
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isString
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isProcedure
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isSymbol
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isNil
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isPair
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isVector
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.prim_isBox
  "CExpr:((void)abort(), 0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeGetInteger
  "CExpr:((void)abort(), (void)($r)),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeGetString
  "CExpr:((void)abort(), (const char *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeGetFloat
  "CExpr:((void)abort(), 0.0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeGetChar
  "CExpr:((void)abort(), (char)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeFst
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeSnd
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeApply
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeForce
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeVectorRef
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeUnbox
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeVectorLength
  "CExpr:((void)abort(), (void)($r)),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeVectorToList
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.makeSymbol
  "CExpr:((void)abort(), (void *)0),libc,stdlib.h"
%foreign_impl Libraries.Utils.Scheme.unsafeReadSymbol
  "CExpr:((void)abort(), (const char *)0),libc,stdlib.h"
