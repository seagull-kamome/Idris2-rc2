module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- World arity raising: a world parameter, cancelling the world and an unplanned tail call.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test171ArityRaiseCases.ArityRaiseWorldParam
import Test171ArityRaiseCases.ArityRaiseCancelWorld
import Test171ArityRaiseCases.ArityRaiseUnplannedTail

main : IO ()
main = do
    ArityRaiseWorldParam.run
    ArityRaiseCancelWorld.run
    ArityRaiseUnplannedTail.run
