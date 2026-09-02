module Main

-- rc2-native replacement for upstream's own tests/refc/callingConvention
-- (its own awk inspection of RefC's generated C doesn't carry over to
-- rc2's structurally different codegen -- see
-- rc2/tests/refc-suite/README.md). Exercises the generated-C shapes
-- this test's own postrun.sh greps build/exec/test.c for directly:
-- Compiler.RC2.DualABI's worker/wrapper split, its FFI inline splicing
-- at both a non-tail and a tail call site (rc2/doc/dual-abi.md's
-- Stage 4/Stage 4b), and Compiler.RC2.Loop's goto conversion
-- (rc2/doc/loop-conversion.md).

%foreign "C:abs,libc,stdlib.h"
prim__abs : Int -> Int

-- Dual-ABI-eligible: every position (both args, the return) is a
-- native Int -- gets both a Boxed wrapper and a native worker.
eligibleAdd : Int -> Int -> Int
eligibleAdd x y = x + y

-- Dual-ABI-ineligible: a real (not call-free, so never
-- Compiler.RC2.Inline-eligible either) computation with a Boxed
-- String return -- never gets a worker.
ineligibleShow : Int -> String
ineligibleShow n = "value=" ++ show n

-- Self-tail-recursive: Compiler.RC2.Loop converts this into a
-- goto-based C loop rather than a real recursive call.
sumLoop : Int -> Int -> Int
sumLoop 0 acc = acc
sumLoop n acc = sumLoop (n - 1) (acc + n)

-- This function's own body is nothing but a tail call straight into
-- prim__abs -- exercises rc2/doc/dual-abi.md's Stage 4b: unlike a
-- tail call to an ordinary RC2 function worker, this one is still
-- spliced inline (not deferred via a boxed closure), since prim__abs
-- is a leaf as far as DualABI's own tail-call-deferral scheme is
-- concerned.
tailAbs : Int -> Int
tailAbs n = prim__abs n

main : IO ()
main = do
    -- Non-literal argument (avoids Compiler.RC2.Inline's own
    -- allLiteralArgs guard) at a non-tail call site (an operand of
    -- `+`) -- the shape DualABI's FFI inline splicing targets.
    let n : Int
        n = cast (String.length "hello")
    printLn (eligibleAdd 3 4 + prim__abs (n - 10))
    printLn (ineligibleShow 7)
    printLn (sumLoop 100000 0)
    -- Non-literal argument, same reasoning as above, at a tail call
    -- site this time (tailAbs's own entire body).
    printLn (tailAbs (n - 105))
