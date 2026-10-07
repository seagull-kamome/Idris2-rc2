module Test112Numeric.BoxedCompare

-- A `case` on an Integer/String comparison (and so on Nat, which is
-- Integer here) is one fused `cmp` branch over the Boxed operands, a C
-- `int` with no Boxed Bool in between (rc2/doc/native-type-inference.md).
-- Immediate Integers, heap Integers past the 62-bit immediate range,
-- negatives, equal values, empty/prefix Strings (non-ASCII and NUL
-- bytes: Test124StringNul, which real RefC cannot run);
-- plain `if`, `&&`/`||`, `compare`-based shapes, loops and recursion.

import Data.List
import Data.String

-- Every operand is read out of a list, so it stays a Boxed local.
integers : List Integer
integers =
    [ 0, 1, -1, 7, -7
    , 2305843009213693951, 2305843009213693952, -2305843009213693952, -2305843009213693953
    , 4611686018427387903, 4611686018427387904, -4611686018427387905
    , 9223372036854775807, 9223372036854775808, -9223372036854775809
    , 340282366920938463463374607431768211456, -340282366920938463463374607431768211456
    , 340282366920938463463374607431768211457 ]

strings : List String
strings = ["", "a", "ab", "abc", "abd", "abcd", "b", "B", "ABC", " ", "\x1", "\x7f", "zzz", "abc "]

b : Bool -> String
b True = "T"
b False = "F"

lt5 : Integer -> Integer -> String
lt5 x y = (if x < y then "<" else "") ++ (if x == y then "=" else "")
       ++ (if x > y then ">" else "") ++ (if x <= y then "L" else "")
       ++ (if x >= y then "G" else "") ++ (if x /= y then "N" else "")

s5 : String -> String -> String
s5 x y = (if x < y then "<" else "") ++ (if x == y then "=" else "")
      ++ (if x > y then ">" else "") ++ (if x <= y then "L" else "")
      ++ (if x >= y then "G" else "") ++ (if x /= y then "N" else "")

-- `&&`/`||` over comparisons; the comparison result feeds another case.
conj : Integer -> Integer -> Integer -> String
conj x y z = b (x < y && y < z) ++ b (x < y || y < z) ++ b (x == y && y /= z) ++ b (not (x >= z) || y == z)

sconj : String -> String -> String -> String
sconj x y z = b (x < y && y < z) ++ b (x == y || y == z) ++ b (x /= y && y >= z)

-- `compare`-based shapes: `compare x y /= GT` is `<=`.
viaCompare : Integer -> Integer -> String
viaCompare x y = b (compare x y /= GT) ++ b (compare x y /= LT) ++ b (compare x y == EQ)

sviaCompare : String -> String -> String
sviaCompare x y = b (compare x y /= GT) ++ b (compare x y /= LT) ++ b (compare x y == EQ)

-- Nat is Integer at runtime.
nats : Nat -> Nat -> String
nats n m = b (n < m) ++ b (n == m) ++ b (n <= m) ++ b (n > m) ++ b (n >= m)

-- Loops: the comparison is the loop condition.
countUp : Integer -> Integer -> Integer -> Integer
countUp i n acc = if i < n then countUp (i + 1) n (acc + i) else acc

-- Past the immediate range: stepping a heap Integer up and down.
stepDown : Integer -> Integer -> Integer
stepDown x lim = if x > lim then stepDown (x - 1000000000000000000) lim else x

natLoop : Nat -> Nat -> Nat
natLoop i n = if i == n then i else natLoop (S i) n

sloop : List String -> String -> Nat -> Nat
sloop [] _ acc = acc
sloop (x :: xs) pivot acc = sloop xs pivot (if x < pivot then S acc else if x == pivot then acc + 100 else acc)

-- Recursion with the comparison on a value passed through.
maxInteger : List Integer -> Integer -> Integer
maxInteger [] m = m
maxInteger (x :: xs) m = maxInteger xs (if x > m then x else m)

minString : List String -> String -> String
minString [] m = m
minString (x :: xs) m = minString xs (if x <= m then x else m)

export
run : IO ()
run = do
    putStrLn "-- Integer"
    for_ integers $ \x => putStrLn (unwords (map (lt5 x) integers))
    putStrLn (unwords [conj x y z | x <- take 6 integers, y <- take 6 (drop 5 integers), z <- drop 12 integers])
    putStrLn (unwords [viaCompare x y | x <- integers, y <- integers])
    putStrLn "-- String"
    for_ strings $ \x => putStrLn (unwords (map (s5 x) strings))
    putStrLn (unwords [sconj x y z | x <- take 5 strings, y <- take 5 (drop 3 strings), z <- drop 10 strings])
    putStrLn (unwords [sviaCompare x y | x <- strings, y <- strings])
    putStrLn "-- Nat"
    putStrLn (unwords [nats n m | n <- [0, 1, 5, 4611686018427387904], m <- [0, 1, 5, 4611686018427387904, 18446744073709551616]])
    putStrLn "-- loops"
    printLn (countUp 0 1000 0)
    printLn (countUp (-5) 5 0)
    printLn (stepDown 9223372036854775807000 5)
    printLn (stepDown 3 5)
    printLn (natLoop 0 12345)
    printLn (sloop strings "abc" 0)
    printLn (sloop [] "x" 7)
    printLn (maxInteger integers (-340282366920938463463374607431768211457))
    printLn (maxInteger [] 3)
    printLn (show (minString strings "zzz"))
