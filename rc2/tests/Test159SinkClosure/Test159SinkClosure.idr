module Main

import System

%noinline
add3 : Int -> Int -> Int -> Int
add3 a b c = a * 100 + b * 10 + c

%noinline
pick : Int -> Maybe Int -> (Int -> Int -> Int)
pick k m =
  let f = add3 k
  in case m of
          Nothing => f
          Just j => \x, y => x + y + j

%noinline
both : Int -> Maybe Int -> Int
both k m =
  let f = add3 k
  in case m of
          Nothing => f 1 2
          Just j => f j 3

%noinline
tag : String -> Int -> Int -> String
tag s a b = s ++ show a ++ show b

%noinline
pickStr : String -> Maybe Int -> (Int -> Int -> String)
pickStr s m =
  let f = tag s
  in case m of
          Nothing => f
          Just j => \x, y => show (x + y + j)

%noinline
lazyStr : String -> Maybe Int -> Lazy String
lazyStr s m =
  let d = delay (s ++ "!")
  in case m of
          Nothing => delay (force d ++ force d)
          Just j => delay (show j)

main : IO ()
main = do
  args <- getArgs
  let k = cast {to = Int} (length args)
  let s = "s" ++ show k
  printLn (pick k Nothing 4 5)
  printLn (pick k (Just 7) 4 5)
  printLn (both k Nothing)
  printLn (both k (Just 6))
  putStrLn (pickStr s Nothing 4 5)
  putStrLn (pickStr s (Just 7) 4 5)
  putStrLn (force (lazyStr s Nothing))
  putStrLn (force (lazyStr s (Just 3)))
