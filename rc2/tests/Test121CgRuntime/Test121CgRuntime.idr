module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- C code injected into the generated file: %cg rc2 extraRuntime=<path> and inlineRuntime=<code> (rc2/doc/directives.md).
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test121CgRuntime.CgExtraRuntime
import Test121CgRuntime.CgInlineRuntime

main : IO ()
main = do
    CgExtraRuntime.run
    CgInlineRuntime.run
