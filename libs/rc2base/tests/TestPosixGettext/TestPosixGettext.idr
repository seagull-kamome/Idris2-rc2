module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Gettext: the domain and its directory and charset, then gettext,
-- dgettext, dcgettext, ngettext, dngettext and dcngettext against a catalog in
-- locale/ja (made by make-mo.py), for a message with and without a translation.
-- verify.sh runs it with TEST_LOCALEDIR set, in a ja or en_US locale with
-- LANGUAGE=ja: with the C locale gettext never translates.

import System
import System.Posix.Errno
import System.Posix.Gettext

domain : String
domain = "gettext_test"

showE : Show a => Either e a -> String
showE (Right a) = "Right " ++ show a
showE (Left _) = "Left"

main : IO ()
main = do
  Just dir <- getEnv "TEST_LOCALEDIR"
    | Nothing => putStrLn "TEST_LOCALEDIR is not set" *> exitFailure
  putStrLn ("LC_CTYPE=" ++ show LC_CTYPE ++ " LC_NUMERIC=" ++ show LC_NUMERIC
            ++ " LC_TIME=" ++ show LC_TIME ++ " LC_COLLATE=" ++ show LC_COLLATE
            ++ " LC_MONETARY=" ++ show LC_MONETARY ++ " LC_MESSAGES=" ++ show LC_MESSAGES)
  getTextdomain >>= putStrLn . ("domain: " ++)
  getTextdomainCodeset domain >>= putStrLn . ("codeset before: " ++) . show
  r <- bindtextdomain domain dir
  putStrLn ("bind is the directory: " ++ show (r == Right dir))
  getBindtextdomain domain >>= \d => putStrLn ("bound is the directory: " ++ show (d == Just dir))
  getTextdomainCodeset domain >>= putStrLn . ("codeset after: " ++) . show
  -- through a named domain, the current domain still the default
  dgettext domain "hello" >>= putStrLn
  dgettext domain "nope" >>= putStrLn
  dcgettext domain "hello" LC_MESSAGES >>= putStrLn
  dngettext domain "file" "files" 1 >>= putStrLn
  dngettext domain "file" "files" 2 >>= putStrLn
  dngettext domain "file" "files" 0 >>= putStrLn
  dngettext domain "apple" "apples" 1 >>= putStrLn
  dngettext domain "apple" "apples" 5 >>= putStrLn
  dcngettext domain "file" "files" 2 LC_MESSAGES >>= putStrLn
  gettext "hello" >>= putStrLn . ("before textdomain: " ++)
  -- through the current domain
  t <- textdomain domain
  putStrLn ("textdomain: " ++ showE t)
  getTextdomain >>= putStrLn . ("domain: " ++)
  gettext "hello" >>= putStrLn
  gettext "nope" >>= putStrLn
  ngettext "file" "files" 1 >>= putStrLn
  ngettext "file" "files" 3 >>= putStrLn
