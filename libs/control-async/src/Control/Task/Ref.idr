||| A mutable cell that tasks can share, also when the scheduler runs their
||| actions on several threads (`runTaskParallel`). Every operation is done on
||| the thread of the scheduler (`onReactor`), so reads and updates never
||| overlap. Use it instead of an `IORef` for what more than one task touches.
module Control.Task.Ref

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.IORef

%default total

export
record Ref a where
  constructor MkRef
  cell : IORef a

||| A new cell. (Making it outside a task is fine while nothing else has it.)
export
newRefIO : a -> IO (Ref a)
newRefIO x = MkRef <$> newIORef x

export
newRef : a -> Task (Ref a)
newRef x = onReactor (newRefIO x)

export
readRef : Ref a -> Task a
readRef r = onReactor (readIORef r.cell)

export
writeRef : Ref a -> a -> Task ()
writeRef r x = onReactor (writeIORef r.cell x)

||| Change the value, as one step that no other task can come between.
export
modifyRef : Ref a -> (a -> a) -> Task ()
modifyRef r f = onReactor (modifyIORef r.cell f)

||| Change the value and give back a result computed with it, in one step.
export
atomicModifyRef : Ref a -> (a -> (a, b)) -> Task b
atomicModifyRef r f = onReactor (do
  (x, b) <- f <$> readIORef r.cell
  writeIORef r.cell x
  pure b)
