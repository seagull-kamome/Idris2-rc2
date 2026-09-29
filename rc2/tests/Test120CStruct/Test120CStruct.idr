module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- C structs declared elsewhere through %cg rc2 externStruct=<name> (rc2/doc/directives.md, section 5), read and written with getField/setField.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test120CStruct.CgExternStruct
import Test120CStruct.CgExternStructPtrField

main : IO ()
main = do
    CgExternStruct.run
    CgExternStructPtrField.run
