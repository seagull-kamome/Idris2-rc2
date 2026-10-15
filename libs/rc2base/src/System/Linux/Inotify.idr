||| `inotify`: watch files and directories for changes.
|||
||| Linux only.
module System.Linux.Inotify

import System.FFI
import System.Posix.Errno
import System.Posix.FileDesc

%default total

-- Flags of inotify_init1.
%inline %foreign "CExpr:(IN_NONBLOCK),libc,sys/inotify.h"
export IN_NONBLOCK : Bits32
%inline %foreign "CExpr:(IN_CLOEXEC),libc,sys/inotify.h"
export IN_CLOEXEC : Bits32

-- Event bits, for inotify_add_watch and in the events read.
||| File was accessed.
%inline %foreign "CExpr:(IN_ACCESS),libc,sys/inotify.h"
export IN_ACCESS : Bits32
||| Metadata changed.
%inline %foreign "CExpr:(IN_ATTRIB),libc,sys/inotify.h"
export IN_ATTRIB : Bits32
||| A file opened for writing was closed.
%inline %foreign "CExpr:(IN_CLOSE_WRITE),libc,sys/inotify.h"
export IN_CLOSE_WRITE : Bits32
||| A file not opened for writing was closed.
%inline %foreign "CExpr:(IN_CLOSE_NOWRITE),libc,sys/inotify.h"
export IN_CLOSE_NOWRITE : Bits32
||| A file or directory was created in the watched directory.
%inline %foreign "CExpr:(IN_CREATE),libc,sys/inotify.h"
export IN_CREATE : Bits32
||| A file or directory was deleted from the watched directory.
%inline %foreign "CExpr:(IN_DELETE),libc,sys/inotify.h"
export IN_DELETE : Bits32
||| The watched file or directory itself was deleted.
%inline %foreign "CExpr:(IN_DELETE_SELF),libc,sys/inotify.h"
export IN_DELETE_SELF : Bits32
||| File was modified.
%inline %foreign "CExpr:(IN_MODIFY),libc,sys/inotify.h"
export IN_MODIFY : Bits32
||| The watched file or directory itself was moved.
%inline %foreign "CExpr:(IN_MOVE_SELF),libc,sys/inotify.h"
export IN_MOVE_SELF : Bits32
||| A file was moved out of the watched directory.
%inline %foreign "CExpr:(IN_MOVED_FROM),libc,sys/inotify.h"
export IN_MOVED_FROM : Bits32
||| A file was moved into the watched directory.
%inline %foreign "CExpr:(IN_MOVED_TO),libc,sys/inotify.h"
export IN_MOVED_TO : Bits32
||| File was opened.
%inline %foreign "CExpr:(IN_OPEN),libc,sys/inotify.h"
export IN_OPEN : Bits32
||| `IN_CLOSE_WRITE` or `IN_CLOSE_NOWRITE`.
%inline %foreign "CExpr:(IN_CLOSE),libc,sys/inotify.h"
export IN_CLOSE : Bits32
||| `IN_MOVED_FROM` or `IN_MOVED_TO`.
%inline %foreign "CExpr:(IN_MOVE),libc,sys/inotify.h"
export IN_MOVE : Bits32
||| All of the events above.
%inline %foreign "CExpr:(IN_ALL_EVENTS),libc,sys/inotify.h"
export IN_ALL_EVENTS : Bits32

-- Watch options.
||| Do not follow a symbolic link.
%inline %foreign "CExpr:(IN_DONT_FOLLOW),libc,sys/inotify.h"
export IN_DONT_FOLLOW : Bits32
||| Stop watching children that were unlinked.
%inline %foreign "CExpr:(IN_EXCL_UNLINK),libc,sys/inotify.h"
export IN_EXCL_UNLINK : Bits32
||| Add to the mask of an existing watch instead of replacing it.
%inline %foreign "CExpr:(IN_MASK_ADD),libc,sys/inotify.h"
export IN_MASK_ADD : Bits32
||| Remove the watch after the first event.
%inline %foreign "CExpr:(IN_ONESHOT),libc,sys/inotify.h"
export IN_ONESHOT : Bits32
||| Watch the path only if it is a directory.
%inline %foreign "CExpr:(IN_ONLYDIR),libc,sys/inotify.h"
export IN_ONLYDIR : Bits32

-- Bits that appear in the events read.
||| The watch was removed.
%inline %foreign "CExpr:(IN_IGNORED),libc,sys/inotify.h"
export IN_IGNORED : Bits32
||| The subject of the event is a directory.
%inline %foreign "CExpr:(IN_ISDIR),libc,sys/inotify.h"
export IN_ISDIR : Bits32
||| The event queue overflowed.
%inline %foreign "CExpr:(IN_Q_OVERFLOW),libc,sys/inotify.h"
export IN_Q_OVERFLOW : Bits32
||| The file system of the watch was unmounted.
%inline %foreign "CExpr:(IN_UNMOUNT),libc,sys/inotify.h"
export IN_UNMOUNT : Bits32

||| A watch descriptor.
public export
data WatchDesc = MkWatchDesc Int32

export
Show WatchDesc where
  show (MkWatchDesc w) = "WatchDesc " ++ show w

export
Eq WatchDesc where
  MkWatchDesc a == MkWatchDesc b = a == b

||| An event read from an inotify descriptor.
public export
record InotifyEvent where
  constructor MkInotifyEvent
  wd : WatchDesc
  mask : Bits32
  cookie : Bits32
  ||| The name of the entry in the watched directory ("" when there is none). A name
  ||| is the file name's bytes; one that is not valid UTF-8 is not meant to be used as text.
  name : String

export
Eq InotifyEvent where
  a == b = a.wd == b.wd && a.mask == b.mask && a.cookie == b.cookie && a.name == b.name

export
Show InotifyEvent where
  show e = "InotifyEvent " ++ show e.wd ++ " mask=" ++ show e.mask ++ " cookie=" ++ show e.cookie ++ " name=" ++ show e.name

%inline %foreign "CExpr:(inotify_init1($1)),libc,sys/inotify.h"
prim__inotify_init1 : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(inotify_add_watch($1, $2, $3)),libc,sys/inotify.h"
prim__inotify_add_watch : Bits32 -> String -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(inotify_rm_watch($1, $2)),libc,sys/inotify.h"
prim__inotify_rm_watch : Bits32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(read($1, $2, $3)),libc,unistd.h"
prim__read : Bits32 -> AnyPtr -> Bits64 -> PrimIO Int64
%inline %foreign "CExpr:(((struct inotify_event *)((char *)($1) + ($2)))->wd),libc,sys/inotify.h"
prim__ev_wd : AnyPtr -> Int -> PrimIO Int32
%inline %foreign "CExpr:(((struct inotify_event *)((char *)($1) + ($2)))->mask),libc,sys/inotify.h"
prim__ev_mask : AnyPtr -> Int -> PrimIO Bits32
%inline %foreign "CExpr:(((struct inotify_event *)((char *)($1) + ($2)))->cookie),libc,sys/inotify.h"
prim__ev_cookie : AnyPtr -> Int -> PrimIO Bits32
%inline %foreign "CExpr:(((struct inotify_event *)((char *)($1) + ($2)))->len),libc,sys/inotify.h"
prim__ev_len : AnyPtr -> Int -> PrimIO Bits32
%inline %foreign "CExpr:(((struct inotify_event *)((char *)($1) + ($2)))->name),libc,sys/inotify.h"
prim__ev_name : AnyPtr -> Int -> PrimIO String
%inline %foreign "CExpr:(sizeof(struct inotify_event)),libc,sys/inotify.h"
prim__sizeofEvent : Int

||| Create an inotify instance (`flags`: `IN_NONBLOCK`, `IN_CLOEXEC`).
export
inotify_init : (flags : Bits32) -> IO (Either Errno FileDesc)
inotify_init flags = primIO (prim__inotify_init1 flags) >>= primFdToFileDesc

||| Watch a path for the events in the mask; returns the watch descriptor.
export
inotify_add_watch : FileDesc -> String -> (mask : Bits32) -> IO (Either Errno WatchDesc)
inotify_add_watch fd path mask = do
  r <- primIO (prim__inotify_add_watch fd.rawfd path mask)
  map (map MkWatchDesc) (checkNonNeg r)

||| Stop watching.
export
inotify_rm_watch : FileDesc -> WatchDesc -> IO (Either Errno ())
inotify_rm_watch fd (MkWatchDesc w) = primIO (prim__inotify_rm_watch fd.rawfd w) >>= checkUnit

||| Read the pending events (up to 8 KiB at a time). Blocks until there is one, or
||| `Left EAGAIN` for an `IN_NONBLOCK` instance with none. The count of events in
||| `parse` is bounded by the bytes read divided by the smallest event.
export
readEvents : FileDesc -> IO (Either Errno (List InotifyEvent))
readEvents fd = do
  p <- malloc 8192
  n <- primIO (prim__read fd.rawfd p 8192)
  res <- if n < 0
            then Left <$> errno
            else Right <$> parse p 0 (cast n) (cast (n `div` cast prim__sizeofEvent) + 1)
  free p
  pure res
  where
    parse : AnyPtr -> Int -> Int -> Nat -> IO (List InotifyEvent)
    parse p off limit Z = pure []
    parse p off limit (S fuel) =
      if off + prim__sizeofEvent > limit
         then pure []
         else do
           w <- primIO (prim__ev_wd p off)
           m <- primIO (prim__ev_mask p off)
           c <- primIO (prim__ev_cookie p off)
           len <- primIO (prim__ev_len p off)
           if off + prim__sizeofEvent + cast len > limit
              then pure []
              else do
                nm <- if len == 0 then pure "" else primIO (prim__ev_name p off)
                rest <- parse p (off + prim__sizeofEvent + cast len) limit fuel
                pure (MkInotifyEvent (MkWatchDesc w) m c nm :: rest)
