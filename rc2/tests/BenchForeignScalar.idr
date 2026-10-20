module Main

-- Loop variables and function parameters read only as %foreign scalar
-- arguments (TODO: native scalars across %foreign calls).
%foreign "CExpr:(($1) * 6364136223846793005LL + 1442695040888963407LL),libc,stdint.h"
prim__mix : Int -> Int

%foreign "CExpr:(($1) ^ ($2)),libc,stdint.h"
prim__xor : Int -> Int -> Int

loop : Int -> Int -> Int
loop k 0 = k
loop k n = loop (prim__mix k) (n - 1)

step : Int -> Int -> Int
step a b = if a == 0 then prim__xor a (b + 1) else prim__xor (prim__mix a) b

fold : Int -> Int -> Int
fold acc 0 = acc
fold acc n = fold (step acc n) (n - 1)

main : IO ()
main = do
  printLn (loop 1 400000000)
  printLn (fold 0 200000000)
