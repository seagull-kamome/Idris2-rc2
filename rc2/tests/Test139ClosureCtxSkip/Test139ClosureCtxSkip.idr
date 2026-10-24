module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A difference list (rc2/doc/closure-accumulator.md) whose extension is made
-- before a branch and used by only some of the arms. The arm that passes the
-- old context on, applies it or ends the list does not use the extension, and
-- the cell built for it must be freed: valgrind (this test is in
-- LEAK_SENSITIVE_TESTS) must see no definitely lost bytes. The lists are built
-- at run time and long enough to run each arm several times.

%default covering

-- negative elements are skipped: the old context is passed on
skip : List Int -> (List Int -> List Int) -> List Int
skip [] c = c []
skip (x :: xs) c =
  let c' = c . (x ::)
  in if x < 0 then skip xs c else skip xs c'

-- ... and a large element applies the old context
stop : List Int -> (List Int -> List Int) -> List Int
stop [] c = c []
stop (x :: xs) c =
  let c' = c . (x ::)
  in if x < 0 then skip xs c else if x > 50 then c [x] else stop xs c'

-- ... and a zero drops the context
drop0 : List Int -> (List Int -> List Int) -> List Int
drop0 [] c = c []
drop0 (x :: xs) c =
  let c' = c . (x ::)
  in if x == 0 then [42] else if x < 0 then drop0 xs c else drop0 xs c'

input : Int -> List Int
input n = map (\k => if k `mod` 5 == 0 then negate k else k) [1 .. n]

main : IO ()
main = do
  printLn (skip (input 99) id)
  printLn (stop (input 99) id)
  printLn (drop0 (input 99) id)
  printLn (drop0 (0 :: input 20) id)
  printLn (length (skip (input 3000) id))
