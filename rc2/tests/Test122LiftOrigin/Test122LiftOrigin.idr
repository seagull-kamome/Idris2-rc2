module Main

-- Lambda lifting records where each lifted definition came from
-- (rc2/doc/lambda-lifting.md). `check.sh` reads the `dumplifts` output:
-- a `Lazy` and an `Inf` delay, a delay of a lambda (just the lambda:
-- a value needs no thunk), and a lambda lifted out of
-- another lambda, both credited to the top-level definition. Each
-- function is called twice, so inlining a single caller's callee
-- doesn't move its lambdas into `main`.

%cg rc2 dumplifts

%noinline
lazyTwice : Lazy Int -> Int
lazyTwice x = x + x

%noinline
lazyValue : Int -> Int
lazyValue k = lazyTwice (Delay (k * 3))

%noinline
lazyAdder : Int -> Lazy (Int -> Int)
lazyAdder k = Delay (\x => x + k)

countFrom : Int -> Stream Int
countFrom n = n :: countFrom (n + 1)

%noinline
applyBoth : (Int -> Int) -> Int -> Int
applyBoth f x = f (f x)

%noinline
nested : Int -> Int
nested k = applyBoth (\y => applyBoth (\z => z * k + y) y) k

main : IO ()
main = do
    printLn (lazyValue 7)
    printLn (lazyValue 8)
    printLn (lazyAdder 5 10)
    printLn (lazyAdder 1 2)
    printLn (take 5 (countFrom 3))
    printLn (nested 2)
    printLn (nested 1)
