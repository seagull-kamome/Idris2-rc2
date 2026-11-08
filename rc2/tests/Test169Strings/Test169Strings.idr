module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- String edge cases checked against a saved output: embedded NUL and invalid UTF-8.
-- Each section is a formerly separate test kept verbatim as its own
-- module (its `main` renamed `run`); see rc2/tests/README.md.

import Test169Strings.StringNul
import Test169Strings.Utf8Invalid

main : IO ()
main = do
    StringNul.run
    Utf8Invalid.run
