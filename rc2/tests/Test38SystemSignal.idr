module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for System.Signal (idris_signal.c, a libidris2_support.a
-- fallback rc2 has no native port of): collectSignal registers
-- SIGUSR1 for collection instead of default handling, raiseSignal
-- sends it to this same process, handleNextCollectedSignal retrieves
-- it. Fully sequential (self-signal then immediately poll) -- no
-- concurrency, so no raciness.

import System.Signal

main : IO ()
main = do
  Right () <- collectSignal (SigPosix SigUser1)
    | Left err => putStrLn "collectSignal failed"
  putStrLn "collectSignal: ok"

  Right () <- raiseSignal (SigPosix SigUser1)
    | Left err => putStrLn "raiseSignal failed"
  putStrLn "raiseSignal: ok"

  Just sig <- handleNextCollectedSignal
    | Nothing => putStrLn "handleNextCollectedSignal: nothing pending"
  putStrLn ("collected signal is SigUser1: " ++ show (sig == SigPosix SigUser1))

  Nothing <- handleNextCollectedSignal
    | Just _ => putStrLn "unexpected extra pending signal"
  putStrLn "no more pending signals: ok"

  Right () <- defaultSignal (SigPosix SigUser1)
    | Left err => putStrLn "defaultSignal failed"
  putStrLn "defaultSignal: ok"

  putStrLn "done"
