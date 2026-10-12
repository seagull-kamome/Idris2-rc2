module Network.WebAPI.Auth.OAuth2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- OAuth 2.0 for a command-line program: authorization code with PKCE
-- (RFC 7636) and a loopback redirect (RFC 8252), token refresh, and a
-- token file. See doc/webapi-getting-started.md for setting up a
-- Google client, and doc/webapi.md for why this flow.

import Data.Buffer
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import System
import System.File
import System.File.Buffer
import System.FFI

import Network.Socket
import Network.Curl.Fetch
import Network.WebAPI.JSON
import Network.WebAPI.Auth.PKCE

%default total

public export
record Client where
  constructor MkClient
  authUrl         : String
  tokenUrl        : String
  clientId        : String
  clientSecret    : Maybe String
  scopes          : List String
  extraAuthParams : List (String, String)

||| A Google "Desktop app" client. `access_type=offline` asks for a
||| refresh token; `prompt=consent` asks for it again on a repeat login.
export
google : (clientId, clientSecret : String) -> (scopes : List String) -> Client
google i s sc = MkClient "https://accounts.google.com/o/oauth2/v2/auth"
                         "https://oauth2.googleapis.com/token"
                         i (Just s) sc
                         [("access_type", "offline"), ("prompt", "consent")]

public export
record Token where
  constructor MkToken
  accessToken  : String
  refreshToken : Maybe String
  ||| Unix time in seconds.
  expiresAt    : Integer

------------------------------------------------------------------------
-- URL and form encoding
------------------------------------------------------------------------

utf8 : Char -> List Int
utf8 c = let n = ord c in
    if n < 0x80 then [n]
    else if n < 0x800 then [0xC0 + n `div` 64, 0x80 + n `mod` 64]
    else if n < 0x10000 then [0xE0 + n `div` 4096, 0x80 + (n `div` 64) `mod` 64, 0x80 + n `mod` 64]
    else [0xF0 + n `div` 262144, 0x80 + (n `div` 4096) `mod` 64, 0x80 + (n `div` 64) `mod` 64, 0x80 + n `mod` 64]

dropHead : String -> String
dropHead = pack . drop 1 . unpack

hexDigit : Int -> Char
hexDigit d = if d < 10 then chr (ord '0' + d) else chr (ord 'A' + d - 10)

||| RFC 3986: everything but unreserved characters as `%XX` of UTF-8.
export
percentEncode : String -> String
percentEncode = concatMap enc . unpack
  where
    enc : Char -> String
    enc c = if (isAlphaNum c && ord c < 0x80) || elem c (unpack "-._~")
               then singleton c
               else concatMap (\b => pack ['%', hexDigit (b `div` 16), hexDigit (b `mod` 16)]) (utf8 c)

export
formEncode : List (String, String) -> String
formEncode = joinBy "&" . map (\(k, v) => percentEncode k ++ "=" ++ percentEncode v)

-- The values decoded here (codes, states, error names) are ASCII, so
-- each byte is taken as one character rather than decoding UTF-8.
percentDecode : String -> String
percentDecode = pack . go . unpack
  where
    hexVal : Char -> Maybe Int
    hexVal c = if isDigit c then Just (ord c - ord '0')
               else if isHexDigit c then Just (ord (toUpper c) - ord 'A' + 10)
               else Nothing

    go : List Char -> List Char
    go ('%' :: a :: b :: rest) = case (hexVal a, hexVal b) of
        (Just x, Just y) => chr (x * 16 + y) :: go rest
        _                => '%' :: go (a :: b :: rest)
    go ('+' :: rest) = ' ' :: go rest
    go (c :: rest)   = c :: go rest
    go []            = []

||| The query parameters of a URL or request target (`/?code=...`).
export
queryParams : String -> List (String, String)
queryParams url =
    let afterQ = snd (break (== '?') (trim url))
        query  = fst (break (== '#') (dropHead afterQ))
    in if afterQ == "" then [] else map pair (forget (split (== '&') query))
  where
    pair : String -> (String, String)
    pair kv = let (k, v) = break (== '=') kv in (percentDecode k, percentDecode (dropHead v))

export
authorizationUrl : Client -> (redirectUri, state, challenge : String) -> String
authorizationUrl c redirect state challenge = c.authUrl ++ "?" ++ formEncode (
    [ ("response_type", "code")
    , ("client_id", c.clientId)
    , ("redirect_uri", redirect)
    , ("scope", joinBy " " c.scopes)
    , ("state", state)
    , ("code_challenge", challenge)
    , ("code_challenge_method", "S256") ] ++ c.extraAuthParams)

------------------------------------------------------------------------
-- Tokens
------------------------------------------------------------------------

||| A refresh response usually has no `refresh_token`; `old`'s is kept.
export
decodeTokenResponse : (now : Integer) -> (old : Maybe Token) -> JSON -> Either String Token
decodeTokenResponse now old j = case at ["access_token"] j >>= str of
    Nothing => Left ("no access_token in " ++ render j)
    Just a  => Right $ MkToken a
        ((at ["refresh_token"] j >>= str) <|> (old >>= refreshToken))
        (now + cast (fromMaybe 3600 (at ["expires_in"] j >>= num)))

export
encodeToken : Token -> JSON
encodeToken t = JObject
    [ ("access_token", JString t.accessToken)
    , ("refresh_token", maybe JNull JString t.refreshToken)
    , ("expires_at", JNumber (cast t.expiresAt)) ]

export
decodeToken : JSON -> Maybe Token
decodeToken j = MkToken <$> (at ["access_token"] j >>= str)
                        <*> pure (at ["refresh_token"] j >>= str)
                        <*> map cast (at ["expires_at"] j >>= num)

partial
tokenRequest : Client -> List (String, String) -> Maybe Token -> IO (Either String Token)
tokenRequest c params old = do
    let creds = ("client_id", c.clientId) :: maybe [] (\s => [("client_secret", s)]) c.clientSecret
    Right resp <- fetch (post c.tokenUrl
                              {headers = [ ("Content-Type", "application/x-www-form-urlencoded")
                                         , ("Accept", "application/json") ]}
                              (formEncode (params ++ creds)))
        | Left e => pure (Left (show e))
    now <- time
    pure $ case parse resp.body of
        Nothing => Left ("HTTP " ++ show resp.status ++ ": " ++ resp.body)
        Just j  => if resp.status >= 200 && resp.status < 300
            then decodeTokenResponse now old j
            else Left $ fromMaybe resp.body $
                     (at ["error_description"] j >>= str) <|> (at ["error"] j >>= str)

export partial
refresh : HasIO io => Client -> Token -> io (Either String Token)
refresh c t = liftIO $ case t.refreshToken of
    Nothing => pure (Left "no refresh token; log in again")
    Just r  => tokenRequest c [("grant_type", "refresh_token"), ("refresh_token", r)] (Just t)

||| Readable by the owner only: the file holds a refresh token.
export
saveToken : HasIO io => (path : String) -> Token -> io (Either String ())
saveToken path t = do
    Right () <- writeFile path ""
        | Left e => pure (Left (path ++ ": " ++ show e))
    Right () <- chmodRaw path 0o600
        | Left e => pure (Left (path ++ ": " ++ show e))
    map (mapFst (\e => path ++ ": " ++ show e)) (writeFile path (render (encodeToken t)))

export covering
loadToken : HasIO io => (path : String) -> io (Either String Token)
loadToken path = do
    Right s <- readFile path
        | Left e => pure (Left (path ++ ": " ++ show e))
    pure $ maybe (Left (path ++ ": not a saved token")) Right (parse s >>= decodeToken)

||| The access token saved at `path`, refreshed (and saved again) when
||| it expires within a minute.
export partial
accessToken : HasIO io => Client -> (path : String) -> io (Either String String)
accessToken c path = do
    Right t <- loadToken path
        | Left e => pure (Left e)
    now <- time
    if t.expiresAt - 60 > now
        then pure (Right t.accessToken)
        else do
            Right t' <- refresh c t
                | Left e => pure (Left e)
            Right () <- saveToken path t'
                | Left e => pure (Left e)
            pure (Right t'.accessToken)

------------------------------------------------------------------------
-- Interactive login
------------------------------------------------------------------------

-- `struct pollfd[2]`. A `Struct` from `malloc`, not a `Buffer`: see
-- doc/ffi-without-shims.md, section 2.
PollFds : Type
PollFds = Struct "idris2webapi_pollfd2"
    [ ("fd0", Int32), ("events0", Bits16), ("revents0", Bits16)
    , ("fd1", Int32), ("events1", Bits16), ("revents1", Bits16) ]

%foreign "C:malloc,libc,stdlib.h"
prim__newPollFds : Int -> PrimIO PollFds

%foreign "C:free,libc,stdlib.h"
prim__freePollFds : PollFds -> PrimIO ()

%foreign "C:poll,libc,poll.h"
prim__poll : PollFds -> Int -> Int -> PrimIO Int

randomBytes : Int -> IO (Either String (List Bits8))
randomBytes n = do
    Just buf <- newBuffer n
        | Nothing => pure (Left "out of memory")
    Right f <- openFile "/dev/urandom" Read
        | Left e => pure (Left ("/dev/urandom: " ++ show e))
    r <- readBufferData f buf 0 n
    closeFile f
    case r of
        Right got => if got == n then Right <$> traverse (getBits8 buf) [0 .. n - 1]
                                 else pure (Left "/dev/urandom: short read")
        Left e => pure (Left ("/dev/urandom: " ++ show e))

-- Tries a few ports from `port` on; Nothing when no socket can listen
-- (e.g. a sandbox without networking), and the paste fallback is left.
listenLoopback : Int -> IO (Maybe (Socket, Int))
listenLoopback port = go port (the Nat 5)
  where
    go : Int -> Nat -> IO (Maybe (Socket, Int))
    go _ Z     = pure Nothing
    go p (S k) = do
        Right s <- socket AF_INET Stream 0
            | Left _ => pure Nothing
        0 <- bind s (Just (IPv4Addr 127 0 0 1)) p
            | _ => close s >> go (p + 1) k
        0 <- listen s
            | _ => close s >> go (p + 1) k
        pure (Just (s, p))

-- True when `fd` is readable, False when stdin is.
waitEither : PollFds -> Int -> IO (Either String Bool)
waitEither fds fd = do
    setField fds "fd0" (the Int32 (cast fd))
    setField fds "events0" (the Bits16 1)
    setField fds "revents0" (the Bits16 0)
    setField fds "fd1" (the Int32 0)
    setField fds "events1" (the Bits16 1)
    setField fds "revents1" (the Bits16 0)
    n <- primIO (prim__poll fds 2 (-1))
    pure $ if n < 0 then Left "poll failed" else Right (the Bits16 (getField fds "revents0") /= 0)

isRedirect : List (String, String) -> Bool
isRedirect ps = isJust (lookup "code" ps) || isJust (lookup "error" ps)

badPaste : IO ()
badPaste = do
    putStrLn "That URL has no code= in it; paste the whole address:"
    fflush stdout

covering
readPasted : IO (Either String (List (String, String)))
readPasted = do
    line <- getLine
    if isRedirect (queryParams line)
        then pure (Right (queryParams line))
        else do
            True <- fEOF stdin
                | False => badPaste >> readPasted
            pure (Left "stdin closed before a redirect URL was pasted")

covering
serveOnce : Socket -> IO (Maybe (List (String, String)))
serveOnce s = do
    Right (c, _) <- accept s
        | Left _ => pure Nothing
    Right (req, _) <- recv c 8192
        | Left _ => close c >> pure Nothing
    let target = fromMaybe "" (head' (drop 1 (words (fst (break (== '\r') req)))))
        ps     = queryParams target
    if isRedirect ps
        then do ignore $ send c (response "200 OK" "Authorization received. You can close this tab.")
                close c
                pure (Just ps)
        else do ignore $ send c (response "404 Not Found" "Not found.")
                close c
                pure Nothing
  where
    response : String -> String -> String
    response status body =
        "HTTP/1.1 " ++ status ++ "\r\nContent-Type: text/plain; charset=utf-8\r\n"
        ++ "Content-Length: " ++ show (length body) ++ "\r\nConnection: close\r\n\r\n" ++ body

covering
waitRedirect : Maybe (Socket, Int) -> IO (Either String (List (String, String)))
waitRedirect Nothing       = readPasted
waitRedirect (Just (s, _)) = do
    fds <- primIO (prim__newPollFds 16)
    r <- loop fds
    primIO (prim__freePollFds fds)
    pure r
  where
    covering
    loop : PollFds -> IO (Either String (List (String, String)))
    loop fds = do
        Right sockReady <- waitEither fds (descriptor s)
            | Left e => pure (Left e)
        if sockReady
            then maybe (loop fds) (pure . Right) !(serveOnce s)
            else do
                line <- getLine
                if isRedirect (queryParams line)
                    then pure (Right (queryParams line))
                    else if !(fEOF stdin)
                        then readFromBrowserOnly
                        else badPaste >> loop fds
      where
        covering
        readFromBrowserOnly : IO (Either String (List (String, String)))
        readFromBrowserOnly = maybe readFromBrowserOnly (pure . Right) !(serveOnce s)

||| Prints an authorization URL to open in a browser, then takes the
||| redirect back either on a loopback port or, when the browser can't
||| reach this machine, as the redirected address pasted into stdin.
export partial
login : HasIO io => Client -> io (Either String Token)
login c = liftIO $ do
    Right rnd <- randomBytes 50
        | Left e => pure (Left e)
    let verifier = base64url (take 32 rnd)
        state    = base64url (take 16 (drop 32 rnd))
        port     = 49152 + cast (foldl (\acc, b => acc * 256 + cast b) (the Int 0) (drop 48 rnd)) `mod` 16384
    listener <- listenLoopback port
    let redirect = "http://127.0.0.1:" ++ show (maybe port snd listener)
    putStrLn "Open this URL in a browser and allow access:"
    putStrLn ""
    putStrLn (authorizationUrl c redirect state (challengeS256 verifier))
    putStrLn ""
    putStrLn $ case listener of
        Just _  => "Waiting for the browser. If it ends on an error page instead, paste that page's full address here:"
        Nothing => "After allowing access the browser shows an error page; paste that page's full address here:"
    fflush stdout
    result <- waitRedirect listener
    traverse_ (close . fst) listener
    case result of
        Left e => pure (Left e)
        Right ps =>
            if lookup "state" ps /= Just state
                then pure (Left "state mismatch; start the login again")
                else case (lookup "code" ps, lookup "error" ps) of
                    (Just code, _) => tokenRequest c
                        [ ("grant_type", "authorization_code")
                        , ("code", code)
                        , ("redirect_uri", redirect)
                        , ("code_verifier", verifier) ] Nothing
                    (_, Just e) => pure (Left ("authorization refused: " ++ e))
                    _ => pure (Left "no code in the redirect")
