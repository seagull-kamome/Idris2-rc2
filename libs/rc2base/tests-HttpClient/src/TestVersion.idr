module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- curl_version_info read through its struct view, cross-checked
-- against curl_version's own string.

import Data.String

import Network.Curl.Raw

main : IO ()
main = do
    v <- curlVersionInfo
    s <- curlVersion
    printLn (("libcurl/" ++ v.version) `isPrefixOf` s)
    printLn (v.versionNum > 0x070a00)
    printLn (v.host /= "")
    printLn (v.features /= 0)
    printLn (map (`isInfixOf` s) v.sslVersion)
