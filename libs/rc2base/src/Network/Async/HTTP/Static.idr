||| Static files for `Network.Async.HTTP.Router`: `static` is a `Handler`
||| transformer that answers the requests under a URL prefix with the files of
||| a directory and hands every other request on. See `doc/async-http-router.md`.
module Network.Async.HTTP.Static

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Buffer
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Network.Async.HTTP.Server
import Network.HTTP.Route
import Network.URL
import System.File
import System.Posix.Errno
import System.Posix.Stat
import System.Posix.Time

%default covering

||| What `static` may be asked to tune.
public export
record StaticOptions where
  constructor MkStaticOptions
  ||| The file a directory is answered with.
  indexFile : String
  ||| A file larger than this is not served (500): a file is read into memory whole.
  maxFileBytes : Int
  ||| The value of `Cache-Control` of the answers that have a file, if any.
  cacheControl : Maybe String

||| `index.html`, 16 MiB, no `Cache-Control`.
public export
defaultStatic : StaticOptions
defaultStatic = MkStaticOptions "index.html" 16777216 Nothing

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
||| 404. Symbolic links are followed.
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
              Right content <- blocking (createBufferFromFile path)
                | Left _ => liftIO (serverError "cannot read file\n")
              pure (bytes {headers = tags} 200 (mimeType path) content)

    directory : (path : String) -> Task Response
    directory path =
      let (target, query) = break (== '?') req.path
      in if not (isSuffixOf "/" target)
           then liftIO (noBody {headers = [("Location", target ++ "/" ++ query)]} 301)
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
