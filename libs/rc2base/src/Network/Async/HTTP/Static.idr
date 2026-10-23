||| Static files for `Network.Async.HTTP.Router`: `serveStatic` answers a request with
||| the files of a directory (a route of `routerWith` can use it), and `static` is a
||| `Handler` transformer that does so for the requests under a URL prefix and hands
||| every other request on. See `doc/async-http-router.md`.
module Network.Async.HTTP.Static

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Bits
import Data.Buffer
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Network.Async
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.URL
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Stat
import System.Posix.Time

%default covering

||| What `static` may be asked to tune.
public export
record StaticOptions where
  constructor MkStaticOptions
  ||| The file a directory is answered with.
  indexFile : String
  ||| A file larger than this is not served (500): the body is held in memory whole.
  maxFileBytes : Int
  ||| The file is read this many bytes at a time, each read a `blocking` step of its
  ||| own, so that a large file does not hold a worker (or, with none, the scheduler)
  ||| for the whole read. At least 1.
  chunkBytes : Int
  ||| The value of `Cache-Control` of the answers that have a file, if any.
  cacheControl : Maybe String
  ||| Whether a file or directory whose name starts with `.` (`.git`, `.env`,
  ||| `.htpasswd`, ...) is served; not by default (404).
  serveDotfiles : Bool

||| `index.html`, 16 MiB in chunks of 256 KiB, no `Cache-Control`.
public export
defaultStatic : StaticOptions
defaultStatic = MkStaticOptions "index.html" 16777216 262144 Nothing False

||| The `Content-Type` for a file name, by its extension (case does not matter);
||| `application/octet-stream` for an extension it does not know.
export
mimeType : String -> String
mimeType name = fromMaybe "application/octet-stream" (lookup (toLower extension) table)
  where
    extension : String
    extension = case reverse (forget (split (== '.') name)) of
      ext :: _ :: _ => ext
      _ => ""

    table : List (String, String)
    table =
      [ ("html", "text/html; charset=utf-8"), ("htm", "text/html; charset=utf-8")
      , ("css", "text/css; charset=utf-8"), ("js", "text/javascript; charset=utf-8")
      , ("mjs", "text/javascript; charset=utf-8"), ("json", "application/json")
      , ("txt", "text/plain; charset=utf-8"), ("md", "text/markdown; charset=utf-8")
      , ("csv", "text/csv; charset=utf-8"), ("xml", "application/xml")
      , ("svg", "image/svg+xml"), ("png", "image/png"), ("jpg", "image/jpeg")
      , ("jpeg", "image/jpeg"), ("gif", "image/gif"), ("webp", "image/webp")
      , ("ico", "image/x-icon"), ("woff", "font/woff"), ("woff2", "font/woff2")
      , ("pdf", "application/pdf"), ("wasm", "application/wasm"), ("zip", "application/zip")
      ]

-- Read `len` bytes at `offset` into `buf[off ..]`.
%foreign "CExpr:((int)pread($1, (char *)($2) + ($3), (size_t)($4), (off_t)($5))),libc,unistd.h"
prim__preadBuf : Int32 -> Buffer -> (off, len, offset : Int) -> PrimIO Int

-- Whether a decoded segment may be part of a file path below the root: not an
-- empty one, `.` or `..`, with no `/` or NUL in it, and not a dotfile unless allowed.
safeSegment : (dotfiles : Bool) -> String -> Bool
safeSegment dotfiles seg =
  seg /= "" && seg /= "." && seg /= ".." && not (any (\c => c == '/' || c == '\0') (unpack seg))
  && (dotfiles || not (isPrefixOf "." seg))

||| Answer a request with the file below the directory `root` that the segments `below`
||| name (as they stand in the request, percent-encoded): what `static` does for the
||| requests under its prefix, and what a route of `routerWith` can do with the rest of
||| its path (`get ("assets" // splat) (\rest, req => serveStatic "public" (splitPath rest) req)`).
||| Only `GET` and `HEAD` (405 with `Allow` otherwise). A directory is answered with
||| its `indexFile` (a request for it without the trailing `/` is redirected to the
||| one with it). The answer has `Content-Type` by the extension and an `ETag` from the
||| size and the time of modification, which `If-None-Match` is compared with (304). A
||| file that is not there, or a path with `..` in it, is 404, also a name that starts
||| with `.` unless `serveDotfiles`. Symbolic links are followed. The file is read in
||| chunks of `chunkBytes`.
export
serveStatic : {default defaultStatic options : StaticOptions} -> (root : String)
           -> (below : List String) -> Request -> Task Response
serveStatic {options} root raw req =
    if req.method /= "GET" && req.method /= "HEAD"
      then liftIO (text {headers = [("Allow", "GET, HEAD")]} 405 "method not allowed\n")
      else
        let segs = map percentDecode raw
        in if all (safeSegment options.serveDotfiles) segs then file segs else missing
  where
    missing : Task Response
    missing = liftIO (notFound "not found\n")

    -- The file opened on a worker thread. `handoff` closes the descriptor if the task
    -- is given up after the open has finished and before this task goes on, and
    -- `O_NONBLOCK` keeps a file that was replaced by a FIFO from blocking the open.
    opened : (path : String) -> Task (Either Errno FileDesc)
    opened path = handoff (\env, done => env.offload (openFile path (O_RDONLY .|. O_CLOEXEC .|. O_NONBLOCK) 0 >>= \r => env.post (done r)))
                          (either (\_ => pure ()) (\fd => ignore (close fd)))

    -- The `size` bytes of the file, read `chunkBytes` at a time. `Nothing` if it
    -- cannot be opened or read, or has become shorter than `size`.
    readChunked : (path : String) -> (size : Int) -> Task (Maybe Buffer)
    readChunked path size = do
      Right fd <- opened path
        | Left _ => pure Nothing
      -- `finally` first: nothing may come between the open and the close
      finally (\_ => ignore (close fd)) (liftIO (newBuf size) >>= \buf => go fd buf 0)
      where
        step : Int
        step = min 1073741824 (max 1 options.chunkBytes)

        go : FileDesc -> Buffer -> (off : Int) -> Task (Maybe Buffer)
        go fd buf off = if off >= size then pure (Just buf) else do
          r <- blocking (attempt (prim__preadBuf fd.rawfd buf off (min step (size - off)) off))
          case r of
            Right n => if n > 0 then go fd buf (off + n) else pure Nothing
            Left _ => pure Nothing

    -- The answer for the file at `path`.
    serveFile : (path : String) -> Stat -> Task Response
    serveFile path st =
      if st.stSize > cast options.maxFileBytes
        then liftIO (serverError "file too large\n")
        else do
          let etag = "\"" ++ show st.stSize ++ "-" ++ show st.stMtime.tvSec ++ "\""
          let tags = [("ETag", etag)] ++ maybe [] (\c => [("Cache-Control", c)]) options.cacheControl
          if any (\(k, v) => k == "if-none-match" && any ((== etag) . trim) (forget (split (== ',') v))) req.headers
            then liftIO (noBody {headers = tags} 304)
            else do
              Just content <- readChunked path (cast st.stSize)
                | Nothing => liftIO (serverError "cannot read file\n")
              pure (bytes {headers = tags} 200 (mimeType path) content)

    directory : (path : String) -> Task Response
    directory path =
      let (target, query) = break (== '?') req.path
      in if not (isSuffixOf "/" target)
           then liftIO (noBody {headers = [("Location", "/" ++ joinBy "/" (splitPath target) ++ "/" ++ query)]} 301)
           else do
             let index = path ++ "/" ++ options.indexFile
             Right found <- blocking (stat index)
               | Left _ => missing
             if isRegular found then serveFile index found else missing

    file : List String -> Task Response
    file segs = do
      let path = joinBy "/" (root :: segs)
      Right st <- blocking (stat path)
        | Left _ => missing
      if isRegular st then serveFile path st else
        if isDirectory st then directory path else missing

||| Give the requests whose path is at or below `mountAt` to `serveStatic` (the file of
||| the same path below the directory `root`), and every other request to `next`.
export
static : {default defaultStatic options : StaticOptions} -> (mountAt, root : String) -> (next : Handler) -> Handler
static {options} mountAt root next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just below => serveStatic {options} root below req
