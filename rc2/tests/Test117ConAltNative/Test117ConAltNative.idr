module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Compiler.RC2.ConAltNative (rc2/doc/con-alt-native.md): native shadows of destructured fields.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test117ConAltNative.ConAltNative
import Test117ConAltNative.ConAltNativeLeadingDup
import Test117ConAltNative.ConAltNativeConstCase

main : IO ()
main = do
    ConAltNative.run
    ConAltNativeLeadingDup.run
    ConAltNativeConstCase.run
