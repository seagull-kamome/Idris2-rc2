module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Data.Queue's Semigroup/Monoid: appending keeps the dequeue order of both
-- queues, whatever mix of front and back lists each side holds.

import Data.Queue

-- A queue whose elements sit in both lists: the first `dequeue` moves nothing,
-- the later ones come from the back.
mixed : List Nat -> List Nat -> Queue Nat
mixed front back = foldl (flip enqueue) (fromList front) back

main : IO ()
main = do
  let a = mixed [1, 2] [3, 4]
      b = mixed [5] [6, 7]
  printLn (Queue.toList (a <+> b))
  printLn (Queue.toList (b <+> a))
  printLn (Queue.toList (a <+> neutral))
  printLn (Queue.toList (neutral <+> a))
  -- after appending, new elements still go to the end
  printLn (Queue.toList (enqueue 8 (a <+> b)))
  printLn (map fst (dequeue (a <+> b)))
  let c : Queue Nat = map (+ 1) (a <+> b)
  printLn (Queue.toList c)
