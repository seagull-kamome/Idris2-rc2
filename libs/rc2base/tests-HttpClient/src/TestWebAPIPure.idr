module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- The network-free half of webapi: SHA-256/base64url/PKCE against
-- coreutils' sha256sum, JSON rendering, chat request/response JSON,
-- API error bodies, URL/form encoding and token JSON.

import Data.List

import Network.WebAPI.JSON
import Network.WebAPI.AI.OpenAI
import Network.WebAPI.Auth.OAuth2
import Network.WebAPI.Auth.PKCE

hex : List Bits8 -> String
hex = concatMap (\b => pack [digit (cast b `div` 16), digit (cast b `mod` 16)])
  where
    digit : Int -> Char
    digit d = if d < 10 then chr (ord '0' + d) else chr (ord 'a' + d - 10)

ascii : String -> List Bits8
ascii = map (cast . ord) . unpack

main : IO ()
main = do
    for_ [ "", "abc"
         , "abcdbcdecdefdefgefghfghighijhijkijkljklmjklmnklmnolmnopmnopqnopq"
         , pack (replicate 1000 'a') ] $ \s =>
        putStrLn (hex (sha256 (ascii s)))
    for_ ["", "h", "hi", "hi?", "hi?>"] $ \s => putStrLn (base64url (ascii s))
    putStrLn (challengeS256 "dBjftJeZ4CVP-mB92K9uXqQVuqjTBamvjtQ4RItLx5A")

    putStrLn (render (JObject [ ("n", JNumber 1024), ("x", JNumber 0.5), ("neg", JNumber (-3))
                              , ("s", JString "q\"b\\n\n\t\x01é"), ("a", JArray [JNull, JBoolean True]) ]))

    let req = { maxTokens := Just 256, temperature := Just 0.25 }
                (chatRequest "claude-sonnet-5" [MkMessage System "Be brief.", MkMessage User "Hi"])
    putStrLn (render (encodeChatRequest req))
    putStrLn (render (encodeChatRequest (chatRequest "m" [])))

    let body = "{\"id\":\"x\",\"model\":\"gemini-3-flash\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"Hello!\"},\"finish_reason\":\"stop\"},{\"index\":1,\"message\":{\"role\":\"assistant\",\"content\":null}}]}"
    case parse body of
        Nothing => putStrLn "parse failed"
        Just j  => case decodeChatResponse j of
            Left e  => putStrLn e
            Right r => do
                printLn (r.model, map (\c => (show c.message.role, c.message.content, c.finishReason)) r.choices)
                printLn (reply r)
    printLn (map (const ()) (decodeChatResponse (JObject [("error", JString "x")])))

    putStrLn (errorMessage "{\"error\":{\"message\":\"invalid x-api-key\",\"type\":\"authentication_error\"}}")
    putStrLn (errorMessage "[{\"error\":{\"code\":400,\"message\":\"API key not valid.\"}}]")
    putStrLn (errorMessage "Bad Gateway")

    putStrLn (percentEncode "a b/c?d=é~_.-")
    putStrLn (formEncode [("grant_type", "authorization_code"), ("code", "4/0Ab+x")])
    printLn (queryParams "http://127.0.0.1:50000/?state=s1&code=4%2F0Ab%2Bx&scope=a+b#frag")
    printLn (queryParams "/?error=access_denied&state=s1")
    printLn (queryParams "http://127.0.0.1:50000/")
    let c = google "id.apps.googleusercontent.com" "secret" ["https://www.googleapis.com/auth/cloud-platform", "openid"]
    putStrLn (authorizationUrl c "http://127.0.0.1:50000" "st" "ch")

    let tok = decodeTokenResponse 1000 Nothing
                (JObject [("access_token", JString "ya29.a"), ("expires_in", JNumber 3599), ("refresh_token", JString "1//r")])
    printLn (map (\t => (t.accessToken, t.refreshToken, t.expiresAt)) tok)
    let tok2 = decodeTokenResponse 5000 (either (const Nothing) Just tok)
                 (JObject [("access_token", JString "ya29.b"), ("expires_in", JNumber 3599)])
    printLn (map (\t => (t.accessToken, t.refreshToken, t.expiresAt)) tok2)
    printLn (map (const ()) (decodeTokenResponse 0 Nothing (JObject [("error", JString "invalid_grant")])))
    for_ tok2 $ \t => do
        putStrLn (render (encodeToken t))
        printLn (map (\t' => (t'.accessToken, t'.refreshToken, t'.expiresAt)) (decodeToken (encodeToken t)))
