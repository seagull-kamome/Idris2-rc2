module Test112Numeric.ImmediateInteger

-- Integer arithmetic around the edges of the immediate range, [-2^62, 2^62),
-- where results move between immediates and GMP values: every operation,
-- cast and case on both sides of each boundary, with negative operands.
-- Values come from a list so none of it folds at compile time.

import Data.Bits
import Data.List
import Data.String

p62 : Integer
p62 = 4611686018427387904

edges : List Integer
edges =
  [ 0, 1, -1, 7, -7, 99, 100, -100
  , p62 - 1, p62, p62 + 1, -p62 + 1, -p62, -p62 - 1
  , 2 * p62 - 1, 2 * p62, -2 * p62, -2 * p62 - 1
  , 4 * p62, -4 * p62, 12345678901234567890123, -12345678901234567890123 ]

divisors : List Integer
divisors = [1, -1, 2, -2, 3, -3, 7, -7, p62, -p62, p62 + 1, 4 * p62, -4 * p62 - 5]

line : String -> List Integer -> IO ()
line tag xs = putStrLn (tag ++ ": " ++ unwords (map show xs))

pairs : List Integer -> List Integer -> List (Integer, Integer)
pairs xs ys = [(x, y) | x <- xs, y <- ys]

arith : IO ()
arith = do
  let ps = pairs edges [0, 1, -1, p62 - 1, -p62, p62, 3 * p62, -3]
  line "add" (map (uncurry (+)) ps)
  line "sub" (map (uncurry (-)) ps)
  line "mul" (map (uncurry (*)) ps)
  line "neg" (map negate edges)
  line "abs" (map abs edges)

division : IO ()
division = do
  let ps = pairs edges divisors
  line "div" (map (uncurry div) ps)
  line "mod" (map (uncurry mod) ps)

bits : IO ()
bits = do
  let ps = pairs edges [0, -1, 1, 255, -256, p62 - 1, -p62, 4 * p62 + 3]
  line "and" (map (uncurry (.&.)) ps)
  line "or" (map (uncurry (.|.)) ps)
  line "xor" (map (uncurry xor) ps)
  let ss = pairs edges [0, 1, 2, 30, 60, 61, 62, 63, 64, 100]
  line "shl" (map (\(x, s) => prim__shl_Integer x s) ss)
  line "shr" (map (\(x, s) => prim__shr_Integer x s) ss)

compare' : IO ()
compare' = do
  let ps = pairs edges edges
  putStrLn ("cmp: " ++ pack (map (\(x, y) => case compare x y of LT => '<'; EQ => '='; GT => '>') ps))
  putStrLn ("eq: " ++ pack (map (\(x, y) => if x == y then '1' else '0') ps))

classify : Integer -> String
classify 0 = "zero"
classify 1 = "one"
classify (-1) = "minus one"
classify 4611686018427387903 = "top"
classify (-4611686018427387904) = "bottom"
classify 4611686018427387904 = "just past top"
classify 12345678901234567890123 = "big"
classify _ = "other"

casts : IO ()
casts = do
  putStrLn ("case: " ++ joinBy ", " (map classify edges))
  putStrLn ("i8: " ++ unwords (map (\x => show (the Int8 (cast x))) edges))
  putStrLn ("i16: " ++ unwords (map (\x => show (the Int16 (cast x))) edges))
  putStrLn ("i32: " ++ unwords (map (\x => show (the Int32 (cast x))) edges))
  putStrLn ("i64: " ++ unwords (map (\x => show (the Int64 (cast x))) edges))
  putStrLn ("int: " ++ unwords (map (\x => show (the Int (cast x))) edges))
  putStrLn ("b8: " ++ unwords (map (\x => show (the Bits8 (cast x))) edges))
  putStrLn ("b32: " ++ unwords (map (\x => show (the Bits32 (cast x))) edges))
  putStrLn ("b64: " ++ unwords (map (\x => show (the Bits64 (cast x))) edges))
  -- Read back as an Integer: the exact double, whatever show prints.
  line "dbl" (map (\x => cast (the Double (cast x))) edges)
  putStrLn ("chr: " ++ unwords (map (\x => show (ord (the Char (cast x)))) [0, 65, 0xD800, 0x10FFFF, 0x110000, -1, p62]))
  line "from-i64" (map cast [the Int64 0, -1, 9223372036854775807, -9223372036854775808, 4611686018427387904, -4611686018427387905])
  line "from-b64" (map cast [the Bits64 0, 4611686018427387903, 4611686018427387904, 18446744073709551615])
  line "from-int" (map cast [the Int 4611686018427387903, 4611686018427387904, -4611686018427387904, -4611686018427387905])
  line "from-dbl" (map cast [the Double 0.5, -0.5, -1.5, 4.611686018427388e18, -4.611686018427388e18, 1.0e30, -1.0e30])
  line "from-str" (map cast ["0", "-4611686018427387904", "4611686018427387904", "123456789012345678901234567890", "-7"])

nat : IO ()
nat = do
  let ns = the (List Nat) [0, 1, 5, 4611686018427387903, 4611686018427387904, 9999999999999999999999]
  putStrLn ("nat-minus: " ++ unwords [show (minus a b) | a <- ns, b <- ns])
  putStrLn ("nat-sum: " ++ show (foldl (+) 0 [the Nat 1 .. 100000]))
  putStrLn ("nat-pred: " ++ unwords (map (show . pred) ns))
  putStrLn ("fact25: " ++ show (product [the Integer 1 .. 25]))

export
run : IO ()
run = do
  arith
  division
  bits
  compare'
  casts
  nat
