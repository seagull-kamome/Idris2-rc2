module Main

-- Exercises idris2rc2_tailcallApplyClosure's unique (refCount==1) in-place
-- growth path: each intermediate partial application here is consumed
-- exactly once and dies immediately, so every step after the first
-- extends the same closure allocation in place rather than copying.
add4 : Int -> Int -> Int -> Int -> Int
add4 a b c d = a + b + c + d

main : IO ()
main = do
  -- unique chain: f, g, h are each used exactly once then dead.
  let f = add4 1
      g = f 2
      h = g 3
  printLn (h 4)

  -- shared closure: `shared` is applied from two call sites, forcing
  -- the non-unique (copy+dup) path to fire at least once.
  let shared = add4 10 20
  printLn (shared 1 2)
  printLn (shared 3 4)
