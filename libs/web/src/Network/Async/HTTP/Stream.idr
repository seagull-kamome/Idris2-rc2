||| An HTTP client that gives the body of an answer as it arrives, for
||| server-sent events (`text/event-stream`): a language model that answers a
||| word at a time, a feed. It runs on `Network.Async.HTTP.Client.Curl` (libcurl,
||| as a task of the scheduler), so a slow server holds up nothing else, `https`
||| and host names work, and the framing of the body (chunked or of a given
||| length) is libcurl's. `streamPostUrl` sends a request and reads the head of
||| the answer; `nextEvent` then waits for the next event. The parts that need no
||| connection (the line splitter and the event parser) are pure functions. A
||| body that is cut short is an error and a line has a limit. See
||| `doc/async-http-stream.md`.
module Network.Async.HTTP.Stream

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Network.HTTP.Client
import Network.Async.HTTP.Client
import Network.Async.HTTP.Client.Curl
import Network.HTTP.Client.Curl
import Network.Address
import Text.Encoding.UTF8

%default covering

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

||| The longest line of the body that is taken, in bytes.
lineLimit : Nat
lineLimit = 1048576

||| An answer whose body is being read.
export
record Stream where
  constructor MkStream
  fetch : FetchStream
  ended : IORef Bool
  broken : IORef (Maybe StreamError)  -- why the body cannot be read any more
  started : IORef Bool                -- whether bytes of the body have come (for the byte order mark)
  afterCR : IORef Bool
  unread : IORef (List Bits8)         -- the line being read, last byte first
  unreadLen : IORef Nat
  queued : IORef (List String)        -- lines read and not yet fed
  events : IORef SseState

||| End the transfer. Closing again does nothing.
export
closeStream : Stream -> Task ()
closeStream s = closeStream s.fetch

bytesOf : Buffer -> IO (List Bits8)
bytesOf b = do
  n <- rawSize b
  go (n - 1) []
  where
    go : Int -> List Bits8 -> IO (List Bits8)
    go i acc = if i < 0 then pure acc else do
      x <- getBits8 b i
      go (i - 1) (x :: acc)

lower : String -> String
lower = pack . map toLower . unpack

noLineEnd : String -> Bool
noLineEnd = not . any (\c => c == '\r' || c == '\n') . unpack

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

-- Split the bytes that came into lines. It is run in the step that takes the bytes
-- (`nextChunkWith`), so a task given up loses nothing it has read.
absorb : Stream -> Buffer -> IO (Either String ())
absorb s chunk = do
  raw <- bytesOf chunk
  out <- dropBom s raw
  r <- takeLines s out
  case r of
    Left e => writeIORef s.broken (Just (BadAnswer e)) *> pure (Left e)
    Right () => pure (Right ())

-- A transfer that failed to connect is told from one that failed on the way.
fromFetchError : FetchError -> StreamError
fromFetchError (SetupError m) = SendFailed m
fromFetchError (TransportError m) =
  if isPrefixOf "CURLcode 7 " m || isPrefixOf "CURLcode 6 " m then ConnectFailed m else RecvFailed m
fromFetchError (HttpError s) = HttpStatus s ""

-- Read more of the body into the lines; `False` at its end.
pullBody : Stream -> Task (Either StreamError Bool)
pullBody s = do
  failed <- liftIO (readIORef s.broken)
  done <- liftIO (readIORef s.ended)
  case (failed, done) of
    (Just e, _) => pure (Left e)
    (_, True) => pure (Right False)
    _ => do
      r <- nextChunkWith (absorb s) s.fetch
      case r of
        Left e => do
          let e' = fromFetchError e
          liftIO (writeIORef s.broken (Just e'))
          pure (Left e')
        Right Nothing => liftIO (writeIORef s.ended True) *> pure (Right False)
        Right (Just (Left m)) => pure (Left (BadAnswer m))
        Right (Just (Right ())) => pure (Right True)

||| Wait for the next event; `Nothing` when the body has ended. The lines that
||| are not an event (comments, other fields) are passed over. A body that is cut
||| short and a line over a mebibyte are errors.
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

-- 30 seconds to connect and no other limit: a model may think for minutes before
-- its first word, and the client's low-speed abort would end that.
streamOptions : CurlOptions
streamOptions = MkCurlOptions 30000 0 0 0 10

mkStream : FetchStream -> IO Stream
mkStream fs = do
  ended <- newIORef False
  broken <- newIORef Nothing
  started <- newIORef False
  cr <- newIORef False
  unread <- newIORef []
  unreadLen <- newIORef 0
  queued <- newIORef []
  events <- newIORef sseStart
  pure (MkStream fs ended broken started cr unread unreadLen queued events)

||| POST `body` to `url` and read the head of the answer (`Accept:
||| text/event-stream`; `headers` come after and may replace that). A status outside
||| 200..299 is an error with the start of the body (what came in three seconds, up to
||| 300 characters, the lines joined with a blank). The answer is read with
||| `nextEvent`; give the stream back with `closeStream` when done. The transfer is
||| ended if the task is given up before the head is read. CR and LF are not allowed
||| in `url` and `headers`.
export
streamPostUrl : (url : String) -> (headers : List (String, String)) -> (body : String)
             -> Task (Either StreamError (Head, Stream))
streamPostUrl url headers body =
  if not (all noLineEnd (url :: concatMap (\(k, v) => [k, v]) headers))
     then pure (Left (SendFailed "a line end in the request head"))
     else do
       opened <- streamAsync (curlClientWith streamOptions)
                   (MkFetchRequest url POST (("Accept", "text/event-stream") :: ("Cache-Control", "no-cache") :: headers) (Just body))
       case opened of
         Left e => pure (Left (fromFetchError e))
         Right (h, fs) => do
           s <- liftIO (mkStream fs)
           let head = MkHead h.status (map (\(k, v) => (lower k, v)) h.headers)
           if h.status >= 200 && h.status < 300 then pure (Right (head, s)) else do
             text <- errorText s
             closeStream s
             pure (Left (HttpStatus h.status text))

||| `streamPostUrl` for the server at `addr`:`port` (`http`), with `Host` as `host`
||| says.
export
streamPost : SocketAddress -> Port -> (host : String) -> (path : String)
          -> (headers : List (String, String)) -> (body : String)
          -> Task (Either StreamError (Head, Stream))
streamPost addr port host path headers body =
  streamPostUrl ("http://" ++ show addr ++ ":" ++ show port ++ path) (("Host", host) :: headers) body
