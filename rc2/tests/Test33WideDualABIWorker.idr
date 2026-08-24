module Main

-- Regression test for Compiler.RC2.DualABI's own dual-ABI worker
-- synthesis with MORE than Compiler.RC2.Emit.MaxExtractFunArgs (8)
-- top-level parameters. Mirrors a real bug report: an externally-
-- sourced package had a lambda-lifted internal helper with 9+
-- free-variable parameters, at least one genuinely native-eligible --
-- this used to be excluded from dual-ABI eligibility entirely (see
-- TODO.md/this test's own history). `wideAdd` below has 10 parameters:
-- nine `Int`s (all used only via `+`, so all native-eligible) and one
-- `String` (used only via `length`, so stays Boxed) -- the exact
-- "mostly-native, one non-eligible, width > 8" shape the old
-- exclusion used to rule out unconditionally.
wideAdd : Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> Int -> String -> Int
wideAdd a b c d e f g h i tag =
  a + b + c + d + e + f + g + h + i + cast (length tag)

main : IO ()
main = do
  let r = wideAdd 1 2 3 4 5 6 7 8 9 "hello"
  putStrLn ("wideAdd result: " ++ show r)
