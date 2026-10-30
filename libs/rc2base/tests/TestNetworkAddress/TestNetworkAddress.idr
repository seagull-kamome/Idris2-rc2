module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Address: dotted decimal in and out, the socket address it makes.
-- Network.RC2: String and Buffer IO over a socket pair, a read that would block.

import Data.Bits
import Data.Buffer
import Network.Address
import Network.RC2
import System.Posix.Errno
import System.Posix.Fcntl
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Socket

parseCases : List String
parseCases =
  [ "127.0.0.1", "0.0.0.0", "255.255.255.255", "10.20.30.40"
  , "256.0.0.1", "1.2.3", "1.2.3.4.5", "1..2.3", "a.b.c.d", "", "01.2.3.4", "1.2.3.-4", " 1.2.3.4" ]

showParse : String -> String
showParse s = show s ++ " -> " ++ maybe "none" show (parseAddress s)

main : IO ()
main = do
  traverse_ (putStrLn . showParse) parseCases
  putStrLn (show (toSockAddr loopbackAddress 8080))
  putStrLn (show (toSockAddr anyAddress 0))
  putStrLn (show (toSockAddr (IPv4 192 168 3 82) 1234))
  putStrLn (show (addressWord (IPv4 1 2 3 4)))
  putStrLn (show (loopbackAddress == IPv4 127 0 0 1) ++ " " ++ show (loopbackAddress == anyAddress))
  Right (a, b) <- socketpair AF_UNIX SOCK_STREAM 0
    | Left e => putStrLn ("socketpair " ++ show e)
  Right () <- sendString a "hello 日本"
    | Left e => putStrLn ("sendString " ++ show e)
  r <- recvString b 64
  putStrLn (show r)
  Right fl <- getStatusFlags b
    | Left e => putStrLn ("getStatusFlags " ++ show e)
  Right () <- setStatusFlags b (fl .|. O_NONBLOCK)
    | Left e => putStrLn ("setStatusFlags " ++ show e)
  Just buf <- newBuffer 16
    | Nothing => putStrLn "newBuffer"
  w <- recvBuf b buf 0 16
  putStrLn ("empty: " ++ either (\e => if isWouldBlock e then "would block" else show e) show w)
  _ <- close a
  w' <- recvBuf b buf 0 16
  putStrLn ("closed: " ++ either show show w')
  _ <- close b
  pure ()
