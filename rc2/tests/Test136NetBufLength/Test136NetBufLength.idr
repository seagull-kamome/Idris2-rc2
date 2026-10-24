module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- `sendBuf` and `recvBuf` (idrnet_send_buf / idrnet_recv_buf in
-- rc2/support/rc2/idris_net.c) put the bytes through `htonl` / `ntohl` a word at a
-- time. The conversion must stay inside the `len` bytes: for every length from 1
-- to 9, the bytes that were sent are the bytes that arrive, and valgrind (this test
-- is in LEAK_SENSITIVE_TESTS) sees no read or write past the buffer.
--
-- Single process over 127.0.0.1, as in Test35NetworkLoopback (which also says why
-- the port is fixed).

import Network.Socket
import Network.Socket.Raw

port : Port
port = 34568

-- Send `len` bytes (1, 2, .. len) from `client` and read them on `server`.
roundTrip : Socket -> Socket -> Int -> IO String
roundTrip client server len = do
  out <- sock_alloc len
  traverse_ (\i => sock_poke out i (i + 1)) [0 .. len - 1]
  Right sent <- sendBuf client out len
    | Left e => sock_free out *> pure ("send failed: " ++ show e)
  sock_free out
  inp <- sock_alloc len
  Right got <- recvBuf server inp len
    | Left e => sock_free inp *> pure ("recv failed: " ++ show e)
  bytes <- traverse (sock_peek inp) [0 .. len - 1]
  sock_free inp
  pure ("sent " ++ show sent ++ ", received " ++ show got ++ ": " ++ show bytes)

main : IO ()
main = do
  Right serverSock <- socket AF_INET Stream 0
    | Left err => putStrLn ("server socket failed: " ++ show err)
  _ <- bind serverSock (Just (Hostname "127.0.0.1")) port
  _ <- listen serverSock
  Right clientSock <- socket AF_INET Stream 0
    | Left err => putStrLn ("client socket failed: " ++ show err)
  _ <- connect clientSock (Hostname "127.0.0.1") port
  Right (acceptedSock, _) <- accept serverSock
    | Left err => putStrLn ("accept failed: " ++ show err)
  for_ [1 .. 9] $ \len => do
    r <- roundTrip clientSock acceptedSock len
    putStrLn ("length " ++ show len ++ " -- " ++ r)
  close clientSock
  close acceptedSock
  close serverSock
  putStrLn "done"
