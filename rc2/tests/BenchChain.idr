module Main

-- A straight-line arithmetic *chain* (several sequential ops with no
-- function calls in between) is exactly the shape Compiler.RC2.Types
-- targets: every intermediate here stays a native int64_t in rc2, while
-- RefC boxes (mallocs) each one.
poly : Int -> Int
poly x =
  let a = x * x
      b = a * x
      c = b + a
      d = c - x
      e = d * 2
      f = e + 1
      g = f * f
  in g - a

loopPoly : Int -> Int -> Int
loopPoly acc 0 = acc
loopPoly acc n = loopPoly (acc + poly n) (n - 1)

main : IO ()
main = printLn (loopPoly 0 3000000)
