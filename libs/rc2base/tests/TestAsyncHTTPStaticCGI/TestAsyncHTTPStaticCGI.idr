module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Static and Network.Async.HTTP.CGI behind Network.Async.HTTP.Router:
-- the files of public/ under /static and the programs of cgi/ under /cgi-bin, next to
-- an ordinary route, run from this directory. A blocking client on the pool asks
-- the server running as tasks. Static: a file, the index file of a directory (and the
-- redirect to the slash), a percent-encoded name, the MIME type, ETag and
-- If-None-Match (304), HEAD, 405, a file read in chunks of 4 bytes and one over the
-- size limit (500), and the names that do not go out (404, also
-- `..`). CGI: the variables a program is given and its body on the standard input,
-- Status and Location, a program with no head or too much output (502), one that
-- takes too long (504, and the server goes on), one that is not executable (404),
-- the same through routes of `routerWith` (`serveStatic`, `runCGI`: the rest of the path is their argument),
-- a program that ends and leaves a child holding the output (504; the child is killed),
-- a status that is not a number from 200 to 599 (502),
-- the working directory of a program (the one it is in), the headers a program gets
-- (joined duplicates, no `_` in a name, no Authorization), a dotfile (404).

import Control.Task
import Control.Task.Scheduler
import Data.List
import Data.List1
import Data.String
import Network.Async.HTTP.CGI
import Network.Async.HTTP.Router
import Network.Async.HTTP.Server
import Network.Async.HTTP.Static
import Network.HTTP.Route
import Network.HTTP.Router
import Network.Socket
import Network.Socket.Data
import System
import System.File
import System.Posix.Errno

%default covering

routes : List Network.Async.HTTP.Router.RouteEntry
routes = [ get ("hello" // end) (liftIO (ok "route\n")) ]

staticOptions : StaticOptions
staticOptions = { chunkBytes := 4, maxFileBytes := 40 } defaultStatic

cgiOptions : CGIOptions
cgiOptions = { timeoutMs := 700, maxOutputBytes := 50000, serverPort := 8080
             , environment := [("PATH", "/usr/bin:/bin")] } defaultCGI

-- The same files and programs as routes whose handlers are given the request
-- (`routerWith`): under /files and /scripts. `dir` is the directory of the test.
withRequest : (dir : String) -> List RouteEntryWith
withRequest dir =
  [ get ("files" // splat) (serveStatic {options = staticOptions} (dir ++ "/public"))
  , get ("scripts" // splat) (runCGI {options = cgiOptions} "/scripts" (dir ++ "/cgi"))
  , post ("scripts" // splat) (runCGI {options = cgiOptions} "/scripts" (dir ++ "/cgi"))
  ]

-- `dir` is the directory of the test, which holds public/ and cgi/.
handler : (dir : String) -> Handler
handler dir =
  static {options = staticOptions} "/static" (dir ++ "/public")
    (cgi {options = cgiOptions} "/cgi-bin" (dir ++ "/cgi")
      (Network.Async.HTTP.Router.router (routerWith (\_ => liftIO (notFound "none\n")) (withRequest dir)) routes))

-- Connect, send the request and read the answer to the end of the connection.
session : Port -> String -> IO String
session port request = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("socket " ++ show e)
  0 <- connect sock (IPv4Addr 127 0 0 1) port
    | e => close sock *> pure ("connect " ++ show e)
  Right _ <- Network.Socket.send sock request
    | Left e => pure ("send " ++ show e)
  answer <- drain sock ""
  close sock
  pure answer
  where
    drain : Socket -> String -> IO String
    drain sock acc = do
      r <- Network.Socket.recv sock 65536
      case r of
        Right (s, n) => if n > 0 then drain sock (acc ++ s) else pure acc
        Left _ => pure acc

req : String -> String -> String
req method path = method ++ " " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"

-- The head's lines of an answer and its body.
parts : String -> (List String, String)
parts answer = go [] (lines' answer)
  where
    lines' : String -> List String
    lines' = map (\l => if isSuffixOf "\r" l then pack (reverse (drop 1 (reverse (unpack l)))) else l)
             . forget . split (== '\n')
    go : List String -> List String -> (List String, String)
    go acc [] = (reverse acc, "")
    go acc ("" :: rest) = (reverse acc, joinBy "\n" rest)
    go acc (l :: rest) = go (l :: acc) rest

-- The status line, the headers worth looking at (not Content-Length, ETag, Date)
-- and the body.
summary : List String -> String -> String
summary names answer =
  let (hdrs, body) = parts answer
      shown = filter (\h => any (\n => isPrefixOf (n ++ ":") h) names) (drop 1 hdrs)
  in joinBy " | " (take 1 hdrs ++ shown) ++ "\n" ++ body

headerOf : String -> String -> String
headerOf name answer =
  case find (isPrefixOf (name ++ ": ")) (fst (parts answer)) of
    Just h => pack (drop (length name + 2) (unpack h))
    Nothing => ""

scenario : Port -> (dir : String) -> Task (List String) -> IO ()
scenario port dir clients = do
  r <- runTaskWith 3 (race (serve port (handler dir)) clients)
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn ("server ended: " ++ show stopped)
    Nothing => putStrLn "no result"

-- Whether the process whose number is in `<dir>/build/<name>` has gone (waiting a
-- little for it); `False` if there is no such file.
gone : (dir, name : String) -> IO Bool
gone dir name = do
  Right text <- readFile (dir ++ "/build/" ++ name)
    | Left _ => pure False
  case parsePositive {a = Int32} (trim text) of
    Nothing => pure False
    Just n => wait 20 n
  where
    -- The characters after the last ")" of "<pid> (<name>) <state> ...".
    afterName : List Char -> List Char
    afterName cs = case break (== ')') cs of
      (_, _ :: rest) => if elem ')' rest then afterName rest else rest
      _ => []

    -- A process that is a zombie (killed, not yet reaped by its parent) is gone too.
    running : Int32 -> IO Bool
    running n = do
      Right stat <- readFile ("/proc/" ++ show n ++ "/stat")
        | Left _ => pure False
      pure $ case afterName (unpack stat) of
                  ' ' :: 'Z' :: _ => False
                  _ => True

    wait : Nat -> Int32 -> IO Bool
    wait Z _ = pure False
    wait (S k) n = do
      alive <- running n
      if alive then usleep 50000 *> wait k n else pure True

clients : Port -> (dir : String) -> Task (List String)
clients port dir = do
  let ask = \r => blocking (session port r)
  let types = ["Content-Type", "Location", "Allow", "X-Script"]
  index <- ask (req "GET" "/static/")
  noSlash <- ask (req "GET" "/static/sub")
  subIndex <- ask (req "GET" "/static/sub/")
  hello <- ask (req "GET" "/static/hello.txt?x=1")
  spaced <- ask (req "GET" "/static/a%20b.txt")
  headed <- ask (req "HEAD" "/static/hello.txt")
  etag <- pure (headerOf "ETag" hello)
  cached <- ask ("GET /static/hello.txt HTTP/1.1\r\nHost: t\r\nConnection: close\r\nIf-None-Match: " ++ etag ++ "\r\n\r\n")
  stale <- ask ("GET /static/hello.txt HTTP/1.1\r\nHost: t\r\nConnection: close\r\nIf-None-Match: \"other\"\r\n\r\n")
  tooBig <- ask (req "GET" "/static/big.txt")
  badName <- ask "GET /cgi-bin/badname.sh HTTP/1.1\r\nHost: t\r\nConnection: close\r\nX-A: ok\r\nX-A=B: injected\r\nX-A-B: both\r\n\r\n"
  viaRoute <- traverse ask
    [ req "GET" "/files/hello.txt", req "HEAD" "/files/hello.txt", req "GET" "/files/sub"
    , req "GET" "/files/.hidden", req "GET" "/files/%2e%2e/cgi/env.sh", req "POST" "/files/hello.txt"
    , "POST /scripts/env.sh/extra?z=1 HTTP/1.1\r\nHost: t\r\nConnection: close\r\nContent-Length: 4\r\n\r\nbody"
    , req "GET" "/scripts/nowhere.sh" ]
  dotfile <- ask (req "GET" "/static/.hidden")
  posted <- ask (req "POST" "/static/hello.txt")
  absent <- ask (req "GET" "/static/nothing.txt")
  dotdot <- ask (req "GET" "/static/%2e%2e/cgi/env.sh")
  dotdot2 <- ask (req "GET" "/static/sub/..%2f..%2fcgi/env.sh")
  outside <- ask (req "GET" "/staticx")
  route <- ask (req "GET" "/hello")
  -- CGI
  envRun <- ask ("POST /cgi-bin/env.sh/extra/path?a=1&b=2 HTTP/1.1\r\nHost: t\r\nConnection: close\r\nX-Test: yes\r\nProxy: evil\r\nAuthorization: secret\r\nX-Dup: one\r\nX-Dup: two\r\nX_Test: underscore\r\nContent-Type: text/x-test\r\nContent-Length: 11\r\n\r\nhello world")
  getRun <- ask (req "GET" "/cgi-bin/env.sh")
  status <- ask (req "GET" "/cgi-bin/status.sh")
  redirect <- ask (req "GET" "/cgi-bin/redirect.sh")
  nohead <- ask (req "GET" "/cgi-bin/nohead.sh")
  big <- ask (req "GET" "/cgi-bin/big.sh")
  slow <- ask (req "GET" "/cgi-bin/slow.sh")
  slowGone <- blocking (gone dir "slow.pid")
  slowChildGone <- blocking (gone dir "slow-child.pid")
  orphan <- ask (req "GET" "/cgi-bin/orphan.sh")
  orphanChildGone <- blocking (gone dir "orphan-child.pid")
  badStatus <- ask (req "GET" "/cgi-bin/badstatus.sh")
  textStatus <- ask (req "GET" "/cgi-bin/textstatus.sh")
  keepout <- ask (req "GET" "/cgi-bin/keepout.sh")
  keepoutChildGone <- blocking (gone dir "keepout-child.pid")
  noexec <- ask (req "GET" "/cgi-bin/noexec.sh")
  nowhere <- ask (req "GET" "/cgi-bin/nowhere.sh")
  nameless <- ask (req "GET" "/cgi-bin/")
  escape <- ask (req "GET" "/cgi-bin/..%2fpublic%2fhello.txt")
  cwd <- ask (req "GET" "/cgi-bin/pwd.sh")
  after <- ask (req "GET" "/cgi-bin/env.sh")
  pure (map (summary types)
          ([ index, noSlash, subIndex, hello, spaced, headed, cached, stale, tooBig, badName, dotfile, posted, absent, dotdot, dotdot2
          , outside, route, envRun, getRun, status, redirect, nohead, big, slow, badStatus, textStatus, noexec, nowhere
          , nameless, escape, cwd, after ] ++ viaRoute)
       ++ [ "leader of the timed out program gone: " ++ show slowGone
          , "its child gone: " ++ show slowChildGone
          , "orphan: " ++ summary types orphan
          , "child left by the program that ended gone: " ++ show orphanChildGone
          , "holding the output: " ++ summary types keepout
          , "child that held the output gone: " ++ show keepoutChildGone ])

-- The directory of the test, from the path of the executable
-- (<dir>/build/exec/<name>): verify.sh runs it from another directory.
testDir : IO String
testDir = do
  args <- getArgs
  pure $ case args of
    exe :: _ => joinBy "/" (reverse (drop 3 (reverse (forget (split (== '/') exe)))))
    [] => "."

main : IO ()
main = do
  dir <- testDir
  -- the numbers of an earlier run must not be taken for this one's
  traverse_ (\n => removeFile (dir ++ "/build/" ++ n)) ["slow.pid", "slow-child.pid", "orphan-child.pid", "keepout-child.pid"]
  scenario 18751 dir (clients 18751 dir)
