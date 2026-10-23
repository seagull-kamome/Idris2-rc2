||| Static files for `Network.Async.HTTP.Router`: `static` is a `Handler`
||| transformer that answers the requests under a URL prefix with the files of
||| a directory and hands every other request on. See `doc/async-http-router.md`.
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

||| `index.html`, 16 MiB in chunks of 256 KiB, no `Cache-Control`.
public export
defaultStatic : StaticOptions
defaultStatic = MkStaticOptions "index.html" 16777216 262144 Nothing

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
-- empty one, `.` or `..`, and with no `/` or NUL in it.
safeSegment : String -> Bool
safeSegment seg = seg /= "" && seg /= "." && seg /= ".." && not (any (\c => c == '/' || c == '\0') (unpack seg))

||| Answer the `GET` and `HEAD` requests whose path is at or below `mountAt` with
||| the file of the same path below the directory `root`, and give every other
||| request to `next`. A directory is answered with its `indexFile` (a request for
||| it without the trailing `/` is redirected to the one with it). The answer has
||| `Content-Type` by the extension and an `ETag` from the size and the time of
||| modification, which `If-None-Match` is compared with (304). Other methods are
||| answered with 405, a file that is not there (or a path with `..` in it) with
||| 404. Symbolic links are followed. The file is read in chunks of `chunkBytes`.
export
static : {default defaultStatic options : StaticOptions} -> (mountAt, root : String) -> (next : Handler) -> Handler
static {options} mountAt root next req = case segmentsUnder mountAt req.path of
  Nothing => next req
  Just raw =>
    if req.method /= "GET" && req.method /= "HEAD"
      then liftIO (text {headers = [("Allow", "GET, HEAD")]} 405 "method not allowed\n")
      else
        let segs = map percentDecode raw
        in if all safeSegment segs then file segs else missing
  where
    missing : Task Response
    missing = liftIO (notFound "not found\n")

    -- The `size` bytes of the file, read `chunkBytes` at a time. `Nothing` if it
    -- cannot be opened or read, or has become shorter than `size`.
    readChunked : (path : String) -> (size : Int) -> Task (Maybe Buffer)
    readChunked path size = do
      Right fd <- blocking (openFile path (O_RDONLY .|. O_CLOEXEC) 0)
        | Left _ => pure Nothing
      buf <- liftIO (newBuf size)
      finally (\_ => ignore (close fd)) (go fd buf 0)
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
