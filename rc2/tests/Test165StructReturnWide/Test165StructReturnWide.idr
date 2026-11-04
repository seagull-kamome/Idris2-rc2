module Main

record Five where
  constructor MkFive
  a, b, c, d, e : Int

record Eight where
  constructor MkEight
  a, b, c, d, e, f, g, h : String

rot5 : Int -> Five
rot5 0 = MkFive 1 2 3 4 5
rot5 n = case rot5 (n - 1) of
              MkFive a b c d e => MkFive b c d e (a + n)

rot8 : Nat -> Eight
rot8 Z = MkEight "a" "b" "c" "d" "e" "f" "g" "h"
rot8 (S k) = case rot8 k of
                  MkEight a b c d e f g h => MkEight b c d e f g h (a ++ "'")

show5 : Five -> String
show5 r = show [r.a, r.b, r.c, r.d, r.e]

show8 : Eight -> String
show8 r = concat [r.a, r.b, r.c, r.d, r.e, r.f, r.g, r.h]

main : IO ()
main = do
  putStrLn (show5 (rot5 0))
  putStrLn (show5 (rot5 3))
  putStrLn (show5 (rot5 100))
  putStrLn (show8 (rot8 0))
  putStrLn (show8 (rot8 3))
  putStrLn (show8 (rot8 9))
