module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Bits

import Network.HTTP.Client.Curl.Raw
import Network.HTTP.Client.Curl.Types

showMaybe : Maybe String -> String
showMaybe Nothing  = "(none)"
showMaybe (Just s) = s

main : IO ()
main = do
    v <- curlVersionInfo
    putStrLn ("version: " ++ v.version)
    putStrLn ("version_num: " ++ show v.versionNum)
    putStrLn ("host: " ++ v.host)
    putStrLn ("features has SSL: " ++ show ((v.features .&. 4) /= 0))
    putStrLn ("ssl_version: " ++ showMaybe v.sslVersion)
