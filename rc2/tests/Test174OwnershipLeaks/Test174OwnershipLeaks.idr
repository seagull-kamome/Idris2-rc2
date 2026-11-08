module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Ownership regressions found by valgrind: a wrapper reading a boxed parameter natively, IORef ExtPrim arguments, a reused operand inlined into an op and an ExtPrim literal.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test174OwnershipLeaks.DualABILeak
import Test174OwnershipLeaks.IORefExtPrimLeak
import Test174OwnershipLeaks.ReuseOpInlineOperand
import Test174OwnershipLeaks.ExtPrimLiteral

main : IO ()
main = do
    DualABILeak.run
    IORefExtPrimLeak.run
    ReuseOpInlineOperand.run
    ExtPrimLiteral.run
