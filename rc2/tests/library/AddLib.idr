module Main

-- A library of two exported functions; Add2Lib.idr is this file with other names, so that the
-- two are compiled from identical definitions (and so get identical internal names).
-- The Idris `main` is never run.

%export "C:libadd_two"
add : Int -> Int -> Int
add x y = x + y

%export "C:libgreet"
greet : String -> String
greet s = "hello, " ++ s

%export "C:libtotal"
mulAdd : Integer -> Integer -> Integer
mulAdd a b = a * b + 1

main : IO ()
main = putStrLn "never run"
