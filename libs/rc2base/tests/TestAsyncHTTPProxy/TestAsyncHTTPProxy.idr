module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Proxy: an upstream server and a proxy in front of it run as
-- tasks of one scheduler; a blocking client on the pool asks the proxy. The path
-- below the prefix (and the whole path with `stripMount = False`), the method and
-- the body, the headers (Host and X-Forwarded-Host, the hop-by-hop ones dropped,
-- two Set-Cookie kept), a redirect, HEAD, a big answer, the server that is not
-- there (502), an answer over the limit (502), one that takes too long (504) and
-- a request outside the prefix.

import Control.Task
import Control.Task.Scheduler
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Network.Async.HTTP.Proxy
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data
import System
import System.Posix.Errno

%default covering

upstreamPort, proxyPort, deadPort : Port
upstreamPort = 18761
proxyPort = 18762
deadPort = 18763

header : String -> Request -> String
header name req = fromMaybe "-" (lookup name req.headers)

upstream : Handler
upstream req = case fst (break (== '?') req.path) of
  "/hello" => liftIO (ok {headers = [("X-Up", "1"), ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2"), ("Keep-Alive", "timeout=5")]} "hello\n")
  "/info" => describe
  "/info/" => describe
  "/raw/info" => describe
  "/redirect" => liftIO (noBody {headers = [("Location", "/hello")]} 302)
  "/big" => liftIO (ok (pack (replicate 100000 'y')))
  "/slow" => sleepFor 2000 *> liftIO (ok "slow\n")
  _ => liftIO (notFound "upstream: none\n")
  where
    describe : Task Response
    describe = do
      body <- liftIO (toString req.body)
      liftIO (ok (joinBy " " [req.method, req.path, header "host" req, header "x-forwarded-host" req, header "x-custom" req
                             , header "connection" req, header "content-length" req, body] ++ "\n"))

localhost : SocketAddress
localhost = IPv4Addr 127 0 0 1

front : Handler
front =
  proxy "/api" localhost upstreamPort
    (proxy {options = { stripMount := False } defaultProxy} "/raw" localhost upstreamPort
      (proxy "/dead" localhost deadPort
        (proxy {options = { maxResponseBytes := 1000 } defaultProxy} "/small" localhost upstreamPort
          (proxy {options = { timeoutMs := 300 } defaultProxy} "/quick" localhost upstreamPort
            (\_ => liftIO (notFound "front: none\n"))))))

session : String -> IO String
session request = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("socket " ++ show e)
  0 <- connect sock localhost proxyPort
    | e => close sock *> pure ("connect " ++ show e)
  Right _ <- Network.Socket.send sock request
    | Left e => pure ("send " ++ show e)
  answer <- drain sock ""
  close sock
  pure answer
  where
    drain : Socket -> String -> IO String
    drain sock acc = do
      r <- Network.Socket.recv sock 65536
      case r of
        Right (s, n) => if n > 0 then drain sock (acc ++ s) else pure acc
        Left _ => pure acc

req : String -> String -> String
req method path = method ++ " " ++ path ++ " HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\n\r\n"

-- The head's lines of an answer and its body.
parts : String -> (List String, String)
parts answer = go [] (lines' answer)
  where
    lines' : String -> List String
    lines' = map (\l => if isSuffixOf "\r" l then pack (reverse (drop 1 (reverse (unpack l)))) else l)
             . forget . split (== '\n')
    go : List String -> List String -> (List String, String)
    go acc [] = (reverse acc, "")
    go acc ("" :: rest) = (reverse acc, joinBy "\n" rest)
    go acc (l :: rest) = go (l :: acc) rest

-- The status line, the headers named, and the body.
summary : (shown : List String) -> String -> String
summary shown answer =
  let (hdrs, body) = parts answer
      kept = filter (\h => any (\n => isPrefixOf (n ++ ":") (toLower h)) shown) (drop 1 hdrs)
  in joinBy " | " (take 1 hdrs ++ kept) ++ "\n" ++ body

-- A big answer is not taken apart: whether it starts as it should, and how long it is.
sizeOf : String -> String
sizeOf answer = show (isPrefixOf "HTTP/1.1 200 OK\r\n" answer) ++ " " ++ show (length answer)

clients : Task (List String)
clients = do
  let ask = \r => blocking (session r)
  let plain = summary ["content-type", "x-up", "set-cookie", "location", "keep-alive", "connection"]
  hello <- ask (req "GET" "/api/hello")
  info <- ask ("POST /api/info?a=1&b=%20 HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\nX-Custom: yes\r\nX-Forwarded-Host: spoofed\r\nContent-Length: 5\r\n\r\nhello")
  slash <- ask (req "GET" "/api/info/")
  root <- ask (req "GET" "/api")
  raw <- ask (req "GET" "/raw/info")
  redirect <- ask (req "GET" "/api/redirect")
  headed <- ask (req "HEAD" "/api/hello")
  big <- ask (req "GET" "/api/big")
  missing <- ask (req "GET" "/api/nothing")
  outside <- ask (req "GET" "/apix/hello")
  dead <- ask (req "GET" "/dead/hello")
  tooBig <- ask (req "GET" "/small/big")
  smallOk <- ask (req "GET" "/small/hello")
  slow <- ask (req "GET" "/quick/slow")
  quickOk <- ask (req "GET" "/quick/hello")
  pure [ plain hello, plain info, plain slash, plain root, plain raw, plain redirect, plain headed
       , sizeOf big, plain missing, plain outside, plain dead, plain tooBig, plain smallOk
       , plain slow, plain quickOk ]

main : IO ()
main = do
  r <- runTaskWith 3 (race (race (serve upstreamPort upstream) (serve proxyPort front)) clients)
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn ("a server ended: " ++ show (either id id stopped))
    Nothing => putStrLn "no result"
