module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Loop conversion (Compiler.RC2.Loop, rc2/doc/loop-conversion.md): self-tail loops, their continuations, invariant and native-shadowed parameters.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test110Loop.SelfTailLoop
import Test110Loop.LoopContinuePostDrop
import Test110Loop.LoopInvariantParam
import Test110Loop.LoopCallArgNativeShadow
import Test110Loop.LoopConstClosureParam

main : IO ()
main = do
    SelfTailLoop.run
    LoopContinuePostDrop.run
    LoopInvariantParam.run
    LoopCallArgNativeShadow.run
    LoopConstClosureParam.run
