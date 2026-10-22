||| First-in first-out lists of waiting operations, for the primitives that make
||| tasks wait for each other (`Control.Task.MVar`, `Control.Task.Chan`). Each
||| waiter has a number, so that a wait that is given up can leave the line. A
||| `Waiters` is kept in an `IORef` that only the thread of the scheduler touches.
module Control.Task.Waiters

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.SortedMap

%default total

export
record Waiters a where
  constructor MkWaiters
  next : Nat
  line : SortedMap Nat a

export
none : Waiters a
none = MkWaiters 0 empty

||| Put a waiter at the end of the line; its number is what `leave` takes.
export
enter : a -> Waiters a -> (Nat, Waiters a)
enter w (MkWaiters n line) = (n, MkWaiters (S n) (insert n w line))

||| Take the waiter at the front.
export
front : Waiters a -> Maybe (a, Waiters a)
front (MkWaiters n line) = map (\(k, w) => (w, MkWaiters n (delete k line))) (leftMost line)

||| Everyone waiting, in order, and an empty line.
export
everyone : Waiters a -> (List a, Waiters a)
everyone (MkWaiters n line) = (values line, MkWaiters n empty)

||| Take waiter `k` out of the line (nothing happens if it is not there).
export
leave : Nat -> Waiters a -> Waiters a
leave k (MkWaiters n line) = MkWaiters n (delete k line)
