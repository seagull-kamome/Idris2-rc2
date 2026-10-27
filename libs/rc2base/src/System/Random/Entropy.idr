module System.Random.Entropy

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Random bits from the operating system, for seeding. Written with the POSIX
-- calls every system has (open, read, close on /dev/urandom), each a small
-- binding of its own in System.Posix.File, and the logic here in Idris: no
-- Linux-only getrandom, and no C of its own.

import Data.Bits
import Data.Buffer
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc

%default covering

||| 64 random bits from `/dev/urandom`, which is not seeded by the clock or the
||| process, so two processes started together do not share it. `Nothing` when it
||| cannot be read (no `/dev`, in a chroot, say): a caller falls back to
||| something weaker. A read interrupted by a signal is repeated.
export
entropy64 : HasIO io => io (Maybe Bits64)
entropy64 = liftIO $ do
    Right fd <- openFile "/dev/urandom" (O_RDONLY .|. O_CLOEXEC) 0
      | Left _ => pure Nothing
    Just buf <- newBuffer 8
      | Nothing => ignore (close fd) *> pure Nothing
    ok <- attempt fd buf 8
    _ <- close fd
    if ok then Just <$> getBits64 buf 0 else pure Nothing
  where
    -- (A read of 8 bytes from /dev/urandom is not cut short; if one is, it is
    -- taken as a failure, not stitched together.)
    attempt : FileDesc -> Buffer -> (tries : Nat) -> IO Bool
    attempt _ _ Z = pure False
    attempt fd buf (S k) = do
      n <- read fd buf
      if n == 8 then pure True
      else if n < 0 then do
        e <- errno
        if e == EINTR then attempt fd buf k else pure False
      else pure False
