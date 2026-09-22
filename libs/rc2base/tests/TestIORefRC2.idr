module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Data.IORef.RC2's casIORef: success/failure, the witness value on
-- failure, and a retry-loop pattern with the witness feeding the next
-- attempt, over both a native (Int) and a Boxed (String) payload.

import Data.IORef
import Data.IORef.RC2

main : IO ()
main = do
  ref <- newIORef 1
  v1 <- readIORef ref
  r1 <- casIORef ref v1 2
  putStrLn "cas success: \{show r1}"
  putStrLn "value after: \{show !(readIORef ref)}"

  -- v1 is now stale (the ref moved on to 2) -- this compare must fail
  -- and hand back the actual current value as the witness.
  r2 <- casIORef ref v1 3
  putStrLn "cas failure: \{show r2}"
  putStrLn "value unchanged: \{show !(readIORef ref)}"

  let loop : Nat -> IO ()
      loop Z = putStrLn "loop exhausted"
      loop (S k) = do
        cur <- readIORef ref
        Nothing <- casIORef ref cur (cur + 100)
          | Just _ => loop k
        putStrLn "retry-loop result: \{show !(readIORef ref)}"
  loop 3

  sref <- newIORef "hello"
  sOld <- readIORef sref
  sRes <- casIORef sref sOld "world"
  putStrLn "string cas: \{show sRes}"
  putStrLn "string value after: \{!(readIORef sref)}"

  putStrLn "--- Tests finished ---"
