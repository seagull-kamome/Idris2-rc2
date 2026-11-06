module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Control.Task.Signal: a signal raised before the wait is taken at once, one
-- raised by another task wakes the wait, untilSignals gives the task up on a
-- signal (and returns its result when it ends first), a wait given up by a lost
-- race leaves the signal for the next one, two waits for one signal both end
-- (one takes it, the other waits for the next), and a bad signal is an error.

import Control.Task
import Control.Task.Scheduler
import Control.Task.Signal
import System.Linux.Signalfd
import System.Posix.Errno
import System.Posix.Signal

%default covering

raiseT : Signal -> Task ()
raiseT s = liftIO (ignore (raise s))

name : Either e SignalInfo -> String
name (Right i) =
  let n = the Int32 (cast i.signo)
  in if n == cast SIGUSR1 then "USR1" else if n == cast SIGUSR2 then "USR2" else "other"
name (Left _) = "error"

main : IO ()
main = do
  r <- runTask (do
    Right () <- liftIO (blockSignals [SIGUSR1, SIGUSR2])
      | Left _ => pure ["block failed"]
    raiseT SIGUSR1
    a <- awaitSignals [SIGUSR1]
    spawn (sleepFor 10 *> raiseT SIGUSR2)
    b <- awaitSignals [SIGUSR1, SIGUSR2]
    c <- untilSignals [SIGUSR1] (sleepFor 20 *> pure "finished")
    spawn (sleepFor 10 *> raiseT SIGUSR1)
    d <- untilSignals [SIGUSR1] (sleepFor 2000 *> pure "finished")
    e <- race (awaitSignals [SIGUSR2]) (sleepFor 10)
    raiseT SIGUSR2
    f <- awaitSignals [SIGUSR2]
    spawn (sleepFor 10 *> raiseT SIGUSR1 *> sleepFor 30 *> raiseT SIGUSR1)
    (g, h) <- both (awaitSignals [SIGUSR1]) (awaitSignals [SIGUSR1])
    i <- awaitSignals [MkSignal 0]
    pure [ "before the wait: " ++ name a
         , "raised by a task: " ++ name b
         , "task ends first: " ++ either (const "signal") id c
         , "signal first: " ++ either (\r => "signal " ++ name r) id d
         , "lost race: " ++ either (const "signal") (const "timer") e
         , "taken later: " ++ name f
         , "two waits: " ++ name g ++ " " ++ name h
         , "bad signal: " ++ name i ])
  traverse_ putStrLn (maybe ["no result"] id r)
