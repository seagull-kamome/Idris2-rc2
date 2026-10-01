module Main

-- A value whose evaluation needs itself stops the program instead of
-- running forever (rc2/doc/lazy-memoization.md). `loopy` is a top-level
-- `Delay`, so `Compiler.RC2.LazyCaf` makes it a memoized CAF that calls
-- itself; CAF memoization finds this thread already evaluating it and
-- stops with "a top-level value depends on itself". Nothing else is
-- printed: buffered stdout would land after the message.

loopy : Lazy Int
loopy = delay (force loopy + 1)

main : IO ()
main = printLn (force loopy)
