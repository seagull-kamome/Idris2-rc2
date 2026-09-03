module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Smoke test for rc2's own native `idrnet_*` port
-- (rc2/support/rc2/idris_net.c) backing Idris2's standard `network`
-- package (Network.Socket/.Data/.Raw): does it compile and work
-- end-to-end through rc2's codegen, no longer relying on the shared
-- upstream libidris2_support.a for these symbols at all
-- (Compiler.RC2.CC's compileCFile now links rc2's own runtime ahead of
-- the shared library, so rc2's own idrnet_* wins -- see TODO.md).
--
-- Single-process, single-threaded TCP loopback over 127.0.0.1, no
-- fork: connect() to an already-listen()ing socket completes via the
-- kernel's own backlog handling, so accept() can run right after in
-- the same sequential flow -- no threads/synchronization needed.
--
-- sendBytes/recvBytes (the Buffer-backed path) are exercised too: this
-- specifically regression-tests rc2's own idrnet_send_bytes, which
-- upstream's shared library implements with 3 parameters while
-- Network.FFI.idr's %foreign declares 4 (a real compile-error-causing
-- arity mismatch confirmed against both rc2 and real `idris2 --cg
-- refc`, not merely a harmlessly-ignored extra argument) -- rc2's own
-- port implements the 4-param signature the %foreign declaration
-- actually expects, so this path only compiles at all because of that
-- fix. See TODO.md.
--
-- Known limitation of this test, not a bug: the accepted server-side
-- socket completes a full TCP handshake on the fixed port below, so
-- closing it can leave that port in TIME_WAIT; Network.Socket's own
-- API surface doesn't expose SO_REUSEADDR, so back-to-back re-runs of
-- this test in quick succession could intermittently fail to bind.
--
-- valgrind --leak-check=full ./build/exec/<this test's own output>
-- expect "definitely lost: 0 bytes in 0 blocks".

import Network.Socket

port : Port
port = 34567

main : IO ()
main = do
  Right serverSock <- socket AF_INET Stream 0
    | Left err => putStrLn ("server socket failed: " ++ show err)
  bindRes <- bind serverSock (Just (Hostname "127.0.0.1")) port
  putStrLn ("bind: " ++ show bindRes)
  listenRes <- listen serverSock
  putStrLn ("listen: " ++ show listenRes)

  Right clientSock <- socket AF_INET Stream 0
    | Left err => putStrLn ("client socket failed: " ++ show err)
  connectRes <- connect clientSock (Hostname "127.0.0.1") port
  putStrLn ("connect: " ++ show connectRes)

  Right (acceptedSock, _) <- accept serverSock
    | Left err => putStrLn ("accept failed: " ++ show err)

  Right sendLen <- send clientSock "hello rc2"
    | Left err => putStrLn ("send failed: " ++ show err)
  putStrLn ("send bytes: " ++ show sendLen)

  Right (payload, _) <- recv acceptedSock 32
    | Left err => putStrLn ("recv failed: " ++ show err)
  putStrLn ("recv payload: " ++ payload)

  Right sentBytes <- sendBytes clientSock [1, 2, 3, 4, 5]
    | Left err => putStrLn ("sendBytes failed: " ++ show err)
  putStrLn ("sendBytes count: " ++ show sentBytes)

  Right recvdBytes <- recvBytes acceptedSock 32
    | Left err => putStrLn ("recvBytes failed: " ++ show err)
  putStrLn ("recvBytes payload: " ++ show recvdBytes)

  close clientSock
  close acceptedSock
  close serverSock
  putStrLn "done"
