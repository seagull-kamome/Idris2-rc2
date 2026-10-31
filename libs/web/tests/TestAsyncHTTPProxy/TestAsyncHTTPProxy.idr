module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Proxy: an upstream server and a proxy in front of it run as
-- tasks of one scheduler; a blocking client on the pool asks the proxy. The path
-- below the prefix (and the whole path with `stripMount = False`), the method and
-- the same through routes of `routerWith` (`forwardTo`: the rest of the path is its argument),
-- the body, the headers (Host and X-Forwarded-Host, the hop-by-hop ones and the ones
-- `Connection` names dropped, a `..` segment (400), an answer with chunked framing (502),
-- two Set-Cookie kept), a redirect, HEAD, a big answer, the server that is not
-- there (502), an answer over the limit (502), one that takes too long (504) and
-- a request outside the prefix.

import Control.Task
import Control.Task.Scheduler
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Data.Buffer
import Network.Async
import Network.Async.HTTP.Proxy
import Network.Async.HTTP.Router
import Network.HTTP.Route
import Network.HTTP.Router
import Network.Address
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data

import System
import System.Posix.Errno

-- Network.Address has the same names; the ones of `network` are the clients'.
%hide System.Posix.Socket.Port.Port

%default covering

upstreamPort, proxyPort, deadPort : Port
upstreamPort = 18771
proxyPort = 18772
deadPort = 18773

header : String -> Request -> String
header name req = fromMaybe "-" (lookup name req.headers)

upstream : Handler
upstream req = case fst (break (== '?') req.path) of
  "/hello" => liftIO (ok {headers = [("X-Up", "1"), ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2"), ("Keep-Alive", "timeout=5")]} "hello\n")
  "/info" => describe
  "/info/" => describe
  "/raw/info" => describe
  "/chunked" => liftIO (ok {headers = [("Transfer-Encoding", "chunked")]} "4\r\nabcd\r\n0\r\n\r\n")
  "/redirect" => liftIO (noBody {headers = [("Location", "/hello")]} 302)
  "/big" => liftIO (ok (pack (replicate 100000 'y')))
  "/slow" => sleepFor 2000 *> liftIO (ok "slow\n")
  _ => liftIO (notFound "upstream: none\n")
  where
    describe : Task Response
    describe = do
      body <- liftIO (toString req.body)
      liftIO (ok (joinBy " " [req.method, req.path, header "host" req, header "x-forwarded-host" req, header "x-custom" req, header "x-secret" req
                             , header "x-forwarded-for" req, header "forwarded" req, header "x-real-ip" req, header "x-forwarded-proto" req
                             , header "connection" req, header "content-length" req, body] ++ "\n"))

localhost : Network.Address.SocketAddress
localhost = Network.Address.IPv4Addr 127 0 0 1

-- A server that says the same thing to everyone who connects, and closes without
-- reading what they send (the system then resets the connection).
record Raw where
  constructor MkRaw
  mount : String
  port : Port
  reply : String
  options : ProxyOptions

-- An answer of exactly this many bytes (head and body).
exact : String
exact = "HTTP/1.0 200 OK\r\n\r\nabcd"

raws : List Raw
raws =
  [ MkRaw "/r100" 18791 "HTTP/1.1 100 Continue\r\n\r\n" defaultProxy
  , MkRaw "/rplus" 18792 "HTTP/1.1 +200 OK\r\nContent-Length: 0\r\n\r\n" defaultProxy
  , MkRaw "/rbadcl" 18793 "HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\nxx" defaultProxy
  , MkRaw "/rdupcl" 18794 "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc" defaultProxy
  , MkRaw "/rnocl" 18795 "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\nuntil the end" defaultProxy
  , MkRaw "/rshort" 18796 "HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc" defaultProxy
  , MkRaw "/rexact" 18797 exact ({ maxResponseBytes := cast (length exact) } defaultProxy)
  , MkRaw "/rover" 18798 exact ({ maxResponseBytes := cast (length exact) - 1 } defaultProxy)
  , MkRaw "/rhead" 18799 ("HTTP/1.1 200 OK\r\nX-Pad: " ++ pack (replicate 300 'p') ++ "\r\nContent-Length: 0\r\n\r\n")
          ({ maxHeadBytes := 100 } defaultProxy)
  , MkRaw "/rearly" 18800 "HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n" defaultProxy
  ]

rawServer : Raw -> Task ()
rawServer r = do
  Right listener <- liftIO (Network.Async.listen (cast r.port))
    | Left _ => pure ()
  withSock listener $ forever $ do
    Right conn <- Network.Async.accept listener
      | Left _ => pure ()
    withSock conn $ do
      bytes <- liftIO (fromString r.reply)
      ignore (Network.Async.sendAll conn bytes 0 (byteLength bytes))

-- The same as a route of `routerWith`, which is given the request: `forwardTo` on the
-- rest of the path.
viaRoute : List RouteEntryWith
viaRoute =
  [ get ("fwd" // splat) (forwardTo localhost (cast upstreamPort))
  , post ("fwd" // splat) (forwardTo localhost (cast upstreamPort))
  ]

mainMounts : Handler
mainMounts =
  proxy "/api" localhost (cast upstreamPort)
    (proxy {options = { stripMount := False } defaultProxy} "/raw" localhost (cast upstreamPort)
      (proxy "/dead" localhost (cast deadPort)
        (proxy {options = { maxResponseBytes := 1000 } defaultProxy} "/small" localhost (cast upstreamPort)
          (proxy {options = { timeoutMs := 300 } defaultProxy} "/quick" localhost (cast upstreamPort)
            (routerWith (\_ => liftIO (notFound "front: none\n")) viaRoute)))))


front : Handler
front = foldr (\r, next => proxy {options = r.options} r.mount localhost (cast r.port) next) mainMounts raws

session : String -> IO String
session request = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("socket " ++ show e)
  0 <- connect sock (IPv4Addr 127 0 0 1) proxyPort
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
  -- the servers are started by tasks of the same scheduler: let them listen
  sleepFor 200
  let ask = \r => blocking (session r)
  let plain = summary ["content-type", "x-up", "set-cookie", "location", "keep-alive", "connection"]
  hello <- ask (req "GET" "/api/hello")
  info <- ask ("POST /api/info?a=1&b=%20 HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\nX-Custom: yes\r\nX-Forwarded-Host: spoofed\r\nX-Forwarded-For: 1.2.3.4\r\nForwarded: for=1.2.3.4\r\nX-Real-IP: 9.9.9.9\r\nContent-Length: 5\r\n\r\nhello")
  unlisted <- ask "GET /api/info HTTP/1.1\r\nHost: front.test\r\nConnection: close, X-Secret\r\nX-Secret: s\r\nX-Other: o\r\n\r\n"
  dotdot <- ask (req "GET" "/api/../admin")
  encoded <- ask (req "GET" "/api/%2e%2e/admin")
  chunked <- ask (req "GET" "/api/chunked")
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
  viaRoutes <- traverse ask
    [ req "GET" "/fwd/hello", req "HEAD" "/fwd/hello"
    , "POST /fwd/info?q=1 HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\nX-Custom: yes\r\nContent-Length: 4\r\n\r\nbody"
    , req "GET" "/fwd/../admin" ]
  encodedSlash <- ask (req "GET" "/api/..%2f..%2fetc")
  encodedBackslash <- ask (req "GET" "/api/..%5cetc")
  tabbed <- ask "GET /api/a\tb HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\n\r\n"
  rawAnswers <- traverse (\path => ask (req "GET" (path ++ "/x")))
                  ["/r100", "/rplus", "/rbadcl", "/rdupcl", "/rnocl", "/rshort", "/rexact", "/rover", "/rhead"]
  let body = pack (replicate 2000000 'x')
  early <- ask ("POST /rearly/upload HTTP/1.1\r\nHost: front.test\r\nConnection: close\r\nContent-Length: "
                ++ show (length body) ++ "\r\n\r\n" ++ body)
  pure ([ plain hello, plain info, plain unlisted, plain dotdot, plain encoded, plain chunked, plain slash, plain root, plain raw, plain redirect, plain headed
       , sizeOf big, plain missing, plain outside, plain dead, plain tooBig, plain smallOk
       , plain slow, plain quickOk, plain encodedSlash, plain encodedBackslash, plain tabbed ]
       ++ map plain rawAnswers ++ [plain early] ++ map plain viaRoutes)

main : IO ()
main = do
  r <- runTaskWith 3 (race (race (serve (cast upstreamPort) upstream) (traverse_ (spawn . rawServer) raws *> serve (cast proxyPort) front)) clients)
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn ("a server ended: " ++ show (either id id stopped))
    Nothing => putStrLn "no result"
