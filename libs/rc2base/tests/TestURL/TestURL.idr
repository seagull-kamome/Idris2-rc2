module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Exercises Network.URL: percent codec (incl. UTF-8 bytes and a stray
-- '%'), query parse/build and round-trip, `parse` on a full URL /
-- path-only / scheme-relative / IPv6 host / no-path, `render`, and
-- `pathSegments`.

import Network.URL

dump : URL -> String
dump u = "scheme=\{show u.scheme} host=\{show u.host} port=\{show u.port} path=\{show u.path} query=\{show u.query} frag=\{show u.fragment}"

q0 : List (String, String)
q0 = [("name", "John Doe"), ("q", "a&b=c"), ("empty", "")]

main : IO ()
main = do
  putStrLn "--- Network.URL ---"

  putStrLn "decode: \{percentDecode "a%20b%2Fc%"}"
  putStrLn "encode: \{percentEncode "a b/c~d"}"
  -- %XX runs are decoded as a UTF-8 stream: %C3%A9 -> "é" (one codepoint),
  -- %E3%81%82 -> "あ"; a malformed byte/sequence -> U+FFFD (65533).
  putStrLn "utf8 decode: \{show (map ord (unpack (percentDecode "%C3%A9")))}"
  putStrLn "utf8 == literal: \{show (percentDecode "%C3%A9" == "é")}"
  putStrLn "utf8 3-byte: \{show (percentDecode "%E3%81%82" == "あ")}"
  putStrLn "utf8 encode: \{percentEncode "é"}"
  putStrLn "utf8 roundtrip: \{show (percentEncode (percentDecode "%C3%A9") == "%C3%A9")}"
  putStrLn "utf8 malformed: \{show (map ord (unpack (percentDecode "%FF%C3")))}"

  putStrLn "parseQuery: \{show (parseQuery "?a=1&b=two+words&c&d=%3D")}"
  putStrLn "buildQuery: \{buildQuery [("k", "a b"), ("x", "1+1")]}"
  putStrLn "query roundtrip: \{show (parseQuery (buildQuery q0) == q0)}"

  putStrLn "full:   \{dump (parse "https://user:pw@ex.com:8443/a%20b/c?x=1&y=t+w#sec")}"
  putStrLn "path:   \{dump (parse "/foo/bar?k=v#f")}"
  putStrLn "rel:    \{dump (parse "//cdn.example/lib.js")}"
  putStrLn "ipv6:   \{dump (parse "http://[::1]:9000/p")}"
  putStrLn "bare:   \{dump (parse "http://only.host")}"

  putStrLn "render: \{render (parse "https://user:pw@ex.com:8443/a%20b/c?x=1&y=t+w#sec")}"
  putStrLn "render2: \{render (MkURL (Just "http") (Just "h") (Just 80) "/p" [("a", "b c")] Nothing)}"

  putStrLn "segments: \{show (pathSegments "/a%2Fb/c/")}"

  putStrLn "--- done ---"
