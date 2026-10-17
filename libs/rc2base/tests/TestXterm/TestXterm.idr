module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Console.Xterm: the private modes, the base64 of every padding
-- length (RFC 4648 test vectors), and OSC 52 / OSC 0 with UTF-8 text.

import Data.String
import System.Console.Xterm

show' : String -> String
show' s = concatMap esc (unpack s)
  where
    esc : Char -> String
    esc '\ESC' = "<ESC>"
    esc '\a' = "<BEL>"
    esc c = singleton c

main : IO ()
main = do
  putStrLn "--- System.Console.Xterm ---"
  putStrLn (show' (alternateScreen True ++ alternateScreen False))
  putStrLn (show' (cursorVisible False ++ cursorVisible True))
  putStrLn (show' (bracketedPaste True ++ bracketedPaste False))
  putStrLn (show' (mouseButtonTracking True ++ mouseSgr True ++ mouseButtonTracking False ++ mouseSgr False))
  putStrLn (show' (bracketedPasteStart ++ "x" ++ bracketedPasteEnd))
  putStrLn (show' (privateMode 1000 True))
  traverse_ (\s => putStrLn (show s ++ " -> " ++ base64 (map (cast . ord) (unpack s))))
    ["", "f", "fo", "foo", "foob", "fooba", "foobar"]
  putStrLn (base64 [0, 255, 254, 62, 63])
  putStrLn (show' (setClipboard Clipboard "hello"))
  putStrLn (show' (setClipboard Primary "あ\nb"))
  putStrLn (show' (clearClipboard Clipboard))
  putStrLn (show' (setWindowTitle "my\ESC title\n"))
