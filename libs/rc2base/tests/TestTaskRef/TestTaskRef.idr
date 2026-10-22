module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Ref with the actions of the tasks running on four threads
-- (runTaskParallel): no update is lost, and atomicModifyRef hands out each
-- number once.

import Control.Task
import Control.Task.Ref
import Control.Task.Scheduler
import Data.List

%default covering

repeatT : Nat -> Task () -> Task ()
repeatT Z _ = pure ()
repeatT (S n) t = t *> repeatT n t

-- Run the tasks together and collect what they give.
together : List (Task a) -> Task (List a)
together ts = traverse fork ts >>= traverse wait

main : IO ()
main = do
  r <- runTaskParallel 4 (do
         counter <- newRef (the Nat 0)
         _ <- together (replicate 8 (repeatT 200 (liftIO (pure ()) *> modifyRef counter S)))
         count <- readRef counter
         tickets <- newRef (the Nat 0)
         got <- together (replicate 8 (traverse (\_ => atomicModifyRef tickets (\n => (S n, n))) (the (List Nat) [1 .. 50])))
         pure (count, sort (concat got) == [0 .. 399]))
  putStrLn ("counter and tickets: " ++ show r)
