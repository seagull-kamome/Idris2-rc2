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

data W = MkW P String

glueW : W -> Nat -> String
glueW (MkW p s) Z = glue p 0 ++ s
glueW w (S k) = "<" ++ glueW w k

nested : Nat -> String
nested n = glueW (MkW (MkP (show n) "y") "z") 2 ++ "&"

data V = MkV P String

keepP : V -> Nat -> P
keepP (MkV p _) Z = p
keepP v (S k) = keepP v k

leaky : Nat -> String
leaky n = glue (keepP (MkV (MkP (show n) "q") "r") 2) 0 ++ "@"

kept : List P -> List P
kept xs = MkQ "k" :: xs

main : IO ()
main = do
  putStrLn (twice 5)
  putStrLn (once 7)
  putStrLn (twoLets 3)
  putStrLn (withDouble 4)
  putStrLn (nested 6)
  putStrLn (leaky 8)
  putStrLn (glue (MkQ "heap") 4)
  putStrLn (concat (map (\p => glue p 2) (kept [MkP "u" "v"])))
