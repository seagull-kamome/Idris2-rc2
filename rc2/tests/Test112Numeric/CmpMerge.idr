module Test112Numeric.CmpMerge

-- Two nested comparisons of the same operands become one: `x < y` then
-- `x == y` with equal branches is `x <= y`, likewise `>`/`>=`, in either
-- order and either operand order (Compiler.RC2.CmpMerge,
-- rc2/doc/native-type-inference.md "Merging nested comparisons"). Int,
-- Integer (immediate and heap), String, Char, Double (with NaN,
-- infinities and -0.0) and Nat; the `compare`-based `<=`/`>=`; shapes that
-- must NOT merge (different branches, different operands). Every operand
-- is read from a list, so nothing folds away.

import Data.List
import Data.String

ints : List Int
ints = [0, 1, 2, -1, 4611686018427387903, 4611686018427387904, -4611686018427387905]

integers : List Integer
integers = [0, 1, -1, 2305843009213693951, 2305843009213693952, -2305843009213693953, 340282366920938463463374607431768211456]

strings : List String
strings = ["", "a", "ab", "b", "B", "abc"]

chars : List Char
chars = ['a', 'b', 'A', '~', '\x1', 'z']

zeros : List Double
zeros = [0.0]

doubles : List Double
doubles = case zeros of
               [] => []
               (z :: _) => [0.0, -0.0, 1.0, -1.0, 2.5, 1.0 / z, -1.0 / z, z / z]

-- Shapes. Each function is called from exactly one place, so each
-- comparison appears once in the IR and check.sh can count it.

-- Int
iLeA, iLeB, iGeA, iGeB, iLeSw, iGeSw, iNegThen, iNegOps, iCollapse, iViaLE, iViaGE : Int -> Int -> Int -> Int
iLeA x y z = if x < y then 1 else if x == y then 1 else 2
iLeB x y z = if x == y then 1 else if x < y then 1 else 2
iGeA x y z = if x > y then 1 else if x == y then 1 else 2
iGeB x y z = if x == y then 1 else if x > y then 1 else 2
iLeSw x y z = if x < y then 1 else if y == x then 1 else 2
iGeSw x y z = if y > x then 1 else if x == y then 1 else 2
iNegThen x y z = if x < y then 1 else if x == y then 3 else 2
iNegOps x y z = if x < y then 1 else if x == z then 1 else 2
iCollapse x y z = if x < y then 1 else if x == y then 2 else 2
iViaLE x y z = if compare x y /= GT then 1 else 2
iViaGE x y z = if compare x y /= LT then 1 else 2

-- Branches that are equal only up to the names of the locals bound inside.
iAlpha : Int -> Int -> Int -> Int
iAlpha x y z = if x < y then (let k = x * 3 + z in k - y) else if x == y then (let m = x * 3 + z in m - y) else 0

intRow : Int -> Int -> Int -> String
intRow x y z = concatMap show [iLeA x y z, iLeB x y z, iGeA x y z, iGeB x y z, iLeSw x y z, iGeSw x y z, iNegThen x y z, iNegOps x y z, iCollapse x y z, iViaLE x y z, iViaGE x y z, iAlpha x y z]

-- Integer
gLeA, gLeB, gGeA, gGeB, gLeSw, gGeSw, gNegThen, gNegOps, gCollapse, gViaLE, gViaGE : Integer -> Integer -> Integer -> Int
gLeA x y z = if x < y then 1 else if x == y then 1 else 2
gLeB x y z = if x == y then 1 else if x < y then 1 else 2
gGeA x y z = if x > y then 1 else if x == y then 1 else 2
gGeB x y z = if x == y then 1 else if x > y then 1 else 2
gLeSw x y z = if x < y then 1 else if y == x then 1 else 2
gGeSw x y z = if y > x then 1 else if x == y then 1 else 2
gNegThen x y z = if x < y then 1 else if x == y then 3 else 2
gNegOps x y z = if x < y then 1 else if x == z then 1 else 2
gCollapse x y z = if x < y then 1 else if x == y then 2 else 2
gViaLE x y z = if compare x y /= GT then 1 else 2
gViaGE x y z = if compare x y /= LT then 1 else 2

integerRow : Integer -> Integer -> Integer -> String
integerRow x y z = concatMap show [gLeA x y z, gLeB x y z, gGeA x y z, gGeB x y z, gLeSw x y z, gGeSw x y z, gNegThen x y z, gNegOps x y z, gCollapse x y z, gViaLE x y z, gViaGE x y z]

-- String
sLeA, sLeB, sGeA, sGeB, sLeSw, sGeSw, sNegThen, sNegOps, sCollapse, sViaLE, sViaGE : String -> String -> String -> Int
sLeA x y z = if x < y then 1 else if x == y then 1 else 2
sLeB x y z = if x == y then 1 else if x < y then 1 else 2
sGeA x y z = if x > y then 1 else if x == y then 1 else 2
sGeB x y z = if x == y then 1 else if x > y then 1 else 2
sLeSw x y z = if x < y then 1 else if y == x then 1 else 2
sGeSw x y z = if y > x then 1 else if x == y then 1 else 2
sNegThen x y z = if x < y then 1 else if x == y then 3 else 2
sNegOps x y z = if x < y then 1 else if x == z then 1 else 2
sCollapse x y z = if x < y then 1 else if x == y then 2 else 2
sViaLE x y z = if compare x y /= GT then 1 else 2
sViaGE x y z = if compare x y /= LT then 1 else 2

stringRow : String -> String -> String -> String
stringRow x y z = concatMap show [sLeA x y z, sLeB x y z, sGeA x y z, sGeB x y z, sLeSw x y z, sGeSw x y z, sNegThen x y z, sNegOps x y z, sCollapse x y z, sViaLE x y z, sViaGE x y z]

-- Char
cLeA, cLeB, cGeA, cGeB, cLeSw, cGeSw, cNegThen, cNegOps, cCollapse, cViaLE, cViaGE : Char -> Char -> Char -> Int
cLeA x y z = if x < y then 1 else if x == y then 1 else 2
cLeB x y z = if x == y then 1 else if x < y then 1 else 2
cGeA x y z = if x > y then 1 else if x == y then 1 else 2
cGeB x y z = if x == y then 1 else if x > y then 1 else 2
cLeSw x y z = if x < y then 1 else if y == x then 1 else 2
cGeSw x y z = if y > x then 1 else if x == y then 1 else 2
cNegThen x y z = if x < y then 1 else if x == y then 3 else 2
cNegOps x y z = if x < y then 1 else if x == z then 1 else 2
cCollapse x y z = if x < y then 1 else if x == y then 2 else 2
cViaLE x y z = if compare x y /= GT then 1 else 2
cViaGE x y z = if compare x y /= LT then 1 else 2

charRow : Char -> Char -> Char -> String
charRow x y z = concatMap show [cLeA x y z, cLeB x y z, cGeA x y z, cGeB x y z, cLeSw x y z, cGeSw x y z, cNegThen x y z, cNegOps x y z, cCollapse x y z, cViaLE x y z, cViaGE x y z]

-- Double: NaN fails `<`, `==`, `<=`, `>`, `>=` alike, so the merge keeps every
-- result; the `-0.0 == 0.0` pair is equal.
dLeA, dLeB, dGeA, dGeB, dLeSw, dGeSw, dNegThen, dNegOps, dCollapse, dViaLE, dViaGE : Double -> Double -> Double -> Int
dLeA x y z = if x < y then 1 else if x == y then 1 else 2
dLeB x y z = if x == y then 1 else if x < y then 1 else 2
dGeA x y z = if x > y then 1 else if x == y then 1 else 2
dGeB x y z = if x == y then 1 else if x > y then 1 else 2
dLeSw x y z = if x < y then 1 else if y == x then 1 else 2
dGeSw x y z = if y > x then 1 else if x == y then 1 else 2
dNegThen x y z = if x < y then 1 else if x == y then 3 else 2
dNegOps x y z = if x < y then 1 else if x == z then 1 else 2
dCollapse x y z = if x < y then 1 else if x == y then 2 else 2
dViaLE x y z = if compare x y /= GT then 1 else 2
dViaGE x y z = if compare x y /= LT then 1 else 2

-- Branches that return -0.0 and 0.0 are not equal, whatever `==` says.
dSignedZero : Double -> Double -> Double
dSignedZero x y = if x < y then 0.0 else if x == y then -0.0 else 1.0

doubleRow : Double -> Double -> Double -> String
doubleRow x y z = concatMap show [dLeA x y z, dLeB x y z, dGeA x y z, dGeB x y z, dLeSw x y z, dGeSw x y z, dNegThen x y z, dNegOps x y z, dCollapse x y z, dViaLE x y z, dViaGE x y z] ++ show (the Int (if 1.0 / dSignedZero x y < 0.0 then 1 else 0))

-- Nat compares through Integer here; the shapes still have to agree with RefC.
nLe, nGe, nNeg : Nat -> Nat -> Int
nLe n m = if n < m then 1 else if n == m then 1 else 2
nGe n m = if n > m then 1 else if n == m then 1 else 2
nNeg n m = if n < m then 1 else if n == m then 3 else 2

natRow : Nat -> Nat -> String
natRow n m = concatMap show [nLe n m, nGe n m, nNeg n m, if compare n m /= GT then 1 else 2, if n <= m then 1 else 2, if n >= m then 1 else 2]

-- The merged comparison feeding a loop condition and an accumulator.
countLE : Int -> Int -> Int -> Int
countLE i n acc = if i < n then countLE (i + 1) n (acc + i) else if i == n then acc + 1000 else acc

export
run : IO ()
run = do
    putStrLn "-- cmpmerge Int"
    for_ ints $ \x => putStrLn (unwords [intRow x y z | y <- ints, z <- take 2 ints])
    putStrLn "-- cmpmerge Integer"
    for_ integers $ \x => putStrLn (unwords [integerRow x y z | y <- integers, z <- take 2 integers])
    putStrLn "-- cmpmerge String"
    for_ strings $ \x => putStrLn (unwords [stringRow x y z | y <- strings, z <- take 2 strings])
    putStrLn "-- cmpmerge Char"
    for_ chars $ \x => putStrLn (unwords [charRow x y z | y <- chars, z <- take 2 chars])
    putStrLn "-- cmpmerge Double"
    for_ doubles $ \x => putStrLn (unwords [doubleRow x y z | y <- doubles, z <- take 3 doubles])
    putStrLn "-- cmpmerge Nat"
    putStrLn (unwords [natRow n m | n <- [0, 1, 5, 4611686018427387904], m <- [0, 1, 5, 4611686018427387904, 18446744073709551616]])
    putStrLn "-- cmpmerge loop"
    printLn (countLE 0 100 0)
    printLn (countLE 100 100 0)
    printLn (countLE 101 100 0)
