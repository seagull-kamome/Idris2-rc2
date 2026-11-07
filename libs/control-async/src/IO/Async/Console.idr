||| The standard input, output and error for `Control.Task`: read a line, write a
||| string, without blocking the scheduler. A `Console` holds the three
||| `System.Posix.Async.File.Handle`s and the bytes of the input that were read
||| but not yet returned.
|||
||| * The output is not buffered: a call returns when its bytes have gone out.
|||   Calls on one `Console` are served one at a time, but a string longer than
|||   4096 bytes may be written in pieces, and another process (or the `Console`
|||   of another scheduler) can write in between. A call given up halfway leaves
|||   part of its output. Do not mix it with the Prelude's `putStr`, which has a
|||   buffer of its own. Writing to a pipe whose reader has gone ends the process
|||   with `SIGPIPE`, unless the program calls `System.Posix.Spawn.ignoreSigpipe`,
|||   which turns it into the error `EPIPE`.
||| * The input is read ahead, in chunks of 8 KiB: what a `Console` has read is
|||   not seen by any other reader of the descriptor. Take the process to have
|||   one reader of its standard input, one `Console` (`stdConsole` is one per
|||   scheduler).
||| * A `readLine` that is given up, or fails, loses nothing: the bytes already
|||   read, and the part of a line already taken, stay for the next call.
module IO.Async.Console

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Control.Task.MVar
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String.RC2
import System.Posix.Async.File as A
import System.Posix.Errno
import System.Posix.FileDesc

%default covering

||| A console. Its handles are not owned: closing them is up to the caller.
export
record Console where
  constructor MkConsole
  input : Handle
  output : Handle
  errput : Handle
  chunks : IORef (List (Buffer, Int, Int))
  carry : IORef (List (Buffer, Int))
  lineLock : MVar ()

chunkSize : Int
chunkSize = 8192

-- The longest line, and the largest string written at once (the size of a
-- `Buffer` is a C `int`).
maxLine : Int
maxLine = 16777216

maxBuffer : Int
maxBuffer = 2147483647

newConsoleIO : (input, output, errput : Handle) -> IO Console
newConsoleIO i o e = do
  q <- newIORef []
  carried <- newIORef []
  lock <- newMVarIO ()
  pure (MkConsole i o e q carried lock)

||| A console on three handles.
export
consoleOf : (input, output, errput : Handle) -> Task Console
consoleOf i o e = onReactor (newConsoleIO i o e)

||| The console of the process: file descriptors 0, 1 and 2, one `Console` for
||| the whole scheduler. They are never closed. `Left` if one of them is closed.
export
stdConsole : Task (Either Errno Console)
stdConsole = Async $ \env, done => noCancel <$ (env.slot "IO.Async.Console" made >>= done)
  where
    stdFd : Int32 -> IO (Either Errno Handle)
    stdFd n = case mkFileDesc n of
      Nothing => pure (Left EBADF)
      Just fd => adoptNow fd

    made : IO (Either Errno (Console, IO ()))
    made = do
      Right hin <- stdFd 0
        | Left err => pure (Left err)
      Right hout <- stdFd 1
        | Left err => pure (Left err)
      Right herr <- stdFd 2
        | Left err => pure (Left err)
      c <- newConsoleIO hin hout herr
      pure (Right (c, pure ()))

-------------------------------------------------------------------------------
-- Output

emit : Handle -> String -> Task (Either Errno ())
emit h s =
  let n = byteLength s
  in if n <= 0 then pure (Right ())
     else if n > maxBuffer then pure (Left EFBIG)
     else do
       Just buf <- onReactor (newBuffer n)
         | Nothing => pure (Left ENOMEM)
       onReactor (setString buf 0 s)
       A.writeAll h buf 0 n

||| Write the string to the standard output.
export
putStr : Console -> String -> Task (Either Errno ())
putStr c = emit c.output

||| Write the string and a newline.
export
putStrLn : Console -> String -> Task (Either Errno ())
putStrLn c s = emit c.output (s ++ "\n")

||| Write the string to the standard error.
export
eputStr : Console -> String -> Task (Either Errno ())
eputStr c = emit c.errput

||| Write the string and a newline to the standard error.
export
eputStrLn : Console -> String -> Task (Either Errno ())
eputStrLn c s = emit c.errput (s ++ "\n")

-------------------------------------------------------------------------------
-- Input

-- The first newline in the buffer between the two offsets.
findNewline : Buffer -> (from, to : Int) -> IO (Maybe Int)
findNewline buf from to =
  if from >= to then pure Nothing else do
    b <- getBits8 buf from
    if b == 10 then pure (Just from) else findNewline buf (from + 1) to

-- A copy of the bytes between the two offsets.
piece : Buffer -> (from, to : Int) -> IO (Maybe (Buffer, Int))
piece buf from to = do
  Just out <- newBuffer (to - from)
    | Nothing => pure Nothing
  copyData buf from (to - from) out 0
  pure (Just (out, to - from))

-- The pieces (last first) joined into a string.
joined : List (Buffer, Int) -> IO (Maybe String)
joined ps = do
  Just out <- newBuffer size
    | Nothing => pure Nothing
  fill out size ps
  Just <$> getString out 0 size
  where
    size : Int
    size = sum (map snd ps)

    fill : Buffer -> Int -> List (Buffer, Int) -> IO ()
    fill _ _ [] = pure ()
    fill out end ((b, n) :: rest) = do
      copyData b 0 n out (end - n)
      fill out (end - n) rest

data Step = Line String | More | TooLong | NoMemory

-- Take what is read so far, one chunk after another, until a line is complete.
-- It is one step of the scheduler, so a task given up never leaves it half done:
-- the part of the line taken from a chunk is in `carry` when the chunk is gone.
nextLine : Console -> IO Step
nextLine c = do
  q <- readIORef c.chunks
  case q of
    [] => pure More
    ((b, s, e) :: rest) => do
      nl <- findNewline b s e
      Just p <- piece b s (fromMaybe e nl)
        | Nothing => pure NoMemory
      modifyIORef c.carry (p ::)
      writeIORef c.chunks (case nl of
                             Just i => if i + 1 < e then (b, i + 1, e) :: rest else rest
                             Nothing => rest)
      ps <- readIORef c.carry
      case nl of
        Just _ => do
          Just line <- joined ps
            | Nothing => pure NoMemory
          writeIORef c.carry []
          pure (Line line)
        Nothing =>
          if sum (map snd ps) > maxLine
             then writeIORef c.carry [] *> pure TooLong
             else nextLine c

-- The end of the input: the last line, if it has no newline.
lastLine : Console -> IO (Either Errno (Maybe String))
lastLine c = do
  ps <- readIORef c.carry
  if null ps then pure (Right Nothing) else do
    Just line <- joined ps
      | Nothing => pure (Left ENOMEM)
    writeIORef c.carry []
    pure (Right (Just line))

||| The next line, without its newline (a `\r` before it stays; the bytes are not
||| checked to be UTF-8). `Nothing` at the end of the input, and a last line with
||| no newline is returned as it is. `EFBIG` for a line of more than 16 MiB,
||| which is dropped. Reads are served one at a time.
export
readLine : Console -> Task (Either Errno (Maybe String))
readLine c = withMVar c.lineLock (\_ => loop)
  where
    queue : Buffer -> Either Errno Int -> IO ()
    queue buf (Right n) = when (n > 0) (modifyIORef c.chunks (++ [(buf, 0, n)]))
    queue _ (Left _) = pure ()

    loop : Task (Either Errno (Maybe String))

    fetch : Task (Either Errno (Maybe String))
    fetch = do
      Just buf <- onReactor (newBuffer chunkSize)
        | Nothing => pure (Left ENOMEM)
      r <- A.readThen c.input buf 0 chunkSize (queue buf)
      case r of
        Left err => pure (Left err)
        Right 0 => onReactor (lastLine c)
        Right _ => loop

    loop = do
      st <- onReactor (nextLine c)
      case st of
        Line s => pure (Right (Just s))
        More => fetch
        TooLong => pure (Left EFBIG)
        NoMemory => pure (Left ENOMEM)
