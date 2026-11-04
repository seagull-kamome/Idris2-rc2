module Main

step : Int -> Int -> Either String Int
step 0 x = if x < 0 then Left "neg" else Right x
step d x = case step (d - 1) (x + 1) of
             Left e => Left e
             Right v => Right (v + 1)

keep : Int -> Int -> List Int -> List Int
keep n m acc =
  let r = step n (n - 3)
      k = m * 7 + n
  in case r of
          Left _ => k :: acc
          Right v => if v > 100 then acc else (v + k) :: acc

sumAll : List Int -> Int
sumAll [] = 0
sumAll (x :: xs) = x + sumAll xs

main : IO ()
main = do
  printLn (sumAll (keep 2 3 (keep 5 4 [])))
  printLn (sumAll (keep 1 9 (keep 0 2 (keep 200 5 []))))
  printLn (length (keep 3 1 (keep 1 6 [7])))
