module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Network.Async.HTTP.Rewrite in front of a handler that says which path it was given:
-- an internal rewrite with groups (an absent group is empty, `\0` is all of the path),
-- the query string kept or replaced, a path matched as a whole and not in part, the
-- first rule that matches and no second pass over the result, redirects (a path, a
-- URL the template names), and the results that must not come out: `//host` of a
-- redirect and a `..` segment out of what the groups caught (400). Rules that cannot be
-- made: a bad pattern, a group the pattern does not have, a bad redirect status, a
-- template that ends with a backslash or has a control character in it, a group before the
-- end of the host of a URL template. A TAB in a path (a browser drops it from a URL:
-- `/<TAB>/host` is `//host`), a template of only a query string, and `..` hidden by
-- `%2f` or `%5c` are 400.

import Control.Task
import Control.Task.Scheduler
import Data.Either
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Network.Async.HTTP.Rewrite
import Network.Async.HTTP.Server
import Network.Socket
import Network.Socket.Data

import System
import System.Posix.Errno

-- Network.Address has the same names; the ones of `network` are the clients'.
%hide System.Posix.Socket.Port.Port
%hide Network.Address.SocketAddress

%default covering

port : Port
port = 18781

localhost : SocketAddress
localhost = IPv4Addr 127 0 0 1

-- The rule that has to be valid for the test to go on.
mk : String -> String -> Action -> IO RewriteRule
mk pattern template action = do
  Right r <- rule pattern template action
    | Left e => assert_total (idris_crash ("rule failed: " ++ e))
  pure r

echo : Handler
echo req = liftIO (ok ("path " ++ req.path ++ " method " ++ req.method ++ "\n"))

rules : IO (List RewriteRule)
rules = sequence
  [ mk "/old/(.*)" "/new/\\1" Internal
  , mk "/legacy/([0-9]+)" "/items/\\1" (Redirect 301)
  , mk "/moved" "/target?from=moved" (Redirect 302)
  , mk "/ext/(.*)" "https://example.org/\\1" (Redirect 307)
  , mk "/redir/(.*)" "/\\1" (Redirect 302)
  , mk "/up/(.*)" "/\\1" Internal
  , mk "/(a)(b)?" "/\\2-\\1" Internal
  , mk "/whole" "/x\\0" Internal
  , mk "/plain" "/found" Internal
  , mk "/first" "/one" Internal
  , mk "/first" "/two" Internal
  , mk "/loop" "/loop/again" Internal
  , mk "/slash\\\\back" "/a\\\\b" Internal
  , mk "/q" "?only=1" Internal
  , mk "(.*)/" "\\1" (Redirect 301)
  ]

-- Connect, send the request and read the answer to the end of the connection.
session : String -> IO String
session request = do
  Right sock <- socket AF_INET Stream 0
    | Left e => pure ("socket " ++ show e)
  0 <- connect sock localhost port
    | e => close sock *> pure ("connect " ++ show e)
  Right _ <- Network.Socket.send sock request
    | Left e => pure ("send " ++ show e)
  answer <- drain sock ""
  close sock
  pure answer
  where
    drain : Socket -> String -> IO String
    drain sock acc = do
      r <- Network.Socket.recv sock 65536
      case r of
        Right (s, n) => if n > 0 then drain sock (acc ++ s) else pure acc
        Left _ => pure acc

req : String -> String -> String
req method path = method ++ " " ++ path ++ " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"

-- The head's lines of an answer and its body.
parts : String -> (List String, String)
parts answer = go [] (lines' answer)
  where
    lines' : String -> List String
    lines' = map (\l => if isSuffixOf "\r" l then pack (reverse (drop 1 (reverse (unpack l)))) else l)
             . forget . split (== '\n')
    go : List String -> List String -> (List String, String)
    go acc [] = (reverse acc, "")
    go acc ("" :: rest) = (reverse acc, joinBy "\n" rest)
    go acc (l :: rest) = go (l :: acc) rest

-- The status line, the Location, and the body.
summary : String -> String
summary answer =
  let (hdrs, body) = parts answer
      kept = filter (isPrefixOf "Location:") (drop 1 hdrs)
  in joinBy " | " (take 1 hdrs ++ kept) ++ "\n" ++ body

clients : Task (List String)
clients = do
  let ask = \r => blocking (session r)
  answers <- traverse (\(m, p) => ask (req m p))
    [ ("GET", "/old/a/b"), ("POST", "/old/x?k=v"), ("GET", "/plain"), ("GET", "/plain/more")
    , ("GET", "/first"), ("GET", "/loop"), ("GET", "/a"), ("GET", "/ab"), ("GET", "/whole")
    , ("GET", "/untouched?q=1")
    , ("GET", "/legacy/42"), ("GET", "/legacy/42?x=1"), ("GET", "/legacy/x"), ("GET", "/moved?x=1")
    , ("GET", "/ext/some/where"), ("HEAD", "/legacy/7")
    , ("GET", "/redir//evil.example"), ("GET", "/redir/ok/path")
    , ("GET", "/up/%2e%2e/etc"), ("GET", "/up/a/../b"), ("GET", "/up/ok")
    , ("GET", "/slash\\back"), ("GET", "/q"), ("GET", "/trail/"), ("GET", "/\t/evil.example/")
    , ("GET", "/up/..%2fetc"), ("GET", "/up/..%5cetc") ]
  pure (map summary answers)

-- Whether making a rule fails, as it should.
refused : String -> String -> Action -> IO String
refused pattern template action = do
  r <- rule pattern template action
  pure (show pattern ++ " " ++ show template ++ ": " ++ (if isLeft r then "refused" else "made"))

main : IO ()
main = do
  rs <- rules
  bad <- sequence
    [ refused "(" "/x" Internal
    , refused "/a(b)" "/\\2" Internal
    , refused "/a" "/x" (Redirect 200)
    , refused "/a" "/x\\" Internal
    , refused "/a" "/x\\q" Internal
    , refused "/a" "/x\r\nSet-Cookie: a=b" (Redirect 302)
    , refused "/a" "/x\ty" Internal
    , refused "(.*)" "https://example.org\\1" (Redirect 302)
    , refused "(.*)" "http://example.org\\1/x" (Redirect 302)
    , refused "(.*)" "https://example.org/\\1" (Redirect 302)
    , refused "/a" "/x" (Redirect 308)
    ]
  traverse_ putStrLn bad
  r <- runTaskWith 3 (race (serve (cast port) (urlRewrite rs echo)) clients)
  case r of
    Just (Right lines) => traverse_ putStrLn lines
    Just (Left stopped) => putStrLn "the server ended"
    Nothing => putStrLn "no result"
