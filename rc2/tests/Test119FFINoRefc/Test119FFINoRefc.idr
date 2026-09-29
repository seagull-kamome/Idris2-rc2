module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- %foreign calls real RefC cannot build: a String aliasing its GCAnyPtr argument, a const char * return.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test119FFINoRefc.GCPtrAliasString
import Test119FFINoRefc.ConstCFStringReturn

main : IO ()
main = do
    GCPtrAliasString.run
    ConstCFStringReturn.run
