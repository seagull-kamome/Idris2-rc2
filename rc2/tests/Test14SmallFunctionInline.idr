module Main

-- Regression test for Compiler.RC2.Inline's own Criterion A: a small,
-- call-free top-level helper (`bump` below) gets spliced directly into
-- every one of its own call sites, rather than staying a genuine
-- function call -- verify with `--directive dumprcexp` that `bump`'s
-- own name never appears as a `callRep`/`call` target inside `loop`'s
-- own body once inlining has run (compare against
-- `--directive noinline`, where it still does). `--directive noinline`
-- also serves as this test's own A/B control: both builds must produce
-- identical, correct output and leak nothing, since inlining is only
-- ever supposed to change *how* the program is compiled, never *what*
-- it computes.
--
-- `acc` is pushed well outside the small-int cache range ([0,100),
-- immortal) so a real heap allocation -- and a real leak if this pass's
-- own substitution ever mishandles ownership -- is unavoidable; verify
-- with:
--   valgrind --leak-check=full ./build/exec/<this test's own output>
-- and expect "definitely lost: 0 bytes in 0 blocks".

bump : Int -> Int
bump x = x + 1

loop : Nat -> Int -> Int
loop Z acc = acc
loop (S k) acc = loop k (bump acc)

main : IO ()
main = printLn (loop 2000000 1000)
