module Network.Curl.TextBuffer

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Body capture into rc2base's `Data.TextBuffer`, an rc2 runtime type,
-- so this lives in the separate `curl-rc2` package rather than in
-- `curl` (doc/memstream-capture.md).

import Data.So
import Data.TextBuffer

import Network.Curl.Raw
import Network.Curl.Types

||| Same as `curlEasyPerformToBuffer`, decoding the body straight from
||| the captured bytes into a `TextBuffer` (one copy).
export
curlEasyPerformToTextBuffer : HasIO io => AnyPtr -> io (Maybe (CURLcode, TextBuffer))
curlEasyPerformToTextBuffer = curlEasyPerformCapture $ \raw, _ =>
    case choose (prim__nullAnyPtr raw == 0) of
         Left ok => Just <$> fromRawUtf8 raw ok
         Right _ => pure Nothing
