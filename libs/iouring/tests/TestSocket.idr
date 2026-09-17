||| Automated smoke test: a real loopback TCP connection, `accept`/
||| `connect`/`send`/`recv` all driven through io_uring (socket
||| creation/`bind`/`listen` stay synchronous, via upstream
||| `Network.Socket` -- see doc/iouring.md's own "Design choices").
||| Submits the accept and connect requests together in one `submit`
||| call, since either genuinely can complete before the other.
module Main

import Data.Buffer
import Network.Socket
import Network.Socket.Data
import System.FFI
import System.IO.Uring

port : Port
port = 18734

message : String
message = "hello over io_uring tcp"

-- SO_REUSEADDR (upstream Network.Socket exposes no socket-option API
-- at all) -- without it, re-running this test soon after a previous
-- run leaves `port` in TIME_WAIT (this test's own server socket closes
-- normally, but the kernel still holds the port for the standard ~60s
-- drain) and every re-run fails `bind` with EADDRINUSE until it clears
-- -- confirmed the hard way, re-running this exact test twice in a
-- row. SOL_SOCKET=1/SO_REUSEADDR=2 are fixed Linux ABI constants,
-- stable to hardcode.
%foreign "C:setsockopt, libc 6"
prim__setsockopt : Int -> Int -> Int -> Buffer -> Int -> PrimIO Int

setReuseAddr : Socket -> IO ()
setReuseAddr sock = do
  Just optBuf <- newBuffer 4
    | Nothing => pure ()
  setBits32 optBuf 0 1
  _ <- primIO (prim__setsockopt sock.descriptor 1 2 optBuf 4)
  pure ()

runOne : URing -> SQE -> IO (Maybe Int)
runOne ring sqe = do
  n <- submit ring
  if n /= 1
     then pure Nothing
     else do
       Just completion <- waitCompletion ring
         | Nothing => pure Nothing
       pure (Just completion.res)

main : IO ()
main = do
  Just ring <- init 8
    | Nothing => putStrLn "FAIL: init failed"

  Right serverSock <- socket AF_INET Stream 0
    | Left err => putStrLn $ "FAIL: server socket() errno=" ++ show err
  setReuseAddr serverSock
  bindRes <- bind serverSock (Just (Hostname "127.0.0.1")) port
  if bindRes /= 0
     then putStrLn $ "FAIL: bind res=" ++ show bindRes
     else do
       listenRes <- listen serverSock
       if listenRes /= 0
          then putStrLn $ "FAIL: listen res=" ++ show listenRes
          else do
            Right clientSock <- socket AF_INET Stream 0
              | Left err => putStrLn $ "FAIL: client socket() errno=" ++ show err

            Just acceptSqe <- getSqe ring
              | Nothing => putStrLn "FAIL: getSqe (accept) failed"
            prepAccept acceptSqe serverSock.descriptor 0
            setUserData acceptSqe 1

            Just connectSqe <- getSqe ring
              | Nothing => putStrLn "FAIL: getSqe (connect) failed"
            resolved <- prepConnect ring connectSqe clientSock.descriptor "127.0.0.1" (cast port)
            if not resolved
               then putStrLn "FAIL: prepConnect address resolution failed"
               else do
                 setUserData connectSqe 2
                 n <- submit ring
                 if n /= 2
                    then putStrLn $ "FAIL: submit returned " ++ show n ++ ", expected 2"
                    else do
                      Just c1 <- waitCompletion ring
                        | Nothing => putStrLn "FAIL: waitCompletion (1st) failed"
                      Just c2 <- waitCompletion ring
                        | Nothing => putStrLn "FAIL: waitCompletion (2nd) failed"
                      -- Completion order between accept/connect isn't
                      -- guaranteed -- sort by the userData tags above.
                      let (acceptC, connectC) = if c1.userData == 1 then (c1, c2) else (c2, c1)
                      if acceptC.res < 0 || connectC.res /= 0
                         then putStrLn $ "FAIL: accept res=" ++ show acceptC.res ++
                                " connect res=" ++ show connectC.res
                         else do
                           let acceptedFd = acceptC.res

                           Just sendBuf <- newBuffer (cast (length message))
                             | Nothing => putStrLn "FAIL: newBuffer (send) failed"
                           setString sendBuf 0 message
                           Just sendSqe <- getSqe ring
                             | Nothing => putStrLn "FAIL: getSqe (send) failed"
                           prepSend ring sendSqe clientSock.descriptor sendBuf (cast (length message)) 0
                           Just sendRes <- runOne ring sendSqe
                             | Nothing => putStrLn "FAIL: submit/wait (send) failed"

                           Just recvBuf <- newBuffer (cast (length message))
                             | Nothing => putStrLn "FAIL: newBuffer (recv) failed"
                           Just recvSqe <- getSqe ring
                             | Nothing => putStrLn "FAIL: getSqe (recv) failed"
                           prepRecv ring recvSqe acceptedFd recvBuf (cast (length message)) 0
                           Just recvRes <- runOne ring recvSqe
                             | Nothing => putStrLn "FAIL: submit/wait (recv) failed"

                           Just closeAcceptedSqe <- getSqe ring
                             | Nothing => putStrLn "FAIL: getSqe (close accepted) failed"
                           prepClose closeAcceptedSqe acceptedFd
                           _ <- runOne ring closeAcceptedSqe

                           close clientSock
                           close serverSock
                           exit ring

                           received <- getString recvBuf 0 (cast (length message))
                           if sendRes == cast (length message) &&
                              recvRes == cast (length message) &&
                              received == message
                              then putStrLn "PASS: socket round-trip"
                              else putStrLn $ "FAIL: sendRes=" ++ show sendRes ++
                                     " recvRes=" ++ show recvRes ++ " content=" ++ show received
