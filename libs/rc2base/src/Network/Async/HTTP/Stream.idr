||| An HTTP client that gives the body of an answer as it arrives, for
||| server-sent events (`text/event-stream`): a language model that answers a
||| word at a time, a feed. The connection is a task of the scheduler
||| (`Network.Async`), so a slow server holds up nothing else. `streamPost`
||| sends a request and reads the head of the answer; `nextEvent` then waits
||| for the next event. The body may be chunked (`Transfer-Encoding: chunked`),
||| of a given length, or end with the connection. The parts that need no
||| socket (the chunk decoder, the line splitter and the event parser) are
||| pure functions. Only plain `http` to an IPv4 address: there is no TLS and no
||| host name lookup. A body that is cut short is an error and a line has a
||| limit. See `doc/async-http-stream.md`.
module Network.Async.HTTP.Stream

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Network.Async
import Network.HTTP.Message
import Network.Socket.Data
import System.Posix.Errno
import Text.Encoding.UTF8

%default covering

-------------------------------------------------------------------------------
-- The chunk decoder

||| Where the decoder is in a chunked body.
public export
data ChunkState
  = SizeLine (List Bits8)   -- the size line so far, last byte first
  | InChunk Nat             -- bytes of the chunk still to come
  | AfterChunk              -- the line end that follows the data of a chunk
  | Trailer Bool            -- the trailer lines; whether the current one has any byte
  | Finished

||| The decoder before the first chunk.
export
chunkStart : ChunkState
chunkStart = SizeLine []

-- A hexadecimal number, then nothing but blanks, or a `;` and a chunk extension.
hexSize : List Bits8 -> Maybe Nat
hexSize bs =
  let (digits, after) = span isHex (dropWhile (== 32) bs)
  in if null digits || not (ok after) then Nothing else foldlM step 0 digits
  where
    isHex : Bits8 -> Bool
    isHex b = (b >= 48 && b <= 57) || (b >= 97 && b <= 102) || (b >= 65 && b <= 70)

    ok : List Bits8 -> Bool
    ok after = case dropWhile (\b => b == 32 || b == 9 || b == 13) after of
                 [] => True
                 (59 :: _) => True
                 _ => False

    step : Nat -> Bits8 -> Maybe Nat
    step acc b =
      if b >= 48 && b <= 57 then Just (acc * 16 + cast (b - 48))
      else if b >= 97 && b <= 102 then Just (acc * 16 + cast (b - 87))
      else if b >= 65 && b <= 70 then Just (acc * 16 + cast (b - 55))
      else Nothing

||| The longest size line of a chunk that is taken.
sizeLineLimit : Nat
sizeLineLimit = 128

||| Feed bytes of a chunked body to the decoder: the new state and the bytes of
||| the body that were in them. A size that is not a number, a size line that is
||| too long and anything but a line end after the data of a chunk are errors.
export
feedChunked : ChunkState -> List Bits8 -> Either String (ChunkState, List Bits8)
feedChunked st0 input = go st0 input []
  where
    go : ChunkState -> List Bits8 -> List Bits8 -> Either String (ChunkState, List Bits8)
    go st [] out = Right (st, reverse out)
    go Finished _ out = Right (Finished, reverse out)
    go (SizeLine acc) (b :: rest) out =
      if b == 10
         then (case hexSize (reverse acc) of
                 Nothing => Left "bad chunk size"
                 Just 0 => go (Trailer False) rest out
                 Just n => go (InChunk n) rest out)
         else if length acc >= sizeLineLimit then Left "chunk size line too long"
         else go (SizeLine (b :: acc)) rest out
    go (InChunk n) bs out =
      let (now, later) = splitAt n bs
          taken = length now
      in if taken == n then go AfterChunk later (reverseOnto out now)
         else go (InChunk (n `minus` taken)) later (reverseOnto out now)
    go AfterChunk (b :: rest) out =
      if b == 10 then go (SizeLine []) rest out
      else if b == 13 then go AfterChunk rest out
      else Left "bad end of a chunk"
    go (Trailer seen) (b :: rest) out =
      if b == 10 then (if seen then go (Trailer False) rest out else go Finished rest out)
      else go (Trailer (seen || b /= 13)) rest out

    reverseOnto : List Bits8 -> List Bits8 -> List Bits8
    reverseOnto acc xs = foldl (flip (::)) acc xs

-------------------------------------------------------------------------------
-- Lines and events

||| Complete lines in `pending` (last byte first) followed by `bytes`: the lines
||| without their line end, the rest of the input, and whether the last byte was
||| a CR (the LF that may follow it belongs to that line end). A line ends with
||| `\n`, `\r\n` or `\r`.
export
splitLines : (afterCR : Bool) -> (pending : List Bits8) -> (bytes : List Bits8) -> (List String, List Bits8, Bool)
splitLines afterCR pending bytes = go afterCR pending bytes []
  where
    line : List Bits8 -> String
    line revBytes = pack (decode (reverse revBytes))

    go : Bool -> List Bits8 -> List Bits8 -> List String -> (List String, List Bits8, Bool)
    go cr acc [] done = (reverse done, acc, cr)
    go cr acc (b :: rest) done =
      if b == 13 then go True [] rest (line acc :: done)
      else if b == 10 then (if cr then go False acc rest done else go False [] rest (line acc :: done))
      else go False (b :: acc) rest done

||| One server-sent event.
public export
record SseEvent where
  constructor MkSseEvent
  eventName : Maybe String
  payload : String           -- the `data` lines, joined with a line end

||| The lines of the event being read.
public export
record SseState where
  constructor MkSseState
  nameSoFar : Maybe String
  dataLines : List String    -- last first

export
sseStart : SseState
sseStart = MkSseState Nothing []

||| Feed one line. An empty line ends an event; it is given if it had data. A
||| line that starts with `:` is a comment, a field that is not `event` or
||| `data` (`id`, `retry`) is ignored; an empty `event` is no name.
export
feedSse : SseState -> String -> (SseState, Maybe SseEvent)
feedSse st "" =
  if null st.dataLines then (sseStart, Nothing)
  else (sseStart, Just (MkSseEvent st.nameSoFar (joinBy "\n" (reverse st.dataLines))))
feedSse st ln =
  if isPrefixOf ":" ln then (st, Nothing) else
    let (field, rest) = break (== ':') ln
        value = case unpack rest of
                  (':' :: ' ' :: v) => pack v
                  (':' :: v) => pack v
                  _ => ""
    in case field of
         "data" => ({ dataLines $= (value ::) } st, Nothing)
         "event" => ({ nameSoFar := if value == "" then Nothing else Just value } st, Nothing)
         _ => (st, Nothing)

||| The event left when the stream ends in the middle of one.
export
sseFlush : SseState -> Maybe SseEvent
sseFlush st = snd (feedSse st "")

-------------------------------------------------------------------------------
-- The connection

public export
data StreamError
  = ConnectFailed String
  | SendFailed String
  | RecvFailed String
  | BadAnswer String
  | HttpStatus Int String    -- the status and the start of the body

export
Show StreamError where
  show (ConnectFailed e) = "cannot connect: " ++ e
  show (SendFailed e) = "cannot send: " ++ e
  show (RecvFailed e) = "cannot receive: " ++ e
  show (BadAnswer e) = "bad answer: " ++ e
  show (HttpStatus s body) = "HTTP " ++ show s ++ ": " ++ body

||| The status and the headers of the answer; the names are in lower case.
public export
record Head where
  constructor MkHead
  status : Int
  headers : List (String, String)

data Framing = Chunked | Length | UntilClose

||| The longest line of the body that is taken, in bytes.
lineLimit : Nat
lineLimit = 1048576

||| A connection whose body is being read.
export
record Stream where
  constructor MkStream
  sock : Sock
  buf : Buffer
  framing : Framing
  chunks : IORef ChunkState
  left : IORef Nat                  -- bytes of a body of a given length still to come
  ended : IORef Bool
  broken : IORef (Maybe String)     -- why the body cannot be read any more
  started : IORef Bool              -- whether bytes of the body have come (for the byte order mark)
  afterCR : IORef Bool
  unread : IORef (List Bits8)       -- the line being read, last byte first
  unreadLen : IORef Nat
  queued : IORef (List String)      -- lines read and not yet fed
  events : IORef SseState

||| Close the connection. Closing again does nothing.
export
closeStream : Stream -> Task ()
closeStream s = onReactor (close s.sock)

bytesOf : Buffer -> Int -> IO (List Bits8)
bytesOf b n = go (n - 1) []
  where
    go : Int -> List Bits8 -> IO (List Bits8)
    go i acc = if i < 0 then pure acc else do
      x <- getBits8 b i
      go (i - 1) (x :: acc)

lower : String -> String
lower = pack . map toLower . unpack

-- The head of an answer in `bytes`: the head and the body bytes after it. The
-- head ends with an empty line; its line ends are `\r\n` or `\n`.
splitHead : List Bits8 -> Maybe (String, List Bits8)
splitHead bytes = go bytes [] 0 False
  where
    -- `len`: the bytes of the current line (without a CR); `any`: a line was seen
    go : List Bits8 -> List Bits8 -> Nat -> Bool -> Maybe (String, List Bits8)
    go [] _ _ _ = Nothing
    go (b :: rest) acc len any =
      let acc' = b :: acc
      in if b == 10 then (if len == 0 && any then Just (pack (decode (reverse acc')), rest) else go rest acc' 0 True)
         else if b == 13 then go rest acc' len any
         else go rest acc' (S len) any

parseHead : String -> Maybe Head
parseHead text =
  case lines' text of
    [] => Nothing
    (status :: fields) =>
      case words status of
        (version :: code :: _) =>
          if isPrefixOf "HTTP/" version
             then (\c => MkHead c (mapMaybe field fields)) <$> parsePositive code
             else Nothing
        _ => Nothing
  where
    lines' : String -> List String
    lines' t = filter (/= "") (map (pack . filter (/= '\r') . unpack) (lines t))

    field : String -> Maybe (String, String)
    field l = case break (== ':') l of
                (name, rest) => if rest == "" then Nothing
                                else Just (lower name, trim (pack (drop 1 (unpack rest))))

noLineEnd : String -> Bool
noLineEnd = not . any (\c => c == '\r' || c == '\n') . unpack

requestText : (host : String) -> (path : String) -> List (String, String) -> (body : String) -> String
requestText host path headers body =
  "POST " ++ path ++ " HTTP/1.1\r\n"
  ++ "Host: " ++ host ++ "\r\n"
  ++ "Accept: text/event-stream\r\n"
  ++ "Cache-Control: no-cache\r\n"
  ++ "Connection: close\r\n"
  ++ "Content-Length: " ++ show (stringByteLength body) ++ "\r\n"
  ++ concatMap (\(k, v) => k ++ ": " ++ v ++ "\r\n") headers
  ++ "\r\n" ++ body

-- Bytes of the body from `raw`, as the framing says.
decodeBody : Stream -> List Bits8 -> IO (Either String (List Bits8))
decodeBody s raw =
  case s.framing of
    UntilClose => pure (Right raw)
    Length => do
      n <- readIORef s.left
      let (now, _) = splitAt n raw
      writeIORef s.left (n `minus` length now)
      when (length now >= n) (writeIORef s.ended True)
      pure (Right now)
    Chunked => do
      st <- readIORef s.chunks
      case feedChunked st raw of
        Left e => pure (Left e)
        Right (st', out) => do
          writeIORef s.chunks st'
          case st' of
            Finished => writeIORef s.ended True
            _ => pure ()
          pure (Right out)

-- The start of the body of an event stream may be a byte order mark.
dropBom : Stream -> List Bits8 -> IO (List Bits8)
dropBom s out = do
  begun <- readIORef s.started
  if begun || null out then pure out else do
    writeIORef s.started True
    pure (case out of
            (239 :: 187 :: 191 :: rest) => rest
            _ => out)

-- Feed the body bytes `out` to the line splitter. A line that is too long is an error.
takeLines : Stream -> List Bits8 -> IO (Either String ())
takeLines s out = do
  pending <- readIORef s.unread
  cr <- readIORef s.afterCR
  oldLen <- readIORef s.unreadLen
  let (ls, rest, cr') = splitLines cr pending out
  writeIORef s.unread rest
  writeIORef s.afterCR cr'
  let newLen = if null ls then oldLen + length out else length rest
  writeIORef s.unreadLen newLen
  modifyIORef s.queued (++ ls)
  pure (if newLen > lineLimit then Left "a line of the body is too long" else Right ())

-- Decode the bytes that came, split them into lines; both or neither happens
-- if the task is given up.
absorb : Stream -> List Bits8 -> IO (Either String ())
absorb s raw = do
  decoded <- decodeBody s raw
  case decoded of
    Left e => writeIORef s.broken (Just e) *> pure (Left e)
    Right out => do
      out' <- dropBom s out
      r <- takeLines s out'
      case r of
        Left e => writeIORef s.broken (Just e) *> pure (Left e)
        Right () => pure (Right ())

-- Read more of the body into the lines; `False` at its end.
pullBody : Stream -> Task (Either StreamError Bool)
pullBody s = do
  failed <- liftIO (readIORef s.broken)
  done <- liftIO (readIORef s.ended)
  case (failed, done) of
    (Just e, _) => pure (Left (BadAnswer e))
    (_, True) => pure (Right False)
    _ => do
      r <- recv s.sock s.buf 0 4096
      case r of
        Left e => pure (Left (RecvFailed (show e)))
        Right 0 => do
          cut <- liftIO (cutShort s)
          liftIO (writeIORef s.ended True)
          pure (if cut then Left (RecvFailed "the connection closed before the end of the body") else Right False)
        Right n => do
          raw <- liftIO (bytesOf s.buf n)
          absorbed <- liftIO (absorb s raw)
          pure (either (Left . BadAnswer) (const (Right True)) absorbed)
  where
    -- Whether the body should have gone on.
    cutShort : Stream -> IO Bool
    cutShort st =
      case st.framing of
        UntilClose => pure False
        Length => (> 0) <$> readIORef st.left
        Chunked => do
          c <- readIORef st.chunks
          pure (case c of Finished => False; _ => True)

||| Wait for the next event; `Nothing` when the body has ended. The lines that
||| are not an event (comments, other fields) are passed over. A body that is cut
||| short, bytes that are not the framing the head says and a line over a mebibyte
||| are errors.
export
nextEvent : Stream -> Task (Either StreamError (Maybe SseEvent))
nextEvent s = do
  ready <- liftIO (readIORef s.queued)
  case ready of
    (l :: more) => do
      liftIO (writeIORef s.queued more)
      st <- liftIO (readIORef s.events)
      let (st', ev) = feedSse st l
      liftIO (writeIORef s.events st')
      case ev of
        Just _ => pure (Right ev)
        Nothing => nextEvent s
    [] => do
      more <- pullBody s
      case more of
        Left e => pure (Left e)
        Right True => nextEvent s
        Right False => do
          -- a last line without its line end, and an event without its blank line
          pending <- liftIO (readIORef s.unread)
          liftIO (writeIORef s.unread [])
          liftIO (writeIORef s.unreadLen 0)
          unless (null pending) $ liftIO (modifyIORef s.queued (++ fst (splitLines False pending [10])))
          rest <- liftIO (readIORef s.queued)
          case rest of
            (_ :: _) => nextEvent s
            [] => do
              st <- liftIO (readIORef s.events)
              liftIO (writeIORef s.events sseStart)
              pure (Right (sseFlush st))

-- The head of the answer: bytes read until the empty line.
readHead : Sock -> Buffer -> Int -> List Bits8 -> Task (Either StreamError (Head, List Bits8))
readHead sock buf budget acc =
  case splitHead acc of
    Just (text, rest) =>
      case parseHead text of
        Nothing => pure (Left (BadAnswer "bad status line"))
        Just h => pure (Right (h, rest))
    Nothing =>
      if budget <= 0 then pure (Left (BadAnswer "head too large")) else do
        r <- recv sock buf 0 4096
        case r of
          Left e => pure (Left (RecvFailed (show e)))
          Right 0 => pure (Left (BadAnswer "the connection closed before the head ended"))
          Right n => do
            bs <- liftIO (bytesOf buf n)
            readHead sock buf (budget - n) (acc ++ bs)

framingOf : Head -> (Framing, Nat)
framingOf h =
  case lookup "transfer-encoding" h.headers of
    Just v => if isInfixOf "chunked" (lower v) then (Chunked, 0) else (UntilClose, 0)
    Nothing => case lookup "content-length" h.headers >>= parsePositive of
                 Just n => (Length, n)
                 Nothing => (UntilClose, 0)

-- The start of what the body of an error answer says, on one line.
errorText : Stream -> Task String
errorText s = do
  _ <- race (fill 8) (sleepFor 3000)
  queued <- liftIO (readIORef s.queued)
  pending <- liftIO (readIORef s.unread)
  pure (pack (take 300 (unpack (joinBy " " (filter (/= "") (queued ++ [pack (decode (reverse pending))]))))))
  where
    fill : Nat -> Task ()
    fill Z = pure ()
    fill (S k) = do
      r <- pullBody s
      case r of
        Right True => do
          ls <- liftIO (readIORef s.queued)
          pending <- liftIO (readIORef s.unread)
          if length (unpack (joinBy " " ls)) + length pending >= 300 then pure () else fill k
        _ => pure ()

||| POST `body` to `path` on the server at `addr`:`port` and read the head of the
||| answer, as `Host` says `host`. A status outside 200..299 is an error with the
||| start of the body (what came in three seconds, up to 300 characters, the lines
||| joined with a blank). The answer is read with `nextEvent`; give the stream back
||| with `closeStream` when done. The socket is closed if the task is given up
||| before the head is read. CR and LF are not allowed in `host`, `path` and
||| `headers`.
export
streamPost : SocketAddress -> Port -> (host : String) -> (path : String)
          -> (headers : List (String, String)) -> (body : String)
          -> Task (Either StreamError (Head, Stream))
streamPost addr port host path headers body =
  if not (all noLineEnd (host :: path :: concatMap (\(k, v) => [k, v]) headers))
     then pure (Left (SendFailed "a line end in the request head"))
     else do
       connected <- connect addr port
       case connected of
         Left e => pure (Left (ConnectFailed (show e)))
         Right sock => finally (release sock) (exchange sock)
  where
    -- Gone with the socket unless a stream was made of it.
    release : Sock -> Maybe (Either StreamError (Head, Stream)) -> IO ()
    release sock (Just (Right _)) = pure ()
    release sock _ = close sock

    mkStream : Sock -> Buffer -> Framing -> Nat -> IO Stream
    mkStream sock buf framing n = do
      chunks <- newIORef chunkStart
      left <- newIORef n
      ended <- newIORef (case framing of Length => n == 0; _ => False)
      broken <- newIORef Nothing
      started <- newIORef False
      cr <- newIORef False
      unread <- newIORef []
      unreadLen <- newIORef 0
      queued <- newIORef []
      events <- newIORef sseStart
      pure (MkStream sock buf framing chunks left ended broken started cr unread unreadLen queued events)

    exchange : Sock -> Task (Either StreamError (Head, Stream))
    exchange sock = do
      Just buf <- liftIO (newBuffer 4096)
        | Nothing => pure (Left (ConnectFailed "no memory"))
      out <- liftIO (fromString (requestText host path headers body))
      sent <- sendAll sock out 0 (byteLength out)
      case sent of
        Left e => pure (Left (SendFailed (show e)))
        Right () => do
          answer <- readHead sock buf 65536 []
          case answer of
            Left e => pure (Left e)
            Right (h, restBytes) => do
              let (framing, n) = framingOf h
              s <- liftIO (mkStream sock buf framing n)
              first <- liftIO (absorb s restBytes)
              case first of
                Left e => pure (Left (BadAnswer e))
                Right () =>
                  if h.status >= 200 && h.status < 300 then pure (Right (h, s)) else do
                    text <- errorText s
                    pure (Left (HttpStatus h.status text))
