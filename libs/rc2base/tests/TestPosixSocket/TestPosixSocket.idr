module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Socket: constants, socketpair, TCP / UDP / Unix domain sockets
-- over the loopback, socket options, addresses.

import Data.Bits
import Data.Buffer
import Data.Maybe
import Data.List
import System.Directory
import System.Posix.Errno
import System.Posix.FileDesc
import System.Posix.Socket

path : String
path = "TestPosixSocket.scratch"

report : Show a => String -> Either Errno a -> IO ()
report what (Left e) = putStrLn (what ++ ": FAILED " ++ show e)
report what (Right v) = putStrLn (what ++ ": " ++ show v)

||| Send the text over one socket and read it from the other.
transfer : (from, to : FileDesc) -> String -> IO (Either Errno String)
transfer from to text = do
  Just buf <- newBuffer 64 | Nothing => pure (Left EINVAL)
  setString buf 0 text
  Right sent <- send from buf 0 (cast (length text)) 0 | Left e => pure (Left e)
  Right got <- recv to buf 0 64 0 | Left e => pure (Left e)
  s <- getString buf 0 got
  pure (Right (s ++ " (" ++ show sent ++ "/" ++ show got ++ ")"))

hostOf : SockAddr -> Bits32
hostOf (SockAddrIn a _) = a
hostOf _ = 0

portOf : SockAddr -> Bits16
portOf (SockAddrIn _ p) = p
portOf (SockAddrIn6 _ _ p) = p
portOf (SockAddrUn _) = 0

named : Either Errno (Maybe SockAddr) -> IO SockAddr
named (Right (Just a)) = pure a
named _ = pure (SockAddrUn "?")

constants : IO ()
constants = do
  putStrLn $ "AF_UNIX/INET/INET6: " ++ show (AF_UNIX, AF_INET, AF_INET6)
  putStrLn $ "SOCK_STREAM/DGRAM: " ++ show (SOCK_STREAM, SOCK_DGRAM)
  putStrLn $ "addresses: " ++ show (SockAddrIn 0x7f000001 8080) ++ " "
    ++ show (SockAddrIn6 0 1 443) ++ " " ++ show (SockAddrUn "/run/x")
  putStrLn $ "loopback == SockAddrIn 0x7f000001: " ++ show (loopback 9 == SockAddrIn 0x7f000001 9)

pair : IO ()
pair = do
  Right (a, b) <- socketpair AF_UNIX SOCK_STREAM 0
    | Left e => putStrLn ("socketpair: FAILED " ++ show e)
  transfer a b "hello" >>= report "pair a->b"
  transfer b a "world!" >>= report "pair b->a"
  _ <- shutdown a ShutWrite
  Just buf <- newBuffer 8 | Nothing => pure ()
  recv b buf 0 8 0 >>= report "recv after shutdown(write)"
  _ <- close a
  _ <- close b
  Right (c, d) <- socketpair AF_UNIX (SOCK_STREAM .|. SOCK_NONBLOCK) 0
    | Left e => putStrLn ("socketpair nonblock: FAILED " ++ show e)
  recv c buf 0 8 0 >>= report "recv with nothing to read"
  recv c buf 0 8 MSG_DONTWAIT >>= report "recv MSG_DONTWAIT"
  _ <- close c
  _ <- close d
  pure ()

tcp : IO ()
tcp = do
  Right l <- socket AF_INET SOCK_STREAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  setSockOptInt l SOL_SOCKET SO_REUSEADDR 1 >>= report "setsockopt SO_REUSEADDR"
  map (/= 0) <$> getSockOptInt l SOL_SOCKET SO_REUSEADDR >>= report "getsockopt SO_REUSEADDR set"
  bind l (loopback 0) >>= report "bind port 0"
  listen l 4 >>= report "listen"
  addr <- getSockName l >>= named
  putStrLn $ "bound to the loopback, port chosen: " ++ show (portOf addr /= 0)
  Right c <- socket AF_INET SOCK_STREAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  setSockOptInt c IPPROTO_TCP TCP_NODELAY 1 >>= report "setsockopt TCP_NODELAY"
  connect c addr >>= report "connect"
  Right (s, from) <- accept l | Left e => putStrLn ("accept: FAILED " ++ show e)
  putStrLn $ "accepted from the loopback: " ++ show (map hostOf from == Just 0x7f000001)
  peer <- getPeerName s >>= named
  mine <- getSockName c >>= named
  putStrLn $ "peer of the accepted is the client: " ++ show (peer == mine)
  socketError c >>= report "socketError"
  transfer c s "ping" >>= report "tcp c->s"
  transfer s c "pong" >>= report "tcp s->c"
  _ <- close s
  _ <- close c
  _ <- close l
  pure ()

udp : IO ()
udp = do
  Right a <- socket AF_INET SOCK_DGRAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  Right b <- socket AF_INET SOCK_DGRAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  bind a (loopback 0) >>= report "udp bind a"
  bind b (loopback 0) >>= report "udp bind b"
  addrA <- getSockName a >>= named
  addrB <- getSockName b >>= named
  Just buf <- newBuffer 32 | Nothing => pure ()
  setString buf 0 "datagram"
  sendTo b buf 0 8 0 addrA >>= report "sendTo"
  Right (n, Just src) <- recvFrom a buf 0 32 0
    | Right (n, Nothing) => putStrLn "recvFrom: no sender"
    | Left e => putStrLn ("recvFrom: FAILED " ++ show e)
  text <- getString buf 0 n
  putStrLn $ "recvFrom: " ++ text ++ ", from b: " ++ show (src == addrB)
  _ <- close a
  _ <- close b
  pure ()

unixDomain : IO ()
unixDomain = do
  _ <- removeFile path
  Right l <- socket AF_UNIX SOCK_STREAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  bind l (SockAddrUn path) >>= report "unix bind"
  listen l 1 >>= report "unix listen"
  Right c <- socket AF_UNIX SOCK_STREAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  connect c (SockAddrUn path) >>= report "unix connect"
  Right (s, from) <- accept l | Left e => putStrLn ("accept: FAILED " ++ show e)
  putStrLn $ "unnamed unix peer has no address: " ++ show (isNothing from)
  transfer c s "over a path" >>= report "unix c->s"
  name <- getSockName l >>= named
  putStrLn $ "unix name: " ++ show (name == SockAddrUn path)
  _ <- close s
  _ <- close c
  _ <- close l
  _ <- removeFile path
  pure ()

ipv6 : IO ()
ipv6 = do
  let loop6 = SockAddrIn6 0 1 0
  Right l <- socket AF_INET6 SOCK_STREAM 0
    | Left _ => putStrLn "ipv6: ok (no IPv6)"
  Right () <- bind l loop6
    | Left _ => putStrLn "ipv6: ok (no IPv6 loopback)" *> (ignore (close l))
  Right (Just (SockAddrIn6 hi lo p)) <- getSockName l
    | _ => putStrLn "ipv6: FAILED getSockName"
  putStrLn $ "ipv6: " ++ (if hi == 0 && lo == 1 && p /= 0 then "ok" else "FAILED")
  _ <- close l
  pure ()

edges : IO ()
edges = do
  putStrLn $ "ipv6 text: " ++ show (SockAddrIn6 0x20010db800000000 1 80)
  Right s <- socket AF_UNIX SOCK_STREAM 0 | Left e => putStrLn ("socket: FAILED " ++ show e)
  bind s (SockAddrUn (pack (replicate 200 'x'))) >>= report "bind with a path too long"
  Just buf <- newBuffer 8 | Nothing => pure ()
  send s buf 0 (-1) 0 >>= report "send with a negative length"
  recv s buf (-1) 4 0 >>= report "recv at a negative offset"
  _ <- close s
  pure ()

resolution : IO ()
resolution = do
  Right info <- getAddrInfo "127.0.0.1" "8080" AF_UNSPEC SOCK_STREAM AI_NUMERICSERV
    | Left e => putStrLn ("getAddrInfo: FAILED " ++ show e)
  addrInfoAddress info >>= printLn
  Right info6 <- getAddrInfo "::1" "443" AF_INET6 SOCK_STREAM (AI_NUMERICHOST .|. AI_NUMERICSERV)
    | Left e => putStrLn ("getAddrInfo ::1: FAILED " ++ show e)
  addrInfoAddress info6 >>= printLn
  Left _ <- getAddrInfo "not an address" "80" AF_UNSPEC SOCK_STREAM (AI_NUMERICHOST .|. AI_NUMERICSERV)
    | Right _ => putStrLn "getAddrInfo: bad host accepted"
  putStrLn "getAddrInfo: a bad host is refused"
  addressText (SockAddrIn 0xc0000201 1) >>= printLn
  addressText (SockAddrIn6 0x20010db800000000 1 1) >>= printLn
  addressText (SockAddrUn "/x") >>= printLn

main : IO ()
main = do
  constants
  pair
  tcp
  udp
  unixDomain
  ipv6
  edges
  resolution
