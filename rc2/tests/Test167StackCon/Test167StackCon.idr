module Main

data P = MkP String String | MkQ String

glue : P -> Nat -> String
glue (MkP a b) Z = a ++ b
glue (MkQ a) Z = a
glue p (S k) = glue p k

twice : Nat -> String
twice n = let p = MkP (show n) "-x" in glue p 3 ++ "!" ++ glue p 1

once : Nat -> String
once n = glue (MkP "a" (show n)) 2 ++ "?"

twoLets : Nat -> String
twoLets n = glue (MkP (show n) (show (n + 1))) 1 ++ "#"

data D = MkD Double String

showD : D -> Nat -> String
showD (MkD d s) Z = s ++ show d
showD x (S k) = showD x k

withDouble : Nat -> String
withDouble n = showD (MkD 1.5 (show n)) 2 ++ "%"

kept : List P -> List P
kept xs = MkQ "k" :: xs

main : IO ()
main = do
  putStrLn (twice 5)
  putStrLn (once 7)
  putStrLn (twoLets 3)
  putStrLn (withDouble 4)
  putStrLn (glue (MkQ "heap") 4)
  putStrLn (concat (map (\p => glue p 2) (kept [MkP "u" "v"])))
