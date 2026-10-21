||| Automated smoke test: a real loopback TCP connection, `accept`/
||| `connect`/`send`/`recv` all driven through io_uring (socket
||| creation/`bind`/`listen` stay synchronous, via upstream
||| `Network.Socket` -- see doc/uring.md's own "Design choices").
||| Two scenarios: `singleShotTest` submits the accept and connect
||| requests together in one `submit` call, since either genuinely can
||| complete before the other; `multishotTest` exercises
||| `prepMultishotAccept`/`readMultishotAccept` across two connections
||| accepted from the same registration, then a `prepCancel64` to drive
||| it to its terminal (`hasMore = False`) completion.
module Main

import Data.Buffer
import Data.Maybe
import Data.So
import Network.Socket
import Network.Socket.Data
import System.FFI
import System.Linux.Uring
import System.Posix.Errno
import System.Posix.FileDesc

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

||| The `FileDesc` of an upstream `Socket` (its `descriptor` is an `Int`, never
||| negative for a socket that `socket` made).
socketFd : Socket -> FileDesc
socketFd sock = fromMaybe (MkFileDesc 0) (mkFileDesc (cast sock.descriptor))

runOne : URing -> SQE -> IO (Maybe Int)
runOne ring sqe = do
  Right 1 <- submit ring
    | _ => pure Nothing
  Right completion <- waitCompletion ring
    | Left _ => pure Nothing
  pure (Just completion.res)

||| Sends `msg` from `clientFd` and receives it back via `acceptedFd`,
||| one `submit`+`waitCompletion` round-trip each. Shared by both
||| scenarios below -- everything past "accept a connection" is
||| identical either way.
roundTrip : URing -> (clientFd : FileDesc) -> (acceptedFd : FileDesc) -> (msg : String) -> IO (Either String ())
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
  Right ring <- init 8
    | Left e => pure (Left ("init " ++ show e))

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
            let serverFd = socketFd serverSock
            let clientFd = socketFd clientSock

            Just acceptSqe <- getSqe ring
              | Nothing => pure (Left "getSqe (accept) failed")
            prepAccept acceptSqe serverFd 0
            setUserData acceptSqe 1

            Just connectSqe <- getSqe ring
              | Nothing => pure (Left "getSqe (connect) failed")
            resolved <- prepConnect ring connectSqe clientFd "127.0.0.1" (cast port) 2
            if not resolved
               then pure (Left "prepConnect address resolution failed")
               else do
                 n <- submit ring
                 if n /= Right 2
                    then pure (Left ("submit returned " ++ show n ++ ", expected 2"))
                    else do
                      Right c1 <- waitCompletion ring
                        | Left e => pure (Left ("waitCompletion (1st) " ++ show e))
                      Right c2 <- waitCompletion ring
                        | Left e => pure (Left ("waitCompletion (2nd) " ++ show e))
                      -- Completion order between accept/connect isn't
                      -- guaranteed -- sort by the userData tags above.
                      let (acceptC, connectC) = if c1.userData == 1 then (c1, c2) else (c2, c1)
                      case (fdResult acceptC, result connectC) of
                        (Right acceptedFd, Right 0) => do
                           outcome <- roundTrip ring clientFd acceptedFd message

                           Just closeAcceptedSqe <- getSqe ring
                             | Nothing => pure (Left "getSqe (close accepted) failed")
                           prepClose closeAcceptedSqe acceptedFd
                           _ <- runOne ring closeAcceptedSqe

                           close clientSock
                           close serverSock
                           exit ring
                           pure outcome
                        (a, b) => pure (Left ("accept " ++ show (map (.rawfd) a) ++ " connect " ++ show b))

acceptRegUserData : Bits64
acceptRegUserData = 42

||| Connects a fresh client socket to `serverSock`'s own port, tagging
||| its `SQE` with `tag` so its completion can be told apart from the
||| multishot registration's own (`acceptRegUserData`-tagged) ones once
||| both are submitted together.
connectClient : URing -> (tag : Bits64) -> IO (Either String (Socket, FileDesc))
connectClient ring tag = do
  Right clientSock <- socket AF_INET Stream 0
    | Left err => pure (Left ("client socket() errno=" ++ show err))
  let clientFd = socketFd clientSock
  Just connectSqe <- getSqe ring
    | Nothing => pure (Left "getSqe (connect) failed")
  resolved <- prepConnect ring connectSqe clientFd "127.0.0.1" (cast multishotPort) tag
  if not resolved
     then pure (Left "prepConnect address resolution failed")
     else do
       n <- submit ring
       if n /= Right 1
          then pure (Left ("submit (connect) returned " ++ show n))
          else pure (Right (clientSock, clientFd))

||| Waits for exactly one accept-registration completion (tagged
||| `acceptRegUserData`) and one connect completion (tagged `tag`),
||| telling them apart by `userData` since their arrival order isn't
||| guaranteed.
waitAcceptAndConnect : URing -> (tag : Bits64) -> IO (Either String (Completion, Completion))
waitAcceptAndConnect ring tag = do
  Right c1 <- waitCompletion ring
    | Left e => pure (Left ("waitCompletion (1st) " ++ show e))
  Right c2 <- waitCompletion ring
    | Left e => pure (Left ("waitCompletion (2nd) " ++ show e))
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
  Right (clientSock, clientFd) <- connectClient ring connectTag
    | Left e => pure (Left e)
  Right (acceptC, connectC) <- waitAcceptAndConnect ring connectTag
    | Left e => pure (Left e)
  if result connectC /= Right 0
     then pure (Left ("connect res=" ++ show connectC.res))
     else do
       let (accepted, mReg') = readMultishotAccept reg acceptC
       case (accepted, mReg') of
            (_, Nothing) => pure (Left ("multishot accept terminated early, " ++ show (map (.rawfd) accepted)))
            (Left e, _) => pure (Left ("accept " ++ show e))
            (Right fd, Just reg') => do
              Right () <- roundTrip ring clientFd fd msg
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
  Right ring <- init 8
    | Left e => pure (Left ("init " ++ show e))

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
            let serverFd = socketFd serverSock
            reg0 <- prepMultishotAccept acceptSqe serverFd 0 acceptRegUserData
            n0 <- submit ring
            if n0 /= Right 1
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
                 if n1 /= Right 1
                    then pure (Left ("submit (cancel) returned " ++ show n1))
                    else do
                      Right ca <- waitCompletion ring
                        | Left e => pure (Left ("waitCompletion (cancel ack) " ++ show e))
                      Right cb <- waitCompletion ring
                        | Left e => pure (Left ("waitCompletion (accept terminal) " ++ show e))
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
