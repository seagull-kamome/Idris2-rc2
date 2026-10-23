||| External CGI programs for `Network.Async.HTTP.Router`: `runCGI` runs the executable
||| a request names, as RFC 3875 describes, and gives its output back as the response
||| (a route of `routerWith` can use it), and `cgi` is a `Handler` transformer that does
||| so for the requests under a URL prefix. The program
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
import Data.Either
import Data.Maybe
import Data.String
import Network.Async
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.URL
import System.Concurrency
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
  ||| Whether the `Authorization` header of the request is passed on as
  ||| `HTTP_AUTHORIZATION`; not by default (RFC 3875, 4.1.18).
  passAuthorization : Bool

||| 30 seconds, 16 MiB, `localhost:80`, and no `environment` at all: a program has
||| no `PATH` (nor anything else of ours) unless `environment` gives it one.
public export
defaultCGI : CGIOptions
defaultCGI = MkCGIOptions 30000 16777216 "localhost" 80 [] False

%foreign "CExpr:((int)read($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__readBuf : Int32 -> Buffer -> Int -> Int -> PrimIO Int

%foreign "CExpr:((int)write($1, (char *)($2) + ($3), (size_t)($4))),libc,unistd.h"
prim__writeBuf : Int32 -> Buffer -> Int -> Int -> PrimIO Int

-- The index of the end of the head of a program's output, and where its body
-- starts: the head ends at the first empty line, with CRLF or only LF line ends.
headEnd : Buffer -> (len : Int) -> IO (Maybe (Int, Int))
headEnd buf len = go 0
  where
    -- The byte at `j`, -1 past the end.
    at : Int -> IO Int
    at j = if j < len then byteAt buf j else pure (-1)

    go : Int -> IO (Maybe (Int, Int))
    go i = if i >= len then pure Nothing else do
      [a, b, c] <- traverse at [i, i + 1, i + 2]
        | _ => pure Nothing
      if a == 10 && b == 10 then pure (Just (i, i + 2)) else
        if a == 10 && b == 13 && c == 10 then pure (Just (i, i + 3)) else go (i + 1)

-- The group of a process that is a group leader, as `kill` takes it (`-pid`).
negateProcess : ProcessID -> ProcessID
negateProcess (MkProcessID p) = MkProcessID (negate p)

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

||| Run the executable that the path `rest` names (the rest of the path below the mount, as
||| `splat` gives it: segments joined with `/`, as they stand in the request,
||| percent-encoded) in the directory `dir`: what `cgi` does for the requests under its
||| prefix `mountAt`, and what a route of `routerWith` can do with the rest of its path
||| (`post ("cgi-bin" // splat) (runCGI "/cgi-bin" "cgi")`;
||| `mountAt` is the path of the route, for `SCRIPT_NAME`). The first segment is the name
||| of the program (a regular file with the execute permission, else 404); the segments
||| after it are `PATH_INFO`.
|||
||| The request is passed as in RFC 3875 (`doc/async-http-router.md` has the variables),
||| the body on the standard input. The output must be a head (`Content-Type`, or
||| `Location` for a redirect, and `Status: 404 Not Found` to change the status) and then
||| the body; the answer is 502 when it is not, when the program cannot be run or fails
||| before a head, or when it gives more than `maxOutputBytes`, and 504 when it takes
||| more than `timeoutMs`. The program runs with `dir` as its working directory. Its
||| standard error is ours.
export
runCGI : {default defaultCGI options : CGIOptions} -> (mountAt, dir : String)
      -> (rest : String) -> Request -> Task Response
runCGI {options} mountAt dir rest req = case splitPath rest of
  [] => missing
  raw :: more =>
    let name = percentDecode raw
    in if name == "" || name == "." || name == ".." || any (\c => c == '/' || c == '\0') (unpack name)
         then missing else do
           let program = dir ++ "/" ++ name
           Right st <- blocking (stat program)
             | Left _ => missing
           Right () <- blocking (access program X_OK)
             | Left _ => missing
           if isRegular st then run name raw (map percentDecode more) else missing
  where
    missing : Task Response
    missing = liftIO (notFound "not found\n")

    failed : (status : Int) -> String -> Task Response
    failed status message = liftIO (text status message)

    environmentOf : (name : String) -> (pathInfo : List String) -> List String
    environmentOf name pathInfo = map (\(k, v) => k ++ "=" ++ v) (inherited ++ cgiVars ++ headerVars)
      where
        query : String
        query = pack (drop 1 (snd (break (== '?') (unpack req.path))))

        -- `HTTP_*` of the headers: a name with `_` is left out (it would be the
        -- same variable as the one with `-`), and the values of a header sent
        -- more than once are joined with `, `.
        headerVars : List (String, String)
        headerVars =
          let wanted = filter (\k => not (elem k ["proxy", "content-type", "content-length"])
                                      && all (\c => isAlphaNum c || c == '-') (unpack k)
                                      && (options.passAuthorization || k /= "authorization"))
                              (nub (map fst req.headers))
          in map (\k => (variableName k, joinBy ", " [ v | (k', v) <- req.headers, k' == k ])) wanted

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

    -- Whether the descriptor could be made non-blocking.
    nonBlocking : FileDesc -> IO Bool
    nonBlocking fd = do
      Right flags <- getStatusFlags fd
        | Left _ => pure False
      isRight <$> setStatusFlags fd (flags .|. O_NONBLOCK)

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
          -- One byte more than may be taken is read, so that an output of exactly
          -- the limit is not taken for more of it.
          Just buf' <- liftIO (growBuffer buf (len + 1) (options.maxOutputBytes + 1))
            | Nothing => pure Nothing
          r <- retrying (awaitReadable fd) (prim__readBuf fd.rawfd buf' len (min 65536 (byteLength buf' - len)))
          case r of
            Right 0 => pure (Just (buf', len))
            Right n => if len + n > options.maxOutputBytes then pure Nothing else go buf' (len + n)
            Left _ => pure (Just (buf', len))

    -- Wait for the program to end, without blocking the scheduler: on its pidfd, or,
    -- where there is none, by asking now and then. Then what it started is killed,
    -- and the flag set, in the one step that also reaps it: the group number is not
    -- free while a member of the group lives, and the cleanup never signals a number
    -- that is free again.
    reap : ProcessID -> IORef Bool -> Task ()
    reap pid reaped = do
      pidfd <- liftIO (pidfd_open pid 0)
      case pidfd of
        Right fd => do
          _ <- finally (\_ => ignore (close fd)) (awaitReadable fd)
          onReactor finish
        Left _ => poll
      where
        finish : IO ()
        finish = do
          _ <- waitpid pid WNOHANG
          _ <- kill (negateProcess pid) SIGKILL
          writeIORef reaped True

        poll : Task ()
        poll = do
          r <- onReactor (waitpid pid WNOHANG)
          case r of
            Right (MkProcessID 0, _) => sleepFor 5 *> poll
            _ => onReactor (kill (negateProcess pid) SIGKILL *> writeIORef reaped True)

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

    exchange : ProcessID -> FileDesc -> FileDesc -> IORef Bool -> IORef Bool -> Task Response
    exchange pid inWrite outRead reaped writing = do
      deadline <- case options.timeoutMs of
                    Z => pure Nothing
                    ms => (\t => Just (t + ms)) <$> now
      -- The body is written while the output is read; when the output is over, or too
      -- much, the writer is given up (it may be stuck on a program that reads no
      -- more). Too much output is not waited for: the program is killed by the
      -- cleanup, as it may be stuck writing what is not read.
      let work = do
            output <- either id (const Nothing) <$> race (collect outRead) (feed inWrite writing *> Empty {a = ()})
            when (isJust output) (reap pid reaped)
            pure output
      result <- maybe (Just <$> work) (\t => timeoutAt t work) deadline
      case result of
        Nothing => failed 504 "gateway timeout\n"
        Just Nothing => failed 502 "bad gateway: too much output\n"
        Just (Just (buf, len)) => answer buf len

    -- `file` is the name of the program in `dir`, `name` as it stands in the request.
    run : (file, name : String) -> (pathInfo : List String) -> Task Response
    run file name pathInfo = do
      liftIO ignoreSigpipe
      Right (inRead, inWrite) <- liftIO (pipe2 O_CLOEXEC)
        | Left _ => failed 502 "bad gateway\n"
      Right (outRead, outWrite) <- liftIO (pipe2 O_CLOEXEC)
        | Left _ => liftIO (ignore (close inRead) *> ignore (close inWrite)) *> failed 502 "bad gateway\n"
      started <- liftIO (spawnStdio ("./" ++ file) dir ["./" ++ file] (environmentOf name pathInfo) inRead outWrite)
      -- the child has its ends; ours are the other two, which must not block
      liftIO (ignore (close inRead) *> ignore (close outWrite))
      case started of
        Left _ => liftIO (ignore (close inWrite) *> ignore (close outRead)) *> failed 502 "bad gateway\n"
        Right pid => do
          reaped <- liftIO (newIORef False)
          writing <- liftIO (newIORef True)
          let cleanup : Maybe Response -> IO ()
              cleanup _ = do
                shut writing inWrite
                ignore (close outRead)
                done <- readIORef reaped
                unless done $ do
                  -- the program is a process group of its own: what it started goes too
                  _ <- kill (negateProcess pid) SIGKILL
                  _ <- kill pid SIGKILL
                  -- killed, so gone at once; a process in an uninterruptible sleep is
                  -- reaped by a thread of its own, not waited for on the scheduler
                  r <- waitpid pid WNOHANG
                  case r of
                    Right (MkProcessID 0, _) => ignore (fork (ignore (waitpid pid 0)))
                    _ => pure ()
                  writeIORef reaped True
          finally cleanup $ do
            -- both ends have to be non-blocking for the reads and writes to wait
            ready <- liftIO (all id <$> traverse nonBlocking [inWrite, outRead])
            if ready then exchange pid inWrite outRead reaped writing else failed 502 "bad gateway\n"

||| Give the requests whose path is at or below `mountAt` to `runCGI` (the first
||| segment after `mountAt` names the program in `dir`), and every other request to
||| `next`.
export
cgi : {default defaultCGI options : CGIOptions} -> (mountAt, dir : String) -> (next : Handler) -> Handler
cgi {options} mountAt dir next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just below => runCGI {options} mountAt dir (joinBy "/" below) req
