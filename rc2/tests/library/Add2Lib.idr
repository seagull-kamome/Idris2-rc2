module Main

-- A library of two exported functions; Add2Lib.idr is this file with other names, so that the
-- two are compiled from identical definitions (and so get identical internal names).
-- The Idris `main` is never run.

%export "C:lib2_add_two"
add : Int -> Int -> Int
add x y = x + y

%export "C:lib2_greet"
greet : String -> String
greet s = "hi, " ++ s

%export "C:lib2_total"
mulAdd : Integer -> Integer -> Integer
mulAdd a b = a * b + 1

main : IO ()
main = putStrLn "never run"
