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
  ||| The address of the client, as text (`192.0.2.1`, `::1`), where the server
  ||| knows it: `Network.Async.HTTP.Server` does, the callback server does not.
  remote  : Maybe String

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
reasonPhrase 303 = "See Other"
reasonPhrase 304 = "Not Modified"
reasonPhrase 307 = "Temporary Redirect"
reasonPhrase 308 = "Permanent Redirect"
reasonPhrase 400 = "Bad Request"
reasonPhrase 401 = "Unauthorized"
reasonPhrase 403 = "Forbidden"
reasonPhrase 404 = "Not Found"
reasonPhrase 405 = "Method Not Allowed"
reasonPhrase 408 = "Request Timeout"
reasonPhrase 413 = "Payload Too Large"
reasonPhrase 417 = "Expectation Failed"
reasonPhrase 431 = "Request Header Fields Too Large"
reasonPhrase 500 = "Internal Server Error"
reasonPhrase 501 = "Not Implemented"
reasonPhrase 502 = "Bad Gateway"
reasonPhrase 503 = "Service Unavailable"
reasonPhrase 504 = "Gateway Timeout"
reasonPhrase 505 = "HTTP Version Not Supported"
reasonPhrase _   = "Unknown"

||| Whether a string has no control character (C0, DEL): fit for a method, a target or
||| a header name. A CR, LF or NUL would split the message or cut it short; the others
||| are dropped or read differently by one reader and the next (a browser removes TAB
||| from a URL, so `/<TAB>/host` is `//host`).
export
noControl : String -> Bool
noControl = all (\c => ord c >= 32 && ord c /= 127) . unpack

||| `noControl`, with HTAB allowed: fit for the value of a header (RFC 9110, 5.5).
export
fieldSafe : String -> Bool
fieldSafe = all (\c => c == '\t' || (ord c >= 32 && ord c /= 127)) . unpack

-- `trim` of SP and HTAB only, the white space around a field value (RFC 9110, 5.5); `trim`
-- also takes VT and FF, which a stricter reader of the same header does not.
trimOws : String -> String
trimOws = pack . dropWhile ow . reverse . dropWhile ow . reverse . unpack
  where
    ow : Char -> Bool
    ow c = c == ' ' || c == '\t'

||| How the body of a request is delimited.
public export
data Framing = Sized Int | Chunked

||| Why the headers of a request do not frame its body: `Malformed` (answer 400),
||| or `UnsupportedCoding`, a transfer coding other than `chunked` (answer 501).
public export
data FramingError = Malformed | UnsupportedCoding

export
Show Framing where
  show (Sized n) = "Sized " ++ show n
  show Chunked = "Chunked"

export
Show FramingError where
  show Malformed = "Malformed"
  show UnsupportedCoding = "UnsupportedCoding"

||| The framing of a request's body (RFC 9112, 6.3): `Sized 0` without a
||| `Content-Length`, `Chunked` for `Transfer-Encoding: chunked`. A refusal when the
||| headers do not frame the body reliably: a `Content-Length` that is not plain
||| digits or does not fit (more than 18 of them), two that differ, a
||| `Transfer-Encoding` together with a `Content-Length`, or one that does not end
||| with `chunked`. Taking such a request for one without a body would leave its body
||| to be read as the next request. The codings are the tokens of all the
||| `Transfer-Encoding` headers.
export
framing : List (String, String) -> Either FramingError Framing
framing hdrs =
  if any ((== "transfer-encoding") . fst) hdrs then coded else sized
  where
    valuesOf : String -> List String
    valuesOf name = map snd (filter ((== name) . fst) hdrs)

    codings : List String
    codings = filter (/= "") . map (toLower . trimOws) $ concatMap (forget . split (== ',')) (valuesOf "transfer-encoding")

    coded : Either FramingError Framing
    coded =
      if null codings || not (null (valuesOf "content-length")) then Left Malformed
      else case reverse codings of
        ["chunked"] => Right Chunked
        "chunked" :: others => Left (if elem "chunked" others then Malformed else UnsupportedCoding)
        _ => Left Malformed

    digits : String -> Maybe Int
    digits v = if v /= "" && length v <= 18 && all isDigit (unpack v) then parsePositive v else Nothing

    sized : Either FramingError Framing
    sized = case valuesOf "content-length" of
      [] => Right (Sized 0)
      v :: vs => if all (== v) vs then maybe (Left Malformed) (Right . Sized) (digits v) else Left Malformed

||| What a request expects of the server before it sends its body (RFC 9110, 10.1.1).
public export
data Expectation = NoExpectation | ExpectContinue | ExpectUnmet

||| The `Expect` headers of a request: `ExpectContinue` when they all are
||| `100-continue`, `ExpectUnmet` when one is anything else (answer 417).
export
expectation : List (String, String) -> Expectation
expectation hdrs = case map (toLower . trimOws . snd) (filter ((== "expect") . fst) hdrs) of
  [] => NoExpectation
  vs => if all (== "100-continue") vs then ExpectContinue else ExpectUnmet

export
Show Expectation where
  show NoExpectation = "NoExpectation"
  show ExpectContinue = "ExpectContinue"
  show ExpectUnmet = "ExpectUnmet"

||| The interim response that asks the client to send the body.
export
continueHead : String
continueHead = "HTTP/1.1 100 Continue\r\n\r\n"

-- Whether `Connection` (the headers' names in lower case) has the token among
-- its comma-separated ones.
connectionHas : String -> List (String, String) -> Bool
connectionHas token hdrs =
  any (\(k, v) => k == "connection" && any ((== token) . toLower . trim) (forget (split (== ',') v))) hdrs

||| Whether a request asks for the connection to end: `close` among the tokens of
||| `Connection` (`keep-alive, close` does too). The header names are in lower
||| case, as `parseHead` gives them (`doc/http-server.md`, "Wire format").
export
connectionClose : List (String, String) -> Bool
connectionClose = connectionHas "close"

||| Whether a request asks for the connection to be kept: `keep-alive` among the
||| tokens of `Connection`. What an HTTP/1.0 request has to say for the server not to
||| close after the response.
export
connectionKeepAlive : List (String, String) -> Bool
connectionKeepAlive = connectionHas "keep-alive"

||| Whether the response asks for the connection to end: `Connection: close`, also
||| as one token among others.
export
closes : Response -> Bool
closes resp = connectionClose (map (\(k, v) => (toLower k, v)) resp.headers)

-- The response with `Connection: value`, in place of any `Connection` header it had.
setConnection : String -> Response -> Response
setConnection value resp =
  { headers := ("Connection", value) :: filter ((/= "connection") . toLower . fst) resp.headers } resp

||| The response with `Connection: close`.
export
closeAfter : Response -> Response
closeAfter = setConnection "close"

||| The response with `Connection: keep-alive`.
export
keepAliveAfter : Response -> Response
keepAliveAfter = setConnection "keep-alive"

||| Whether a response with this status has a body and a `Content-Length`: not
||| 1xx, 204 and 304.
export
hasBody : (status : Int) -> Bool
hasBody status = status >= 200 && status /= 204 && status /= 304

-- The status line + header lines + Content-Length + terminating CRLF,
-- as one ASCII string. Header keys/values are assumed ASCII (RFC 7230);
-- a non-ASCII or NUL byte in one corrupts the framing.
--
-- For a response to `HEAD` (`headOnly`), one that carries a `Content-Length`
-- header of its own keeps it, with no second one computed from the body: a
-- `HEAD` answer says how long the body of the `GET` would be, and the handler
-- can say so without building the body. For any other request the header is
-- computed from the body, as always.
export
responseHeadFor : (headOnly : Bool) -> Response -> String
responseHeadFor headOnly resp =
    "HTTP/1.1 " ++ show resp.status ++ " " ++ reasonPhrase resp.status ++ "\r\n"
    ++ concatMap headerLine resp.headers
    ++ (if hasBody resp.status && not ownLength then "Content-Length: " ++ show (byteLength resp.body) ++ "\r\n" else "")
    ++ "\r\n"
  where
    headerLine : (String, String) -> String
    headerLine (k, v) = k ++ ": " ++ v ++ "\r\n"

    ownLength : Bool
    ownLength = headOnly && any (\(k, _) => toLower k == "content-length") resp.headers

||| `responseHeadFor False`: the answer to any request but `HEAD`.
export
responseHead : Response -> String
responseHead = responseHeadFor False

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

||| `parseHead` with the protocol version, the third token of the request line
||| (`""` when there is none).
export
parseRequestHead : Buffer -> (headEnd : Int) -> IO (Maybe (String, String, String, List (String, String)))
parseRequestHead b headEnd = do
  rlEnd <- lineEnd b 0 headEnd
  m0 <- skipSp b 0 rlEnd
  m1 <- spanTok b m0 rlEnd
  p0 <- skipSp b m1 rlEnd
  p1 <- spanTok b p0 rlEnd
  v0 <- skipSp b p1 rlEnd
  v1 <- spanTok b v0 rlEnd
  if m1 <= m0 || p1 <= p0
    then pure Nothing
    else do
      method <- getString b m0 (m1 - m0)
      path   <- getString b p0 (p1 - p0)
      version <- getString b v0 (v1 - v0)
      hdrs   <- collect (rlEnd + 2) []
      pure (map (\h => (method, path, version, reverse h)) hdrs)
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

-- Request line + all header lines from `b[0, headEnd)`.
-- `Nothing` = malformed request line or header line (caller refuses the request).
export
parseHead : Buffer -> (headEnd : Int) -> IO (Maybe (String, String, List (String, String)))
parseHead b headEnd = map (map (\(m, p, _, h) => (m, p, h))) (parseRequestHead b headEnd)

-------------------------------------------------------------------------------
-- Chunked bodies (RFC 9112, 7.1)
-------------------------------------------------------------------------------

||| Where a scan of a chunked body stopped: the offset of the size line of the
||| next chunk, and the bytes of the chunks before it. A scan that needs more bytes
||| goes on from its mark when they have come, and does not read the chunks again.
public export
record ChunkMark where
  constructor MkChunkMark
  at      : Int
  decoded : Int

||| What a scan of a chunked body found: where the body ends (the next request starts
||| there) and how many bytes it holds; that more bytes are needed, and where to go on;
||| that it is not a chunked body (a size that is not hexadecimal, a missing CRLF, a
||| line over 4096 bytes, a trailer section over 8192); or that the chunks hold more
||| than the limit.
public export
data ChunkScan = ChunksEnd Int Int | ChunksMore ChunkMark | ChunksBad | ChunksTooLarge

||| Scan the chunked body in `buf[mark.at .. len)` as far as it goes: chunk extensions
||| and trailer fields are checked and dropped. The data of the chunks is checked to
||| hold no more than `maxBody` bytes as soon as a size says so, before the data has
||| arrived. With `into`, the data of the chunks is copied there, from offset
||| `mark.decoded`.
export
scanChunks : (into : Maybe Buffer) -> Buffer -> (len, maxBody : Int) -> ChunkMark -> IO ChunkScan
scanChunks into buf len maxBody start = chunks start.at start.decoded
  where
    lineLimit : Int
    lineLimit = 4096

    trailerLimit : Int
    trailerLimit = 8192

    -- larger than any limit, and far from overflowing when a digit is added
    sizeCap : Int
    sizeCap = 4503599627370496

    hexValue : Int -> Maybe Int
    hexValue c =
      if c >= 48 && c <= 57 then Just (c - 48)
      else if c >= 65 && c <= 70 then Just (c - 55)
      else if c >= 97 && c <= 102 then Just (c - 87)
      else Nothing

    extension : (i, le, size : Int) -> IO (Maybe Int)
    extension i le size =
      if i >= le then pure (Just size)
      else do
        c <- byteAt buf i
        if (c < 32 && c /= 9) || c == 127 then pure Nothing else extension (i + 1) le size

    -- the size on the line `buf[ls, le)`: hexadecimal digits, then nothing or `;` and
    -- an extension that has no control character
    sizeOf : (i, le : Int) -> (acc : Int) -> (digits : Nat) -> IO (Maybe Int)
    sizeOf i le acc digits =
      if i >= le then pure (if digits > 0 then Just acc else Nothing)
      else do
        c <- byteAt buf i
        case hexValue c of
          Just v => sizeOf (i + 1) le (min sizeCap (acc * 16 + v)) (S digits)
          Nothing => if c == 59 && digits > 0 then extension (i + 1) le acc else pure Nothing

    trailers : (mark : ChunkMark) -> (i, from : Int) -> (decoded : Int) -> IO ChunkScan
    trailers mark i from decoded = do
      le <- lineEnd buf i len
      if le >= len
        then pure (if len - i > lineLimit then ChunksBad else ChunksMore mark)
        else if le == i
          then pure (ChunksEnd (i + 2) decoded)
          else if le - i > lineLimit || le + 2 - from > trailerLimit
            then pure ChunksBad
            else do
              field <- parseHeaderLine buf i le
              case field of
                Nothing => pure ChunksBad
                Just _ => trailers mark (le + 2) from decoded

    withData : (mark : ChunkMark) -> (n, dataStart : Int) -> IO ChunkScan
    chunks : (at, decoded : Int) -> IO ChunkScan
    chunks at decoded = do
      le <- lineEnd buf at len
      let mark = MkChunkMark at decoded
      if le >= len
        then pure (if len - at > lineLimit then ChunksBad else ChunksMore mark)
        else if le - at > lineLimit
          then pure ChunksBad
          else do
            size <- sizeOf at le 0 Z
            case size of
              Nothing => pure ChunksBad
              Just 0 => trailers mark (le + 2) (le + 2) decoded
              Just n => withData mark n (le + 2)

    withData mark n dataStart =
      if mark.decoded + n > maxBody
        then pure ChunksTooLarge
        else if len < dataStart + n + 2
          then pure (ChunksMore mark)
          else do
            cr <- byteAt buf (dataStart + n)
            lf <- byteAt buf (dataStart + n + 1)
            if cr /= 13 || lf /= 10
              then pure ChunksBad
              else do
                traverse_ (\dest => copyData buf dataStart n dest mark.decoded) into
                chunks (dataStart + n + 2) (mark.decoded + n)

||| The data of the chunked body that starts at `start` in `buf[0 .. len)` and has been
||| scanned (`ChunksEnd`) to hold `size` bytes, as one buffer.
export
joinChunks : Buffer -> (start, len, size : Int) -> IO Buffer
joinChunks buf start len size = do
  out <- newBuf size
  _ <- scanChunks (Just out) buf len size (MkChunkMark start 0)
  pure out

||| The headers of a request whose chunked body was decoded to `size` bytes: no
||| `Transfer-Encoding`, and the `Content-Length` that a request with that body would
||| have had.
export
decodedHeaders : (size : Int) -> List (String, String) -> List (String, String)
decodedHeaders size hdrs = filter ((/= "transfer-encoding") . fst) hdrs ++ [("content-length", show size)]
