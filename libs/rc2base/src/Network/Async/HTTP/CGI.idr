||| External CGI programs for `Network.Async.HTTP.Router`: `cgi` is a `Handler`
||| transformer that runs the executable a request names under a URL prefix, as
||| RFC 3875 describes, and gives its output back as the response. The program
||| runs as a process of its own while the task waits for it on the scheduler.
||| See `doc/async-http-router.md`.
|||
||| Linux (see `System.Posix.Spawn`); build with `IDRIS2_CFLAGS=-D_GNU_SOURCE`.
module Network.Async.HTTP.CGI

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.URL
import System.Linux.Epoll
import System.Linux.Pipe
import System.Linux.Process
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Process
import System.Posix.Signal
import System.Posix.Spawn
import System.Posix.Stat

%default covering

||| What `cgi` may be asked to tune.
public export
record CGIOptions where
  constructor MkCGIOptions
  ||| How long a program may run, in milliseconds, from its start to the end of
  ||| its output: after that it is killed and the answer is 504. 0 is no limit.
  timeoutMs : Nat
  ||| The most output of a program that is taken: more is answered with 502.
  maxOutputBytes : Int
  ||| `SERVER_NAME` and `SERVER_PORT`.
  serverName : String
  serverPort : Nat
  ||| The environment of the program besides the CGI variables (it does not inherit
  ||| ours), set first so that a CGI variable of the same name wins.
  environment : List (String, String)

||| 30 seconds, 16 MiB, `localhost:80`, and `PATH=/usr/local/bin:/usr/bin:/bin`.
public export
defaultCGI : CGIOptions
defaultCGI = MkCGIOptions 30000 16777216 "localhost" 80 [("PATH", "/usr/local/bin:/usr/bin:/bin")]

%foreign "CExpr:((int)read($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__readBuf : Int32 -> Buffer -> Int -> Int -> PrimIO Int

%foreign "CExpr:((int)write($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__writeBuf : Int32 -> Buffer -> Int -> Int -> PrimIO Int

-- One attempt at a system call that answers -1 and sets `errno` on failure.
attempt : PrimIO Int -> IO (Either Errno Int)
attempt call = do
  n <- primIO call
  if n >= 0 then pure (Right n) else Left <$> errno

-- Repeat the call, waiting with `wait` when it would block.
retrying : (wait : Task a) -> PrimIO Int -> Task (Either Errno Int)
retrying wait call = do
  r <- onReactor (attempt call)
  case r of
    Left e => if e == EAGAIN then wait *> retrying wait call
              else if e == EINTR then retrying wait call
              else pure r
    Right _ => pure r

-- The index of the end of the head of a program's output, and where its body
-- starts: the head ends at the first empty line, with CRLF or only LF line ends.
headEnd : Buffer -> (len : Int) -> IO (Maybe (Int, Int))
headEnd buf len = go 0
  where
    go : Int -> IO (Maybe (Int, Int))
    go i = if i >= len then pure Nothing else do
      b <- byteAt buf i
      if b /= 10 then go (i + 1) else
        if i + 1 < len then do
          n <- byteAt buf (i + 1)
          if n == 10 then pure (Just (i, i + 2)) else
            if n == 13 && i + 2 < len then do
              m <- byteAt buf (i + 2)
              if m == 10 then pure (Just (i, i + 3)) else go (i + 1)
            else go (i + 1)
        else pure Nothing

-- A header name as a CGI variable: `X-Forwarded-For` is `HTTP_X_FORWARDED_FOR`.
variableName : String -> String
variableName name = "HTTP_" ++ pack (map (\c => if c == '-' then '_' else toUpper c) (unpack name))

-- What a program's head says: its `Status` (200, or 302 for a `Location` alone),
-- and the other headers, not the ones the server frames the answer with. `Nothing`
-- when there is neither a `Content-Type` nor a `Location`.
parseOutput : (head : String) -> Maybe (Int, List (String, String))
parseOutput head =
  let fields = mapMaybe field (lines head)
      named : String -> Maybe String
      named n = lookup n (map (\(k, v) => (toLower k, v)) fields)
      status = fromMaybe (if isJust (named "location") then 302 else 200)
                 (named "status" >>= \s => parsePositive {a = Int} (fst (break (== ' ') s)))
      kept = filter (\(k, _) => not (elem (toLower k) ["status", "content-length", "connection", "transfer-encoding"])) fields
  in if isJust (named "content-type") || isJust (named "location") then Just (status, kept) else Nothing
  where
    field : String -> Maybe (String, String)
    field line = case break (== ':') (trim line) of
      (k, rest) => if rest == "" then Nothing else Just (trim k, trim (pack (drop 1 (unpack rest))))

||| Run the executable a request names, below the directory `dir`, for the requests
||| whose path is at or below `mountAt`, and give every other request to `next`.
||| The first segment after `mountAt` is the name of the program (a regular file
||| with the execute permission, else 404); the segments after it are `PATH_INFO`.
||| The request is passed as in RFC 3875: the `REQUEST_METHOD`, `SCRIPT_NAME`,
||| `PATH_INFO`, `QUERY_STRING`, `CONTENT_TYPE`, `CONTENT_LENGTH` and the
||| `HTTP_*` variables of the headers (but not `Proxy`) in the environment, the body
||| on the standard input. The output must be a head (`Content-Type`, or `Location`
||| for a redirect, and `Status: 404 Not Found` to change the status) and then the
||| body; the answer is 502 when it is not, when the program cannot be run or fails
||| before a head, or when it gives more than `maxOutputBytes`, and 504 when it
||| takes more than `timeoutMs`. The program does not run in `dir` itself:
||| it has to find what it needs by absolute paths. Its standard error is ours.
export
cgi : {default defaultCGI options : CGIOptions} -> (mountAt, dir : String) -> (next : Handler) -> Handler
cgi {options} mountAt dir next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just [] => missing
  Just (raw :: rest) =>
    let name = percentDecode raw
    in if name == "" || name == "." || name == ".." || any (\c => c == '/' || c == '\0') (unpack name)
         then missing else do
           let program = dir ++ "/" ++ name
           Right st <- blocking (stat program)
             | Left _ => missing
           Right () <- blocking (access program X_OK)
             | Left _ => missing
           if isRegular st then run program raw (map percentDecode rest) else missing
  where
    missing : Task Response
    missing = liftIO (notFound "not found\n")

    failed : (status : Int) -> String -> Task Response
    failed status message = liftIO (text status message)

    environmentOf : (name : String) -> (pathInfo : List String) -> IO (List String)
    environmentOf name pathInfo = pure (map (\(k, v) => k ++ "=" ++ v) (inherited ++ cgiVars ++ headerVars))
      where
        query : String
        query = pack (drop 1 (snd (break (== '?') (unpack req.path))))

        headerVars : List (String, String)
        headerVars = [ (variableName k, v) | (k, v) <- req.headers, k /= "proxy", k /= "content-type", k /= "content-length" ]

        contentType : List (String, String)
        contentType = maybe [] (\v => [("CONTENT_TYPE", v)]) (lookup "content-type" req.headers)

        cgiVars : List (String, String)
        cgiVars =
          [ ("GATEWAY_INTERFACE", "CGI/1.1"), ("SERVER_PROTOCOL", "HTTP/1.1")
          , ("SERVER_SOFTWARE", "rc2base"), ("SERVER_NAME", options.serverName)
          , ("SERVER_PORT", show options.serverPort), ("REQUEST_METHOD", req.method)
          , ("SCRIPT_NAME", "/" ++ joinBy "/" (splitPath mountAt ++ [name]))
          , ("PATH_INFO", if null pathInfo then "" else "/" ++ joinBy "/" pathInfo)
          , ("QUERY_STRING", query), ("CONTENT_LENGTH", show (byteLength req.body)) ]
          ++ contentType

        -- the variables of the options that none of the others replaces
        inherited : List (String, String)
        inherited = filter (\(k, _) => not (elem k (map fst (cgiVars ++ headerVars)))) options.environment

    nonBlocking : FileDesc -> IO ()
    nonBlocking fd = do
      Right flags <- getStatusFlags fd
        | Left _ => pure ()
      ignore (setStatusFlags fd (flags .|. O_NONBLOCK))

    -- Close a descriptor once.
    shut : IORef Bool -> FileDesc -> IO ()
    shut open_ fd = do
      isOpen <- readIORef open_
      when isOpen (writeIORef open_ False *> ignore (close fd))

    -- Send the body to the program, and close its input.
    feed : FileDesc -> IORef Bool -> Task ()
    feed fd open_ = go 0 *> onReactor (shut open_ fd)
      where
        size : Int
        size = byteLength req.body

        go : Int -> Task ()
        go off = when (off < size) $ do
          r <- retrying (awaitWritable fd) (prim__writeBuf fd.rawfd req.body off (size - off))
          case r of
            Right n => go (off + n)
            Left _ => pure ()    -- the program does not want the rest

    -- All the output of the program; `Nothing` when it is more than may be taken.
    collect : FileDesc -> Task (Maybe (Buffer, Int))
    collect fd = do
      buf <- liftIO (newBuf 4096)
      go buf 0
      where
        go : Buffer -> (len : Int) -> Task (Maybe (Buffer, Int))
        go buf len = do
          Just buf' <- liftIO (growBuffer buf (len + 4096) options.maxOutputBytes)
            | Nothing => pure Nothing
          r <- retrying (awaitReadable fd) (prim__readBuf fd.rawfd buf' len (min 65536 (byteLength buf' - len)))
          case r of
            Right 0 => pure (Just (buf', len))
            Right n => go buf' (len + n)
            Left _ => pure (Just (buf', len))

    -- Wait for the program to end.
    reap : ProcessID -> IORef Bool -> Task ()
    reap pid reaped = do
      pidfd <- liftIO (pidfd_open pid 0)
      case pidfd of
        Right fd => do
          _ <- awaitReadable fd
          _ <- liftIO (close fd)
          pure ()
        Left _ => pure ()
      _ <- blocking (waitpid pid 0)
      liftIO (writeIORef reaped True)

    answer : Buffer -> (len : Int) -> Task Response
    answer buf len = do
      found <- liftIO (headEnd buf len)
      case found of
        Nothing => failed 502 "bad gateway: no head\n"
        Just (end, start) => do
          head <- liftIO (getString buf 0 end)
          case parseOutput head of
            Nothing => failed 502 "bad gateway: bad head\n"
            Just (status, hdrs) => do
              body <- liftIO (slice buf start (len - start))
              pure (MkResponse status hdrs body)

    exchange : ProcessID -> FileDesc -> FileDesc -> IORef Bool -> IORef Bool -> IORef Bool -> Task Response
    exchange pid inWrite outRead reaped writing reading = do
      deadline <- case options.timeoutMs of
                    Z => pure Nothing
                    ms => (\t => Just (t + ms)) <$> now
      let work = do
            (output, _) <- both (collect outRead) (feed inWrite writing)
            reap pid reaped
            pure output
      result <- maybe (Just <$> work) (\t => timeoutAt t work) deadline
      case result of
        Nothing => failed 504 "gateway timeout\n"
        Just Nothing => failed 502 "bad gateway: too much output\n"
        Just (Just (buf, len)) => answer buf len

    run : (program, name : String) -> (pathInfo : List String) -> Task Response
    run program name pathInfo = do
      env <- liftIO (environmentOf name pathInfo)
      liftIO ignoreSigpipe
      Right (inRead, inWrite) <- liftIO (pipe2 O_CLOEXEC)
        | Left _ => failed 502 "bad gateway\n"
      Right (outRead, outWrite) <- liftIO (pipe2 O_CLOEXEC)
        | Left _ => liftIO (ignore (close inRead) *> ignore (close inWrite)) *> failed 502 "bad gateway\n"
      started <- liftIO (spawnStdio program [program] env inRead outWrite)
      -- the child has its ends; ours are the other two, which must not block
      liftIO (ignore (close inRead) *> ignore (close outWrite))
      case started of
        Left _ => liftIO (ignore (close inWrite) *> ignore (close outRead)) *> failed 502 "bad gateway\n"
        Right pid => do
          liftIO (nonBlocking inWrite *> nonBlocking outRead)
          reaped <- liftIO (newIORef False)
          writing <- liftIO (newIORef True)
          reading <- liftIO (newIORef True)
          let cleanup : Maybe Response -> IO ()
              cleanup _ = do
                shut writing inWrite
                shut reading outRead
                done <- readIORef reaped
                unless done $ do
                  _ <- kill pid SIGKILL
                  _ <- waitpid pid 0
                  writeIORef reaped True
          finally cleanup (exchange pid inWrite outRead reaped writing reading)
