||| The libcurl implementation of `Network.Async.HTTP.Client`: a transfer is a
||| task of the scheduler. It drives libcurl's multi interface itself --
||| `curl_multi_perform` when something happened, then a wait for the sockets
||| libcurl names (`curl_multi_waitfds`) with the scheduler's `epoll`, or for the
||| time libcurl names (`curl_multi_timeout`) -- so a slow server holds up nothing,
||| and no thread waits. The body is written to a memory stream, which is how
||| `streamAsync` hands it out in pieces while the transfer goes on. Needs
||| libcurl 8.8.0. See `doc/async-http-client.md`.
module Network.Async.HTTP.Client.Curl

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Control.Task
import Data.Bits
import Data.Buffer
import Data.IORef
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Data.String.FFI
import System.FFI
import System.Linux.Epoll
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Stdio

import public Network.HTTP.Client
import public Network.Async.HTTP.Client
import public Network.HTTP.Client.Curl
import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

%default covering

-------------------------------------------------------------------------------
-- The text of the heads (pure)

||| One response head as libcurl wrote it: a redirected transfer has one per
||| response.
public export
record RawHead where
  constructor MkRawHead
  hStatus : Int
  ||| Latest first while the text is read; `parseHeads` puts them in order.
  hHeaders : List (String, String)
  ||| Whether the blank line that ends it was seen.
  hClosed : Bool

-- `HTTP/1.1 200 OK` and `HTTP/2 200`: the second word.
statusOf : String -> Int
statusOf line = case words line of
  (_ :: code :: _) => fromMaybe 0 (parsePositive code)
  _ => 0

splitLines : String -> List String
splitLines text = map dropCR (forget (split (== '\n') text))
  where
    dropCR : String -> String
    dropCR l = if isSuffixOf "\r" l then substr 0 (length l `minus` 1) l else l

||| The heads in the text libcurl wrote to the header stream, first response first,
||| the headers of each in the order they came.
export
parseHeads : String -> List RawHead
parseHeads text = reverse (map ordered (foldl step [] (splitLines text)))
  where
    ordered : RawHead -> RawHead
    ordered (MkRawHead s hs c) = MkRawHead s (reverse hs) c

    step : List RawHead -> String -> List RawHead
    step acc line =
      if isPrefixOf "HTTP/" line then MkRawHead (statusOf line) [] False :: acc
      else if line == "" then (case acc of
                                  (MkRawHead s hs _ :: rest) => MkRawHead s hs True :: rest
                                  [] => [])
      else case (acc, break (== ':') (unpack line)) of
             (MkRawHead s hs c :: rest, (name, ':' :: value)) =>
                MkRawHead s ((pack name, trim (pack value)) :: hs) c :: rest
             _ => acc

-- Whether a redirect that libcurl follows (another head comes).
followed : RawHead -> Bool
followed h = elem h.hStatus [301, 302, 303, 307, 308]
          && any (\kv => toLower (fst kv) == "location") h.hHeaders

||| The head of the answer once it is all there: the last head, ended by its blank
||| line, that is neither informational (1xx) nor a redirect libcurl follows.
export
finalHead : List RawHead -> Maybe RawHead
finalHead heads = case last' heads of
  Just h => if h.hClosed && h.hStatus >= 200 && not (followed h) then Just h else Nothing
  Nothing => Nothing
  where
    last' : List a -> Maybe a
    last' [] = Nothing
    last' [x] = Just x
    last' (_ :: xs) = last' xs

-------------------------------------------------------------------------------
-- A transfer

%inline %foreign "CExpr:(memcpy($1, (const char *)($2) + $3, $4)),libc,string.h"
prim__copyOut : Buffer -> AnyPtr -> Bits64 -> Bits64 -> PrimIO AnyPtr

record Xfer where
  constructor MkXfer
  multi : AnyPtr
  easy : AnyPtr
  hlist : AnyPtr
  bodyMs : MemStream
  headMs : MemStream
  ||| Bytes of the body that were handed out.
  taken : IORef Bits64
  ||| The result of the transfer once libcurl is done with it.
  outcome : IORef (Maybe CURLcode)
  isOpen : IORef Bool

outcomeError : CURLcode -> FetchError
outcomeError c = TransportError (show c ++ " (" ++ curlEasyStrerror c ++ ")")

releaseStream : MemStream -> IO ()
releaseStream ms = do
  _ <- closeMemstream ms
  freeMemstream ms

openXfer : CurlOptions -> FetchRequest -> IO (Either FetchError Xfer)
openXfer o req = case requestError req of
  Just why => pure (Left (SetupError why))
  Nothing => do
    MkCURLcode 0 <- curlGlobalInitOnce
        | c => pure (Left (SetupError ("curl_global_init failed: " ++ show c)))
    Just easy <- curlEasyInit
        | Nothing => pure (Left (SetupError "curl_easy_init failed"))
    Right bodyMs <- openMemstream
        | Left _ => curlEasyCleanup easy >> pure (Left (SetupError "open_memstream failed"))
    Right headMs <- openMemstream
        | Left _ => do curlEasyCleanup easy
                       releaseStream bodyMs
                       pure (Left (SetupError "open_memstream failed"))
    hlist <- applyRequest o easy req
    _ <- curlEasySetoptPointer easy curlopt_WRITEDATA (memstreamFilePtr bodyMs)
    _ <- curlEasySetoptPointer easy curlopt_HEADERDATA (memstreamFilePtr headMs)
    let giveUp : String -> IO (Either FetchError Xfer)
        giveUp why = do curlEasyCleanup easy
                        curlSlistFreeAll hlist
                        releaseStream bodyMs
                        releaseStream headMs
                        pure (Left (SetupError why))
    Just multi <- curlMultiInit
        | Nothing => giveUp "curl_multi_init failed"
    MkCURLMcode 0 <- curlMultiAddHandle multi easy
        | c => do _ <- curlMultiCleanup multi
                  giveUp ("curl_multi_add_handle failed: " ++ show c)
    Right <$> (MkXfer multi easy hlist bodyMs headMs <$> newIORef 0 <*> newIORef Nothing <*> newIORef True)

||| Release everything; calling it again does nothing.
closeXfer : Xfer -> IO ()
closeXfer x = do
  True <- readIORef x.isOpen
      | False => pure ()
  writeIORef x.isOpen False
  _ <- curlMultiRemoveHandle x.multi x.easy
  curlEasyCleanup x.easy
  _ <- curlMultiCleanup x.multi
  curlSlistFreeAll x.hlist
  releaseStream x.bodyMs
  releaseStream x.headMs

||| Let libcurl do what it can without waiting; whether the transfer is over.
advance : Xfer -> IO (Either FetchError Bool)
advance x = do
  Nothing <- readIORef x.outcome
      | Just _ => pure (Right True)
  Right running <- curlMultiPerform x.multi
      | Left c => pure (Left (TransportError (curlMultiStrerror c)))
  if running > 0 then pure (Right False) else do
    Just (_, _, code) <- curlMultiInfoRead x.multi
        | Nothing => pure (Left (TransportError "the transfer ended without a result"))
    writeIORef x.outcome (Just code)
    pure (Right True)

-- The bytes of the stream that are not handed out yet.
takeBody : Xfer -> IO (Maybe Buffer)
takeBody x = do
  _ <- fflush (memstreamFile x.bodyMs)
  size <- memstreamSize x.bodyMs
  off <- readIORef x.taken
  if size <= off then pure Nothing else do
    let n = size - off
    Just buf <- newBuffer (cast n)
        | Nothing => pure Nothing
    raw <- memstreamData x.bodyMs
    _ <- primIO (prim__copyOut buf raw off n)
    writeIORef x.taken size
    pure (Just buf)

headText : Xfer -> IO String
headText x = do
  _ <- fflush (memstreamFile x.headMs)
  raw <- memstreamData x.headMs
  fromMaybe "" <$> ptrToString raw

-------------------------------------------------------------------------------
-- Waiting

-- The sockets libcurl waits on, one entry for each with its events together.
mergeWaits : List (Int32, Bits16) -> List (Int32, Bits16)
mergeWaits = foldl add []
  where
    add : List (Int32, Bits16) -> (Int32, Bits16) -> List (Int32, Bits16)
    add acc (fd, ev) =
      if any ((== fd) . fst) acc
         then map (\(f, e) => if f == fd then (f, e .|. ev) else (f, e)) acc
         else acc ++ [(fd, ev)]

-- `POLLIN` and `POLLOUT` are the `CURL_WAIT_*` bits.
epollOf : Bits16 -> EpollEvents
epollOf ev =
  let r = if (ev .&. 1) /= 0 then EPOLLIN else 0
      w = if (ev .&. 4) /= 0 then EPOLLOUT else 0
      both = r .|. w
  in if both == 0 then EPOLLIN else both

raceAny : List (Task ()) -> Task ()
raceAny [] = Empty
raceAny (t :: ts) = map (either id id) (race t (raceAny ts))

||| Until libcurl has something to do: a socket it waits on is ready, or the time it
||| named has passed.
waitStep : Xfer -> Task ()
waitStep x = do
  fds <- liftIO (curlMultiWaitfds x.multi)
  limit <- liftIO (curlMultiTimeout x.multi)
  let ms : Int = case limit of
                   Right t => if t < 0 then 50 else min 1000 t
                   Left _ => 50
  raceAny (sleepFor (cast {to=Nat} (max 0 ms)) :: map watch (mergeWaits (either (const []) id fds)))
  where
    watch : (Int32, Bits16) -> Task ()
    watch (fd, ev) = case mkFileDesc fd of
      Just f => map (const ()) (awaitEvents f (epollOf ev))
      Nothing => Empty

-------------------------------------------------------------------------------
-- The answer as a whole

drive : Xfer -> Task (Either FetchError ())
drive x = do
  Right over <- liftIO (advance x)
      | Left e => pure (Left e)
  if over then pure (Right ()) else waitStep x >> drive x

outcomeOf : Xfer -> IO (Either FetchError ())
outcomeOf x = do
  r <- readIORef x.outcome
  pure $ case r of
    Just (MkCURLcode 0) => Right ()
    Just c => Left (outcomeError c)
    Nothing => Left (TransportError "the transfer did not end")

-- The headers of the response that was the answer: the last head.
lastHeaders : List RawHead -> List (String, String)
lastHeaders [] = []
lastHeaders [h] = h.hHeaders
lastHeaders (_ :: hs) = lastHeaders hs

answerOf : Xfer -> IO (Either FetchError (Int, List (String, String), Buffer))
answerOf x = do
  Right () <- outcomeOf x
      | Left e => pure (Left e)
  Right status <- curlEasyGetinfoLong x.easy curlinfo_RESPONSE_CODE
      | Left c => pure (Left (outcomeError c))
  heads <- parseHeads <$> headText x
  Just body <- maybe (newBuffer 0) (pure . Just) =<< takeBody x
      | Nothing => pure (Left (SetupError "out of memory"))
  pure (Right (status, lastHeaders heads, body))

fetchWith : CurlOptions -> (Int -> List (String, String) -> Buffer -> r) -> FetchRequest -> Task (Either FetchError r)
fetchWith o mk req = do
  Right x <- liftIO (openXfer o req)
      | Left e => pure (Left e)
  finally (\_ => closeXfer x) $ do
    Right () <- drive x
        | Left e => pure (Left e)
    answer <- liftIO (answerOf x)
    pure (map (\(st, hs, b) => mk st hs b) answer)

-- The text of a body, cut at its first NUL like the synchronous client's.
bodyText : Int -> List (String, String) -> Buffer -> FetchResponse
bodyText st hs b = unsafePerformIO $ do
  size <- rawSize b
  s <- getString b 0 size
  pure (MkFetchResponse st hs (pack (takeWhile (/= '\0') (unpack s))))

-------------------------------------------------------------------------------
-- The answer in pieces

||| An answer whose body is still coming (`streamAsync`). `closeStream` it when done
||| with it unless `nextChunk` has given the end or an error: the transfer holds a
||| connection until then.
export
record FetchStream where
  constructor MkFetchStream
  xfer : Xfer

||| Send the request and wait for the head of the answer; the body is read with
||| `nextChunk`. A status outside 200..299 is not an error here. Giving the task up
||| before the head is there ends the transfer.
export
streamAsync : CurlClient -> FetchRequest -> Task (Either FetchError (FetchHead, FetchStream))
streamAsync (MkCurlClient o) req = do
  Right x <- liftIO (openXfer o req)
      | Left e => pure (Left e)
  finally (\r => case r of
                    Just (Right _) => pure ()
                    _ => closeXfer x) (headLoop x)
  where
    headLoop : Xfer -> Task (Either FetchError (FetchHead, FetchStream))
    headLoop x = do
      Right over <- liftIO (advance x)
          | Left e => pure (Left e)
      text <- liftIO (headText x)
      case finalHead (parseHeads text) of
        Just h => pure (Right (MkFetchHead h.hStatus h.hHeaders, MkFetchStream x))
        Nothing =>
          if over
            then map (\r => case r of
                              Left e => Left e
                              Right () => Left (TransportError "no head in the answer")) (liftIO (outcomeOf x))
            else waitStep x >> headLoop x

||| The next bytes of the body, as they arrive: `Nothing` at the end of the body. A
||| transfer that fails on the way is `Left`, not an end. The transfer is closed when
||| it gives the end or an error.
export
nextChunk : FetchStream -> Task (Either FetchError (Maybe Buffer))
nextChunk (MkFetchStream x) = do
  True <- liftIO (readIORef x.isOpen)
      | False => pure (Right Nothing)
  Right over <- liftIO (advance x)
      | Left e => liftIO (closeXfer x) >> pure (Left e)
  Nothing <- liftIO (takeBody x)
      | Just b => pure (Right (Just b))
  if over
    then liftIO (do r <- outcomeOf x
                    closeXfer x
                    pure (map (const Nothing) r))
    else waitStep x >> nextChunk (MkFetchStream x)

||| End the transfer; does nothing if it has ended.
export
closeStream : FetchStream -> Task ()
closeStream (MkFetchStream x) = liftIO (closeXfer x)

-------------------------------------------------------------------------------
-- The client

export
AsyncHTTPClient CurlClient where
  fetchAsync (MkCurlClient o) = fetchWith o bodyText'
    where
      bodyText' : Int -> List (String, String) -> Buffer -> FetchResponse
      bodyText' = bodyText
  fetchBytesAsync (MkCurlClient o) = fetchWith o MkFetchResponseBytes
