||| A source of completions for the scheduler of `Control.Task`: whatever
||| tells that asynchronous operations are done (the readiness of descriptors,
||| an `io_uring` ring, a library with its own descriptors). See
||| libs/control-async/doc/task.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Control.Task.Source

import System.Posix.FileDesc

%default total

public export
record Source where
  constructor MkSource
  pollFd : FileDesc     -- readable when completions are waiting
  drain  : IO ()        -- reap them without blocking, calling their completions
