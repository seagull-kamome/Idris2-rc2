module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Constructor representation: ADTs mixing native and boxed fields, and nullary constructors as operands.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test173DataRep.ConstructorFields
import Test173DataRep.EmptyCon

main : IO ()
main = do
    ConstructorFields.run
    EmptyCon.run
