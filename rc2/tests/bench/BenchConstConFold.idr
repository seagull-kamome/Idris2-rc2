module Main

-- Compiler.RC2.ConstFold's own RCConstCon folding: `constList` is a
-- constant constructor chain that folds to a single immortal static
-- (Compiler.RC2.Emit's ConstConDef) instead of being rebuilt on every
-- evaluation. Real RefC allocates all ten cons cells fresh on every
-- one of the loop's three million iterations.

constList : List Int
constList = [1,2,3,4,5,6,7,8,9,10]

sumList : List Int -> Int
sumList [] = 0
sumList (x :: xs) = x + sumList xs

loop : Int -> Int -> Int
loop acc 0 = acc
loop acc n = loop (acc + sumList constList) (n - 1)

main : IO ()
main = printLn (loop 0 3000000)
