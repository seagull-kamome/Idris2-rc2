module Test84CgExternStruct.Pair

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Test84CgExternStruct's imported module: its own `externStruct`
-- directive has to reach the C file generated for Main as well.

import System.FFI

%cg rc2 externStruct=test_pair

public export
Pair : Type
Pair = Struct "test_pair" [("a", Double), ("b", Double)]

export
%foreign "C:idris2rc2_test84_make_pair,libc,Test84CgExternStruct.h"
prim__makePair : Double -> Double -> PrimIO Pair

export
%foreign "C:idris2rc2_test84_free_point,libc,Test84CgExternStruct.h"
prim__freePair : Pair -> PrimIO ()

export
sumPair : Pair -> Double
sumPair p = getField p "a" + getField p "b"
