module Main

import Data.IORef

-- Regression guard for the CRITICAL CONSTRAINT of the
-- idris2rc2_applyClosure fast path added alongside this test:
-- idris2rc2_tailcallApplyClosure itself must keep returning an
-- undispatched closure at tail position, even for a non-unique
-- (shared) closure, so deep tail recursion through closures stays
-- bounded C stack via idris2rc2_trampoline's own while loop rather
-- than recursing.
--
-- `ref` ties the classic self-referential-IORef knot: it holds
-- `loop ref` itself, so every `readIORef ref` inside `loop`'s own body
-- returns a dup of a closure whose original copy is retained by `ref`
-- forever -- i.e. genuinely non-unique (refcount >= 2) on every single
-- iteration, not just the first. Applying it with its one remaining
-- argument is thus exactly the shape the new fast path targets --
-- except this application is in TAIL position (`(...) (n - 1)` is
-- `loop`'s own return value), so it must go through
-- idris2rc2_tailcallApplyClosure directly, never through
-- idris2rc2_applyClosure/the new fast path at all (confirmed during
-- development: instrumenting idris2rc2_dispatchWithExtra showed zero
-- calls for this test). If a future change mistakenly routed
-- non-unique tail-position dispatch into eager evaluation, this would
-- turn into genuine unbounded C-stack recursion and crash well before
-- 10 million iterations.
--
-- 10,000,000 iterations (well above the "5-10 million" floor) run in
-- ~2.3s on the dev machine -- fast enough to run outside valgrind
-- every time; not added to verify.sh's LEAK_SENSITIVE_TESTS since
-- valgrind's per-allocation overhead would make 10M malloc/free pairs
-- prohibitively slow for routine runs.
covering
loop : IORef (Int -> Int) -> Int -> Int
loop ref n =
    if n <= 0
       then n
       else (unsafePerformIO (readIORef ref)) (n - 1)

main : IO ()
main = do
    ref <- newIORef (\_ => 0)
    writeIORef ref (loop ref)
    printLn (loop ref 5)
    printLn (loop ref 10000000)
