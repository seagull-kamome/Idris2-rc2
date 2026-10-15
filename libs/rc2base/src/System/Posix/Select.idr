||| `select`: wait for descriptors to become ready. `System.Posix.Poll` has no
||| limit on the descriptor number; use it unless `select` is needed.
module System.Posix.Select

import Data.List
import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

||| The descriptors that are ready, by kind.
public export
record Ready where
  constructor MkReady
  readable : List FileDesc
  writable : List FileDesc
  exceptional : List FileDesc

%inline %foreign "CExpr:(FD_SETSIZE),libc,sys/select.h"
prim__FD_SETSIZE : Int
%inline %foreign "CExpr:(sizeof(fd_set)),libc,sys/select.h"
prim__sizeofFdSet : Int
%inline %foreign "CExpr:(({ FD_ZERO((fd_set *)($1)); 0; })),libc,sys/select.h"
prim__fdZero : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(({ FD_SET($1, (fd_set *)($2)); 0; })),libc,sys/select.h"
prim__fdSet : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(FD_ISSET($1, (fd_set *)($2))),libc,sys/select.h"
prim__fdIsSet : Int32 -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(sizeof(struct timeval)),libc,sys/time.h"
prim__sizeofTimeval : Int
%inline %foreign "CExpr:(((struct timeval *)($1))->tv_sec = ($2)),libc,sys/time.h"
prim__set_tv_sec : AnyPtr -> Int64 -> PrimIO Int64
%inline %foreign "CExpr:(((struct timeval *)($1))->tv_usec = ($2)),libc,sys/time.h"
prim__set_tv_usec : AnyPtr -> Int64 -> PrimIO Int64
%inline %foreign "CExpr:(select($1, (fd_set *)($2), (fd_set *)($3), (fd_set *)($4), (struct timeval *)($5))),libc,sys/select.h"
prim__select : Int32 -> AnyPtr -> AnyPtr -> AnyPtr -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:((void *)NULL),libc,stddef.h"
prim__nullPtr : AnyPtr

||| Wait until a descriptor of the three lists is ready, or for `timeoutMs`
||| milliseconds (`Nothing`: forever; a negative time is 0). Returns the ready ones, in the order
||| given; `Left EINTR` when a signal interrupted the wait. A descriptor
||| number of `FD_SETSIZE` (1024 on Linux) or more is `Left EINVAL`.
export
select : (readFds : List FileDesc) -> (writeFds : List FileDesc) -> (exceptFds : List FileDesc)
      -> (timeoutMs : Maybe Int64) -> IO (Either Errno Ready)
select rs ws es timeout =
  if any (\fd => cast fd.rawfd >= prim__FD_SETSIZE) (rs ++ ws ++ es)
     then pure (Left EINVAL)
     else do
       rp <- newSet rs
       wp <- newSet ws
       ep <- newSet es
       tp <- malloc prim__sizeofTimeval
       tv <- case timeout of
                  Nothing => pure prim__nullPtr
                  Just ms0 => do
                    let ms = max 0 ms0
                    _ <- primIO (prim__set_tv_sec tp (ms `div` 1000))
                    _ <- primIO (prim__set_tv_usec tp ((ms `mod` 1000) * 1000))
                    pure tp
       let nfds = foldl (\m, fd => max m (cast fd.rawfd + 1)) 0 (rs ++ ws ++ es)
       rc <- primIO (prim__select nfds rp wp ep tv)
       res <- if rc < 0
                 then Left <$> errno
                 else do r <- pick rp rs
                         w <- pick wp ws
                         e <- pick ep es
                         pure (Right (MkReady r w e))
       free rp
       free wp
       free ep
       free tp
       pure res
  where
    newSet : List FileDesc -> IO AnyPtr
    newSet fds = do
      p <- malloc prim__sizeofFdSet
      _ <- primIO (prim__fdZero p)
      traverse_ (\fd => primIO (prim__fdSet (cast fd.rawfd) p)) fds
      pure p
    pick : AnyPtr -> List FileDesc -> IO (List FileDesc)
    pick p [] = pure []
    pick p (fd :: rest) = do
      set <- primIO (prim__fdIsSet (cast fd.rawfd) p)
      more <- pick p rest
      pure (if set /= 0 then fd :: more else more)
