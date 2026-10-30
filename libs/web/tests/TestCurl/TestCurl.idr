module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.HTTP.Client.Curl against libcurl, without outbound network:
-- local transfers use a `file://` URL on a file the test writes, HTTP
-- transfers go to a Network.HTTP.Server running in a forked thread.
--   * Raw: escape/unescape, the URL API, strerror bindings, version
--     info, every getinfo cell type, the multi interface, the header
--     API, body capture into String / Buffer / TextBuffer;
--   * Fetch: status, header names and body (String and bytes), and the
--     HttpError for a missing path.
-- Needs libcurl's headers and library (verify.sh skips it otherwise).

import Network.Address
import Data.Buffer
import Data.String
import Data.TextBuffer
import System
import System.Directory
import System.File

import Network.HTTP.Client.Curl
import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.TextBuffer
import Network.HTTP.Client.Curl.Types
import Network.HTTP.Server

import System.Concurrency
import System.Concurrency.RC2

testPort : Int
testPort = 18724

napMs : Int -> IO ()
napMs ms = do
    m <- makeMutex
    c <- makeCondition
    mutexAcquire m
    conditionWaitTimeout c m (ms * 1000)
    mutexRelease m

-- The server runs in a forked thread: wait until it accepts connections.
partial
waitServer : String -> Nat -> IO ()
waitServer base Z = putStrLn "server did not start"
waitServer base (S k) = do
    Right _ <- fetch curlClient (get (base ++ "/hello.txt"))
        | Left _ => napMs 20 >> waitServer base k
    pure ()

section : String -> IO ()
section s = putStrLn ("--- " ++ s ++ " ---")

withHandle : (AnyPtr -> IO ()) -> IO ()
withHandle k = do
    Just h <- curlEasyInit
        | Nothing => putStrLn "curl_easy_init failed"
    k h
    curlEasyCleanup h

------------------------------------------------------------------------
-- Raw: no transfer
------------------------------------------------------------------------

testUrl : IO ()
testUrl = do
    section "url"
    withHandle $ \h => do
        curlEasyEscape h "a b/c?d" >>= printLn
        curlEasyUnescape h "a%20b%2Fc%3Fd" >>= printLn
    Just u <- curlUrl
        | Nothing => putStrLn "curl_url failed"
    rc <- curlUrlSet u curlupart_URL "https://user@example.com:8080/p/q?x=1#frag" 0
    printLn (rc == curlue_OK)
    for_ [ curlupart_SCHEME, curlupart_USER, curlupart_PASSWORD, curlupart_HOST
         , curlupart_PORT, curlupart_PATH, curlupart_QUERY, curlupart_FRAGMENT ] $ \p =>
        curlUrlGet u p 0 >>= printLn
    Just u2 <- curlUrlDup u
        | Nothing => putStrLn "curl_url_dup failed"
    curlUrlGet u2 curlupart_URL 0 >>= printLn
    bad <- curlUrlSet u2 curlupart_URL "https://[::1" 0
    putStrLn (curlUrlStrerror bad)
    curlUrlCleanup u2
    curlUrlCleanup u
    putStrLn (curlEasyStrerror (MkCURLcode 6))
    putStrLn (curlMultiStrerror (MkCURLMcode 1))
    putStrLn (curlShareStrerror (MkCURLSHcode 1))

testVersion : IO ()
testVersion = do
    section "version"
    v <- curlVersionInfo
    s <- curlVersion
    printLn (("libcurl/" ++ v.version) `isPrefixOf` s)
    printLn (v.versionNum > 0x070a00)
    printLn (v.host /= "")
    printLn (v.features /= 0)
    printLn (map (`isInfixOf` s) v.sslVersion)

------------------------------------------------------------------------
-- Raw: file:// transfers
------------------------------------------------------------------------

testGetinfo : String -> IO ()
testGetinfo path = do
    section "getinfo"
    withHandle $ \h => do
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
        rc <- curlEasyPerform h
        printLn rc
        curlEasyGetinfoLong h curlinfo_RESPONSE_CODE >>= printLn
        url <- curlEasyGetinfoString h curlinfo_EFFECTIVE_URL
        printLn (map (isSuffixOf "/hello.txt") url)
        curlEasyGetinfoOfft h curlinfo_SIZE_DOWNLOAD_T >>= printLn
        t <- curlEasyGetinfoDouble h curlinfo_TOTAL_TIME
        printLn (map (>= 0) t)
        curlEasyGetinfoSocket h curlinfo_ACTIVESOCKET >>= printLn
        Right cookies <- curlEasyGetinfoSlist h curlinfo_COOKIELIST
            | Left c => printLn c
        curlSlistToList cookies >>= printLn
        curlSlistFreeAll cookies
        curlEasyGetinfoLong h (MkCURLINFO 0) >>= printLn
        list <- curlSlistAppend curlSlistEmpty "one"
        list <- curlSlistAppend list "two"
        curlSlistToList list >>= printLn
        curlSlistFreeAll list

partial
drain : AnyPtr -> IO (List Int)
drain m = do
    Just (msg, h, MkCURLcode result) <- curlMultiInfoRead m
        | Nothing => pure []
    _ <- curlMultiRemoveHandle m h
    curlEasyCleanup h
    rest <- drain m
    pure $ if msg == curlmsg_DONE then result :: rest else rest

partial
loop : AnyPtr -> IO (List Int)
loop m = do
    Right running <- curlMultiPerform m
        | Left c => do putStrLn ("curl_multi_perform failed: " ++ curlMultiStrerror c)
                       pure []
    done <- drain m
    if running == 0 then pure done else do
        Right _ <- curlMultiWait m 1000
            | Left c => do putStrLn ("curl_multi_wait failed: " ++ curlMultiStrerror c)
                           pure done
        (done ++) <$> loop m

-- Completion order is up to libcurl, so only membership is printed.
partial
testMulti : String -> IO ()
testMulti path = do
    section "multi"
    Just m <- curlMultiInit
        | Nothing => putStrLn "curl_multi_init failed"
    for_ [path, path ++ ".missing"] $ \p => do
        Just h <- curlEasyInit
            | Nothing => putStrLn "curl_easy_init failed"
        _ <- curlEasySetoptLong h curlopt_NOBODY 1
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ p)
        curlMultiAddHandle m h >>= printLn
    done <- loop m
    printLn (length done, elem 0 done, elem 37 done)
    curlMultiCleanup m >>= printLn

testCapture : String -> IO ()
testCapture path = do
    section "capture"
    withHandle $ \h => do
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
        curlEasyPerformToString h >>= printLn
        Just (rc, buf) <- curlEasyPerformToBuffer h
            | Nothing => putStrLn "capture failed"
        printLn rc
        bufferData buf >>= printLn
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path ++ ".missing")
        curlEasyPerformToString h >>= printLn

testCaptureText : String -> IO ()
testCaptureText path = do
    section "capture text"
    withHandle $ \h => do
        _ <- curlEasySetoptString h curlopt_URL ("file://" ++ path)
        Just (rc, txt) <- curlEasyPerformToTextBuffer h
            | Nothing => putStrLn "capture failed"
        printLn rc
        printLn (toString txt)

------------------------------------------------------------------------
-- HTTP transfers against Network.HTTP.Server
------------------------------------------------------------------------

handler : Handler
handler req respond =
    case req.path of
      "/hello.txt" => respond !(text 200 "hello curl\n")
      "/slow"      => do napMs 1500
                         respond !(text 200 "late")
      "/stop"      => do stop
                         respond !(text 200 "bye")
      _            => respond !(Response.notFound "nope")

partial
names : AnyPtr -> AnyPtr -> IO (List String)
names h prev = do
    Just (next, name, _) <- curlEasyNextheader h curlh_HEADER (-1) prev
        | Nothing => pure []
    (name ::) <$> names h next

-- The header API (curl_easy_header's struct out-parameter,
-- curl_easy_nextheader's iteration) and the status code.
partial
testHttp : String -> IO ()
testHttp base = do
    section "http"
    withHandle $ \h => do
        _ <- curlEasySetoptString h curlopt_URL (base ++ "/hello.txt")
        _ <- curlEasySetoptLong h curlopt_NOBODY 1
        curlEasyPerform h >>= printLn
        curlEasyGetinfoLong h curlinfo_RESPONSE_CODE >>= printLn
        curlEasyHeader h "content-length" curlh_HEADER (-1) >>= printLn
        curlEasyHeader h "x-absent" curlh_HEADER (-1) >>= printLn
        ns <- names h curlSlistEmpty
        printLn (elem "Content-Type" ns, elem "Content-Length" ns)

testFetch : String -> IO ()
testFetch base = do
    section "fetch"
    Right r <- fetch curlClient (get (base ++ "/hello.txt"))
        | Left e => printLn e
    printLn (r.status, r.body)
    Right b <- fetchBytes curlClient (get (base ++ "/hello.txt"))
        | Left e => printLn e
    bufferData b.body >>= printLn
    fetchText curlClient (base ++ "/hello.txt") >>= printLn
    fetchText curlClient (base ++ "/missing.txt") >>= printLn

-- What the request would write to the wire is checked first: a CR or LF in
-- a header value or method, or a header name that is not a token, is refused
-- before libcurl is given anything. A control-free value is sent as it is.
refused : Either FetchError a -> String
refused (Left (SetupError _)) = "refused"
refused (Left _) = "other error"
refused (Right _) = "sent"

testRefused : String -> IO ()
testRefused base = do
    section "refused"
    r1 <- fetch curlClient (get (base ++ "/hello.txt") {headers = [("X-A", "b\r\nX-Evil: 1")]})
    putStrLn ("CRLF in a value: " ++ refused r1)
    r2 <- fetch curlClient (get (base ++ "/hello.txt") {headers = [("X-A", "b\nX-Evil: 1")]})
    putStrLn ("LF in a value: " ++ refused r2)
    r3 <- fetch curlClient (get (base ++ "/hello.txt") {headers = [("Bad Name", "x")]})
    putStrLn ("space in a name: " ++ refused r3)
    r4 <- fetch curlClient (get (base ++ "/hello.txt") {headers = [("X-A:", "x")]})
    putStrLn ("colon in a name: " ++ refused r4)
    r5 <- fetch curlClient (request (OTHER "GET / HTTP/1.1\r\nX: y") (base ++ "/hello.txt"))
    putStrLn ("CRLF in a method: " ++ refused r5)
    r6 <- fetch curlClient (get (base ++ "/hello.txt") {headers = [("X-A", "tab\tok")]})
    putStrLn ("a tab in a value: " ++ refused r6)
    fetchBytes curlClient (get (base ++ "/hello.txt") {headers = [("X-A", "b\r\nX-Evil: 1")]})
      >>= \r => putStrLn ("fetchBytes, CRLF in a value: " ++ refused r)

-- A transfer that hangs is given up: the server answers /slow after 1.5 s.
testTimeout : String -> IO ()
testTimeout base = do
    section "timeout"
    let quick = curlClientWith ({ totalTimeoutMs := 300 } defaultCurlOptions)
    t0 <- fetch quick (get (base ++ "/slow"))
    putStrLn $ "300 ms limit on a slow answer: " ++ case t0 of
                 Left (TransportError _) => "timed out"
                 Left _ => "other error"
                 Right _ => "answered"
    let impatient = curlClientWith ({ lowSpeedBytesPerSec := 1000, lowSpeedSeconds := 1 } defaultCurlOptions)
    t1 <- fetch impatient (get (base ++ "/slow"))
    putStrLn $ "1 s without data: " ++ case t1 of
                 Left (TransportError _) => "timed out"
                 Left _ => "other error"
                 Right _ => "answered"
    -- the default options let a prompt answer through
    fetchText curlClient (base ++ "/hello.txt") >>= printLn

partial
main : IO ()
main = do
    Just dir <- currentDir
        | Nothing => putStrLn "no cwd"
    let path = dir ++ "/hello.txt"
    Right () <- writeFile path "hello curl\n"
        | Left e => printLn e
    MkCURLcode 0 <- curlGlobalInit
        | c => putStrLn ("curl_global_init failed: " ++ show c)
    testUrl
    testVersion
    testGetinfo path
    testMulti path
    testCapture path
    testCaptureText path
    srv <- forkJoin {a = ()} $ serve {bindAddr = IPv4 127 0 0 1} testPort handler
    let base = "http://127.0.0.1:" ++ show testPort
    waitServer base 100
    testHttp base
    testFetch base
    testRefused base
    testTimeout base
    section "stop"
    fetchText curlClient (base ++ "/stop") >>= printLn
    join srv
    curlGlobalCleanup
    Right () <- removeFile path
        | Left _ => pure ()
    pure ()
