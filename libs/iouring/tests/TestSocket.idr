||| Automated smoke test: a real loopback TCP connection, `accept`/
||| `connect`/`send`/`recv` all driven through io_uring (socket
||| creation/`bind`/`listen` stay synchronous, via upstream
||| `Network.Socket` -- see doc/iouring.md's own "Design choices").
||| Two scenarios: `singleShotTest` submits the accept and connect
||| requests together in one `submit` call, since either genuinely can
||| complete before the other; `multishotTest` exercises
||| `prepMultishotAccept`/`readMultishotAccept` across two connections
||| accepted from the same registration, then a `prepCancel64` to drive
||| it to its terminal (`hasMore = False`) completion.
module Main

import Data.Buffer
import Network.Socket
import Network.Socket.Data
import System.FFI
import System.IO.Uring

port : Port
port = 18734

multishotPort : Port
multishotPort = 18735

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

||| Sends `msg` from `clientFd` and receives it back via `acceptedFd`,
||| one `submit`+`waitCompletion` round-trip each. Shared by both
||| scenarios below -- everything past "accept a connection" is
||| identical either way.
roundTrip : URing -> (clientFd : Int) -> (acceptedFd : Int) -> (msg : String) -> IO (Either String ())
roundTrip ring clientFd acceptedFd msg = do
  Just sendBuf <- newBuffer (cast (length msg))
    | Nothing => pure (Left "newBuffer (send) failed")
  setString sendBuf 0 msg
  Just sendSqe <- getSqe ring
    | Nothing => pure (Left "getSqe (send) failed")
  prepSend ring sendSqe clientFd sendBuf (cast (length msg)) 0 0
  Just sendRes <- runOne ring sendSqe
    | Nothing => pure (Left "submit/wait (send) failed")

  Just recvBuf <- newBuffer (cast (length msg))
    | Nothing => pure (Left "newBuffer (recv) failed")
  Just recvSqe <- getSqe ring
    | Nothing => pure (Left "getSqe (recv) failed")
  prepRecv ring recvSqe acceptedFd recvBuf (cast (length msg)) 0 0
  Just recvRes <- runOne ring recvSqe
    | Nothing => pure (Left "submit/wait (recv) failed")

  received <- getString recvBuf 0 (cast (length msg))
  if sendRes == cast (length msg) && recvRes == cast (length msg) && received == msg
     then pure (Right ())
     else pure (Left ("sendRes=" ++ show sendRes ++ " recvRes=" ++ show recvRes ++
            " content=" ++ show received))

singleShotTest : IO (Either String ())
singleShotTest = do
  Just ring <- init 8
    | Nothing => pure (Left "init failed")

  Right serverSock <- socket AF_INET Stream 0
    | Left err => pure (Left ("server socket() errno=" ++ show err))
  setReuseAddr serverSock
  bindRes <- bind serverSock (Just (Hostname "127.0.0.1")) port
  if bindRes /= 0
     then pure (Left ("bind res=" ++ show bindRes))
     else do
       listenRes <- listen serverSock
       if listenRes /= 0
          then pure (Left ("listen res=" ++ show listenRes))
          else do
            Right clientSock <- socket AF_INET Stream 0
              | Left err => pure (Left ("client socket() errno=" ++ show err))

            Just acceptSqe <- getSqe ring
              | Nothing => pure (Left "getSqe (accept) failed")
            prepAccept acceptSqe serverSock.descriptor 0
            setUserData acceptSqe 1

            Just connectSqe <- getSqe ring
              | Nothing => pure (Left "getSqe (connect) failed")
            resolved <- prepConnect ring connectSqe clientSock.descriptor "127.0.0.1" (cast port) 2
            if not resolved
               then pure (Left "prepConnect address resolution failed")
               else do
                 n <- submit ring
                 if n /= 2
                    then pure (Left ("submit returned " ++ show n ++ ", expected 2"))
                    else do
                      Just c1 <- waitCompletion ring
                        | Nothing => pure (Left "waitCompletion (1st) failed")
                      Just c2 <- waitCompletion ring
                        | Nothing => pure (Left "waitCompletion (2nd) failed")
                      -- Completion order between accept/connect isn't
                      -- guaranteed -- sort by the userData tags above.
                      let (acceptC, connectC) = if c1.userData == 1 then (c1, c2) else (c2, c1)
                      if acceptC.res < 0 || connectC.res /= 0
                         then pure (Left ("accept res=" ++ show acceptC.res ++
                                " connect res=" ++ show connectC.res))
                         else do
                           let acceptedFd = acceptC.res
                           result <- roundTrip ring clientSock.descriptor acceptedFd message

                           Just closeAcceptedSqe <- getSqe ring
                             | Nothing => pure (Left "getSqe (close accepted) failed")
                           prepClose closeAcceptedSqe acceptedFd
                           _ <- runOne ring closeAcceptedSqe

                           close clientSock
                           close serverSock
                           exit ring
                           pure result

acceptRegUserData : Bits64
acceptRegUserData = 42

||| Connects a fresh client socket to `serverSock`'s own port, tagging
||| its `SQE` with `tag` so its completion can be told apart from the
||| multishot registration's own (`acceptRegUserData`-tagged) ones once
||| both are submitted together.
connectClient : URing -> (tag : Bits64) -> IO (Either String Socket)
connectClient ring tag = do
  Right clientSock <- socket AF_INET Stream 0
    | Left err => pure (Left ("client socket() errno=" ++ show err))
  Just connectSqe <- getSqe ring
    | Nothing => pure (Left "getSqe (connect) failed")
  resolved <- prepConnect ring connectSqe clientSock.descriptor "127.0.0.1" (cast multishotPort) tag
  if not resolved
     then pure (Left "prepConnect address resolution failed")
     else do
       n <- submit ring
       if n /= 1
          then pure (Left ("submit (connect) returned " ++ show n))
          else pure (Right clientSock)

||| Waits for exactly one accept-registration completion (tagged
||| `acceptRegUserData`) and one connect completion (tagged `tag`),
||| telling them apart by `userData` since their arrival order isn't
||| guaranteed.
waitAcceptAndConnect : URing -> (tag : Bits64) -> IO (Either String (Completion, Completion))
waitAcceptAndConnect ring tag = do
  Just c1 <- waitCompletion ring
    | Nothing => pure (Left "waitCompletion (1st) failed")
  Just c2 <- waitCompletion ring
    | Nothing => pure (Left "waitCompletion (2nd) failed")
  pure (Right (if c1.userData == acceptRegUserData then (c1, c2) else (c2, c1)))

||| One accept-and-round-trip step against `reg`: connects a new
||| client (tagged `connectTag`), waits for both its own completion and
||| the accept registration's next one, decodes the latter via
||| `readMultishotAccept`, and does a full send/recv round-trip on the
||| freshly accepted connection. Returns the still-armed continuation
||| `MultishotAccept` (see that function's own doc comment for why a
||| caller must thread this, not `reg`, into the next step) alongside
||| the connected client socket, so the caller can close it later.
acceptOne : URing -> MultishotAccept -> (connectTag : Bits64) -> (msg : String) ->
            IO (Either String (Socket, MultishotAccept))
acceptOne ring reg connectTag msg = do
  Right clientSock <- connectClient ring connectTag
    | Left e => pure (Left e)
  Right (acceptC, connectC) <- waitAcceptAndConnect ring connectTag
    | Left e => pure (Left e)
  if connectC.res /= 0
     then pure (Left ("connect res=" ++ show connectC.res))
     else do
       let (fd, mReg') = readMultishotAccept reg acceptC
       case mReg' of
            Nothing => pure (Left ("multishot accept terminated early, res=" ++ show fd))
            Just reg' =>
              if fd < 0
                 then pure (Left ("accept res=" ++ show fd))
                 else do
                   Right () <- roundTrip ring clientSock.descriptor fd msg
                     | Left e => pure (Left e)
                   pure (Right (clientSock, reg'))

||| Exercises `prepMultishotAccept`: one registration on `serverSock`
||| accepts two separate connections in turn (each still reported via
||| `hasMore = True`, since the kernel doesn't know a caller intends to
||| stop there), does a full send/recv round-trip on each via
||| `acceptOne`, then `prepCancel64`s the registration and confirms its
||| terminal completion reports `hasMore = False` -- see
||| `MultishotAccept`'s own doc comment for why this discipline (stop
||| reading completions under a registration's `userData` once that
||| happens) is documented, not type-enforced.
multishotTest : IO (Either String ())
multishotTest = do
  Just ring <- init 8
    | Nothing => pure (Left "init failed")

  Right serverSock <- socket AF_INET Stream 0
    | Left err => pure (Left ("server socket() errno=" ++ show err))
  setReuseAddr serverSock
  bindRes <- bind serverSock (Just (Hostname "127.0.0.1")) multishotPort
  if bindRes /= 0
     then pure (Left ("bind res=" ++ show bindRes))
     else do
       listenRes <- listen serverSock
       if listenRes /= 0
          then pure (Left ("listen res=" ++ show listenRes))
          else do
            Just acceptSqe <- getSqe ring
              | Nothing => pure (Left "getSqe (multishot accept) failed")
            reg0 <- prepMultishotAccept acceptSqe serverSock.descriptor 0 acceptRegUserData
            n0 <- submit ring
            if n0 /= 1
               then pure (Left ("submit (arm accept) returned " ++ show n0))
               else do
                 Right (client1, reg1) <- acceptOne ring reg0 101 "hello-1"
                   | Left e => pure (Left e)
                 Right (client2, reg2) <- acceptOne ring reg1 102 "hello-2"
                   | Left e => pure (Left e)

                 Just cancelSqe <- getSqe ring
                   | Nothing => pure (Left "getSqe (cancel) failed")
                 prepCancel64 cancelSqe acceptRegUserData 0
                 setUserData cancelSqe 999
                 n1 <- submit ring
                 if n1 /= 1
                    then pure (Left ("submit (cancel) returned " ++ show n1))
                    else do
                      Just ca <- waitCompletion ring
                        | Nothing => pure (Left "waitCompletion (cancel ack) failed")
                      Just cb <- waitCompletion ring
                        | Nothing => pure (Left "waitCompletion (accept terminal) failed")
                      let acceptFinal = if ca.userData == acceptRegUserData then ca else cb
                      let (_, mRegFinal) = readMultishotAccept reg2 acceptFinal

                      close client1
                      close client2
                      close serverSock
                      exit ring

                      case mRegFinal of
                           Just _ => pure (Left "multishot accept still armed after cancel")
                           Nothing => pure (Right ())

main : IO ()
main = do
  Right () <- singleShotTest
    | Left e => putStrLn ("FAIL: " ++ e)
  Right () <- multishotTest
    | Left e => putStrLn ("FAIL: multishot " ++ e)
  putStrLn "PASS: socket round-trip + multishot accept"
