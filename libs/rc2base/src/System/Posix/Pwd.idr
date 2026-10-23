||| The user and group database: `getpwnam`, `getpwuid`, `getgrnam`, `getgrgid`.
|||
||| The C functions return a pointer into static storage, so they are not
||| thread-safe; each call here copies the fields into a record before
||| returning.
module System.Posix.Pwd

import Data.List
import Data.Maybe
import Data.String.FFI
import System.FFI
import System.Posix.Errno

%default covering

||| The fields of `struct passwd` that POSIX defines.
public export
record Passwd where
  constructor MkPasswd
  name : String
  uid : Bits32
  gid : Bits32
  gecos : String
  dir : String
  shell : String

export
Show Passwd where
  show p = "Passwd " ++ show p.name ++ " " ++ show p.uid ++ " " ++ show p.gid ++ " "
        ++ show p.gecos ++ " " ++ show p.dir ++ " " ++ show p.shell

||| The fields of `struct group`.
public export
record Group where
  constructor MkGroup
  name : String
  gid : Bits32
  members : List String

export
Show Group where
  show g = "Group " ++ show g.name ++ " " ++ show g.gid ++ " " ++ show g.members

%inline %foreign "CExpr:(getpwnam($1)),libc,pwd.h"
prim__getpwnam : String -> PrimIO AnyPtr
%inline %foreign "CExpr:(getpwuid($1)),libc,pwd.h"
prim__getpwuid : Bits32 -> PrimIO AnyPtr
%inline %foreign "CExpr:(getgrnam($1)),libc,grp.h"
prim__getgrnam : String -> PrimIO AnyPtr
%inline %foreign "CExpr:(getgrgid($1)),libc,grp.h"
prim__getgrgid : Bits32 -> PrimIO AnyPtr

%inline %foreign "CExpr:(((struct passwd *)($1))->pw_name),libc,pwd.h"
prim__pw_name : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct passwd *)($1))->pw_uid),libc,pwd.h"
prim__pw_uid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct passwd *)($1))->pw_gid),libc,pwd.h"
prim__pw_gid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct passwd *)($1))->pw_gecos),libc,pwd.h"
prim__pw_gecos : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct passwd *)($1))->pw_dir),libc,pwd.h"
prim__pw_dir : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct passwd *)($1))->pw_shell),libc,pwd.h"
prim__pw_shell : AnyPtr -> PrimIO String

%inline %foreign "CExpr:(((struct group *)($1))->gr_name),libc,grp.h"
prim__gr_name : AnyPtr -> PrimIO String
%inline %foreign "CExpr:(((struct group *)($1))->gr_gid),libc,grp.h"
prim__gr_gid : AnyPtr -> PrimIO Bits32
%inline %foreign "CExpr:(((struct group *)($1))->gr_mem[$2]),libc,grp.h"
prim__gr_mem : AnyPtr -> Int -> PrimIO AnyPtr

-- `getpwnam` and friends return NULL both for "no such entry" and for an
-- error. For the former errno stays 0 or, through NSS, becomes one of the
-- codes in `notFound`, so it is zeroed first.
%inline %foreign "CExpr:(errno = 0),libc,errno.h"
prim__clearErrno : PrimIO Int32

notFound : List Errno
notFound = [ENOENT, ESRCH, EBADF, EPERM]

lookupWith : PrimIO AnyPtr -> (AnyPtr -> IO a) -> IO (Either Errno (Maybe a))
lookupWith call read = do
  _ <- primIO prim__clearErrno
  p <- primIO call
  if prim__nullAnyPtr p /= 0
     then do e@(MkErrno c) <- errno
             pure (if c == 0 || (e `elem` notFound) then Right Nothing else Left e)
     else Right . Just <$> read p

readPasswd : AnyPtr -> IO Passwd
readPasswd p = do
  n <- primIO (prim__pw_name p)
  u <- primIO (prim__pw_uid p)
  g <- primIO (prim__pw_gid p)
  c <- primIO (prim__pw_gecos p)
  d <- primIO (prim__pw_dir p)
  s <- primIO (prim__pw_shell p)
  pure (MkPasswd n u g c d s)

readGroup : AnyPtr -> IO Group
readGroup p = do
  n <- primIO (prim__gr_name p)
  g <- primIO (prim__gr_gid p)
  ms <- members 0
  pure (MkGroup n g ms)
  where
    members : Int -> IO (List String)
    members i = do
      m <- primIO (prim__gr_mem p i)
      if prim__nullAnyPtr m /= 0
         then pure []
         else do s <- ptrToString m
                 (fromMaybe "" s ::) <$> members (i + 1)

||| The entry of a user by name; `Right Nothing` when there is none.
export
getpwnam : String -> IO (Either Errno (Maybe Passwd))
getpwnam name = lookupWith (prim__getpwnam name) readPasswd

||| The entry of a user by id; `Right Nothing` when there is none.
export
getpwuid : Bits32 -> IO (Either Errno (Maybe Passwd))
getpwuid uid = lookupWith (prim__getpwuid uid) readPasswd

||| The entry of a group by name; `Right Nothing` when there is none.
export
getgrnam : String -> IO (Either Errno (Maybe Group))
getgrnam name = lookupWith (prim__getgrnam name) readGroup

||| The entry of a group by id; `Right Nothing` when there is none.
export
getgrgid : Bits32 -> IO (Either Errno (Maybe Group))
getgrgid gid = lookupWith (prim__getgrgid gid) readGroup
