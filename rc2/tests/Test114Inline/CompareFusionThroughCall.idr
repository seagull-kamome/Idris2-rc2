module Test114Inline.CompareFusionThroughCall

-- Regression test for Compiler.RC2.Inline's own motivating gap:
-- `Compiler.RC2.RC`'s `tryFuseCompare` only fuses a *direct* primitive
-- comparison immediately consumed by a two-way Bool match into a single
-- native `RCmpCase` -- when the comparison is reached through an
-- interface method call instead (`step`'s own `acc <= 0`, via `Ord
-- Int`'s `<=`, a genuine, statically-resolved top-level function, not a
-- direct primitive at the `Lifted` level), this never fires on its own:
-- the comparison sits inside `<=`'s own separate definition, invisible
-- to `step`'s own fusion analysis.
--
-- `Compiler.RC2.Inline` closes this by splicing `Ord Int`'s own small,
-- call-free `<=` implementation directly into `step`'s own body before
-- `RC.idr`'s Phase 1 ever runs -- `tryFuseCompare` then sees a direct
-- comparison and fuses it. Two, cascading effects to check via
-- `--directive dumprcexp` (compare against `--directive noinline`,
-- where neither happens):
--   - `step`'s own worker body shows a single fused `cmp <=Int [...]`,
--     not a separate `callRep`/`call` to `Prelude.EqOrd.<=` followed by
--     a Boxed-Bool match.
--   - `step`'s own worker parameter, previously stuck `Boxed` (nothing
--     inside its own body read it in a native context, since the
--     comparison was an opaque call), is now itself native-shadowed
--     (`Native Int`) -- `Compiler.RC2.Loop`/`DualABI`'s own native-type
--     inference sees straight through to the fused comparison now that
--     there's no call boundary in the way.
--
-- `acc` starts well outside the small-int cache range ([0,100),
-- immortal) and only grows from there, so a real heap allocation -- and
-- a real leak if this pass's own case-of-case collapse or substitution
-- ever mishandles ownership -- is unavoidable on almost every iteration;
-- verify with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".

step : Int -> Int
step acc = if acc <= 0 then 1 else acc + 1

loop : Nat -> Int -> Int
loop Z acc = acc
loop (S k) acc = if acc == (-999999) then acc else loop k (step acc)

-- The same through `Ord Integer` and `Eq Integer`: the fused `cmp` here
-- is over Boxed Integer operands (doc/native-type-inference.md,
-- "Comparisons over Boxed operands"). The accumulator starts past the
-- 62-bit immediate range, so every comparison takes the heap path.
stepI : Integer -> Integer
stepI acc = if acc <= 0 then 1 else acc + 1

loopI : Nat -> Integer -> Integer
loopI Z acc = acc
loopI (S k) acc = if acc == (-999999999999999999999) then acc else loopI k (stepI acc)

export
run : IO ()
run = do
    printLn (loop 2000000 1)
    printLn (loopI 200000 4611686018427387000)
    printLn (loopI 20 (-4611686018427388000))
