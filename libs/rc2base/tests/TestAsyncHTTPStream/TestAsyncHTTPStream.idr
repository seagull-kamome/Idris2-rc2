module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Stream: the pure parts (chunk decoder, line splitter, event
-- parser) on their own, then a server task that sends an answer in pieces while the
-- client task reads the events: events arrive while the server is still sending, a
-- chunked body, a body of a given length and one that ends with the connection,
-- bytes cut in the middle of a character, an error status, and a server that
-- is not there.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.IORef
import Data.List
import Data.String
import Network.Async
import Network.Async.HTTP.Stream
import Network.HTTP.Message
import Network.Socket.Data
import System.Posix.Errno
import Text.Encoding.UTF8

%default covering

port : Port
port = 18764

-------------------------------------------------------------------------------
-- The pure parts

bytes : String -> List Bits8
bytes = encode . unpack

showText : List Bits8 -> String
showText = pack . decode

chunkedAll : List String -> String
chunkedAll parts =
  case foldlM (\(st, acc), p => map (\(st', out) => (st', acc ++ out)) (feedChunked st (bytes p))) (chunkStart, []) parts of
    Left e => "error: " ++ e
    Right (_, out) => showText out

chunkedTests : IO ()
chunkedTests = do
  putStrLn "-- chunked"
  putStrLn (chunkedAll ["5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n"])
  putStrLn (chunkedAll ["5\r\nhel", "lo\r\n", "6\r", "\n wor", "ld\r\n0\r", "\n\r\n"])
  putStrLn (chunkedAll ["A;ext=1\r\n0123456789\r\n0\r\nTrailer: x\r\n\r\n"])
  putStrLn (chunkedAll ["1\r\na\r\n0\r\n\r\nignored after the end"])
  putStrLn (chunkedAll ["zz\r\nabc"])
  putStrLn (chunkedAll ["3\r\n日\r\n0\r\n\r\n"])
  putStrLn (chunkedAll ["3\r\nabcXX\r\n"])
  putStrLn (chunkedAll ["3 junk\r\nabc\r\n"])
  putStrLn (chunkedAll ["3  \r\nabc\r\n0\r\n\r\n"])
  putStrLn (chunkedAll [pack (replicate 200 '1'), "\r\n"])

linesTests : IO ()
linesTests = do
  putStrLn "-- lines"
  let (ls, rest, cr) = splitLines False [] (bytes "one\ntwo\r\nthr")
  putStrLn (show (ls, showText (reverse rest), cr))
  let (ls2, rest2, _) = splitLines False (reverse (bytes "thr")) (bytes "ee\n\nfour")
  putStrLn (show (ls2, showText (reverse rest2)))
  let whole = bytes "日本\n"
  let (a, b) = splitAt 2 whole
  let (l1, r1, c1) = splitLines False [] a
  let (l2, r2, _) = splitLines c1 r1 b
  putStrLn (show (l1, l2, showText (reverse r2)))
  -- a CR alone ends a line, and an LF after a CR in the next read belongs to it
  let (m1, p1, c2) = splitLines False [] (bytes "a\rb\r")
  let (m2, p2, c3) = splitLines c2 p1 (bytes "\nc\r\nd")
  putStrLn (show (m1, m2, showText (reverse p2), c3))

sseAll : List String -> List (Maybe String, String)
sseAll ls = go sseStart ls
  where
    go : SseState -> List String -> List (Maybe String, String)
    go st [] = []
    go st (l :: rest) =
      let (st', ev) = feedSse st l
      in maybe id (\e => ((e.eventName, e.payload) ::)) ev (go st' rest)

sseTests : IO ()
sseTests = do
  putStrLn "-- events"
  putStrLn (show (sseAll ["data: a", "", "data: b", "data: c", "", ": a comment", "event: ping", "data:d", "", "id: 7", "", "data: x"]))
  putStrLn (show (sseAll ["event:", "data: e", "", "retry: 5", "data", ""]))
  putStrLn (show (map (\e => e.payload) (sseFlush (fst (feedSse sseStart "data: last")))))
  putStrLn (show (map (\e => e.payload) (sseFlush sseStart)))

-------------------------------------------------------------------------------
-- A server that sends an answer in pieces

-- Read the request: until the body, which ends with a `}`, is there.
swallow : Sock -> Task ()
swallow conn = do
  Just buf <- liftIO (newBuffer 4096)
    | Nothing => pure ()
  go buf
  where
    go : Buffer -> Task ()
    go buf = do
      r <- recv conn buf 0 4096
      case r of
        Right n => if n <= 0 then pure () else do
                     last <- liftIO (getBits8 buf (n - 1))
                     when (last /= 125) (go buf)
        Left _ => pure ()

-- Send the string, cut into pieces of `n` bytes, with a yield between them.
sendPieces : Sock -> (n : Int) -> String -> Task ()
sendPieces conn n text = do
  out <- liftIO (fromString text)
  let size = byteLength out
  go out size 0
  where
    go : Buffer -> Int -> Int -> Task ()
    go out size off =
      if off >= size then pure () else do
        let len = min n (size - off)
        _ <- sendAll conn out off len
        yield
        go out size (off + len)

serveWith : IORef (List String) -> (Sock -> Task ()) -> Sock -> Task ()
serveWith log script listener = do
  Right conn <- accept listener
    | Left _ => pure ()
  withSock conn $ do
    swallow conn
    script conn
    liftIO (shutdownWrite conn)

note : IORef (List String) -> String -> IO ()
note log s = modifyIORef log (s ::)

-- Read events until the end; each is noted as it comes.
readAll : IORef (List String) -> Stream -> Task (List String)
readAll log s = do
  r <- nextEvent s
  case r of
    Left e => pure ["error: " ++ show e]
    Right Nothing => pure ["end"]
    Right (Just ev) => do
      liftIO (note log ("recv " ++ ev.payload))
      rest <- readAll log s
      pure (ev.payload :: rest)

streamTest : String -> (IORef (List String) -> Sock -> Task ()) -> IO ()
streamTest title script = do
  putStrLn ("-- " ++ title)
  log <- newIORef []
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (serveWith log (script log) listener)
         answer <- streamPost (IPv4Addr 127 0 0 1) port "localhost" "/v1/chat" [("X-Test", "1")] "{\"hello\":\"world\"}"
         got <- case answer of
                  Left e => pure ["failed: " ++ show e]
                  Right (h, s) => do
                    liftIO (note log ("status " ++ show h.status))
                    events <- readAll log s
                    closeStream s
                    pure events
         wait server
         pure got)
  close listener
  putStrLn (show r)
  l <- readIORef log
  putStrLn (show (reverse l))

sseHead : String -> String
sseHead framing = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n" ++ framing ++ "\r\n\r\n"

chunk : String -> String
chunk s = asHex (stringByteLength s) ++ "\r\n" ++ s ++ "\r\n"
  where
    asHex : Int -> String
    asHex n = if n < 16 then singleton (digit n) else asHex (n `div` 16) ++ singleton (digit (n `mod` 16))
      where
        digit : Int -> Char
        digit d = if d < 10 then chr (ord '0' + d) else chr (ord 'a' + d - 10)

-- Give up after `ms` milliseconds.
timeoutAt' : Nat -> Task a -> Task (Maybe a)
timeoutAt' ms t = do
  r <- race t (sleepFor ms)
  pure (either Just (const Nothing) r)

main : IO ()
main = do
  chunkedTests
  linesTests
  sseTests

  -- the events arrive while the server is still sending the next ones
  streamTest "chunked, events arrive while the server is sending" $ \log, conn => do
    sendPieces conn 1000 (sseHead "Transfer-Encoding: chunked")
    liftIO (note log "send 1")
    sendPieces conn 1000 (chunk "data: one\n\n")
    sleepFor 50
    liftIO (note log "send 2")
    sendPieces conn 1000 (chunk "data: two\n\n" ++ chunk ": keep alive\n\n" ++ chunk "data: [DONE]\n\n" ++ "0\r\n\r\n")

  streamTest "an answer cut into pieces of three bytes" $ \log, conn =>
    sendPieces conn 3 (sseHead "Transfer-Encoding: chunked" ++ chunk "data: a b c\n\n" ++ chunk "data: d\ndata: e\n\n" ++ "0\r\n\r\n")

  streamTest "characters cut in the middle" $ \log, conn =>
    sendPieces conn 1 (sseHead "Transfer-Encoding: chunked" ++ chunk "data: 日本語のテキスト\n\n" ++ "0\r\n\r\n")

  streamTest "a body of a given length" $ \log, conn => do
    let body = "data: x\n\ndata: y\n\n"
    sendPieces conn 5 (sseHead ("Content-Length: " ++ show (stringByteLength body)) ++ body)

  streamTest "a body that ends with the connection, the last event without its blank line" $ \log, conn =>
    sendPieces conn 4 (sseHead "Connection: close" ++ "data: p\n\ndata: q")

  streamTest "an error status" $ \log, conn =>
    sendPieces conn 100 ("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 14\r\n\r\n{\"error\":\"no\"}")

  streamTest "not an answer" $ \log, conn =>
    sendPieces conn 100 "garbage\r\n\r\n"

  streamTest "the head ends with a bare line feed, a byte order mark, CR line ends" $ \log, conn =>
    sendPieces conn 7 ("HTTP/1.1 200 OK\nContent-Type: text/event-stream\n\n" ++ "\xFEFF" ++ "data: a\r\rdata: b\r\n\r\n")

  streamTest "a chunked body cut short is an error, not an end" $ \log, conn =>
    sendPieces conn 100 (sseHead "Transfer-Encoding: chunked" ++ chunk "data: a\n\n" ++ "5\r\nda")

  streamTest "a body shorter than its length is an error" $ \log, conn =>
    sendPieces conn 100 (sseHead "Content-Length: 100" ++ "data: a\n\n")

  streamTest "a chunk size that is not a number" $ \log, conn =>
    sendPieces conn 100 (sseHead "Transfer-Encoding: chunked" ++ chunk "data: a\n\n" ++ "zz\r\n")

  streamTest "a body with no line end is cut off at the limit" $ \log, conn =>
    sendPieces conn 65536 (sseHead "Connection: close" ++ "data: " ++ pack (replicate 1100000 'x'))

  putStrLn "-- a line end in the request is refused before anything is sent"
  refused <- runTaskWith 2 (do
               a <- streamPost (IPv4Addr 127 0 0 1) port "h\r\nX: y" "/" [] ""
               b <- streamPost (IPv4Addr 127 0 0 1) port "h" "/ HTTP/1.1\r\n" [] ""
               c <- streamPost (IPv4Addr 127 0 0 1) port "h" "/" [("A", "b\nc")] ""
               pure (map (either show (const "sent")) [a, b, c]))
  putStrLn (show refused)

  putStrLn "-- the socket is closed when the task is given up"
  closedLog <- newIORef []
  Right closedListener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  gaveUp <- runTaskWith 2 (do
         server <- fork (do
                     Right conn <- accept closedListener
                       | Left _ => pure ()
                     withSock conn $ do
                       swallow conn
                       -- no answer; the next thing heard is the client closing
                       Just buf <- liftIO (newBuffer 16)
                         | Nothing => pure ()
                       r <- recv conn buf 0 16
                       liftIO (note closedLog (case r of Right 0 => "closed by the client"; _ => "other")))
         gave <- timeoutAt' 100 (streamPost (IPv4Addr 127 0 0 1) port "localhost" "/" [] "{}")
         wait server
         pure gave)
  close closedListener
  putStrLn (show (map (map (either show (const "head"))) gaveUp))
  readIORef closedLog >>= putStrLn . show

  putStrLn "-- no server"
  r <- runTaskWith 2 (streamPost (IPv4Addr 127 0 0 1) port "localhost" "/" [] "")
  putStrLn (show (map (either show (const "connected")) r))
