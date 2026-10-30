module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Client.WebAPI.AI.OpenAIStream: the endpoint URL and the pieces of a
-- reply on their own, then a server task that answers the way LM Studio does
-- (chunked events, a role first, `[DONE]` last) while a client task reads the
-- pieces; the request the server received is shown, and so are an error answer, a
-- failing key, an endpoint that cannot be used and a reply given up.

import Control.Task
import Control.Task.Scheduler
import Data.Buffer
import Data.IORef
import Data.List
import Data.Maybe
import Data.String
import Network.Async
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.OpenAIStream
import Network.HTTP.Message
import System.Posix.Errno

%default covering

port : Int
port = 18765

-------------------------------------------------------------------------------
-- The pure parts

showBase : String -> String
showBase url =
  case endpointUrl url of
    Left e => "error: " ++ e
    Right base => base

showDelta : String -> String
showDelta payload =
  case decodeDelta payload of
    Left e => "error: " ++ e
    Right Nothing => "done"
    Right (Just d) => show (d.content, d.reasoning, d.finish)

pureTests : IO ()
pureTests = do
  putStrLn "-- endpoint"
  traverse_ (putStrLn . showBase)
    [ "http://192.168.3.82:1234/v1", "http://localhost:8080", "http://127.0.0.1/v1/", "http://10.0.0.5:80/api/v1//"
    , "https://192.168.3.82/v1", "http://example.com/v1", "https://api.example.com/v1/", "http://[::1]:8080/v1", "ftp://1.2.3.4/", "/v1"
    , "HTTP://LocalHost:1234/V1", "http://localhost:abc/v1", "http://localhost:/v1", "http://h:8080x/", "http://localhost:0/"
    , "http://localhost:70000/", "http://localhost:65535", "http://+1.2.3.4/", "http://1.2.3.4.5/", "http://1.2.3/"
    , "http://1.2.3.4/v1?api-version=1", "http://1.2.3.4/v1#x", "http://user:pw@1.2.3.4/v1", "http:///v1", "http://:80/" ]
  putStrLn "-- pieces"
  traverse_ (putStrLn . showDelta)
    [ "[DONE]"
    , "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"finish_reason\":null}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"日本語\"}}]}"
    , "{\"choices\":[{\"delta\":{\"reasoning_content\":\"hmm\"}}]}"
    , "{\"choices\":[{\"delta\":{\"reasoning\":\"think\"}}]}"
    , "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"w\\u00f6rld \\u65e5\\u672c \\\\u00f6\"}}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"\\ud83d\\ude00!\"}}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"a\\ud83d b \\ude00 c \\ud83d\\u0041 \"}}]}"
    , "{\"choices\":[{\"delta\":{\"content\":\"\\u12\"}}]}"
    , "{\"choices\":[{\"delta\":{\"content\":null}}]}"
    , "{\"choices\":[],\"usage\":{\"total_tokens\":3}}"
    , "{\"error\":{\"message\":\"model not found\",\"type\":\"x\"}}"
    , "{\"error\":\"model crashed\"}"
    , "{\"error\":{\"code\":500}}"
    , "{\"error\":null,\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}"
    , "{\"choices\":[{\"index\":1,\"delta\":{\"content\":\"other\"}},{\"index\":0,\"delta\":{\"content\":\"mine\"}}]}"
    , "{\"choices\":[{\"index\":1,\"delta\":{\"content\":\"only the other\"}}]}"
    , "not json" ]

-------------------------------------------------------------------------------
-- A server that answers the way LM Studio does

-- What the client sent: read until the body (a JSON object) ends.
readRequest : Sock -> Task String
readRequest conn = do
  Just buf <- liftIO (newBuffer 8192)
    | Nothing => pure ""
  go buf 0
  where
    go : Buffer -> Int -> Task String
    go buf off = do
      r <- recv conn buf off (8192 - off)
      case r of
        Right n =>
          if n <= 0 then liftIO (getString buf 0 off) else do
            last <- liftIO (getBits8 buf (off + n - 1))
            if last == 125 || off + n >= 8192 then liftIO (getString buf 0 (off + n)) else go buf (off + n)
        Left _ => liftIO (getString buf 0 off)

sendText : Sock -> String -> Task ()
sendText conn text = do
  out <- liftIO (fromString text)
  _ <- sendAll conn out 0 (byteLength out)
  yield

chunk : String -> String
chunk s = asHex (stringByteLength s) ++ "\r\n" ++ s ++ "\r\n"
  where
    asHex : Int -> String
    asHex n = if n < 16 then singleton (digit n) else asHex (n `div` 16) ++ singleton (digit (n `mod` 16))
      where
        digit : Int -> Char
        digit d = if d < 10 then chr (ord '0' + d) else chr (ord 'a' + d - 10)

event : String -> String
event json = chunk ("data: " ++ json ++ "\n\n")

delta : String -> String
delta c = "{\"choices\":[{\"index\":0,\"delta\":{\"content\":\"" ++ c ++ "\"},\"finish_reason\":null}]}"

okHead : String
okHead = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n"

-- Serve one connection; the request the client sent is noted.
serve : IORef (List String) -> Sock -> (Sock -> Task ()) -> Task ()
serve log listener answer = do
  Right conn <- accept listener
    | Left _ => pure ()
  withSock conn $ do
    req <- readRequest conn
    liftIO (modifyIORef log (("request: " ++ req) ::))
    answer conn
    liftIO (shutdownWrite conn)

readAll : ChatStream -> Task (List String)
readAll cs = do
  r <- nextDelta cs
  case r of
    Left e => pure ["error: " ++ show e]
    Right Nothing => pure ["end"]
    Right (Just d) => do
      rest <- readAll cs
      pure (show (d.content, d.reasoning, d.finish) :: rest)

endpoint : IO (Either String (List (String, String))) -> Endpoint
endpoint auth = MkEndpoint ("http://127.0.0.1:" ++ show port ++ "/v1") auth

request : ChatRequest
request = { maxTokens := Just 64 } (chatRequest "test-model" [MkMessage System "be brief", MkMessage User "hi 日本"])

run : String -> IO (Either String (List (String, String))) -> (Sock -> Task ()) -> IO ()
run title auth answer = do
  putStrLn ("-- " ++ title)
  log <- newIORef []
  Right listener <- listen port
    | Left e => putStrLn ("listen " ++ show e)
  r <- runTaskWith 2 (do
         server <- fork (serve log listener answer)
         opened <- chatStream (endpoint auth) request
         got <- case opened of
                  Left e => pure ["failed: " ++ show e]
                  Right cs => do
                    pieces <- readAll cs
                    closeChat cs
                    pure pieces
         wait server
         pure got)
  close listener
  traverse_ putStrLn (fromMaybe ["timeout"] r)
  l <- readIORef log
  traverse_ (putStrLn . show) (reverse l)

main : IO ()
main = do
  pureTests

  run "a reply, piece by piece" (pure (Right [("Authorization", "Bearer secret")])) $ \conn => do
    sendText conn okHead
    sendText conn (event "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"},\"finish_reason\":null}]}")
    sendText conn (event (delta "Hel"))
    sendText conn (event (delta "lo, "))
    sendText conn (event "{\"choices\":[{\"delta\":{\"reasoning_content\":\"(thinking)\"}}]}")
    sendText conn (event (delta "w\\u00f6rld \\u65e5"))
    sendText conn (event "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}")
    sendText conn (event "[DONE]")
    sendText conn "0\r\n\r\n"

  run "the reply ends with the connection, without [DONE]" (pure (Right [])) $ \conn => do
    sendText conn "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n"
    sendText conn ("data: " ++ delta "a" ++ "\n\ndata: " ++ delta "b" ++ "\n\n")

  run "an error answer" (pure (Right [])) $ \conn =>
    sendText conn "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 49\r\n\r\n{\"error\":{\"message\":\"model not found\",\"x\":1}}"

  run "an error in the middle of the reply" (pure (Right [])) $ \conn => do
    sendText conn okHead
    sendText conn (event (delta "x"))
    sendText conn (event "{\"error\":{\"message\":\"out of memory\"}}")
    sendText conn "0\r\n\r\n"

  putStrLn "-- the key cannot be had"
  noKey <- runTaskWith 2 (chatStream (endpoint (pure (Left "no key"))) request)
  putStrLn (show (map (either show (const "stream")) noKey))

  putStrLn "-- an endpoint that cannot be used"
  traverse_ (\url => do
               r <- runTaskWith 2 (chatStream (MkEndpoint url (pure (Right []))) request)
               putStrLn (show (map (either show (const "stream")) r)))
    ["ftp://127.0.0.1/v1", "http://127.0.0.1:99999/v1", "http://127.0.0.1/v1?x=1"]
