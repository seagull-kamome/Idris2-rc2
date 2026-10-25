module Network.HTTP.Client.WebAPI.AI.OpenAIStream

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The streaming form of OpenAI's chat completions API (`"stream": true`), which
-- LM Studio, llama.cpp's llama-server, Ollama and the cloud services also serve:
-- the answer arrives as server-sent events, each with the next piece of the
-- reply. `chatStream` sends the request, `nextDelta` waits for the next piece. It
-- runs on `Network.Async.HTTP.Stream`: plain `http` to an IPv4 address (or
-- `localhost`) only, which is what a local model server is; see
-- `doc/async-http-stream.md`. `OpenAI.chat` is the form that gives the whole
-- answer at once.

import Data.List
import Data.List1
import Data.Maybe
import Data.String

import Control.Task
import Network.Async.HTTP.Stream
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.JSON
import Network.Socket.Data
import Network.URL as U

%default covering

||| One piece of the reply. A model that thinks first sends the thought as
||| `reasoning` and the answer as `content`; `finish` is the reason the reply
||| ended (`stop`, `length`) in the last piece.
public export
record Delta where
  constructor MkDelta
  content   : String
  reasoning : String
  finish    : Maybe String

||| A reply being received.
export
record ChatStream where
  constructor MkChatStream
  stream : Stream

||| Where the endpoint is: the address, the port, what `Host` says, and the path
||| the API is under (`http://192.168.3.82:1234/v1` is `/v1`). The scheme is
||| `http`; the host an IPv4 address or `localhost` (in any case); the port 1 to
||| 65535, 80 if there is none. A query, a fragment and credentials in the URL
||| are refused rather than dropped.
export
parseBase : String -> Either String (SocketAddress, Port, String, String)
parseBase base =
  case (stripPrefixNoCase "http://" base, stripPrefixNoCase "https://" base) of
    (Just rest, _) => withAuthority rest
    (_, Just _) => Left "https is not supported by the stream client: use an http endpoint"
    _ => Left ("not an http URL: " ++ base)
  where
    stripPrefixNoCase : String -> String -> Maybe String
    stripPrefixNoCase pre str =
      if toLower (pack (take (length pre) (unpack str))) == pre then Just (pack (drop (length pre) (unpack str))) else Nothing

    digits : String -> Bool
    digits t = t /= "" && all isDigit (unpack t)

    octet : String -> Maybe Int
    octet t = if digits t && length t <= 3 then parsePositive t else Nothing

    address : String -> Either String SocketAddress
    address "localhost" = Right (IPv4Addr 127 0 0 1)
    address h = case traverse octet (forget (split (== '.') h)) of
                  Just [a, b, c, d] =>
                    if all (<= 255) [a, b, c, d] then Right (IPv4Addr a b c d)
                    else Left ("not an IPv4 address: " ++ h)
                  _ => Left ("the host must be an IPv4 address or localhost: " ++ h)

    stripSlash : String -> String
    stripSlash = pack . reverse . dropWhile (== '/') . reverse . unpack

    portNumber : String -> (given : Bool) -> Either String Int
    portNumber _ False = Right 80
    portNumber t True =
      case (if digits t && length t <= 5 then parsePositive {a = Int} t else Nothing) of
        Just n => if n >= 1 && n <= 65535 then Right n else Left ("bad port: " ++ t)
        Nothing => Left ("bad port: " ++ t)

    withAuthority : String -> Either String (SocketAddress, Port, String, String)
    withAuthority rest =
      let (authority, after) = break (\c => c == '/' || c == '?' || c == '#') rest
      in if any (\c => c == '?' || c == '#') (unpack after) then Left "a query or a fragment in the endpoint URL is not supported"
         else if any (== '@') (unpack authority) then Left "credentials in the endpoint URL are not supported"
         else do
           let (hostPart, portPart) = break (== ':') authority
           let host = toLower hostPart
           when (host == "") (Left ("no host in the endpoint URL: " ++ base))
           port <- portNumber (pack (drop 1 (unpack portPart))) (portPart /= "")
           addr <- address host
           pure (addr, port, host ++ (if portPart == "" then "" else ":" ++ show port), stripSlash after)

-- `Language.JSON` reads the hexadecimal digits of a `\uXXXX` escape in lower case
-- (`\u00f6`) as the wrong numbers, and a pair of surrogates (`\ud83d\ude00`, a
-- character beyond the first plane) as two characters that are none. Servers that
-- escape non-ASCII text (Python's `json.dumps`) write both. The digits are made
-- upper case, a pair of surrogates is replaced by the character, a lone surrogate
-- by U+FFFD.
fixEscapes : String -> String
fixEscapes str = if isInfixOf "\\u" str then pack (go (unpack str)) else str
  where
    hex : Char -> Maybe Int
    hex c = if c >= '0' && c <= '9' then Just (ord c - ord '0')
            else if c >= 'a' && c <= 'f' then Just (ord c - ord 'a' + 10)
            else if c >= 'A' && c <= 'F' then Just (ord c - ord 'A' + 10)
            else Nothing

    -- The value of the four digits that follow `\u`, and what is after them.
    unit : List Char -> Maybe (Int, List Char)
    unit (a :: b :: c :: d :: rest) = do
      x <- hex a
      y <- hex b
      z <- hex c
      w <- hex d
      pure (((x * 16 + y) * 16 + z) * 16 + w, rest)
    unit _ = Nothing

    bad : List Char
    bad = unpack "\\uFFFD"

    go : List Char -> List Char
    go ('\\' :: 'u' :: rest) =
      case unit rest of
        Nothing => '\\' :: 'u' :: go rest
        Just (hi, after) =>
          if hi >= 0xD800 && hi < 0xDC00 then
            (case after of
               ('\\' :: 'u' :: more) =>
                 (case unit more of
                    Just (lo, after') =>
                      if lo >= 0xDC00 && lo < 0xE000
                         then chr (0x10000 + (hi - 0xD800) * 1024 + (lo - 0xDC00)) :: go after'
                         else bad ++ go after
                    Nothing => bad ++ go after)
               _ => bad ++ go after)
          else if hi >= 0xDC00 && hi < 0xE000 then bad ++ go after
          else '\\' :: 'u' :: map toUpper (take 4 rest) ++ go after
    go ('\\' :: c :: rest) = '\\' :: c :: go rest
    go (c :: rest) = c :: go rest
    go [] = []

||| The piece in the data of one event: `Nothing` for the `[DONE]` that ends the
||| reply. An `{"error": ...}` is an error.
export
decodeDelta : String -> Either String (Maybe Delta)
decodeDelta "[DONE]" = Right Nothing
decodeDelta payload =
  case parse (fixEscapes payload) of
    Nothing => Left ("not JSON: " ++ payload)
    Just j =>
      case at ["error"] j of
        Just JNull => piece j
        Just e => Left (fromMaybe (render e) ((at ["message"] e >>= str) <|> str e))
        Nothing => piece j
  where
    -- The first choice only: with `n` above 1 the others are other replies.
    piece : JSON -> Either String (Maybe Delta)
    piece j =
      let first = \c => maybe True (== 0) (at ["index"] c >>= num)
      in case at ["choices"] j >>= arr >>= find first of
           -- a chunk with no choice (the usage at the end, say)
           Nothing => Right (Just (MkDelta "" "" Nothing))
           Just c =>
             let d = at ["delta"] c
                 text = \key => fromMaybe "" (d >>= at [key] >>= str)
                 thought = text "reasoning_content"
             in Right (Just (MkDelta (text "content") (if thought /= "" then thought else text "reasoning")
                                     (at ["finish_reason"] c >>= str)))

streamBody : ChatRequest -> String
streamBody r =
  case encodeChatRequest r of
    JObject kvs => render (JObject (kvs ++ [("stream", JBoolean True)]))
    other => render other

fromStreamError : StreamError -> ApiError
fromStreamError (HttpStatus s text) = HttpStatus s (errorMessage text)
fromStreamError e = TransportError (show e)

||| Send the request and read the head of the answer. The pieces are read with
||| `nextDelta`; give the reply up with `closeChat`.
export
chatStream : Endpoint -> ChatRequest -> Task (Either ApiError ChatStream)
chatStream ep req =
  case parseBase ep.baseUrl of
    Left e => pure (Left (TransportError e))
    Right (addr, port, host, base) => do
      auth <- liftIO ep.authHeaders
      case auth of
        Left e => pure (Left (AuthError e))
        Right hs => do
          r <- streamPost addr port host (base ++ "/chat/completions")
                          (("Content-Type", "application/json") :: hs) (streamBody req)
          pure (bimap fromStreamError (MkChatStream . snd) r)

||| Wait for the next piece; `Nothing` when the reply is complete (`[DONE]`, or
||| the end of the body). Events that carry nothing (a role, the usage) are
||| passed over.
export
nextDelta : ChatStream -> Task (Either ApiError (Maybe Delta))
nextDelta cs = do
  ev <- nextEvent cs.stream
  case ev of
    Left e => pure (Left (fromStreamError e))
    Right Nothing => pure (Right Nothing)
    Right (Just e) =>
      case decodeDelta e.payload of
        Left m => pure (Left (DecodeError m))
        Right Nothing => pure (Right Nothing)
        Right (Just d) =>
          if d.content == "" && d.reasoning == "" && isNothing d.finish
             then nextDelta cs
             else pure (Right (Just d))

||| Give the reply up (or close the connection after the last piece).
export
closeChat : ChatStream -> Task ()
closeChat cs = closeStream cs.stream
