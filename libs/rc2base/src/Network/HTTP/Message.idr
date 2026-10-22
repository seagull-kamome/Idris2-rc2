||| HTTP/1.1 messages shared by the HTTP servers: `Request` and
||| `Response` with their byte-buffer bodies, the `Response.*`
||| constructors, response-head serialization, and the byte-scanning
||| request parser. Transport-free -- it only touches `Buffer`s.
module Network.HTTP.Message

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Buffer
import Data.IORef
import Data.List1
import Data.Maybe
import Data.String

import Language.JSON

-- The byte-scanning parser helpers loop on an `Int` index rather than
-- structurally -- overrides rc2base.ipkg's package-wide `--total`.
%default covering

-------------------------------------------------------------------------------
-- Byte buffers: the currency for request/response bodies
-------------------------------------------------------------------------------

-- Pure: reads the buffer's own size header (`getBufferSize`). A body is
-- just a `Buffer`, with no separate length field to fall out of sync --
-- its length is always exactly this.
%foreign "scheme:blodwen-buffer-size"
         "RefC:getBufferSize"
prim__bufLen : Buffer -> Int

||| Byte length of a `Buffer` (its allocated size).
export
byteLength : Buffer -> Int
byteLength = prim__bufLen

-- `newBuffer` only rejects a negative size (`Data.Buffer`'s own guard),
-- so with a clamped `n` the `Nothing` case is unreachable -- crash
-- rather than thread `Maybe` through every allocation. Same shape as
-- `Network.Socket.sendBytes`'s own handling of this.
export
newBuf : HasIO io => Int -> io Buffer
newBuf n = do
  Just b <- newBuffer (max 0 n)
    | Nothing => assert_total $ idris_crash "Network.HTTP.Message.newBuf: newBuffer failed on a non-negative size"
  pure b

||| UTF-8-encode `s` into a fresh, exactly-sized `Buffer`. A stopgap for
||| building `Response` bodies until richer helpers land; `s` must not
||| contain a NUL byte (the length is computed with `strlen`).
export
fromString : HasIO io => String -> io Buffer
fromString s = do
  let n = stringByteLength s
  b <- newBuf n
  setString b 0 s
  pure b

||| Decode a whole `Buffer` as one UTF-8 `String`. Only meaningful for a
||| body already known to be text -- binary bytes round-trip lossily.
export
toString : HasIO io => Buffer -> io String
toString b = getString b 0 (byteLength b)

-- A fresh `len`-byte buffer holding `src[off .. off+len)`.
export
slice : HasIO io => Buffer -> (off, len : Int) -> io Buffer
slice src off len = do
  b <- newBuf len
  when (len > 0) $ copyData src off len b 0
  pure b

||| Starting size of a connection's read/write accumulators.
export
initCap : Int
initCap = 4096

-- `buf` itself if it holds at least `need` bytes, else a bigger copy (roughly
-- twice the size, clamped to `cap`) holding what it did; `Nothing` if `need`
-- exceeds `cap`.
export
growBuffer : Buffer -> (need, cap : Int) -> IO (Maybe Buffer)
growBuffer cur need cap =
  let have = byteLength cur in
  if need <= have then pure (Just cur)
  else if need > cap then pure Nothing
  else do
    bigger <- newBuf (min cap (max need (have * 2)))
    when (have > 0) $ copyData cur 0 have bigger 0
    pure (Just bigger)

-- Ensure `!ref`'s backing buffer holds at least `need` bytes (`growBuffer`).
-- `False` means `need` exceeds `cap` and `!ref` is left untouched.
export
grow : (ref : IORef Buffer) -> (need, cap : Int) -> IO Bool
grow ref need cap = do
  grown <- readIORef ref >>= \cur => growBuffer cur need cap
  traverse_ (writeIORef ref) grown
  pure (isJust grown)

-------------------------------------------------------------------------------
-- Requests and responses
-------------------------------------------------------------------------------

||| A parsed HTTP/1.1 request. `path` is passed through verbatim,
||| query string and all -- no URL-decoding or splitting. `body` is the
||| raw bytes (`byteLength body` bytes of them); `toString body`
||| decodes it as text.
public export
record Request where
  constructor MkRequest
  method  : String
  path    : String
  headers : List (String, String)
  body    : Buffer

||| A `Handler`'s answer, passed to its `respond` continuation.
||| `Content-Length` is computed from `body` (`byteLength`) and added
||| automatically -- don't set it in `headers`. Build one directly with
||| `MkResponse` and a `Buffer` body, or use the `Response.*`
||| constructors below (`Response.text`, `Response.ok`, ...).
public export
record Response where
  constructor MkResponse
  status  : Int
  headers : List (String, String)
  body    : Buffer

||| Convenience constructors. Common enough names (`text`, `ok`, ...)
||| that they live under the `Response` namespace -- call them bare when
||| that's unambiguous, `Response.text` etc. when it isn't. Each takes
||| an optional `headers` (a `(name, value)` list) as a leading implicit
||| with a `[]` default; a `Content-Type` is prepended where noted.
namespace Response

  ||| `status` with `body` and an explicit `Content-Type`. Pure -- the
  ||| caller already has the bytes.
  export
  bytes : {default [] headers : List (String, String)}
       -> (status : Int) -> (contentType : String) -> Buffer -> Response
  bytes {headers} status contentType body =
    MkResponse status (("Content-Type", contentType) :: headers) body

  ||| `status` with an empty body and no `Content-Type` -- 204, a 3xx
  ||| redirect (add `Location` via `headers`), 304, ...
  export
  noBody : {default [] headers : List (String, String)} -> (status : Int) -> IO Response
  noBody {headers} status = MkResponse status headers <$> newBuf 0

  ||| `status` with a `text/plain; charset=utf-8` body.
  export
  text : {default [] headers : List (String, String)} -> (status : Int) -> String -> IO Response
  text {headers} status body = do
    b <- fromString body
    pure (bytes {headers} status "text/plain; charset=utf-8" b)

  ||| `status` with a `text/html; charset=utf-8` body.
  export
  html : {default [] headers : List (String, String)} -> (status : Int) -> String -> IO Response
  html {headers} status body = do
    b <- fromString body
    pure (bytes {headers} status "text/html; charset=utf-8" b)

  ||| `status` with a `JSON` body, serialized compactly (`Language.JSON`'s
  ||| own `Show JSON` -- no added whitespace; run the value through
  ||| `Language.JSON.format` first and pass the result to `text` instead
  ||| if a pretty-printed body is wanted). `Content-Type` is bare
  ||| `application/json`, no `charset` parameter -- unlike `text`/`html`,
  ||| RFC 8259 mandates UTF-8 for JSON text, so there is nothing for a
  ||| `charset` param to disambiguate.
  export
  json : {default [] headers : List (String, String)} -> (status : Int) -> JSON -> IO Response
  json {headers} status body = do
    b <- fromString (show body)
    pure (bytes {headers} status "application/json" b)

  ||| `text` at a fixed status: 200 / 201 / 400 / 404 / 500.
  export
  ok, created, badRequest, notFound, serverError
    : {default [] headers : List (String, String)} -> String -> IO Response
  ok          {headers} = text {headers} 200
  created     {headers} = text {headers} 201
  badRequest  {headers} = text {headers} 400
  notFound    {headers} = text {headers} 404
  serverError {headers} = text {headers} 500


-------------------------------------------------------------------------------
-- Minimal HTTP/1.1 wire format
-------------------------------------------------------------------------------

export
reasonPhrase : Int -> String
reasonPhrase 100 = "Continue"
reasonPhrase 101 = "Switching Protocols"
reasonPhrase 200 = "OK"
reasonPhrase 201 = "Created"
reasonPhrase 204 = "No Content"
reasonPhrase 301 = "Moved Permanently"
reasonPhrase 302 = "Found"
reasonPhrase 304 = "Not Modified"
reasonPhrase 400 = "Bad Request"
reasonPhrase 401 = "Unauthorized"
reasonPhrase 403 = "Forbidden"
reasonPhrase 404 = "Not Found"
reasonPhrase 405 = "Method Not Allowed"
reasonPhrase 408 = "Request Timeout"
reasonPhrase 413 = "Payload Too Large"
reasonPhrase 431 = "Request Header Fields Too Large"
reasonPhrase 500 = "Internal Server Error"
reasonPhrase 501 = "Not Implemented"
reasonPhrase 503 = "Service Unavailable"
reasonPhrase _   = "Unknown"

||| The length of a request's body, `Just 0` without a `Content-Length`. `Nothing`
||| when the headers do not frame the body reliably: a `Content-Length` that is
||| not plain digits or does not fit (more than 18 of them), two that differ, or
||| a `Transfer-Encoding` (chunked bodies are not supported). Taking such a
||| request for one without a body would leave its body to be read as the next
||| request.
export
bodyLength : List (String, String) -> Maybe Int
bodyLength hdrs =
  if isJust (lookup "transfer-encoding" hdrs) then Nothing
  else case map snd (filter ((== "content-length") . fst) hdrs) of
    [] => Just 0
    v :: vs => if all (== v) vs then digits v else Nothing
  where
    digits : String -> Maybe Int
    digits v = if v /= "" && length v <= 18 && all isDigit (unpack v) then parsePositive v else Nothing

-- HTTP/1.1 defaults to keep-alive; only a "close" among the tokens of
-- "Connection" ends it ("keep-alive, close" does too). HTTP/1.0 (which defaults
-- the other way) isn't supported (`doc/http-server.md`, "Wire format").
export
connectionClose : List (String, String) -> Bool
connectionClose hdrs =
  any (\(k, v) => k == "connection" && elem "close" (map (toLower . trim) (forget (split (== ',') v)))) hdrs

||| Whether the response asks for the connection to end: `Connection: close`, also
||| as one token among others.
export
closes : Response -> Bool
closes resp = connectionClose (map (\(k, v) => (toLower k, v)) resp.headers)

||| The response with `Connection: close`, in place of any `Connection` header
||| it had.
export
closeAfter : Response -> Response
closeAfter resp =
  { headers := ("Connection", "close") :: filter ((/= "connection") . toLower . fst) resp.headers } resp

||| Whether a response with this status has a body and a `Content-Length`: not
||| 1xx, 204 and 304.
export
hasBody : (status : Int) -> Bool
hasBody status = status >= 200 && status /= 204 && status /= 304

-- The status line + header lines + Content-Length + terminating CRLF,
-- as one ASCII string. Header keys/values are assumed ASCII (RFC 7230);
-- a non-ASCII or NUL byte in one corrupts the framing.
export
responseHead : Response -> String
responseHead resp =
    "HTTP/1.1 " ++ show resp.status ++ " " ++ reasonPhrase resp.status ++ "\r\n"
    ++ concatMap headerLine resp.headers
    ++ (if hasBody resp.status then "Content-Length: " ++ show (byteLength resp.body) ++ "\r\n" else "")
    ++ "\r\n"
  where
    headerLine : (String, String) -> String
    headerLine (k, v) = k ++ ": " ++ v ++ "\r\n"

-------------------------------------------------------------------------------
-- Byte-scanning request parser (operates on the read accumulator's
-- bytes; only the final method/path/header-key/header-value substrings
-- are lifted to `String`, each on its own -- never one big head string)
-------------------------------------------------------------------------------

export
byteAt : Buffer -> Int -> IO Int
byteAt b i = cast <$> getBits8 b i

-- Index of the CR of the first "\r\n\r\n" in `b[from .. n)`, else Nothing. Where
-- the bytes read before were already searched, `from` is three bytes before where
-- they ended.
export
findHeadEndFrom : Buffer -> (from, n : Int) -> IO (Maybe Int)
findHeadEndFrom b from n = go from
  where
    go : Int -> IO (Maybe Int)
    go i =
      if i + 3 >= n then pure Nothing
        else do
          a <- byteAt b i
          if a /= 13
            then go (i + 1)
            else do
              c <- byteAt b (i + 1)
              d <- byteAt b (i + 2)
              e <- byteAt b (i + 3)
              if c == 10 && d == 13 && e == 10 then pure (Just i) else go (i + 1)

-- Index of the CR of the first "\r\n\r\n" in `b[0 .. n)`, else Nothing.
export
findHeadEnd : Buffer -> (n : Int) -> IO (Maybe Int)
findHeadEnd b = findHeadEndFrom b 0

-- Index of the CR of the next CRLF at/after `i`, capped at `limit`
-- (returned as-is when there is no CRLF before it).
lineEnd : Buffer -> (i, limit : Int) -> IO Int
lineEnd b i limit = go i
  where
    go : Int -> IO Int
    go j =
      if j + 1 >= limit then pure limit
        else do
          a <- byteAt b j
          if a == 13
            then do c <- byteAt b (j + 1)
                    if c == 10 then pure j else go (j + 1)
            else go (j + 1)

-- First non-(SP) index at/after `i`, capped at `limit`.
skipSp : Buffer -> (i, limit : Int) -> IO Int
skipSp b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 32 then skipSp b (i + 1) limit else pure i

-- First SP index at/after `i`, capped at `limit`.
spanTok : Buffer -> (i, limit : Int) -> IO Int
spanTok b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 32 then pure i else spanTok b (i + 1) limit

-- Index of the first ':' at/after `i`, capped at `limit`.
colonAt : Buffer -> (i, limit : Int) -> IO Int
colonAt b i limit =
  if i >= limit then pure limit
    else do a <- byteAt b i
            if a == 58 then pure i else colonAt b (i + 1) limit

-- Shrink `[lo, hi)` past leading and trailing SP/HTAB.
trimRange : Buffer -> (lo, hi : Int) -> IO (Int, Int)
trimRange b lo hi = do
  lo' <- fwd lo
  hi' <- bwd hi
  pure (lo', max lo' hi')
  where
    fwd : Int -> IO Int
    fwd i = if i >= hi then pure hi
              else do a <- byteAt b i
                      if a == 32 || a == 9 then fwd (i + 1) else pure i
    bwd : Int -> IO Int
    bwd i = if i <= lo then pure lo
              else do a <- byteAt b (i - 1)
                      if a == 32 || a == 9 then bwd (i - 1) else pure i

-- One header line `b[ls, le)` -> (lowercased key, trimmed value). `Nothing` for
-- a line that is not a header: no ':', no name, or white space before the name
-- (an obsolete line fold) or between the name and the ':' -- a proxy that
-- ignores that space reads the request differently (RFC 9112, 5.1 and 5.2).
parseHeaderLine : Buffer -> (ls, le : Int) -> IO (Maybe (String, String))
parseHeaderLine b ls le = do
  c <- colonAt b ls le
  if c >= le || c == ls
    then pure Nothing
    else do
      first <- byteAt b ls
      before <- byteAt b (c - 1)
      if isBlank first || isBlank before
        then pure Nothing
        else do
          (vs, ve) <- trimRange b (c + 1) le
          key <- getString b ls (c - ls)
          val <- getString b vs (ve - vs)
          pure (Just (toLower key, val))
  where
    isBlank : Int -> Bool
    isBlank x = x == 32 || x == 9

-- Request line + all header lines from `b[0, headEnd)`.
-- `Nothing` = malformed request line or header line (caller refuses the request).
export
parseHead : Buffer -> (headEnd : Int) -> IO (Maybe (String, String, List (String, String)))
parseHead b headEnd = do
  rlEnd <- lineEnd b 0 headEnd
  m0 <- skipSp b 0 rlEnd
  m1 <- spanTok b m0 rlEnd
  p0 <- skipSp b m1 rlEnd
  p1 <- spanTok b p0 rlEnd
  if m1 <= m0 || p1 <= p0
    then pure Nothing
    else do
      method <- getString b m0 (m1 - m0)
      path   <- getString b p0 (p1 - p0)
      hdrs   <- collect (rlEnd + 2) []
      pure (map (\h => (method, path, reverse h)) hdrs)
  where
    collect : Int -> List (String, String) -> IO (Maybe (List (String, String)))
    collect i acc =
      if i >= headEnd then pure (Just acc)
        else do
          le  <- lineEnd b i headEnd
          mkv <- parseHeaderLine b i le
          case mkv of
            Nothing => pure Nothing
            Just kv => collect (le + 2) (kv :: acc)
