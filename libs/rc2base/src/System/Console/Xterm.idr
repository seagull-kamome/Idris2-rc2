||| The control sequences xterm defines beyond ECMA-48/ANSI (which `contrib`'s
||| `Control.ANSI` covers): the DEC private modes that switch the alternate
||| screen, the cursor, bracketed paste and mouse reporting, and the operating
||| system commands (OSC) for the clipboard and the window title. All of them
||| are strings to write to the terminal; nothing here touches a descriptor.
|||
||| Reference: "XTerm Control Sequences" (ctlseqs), which most other terminal
||| emulators follow in part. Support varies: tmux and many terminals ask for
||| an option before they pass the clipboard on.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module System.Console.Xterm

import Data.List
import Data.Maybe
import Data.String
import Text.Encoding.UTF8

%default total

-------------------------------------------------------------------------------
-- DEC private modes

||| Set (`CSI ? n h`) or reset (`CSI ? n l`) a DEC private mode.
export
privateMode : (mode : Nat) -> Bool -> String
privateMode mode on = "\ESC[?" ++ show mode ++ (if on then "h" else "l")

||| The alternate screen buffer, saved cursor included (mode 1049).
export
alternateScreen : Bool -> String
alternateScreen = privateMode 1049

||| Show or hide the cursor (mode 25).
export
cursorVisible : Bool -> String
cursorVisible = privateMode 25

||| Bracketed paste (mode 2004): pasted text arrives between
||| `bracketedPasteStart` and `bracketedPasteEnd`.
export
bracketedPaste : Bool -> String
bracketedPaste = privateMode 2004

||| The marks around pasted text when bracketed paste is on.
export
bracketedPasteStart, bracketedPasteEnd : String
bracketedPasteStart = "\ESC[200~"
bracketedPasteEnd = "\ESC[201~"

||| Report the mouse buttons, the drags and the wheel (mode 1002).
export
mouseButtonTracking : Bool -> String
mouseButtonTracking = privateMode 1002

||| Report the mouse in the SGR encoding (`CSI < b ; x ; y M/m`), which has no
||| limit on the columns and tells a release from a press (mode 1006).
export
mouseSgr : Bool -> String
mouseSgr = privateMode 1006

-------------------------------------------------------------------------------
-- Operating system commands

-- `OSC ps ; text ST`, with BEL as the string terminator, which every terminal that
-- has OSC takes.
osc : Nat -> String -> String
osc ps text = "\ESC]" ++ show ps ++ ";" ++ text ++ "\a"

||| Set the title of the window (and of its icon).
export
setWindowTitle : String -> String
setWindowTitle title = osc 0 (pack (filter (\c => ord c >= 32 && ord c /= 127) (unpack title)))

||| Which selection OSC 52 means: the clipboard of the desktop, or the X11
||| primary selection (what the middle button pastes).
public export
data Selection = Clipboard | Primary

selectionCode : Selection -> String
selectionCode Clipboard = "c"
selectionCode Primary = "p"

||| Base64 (RFC 4648, with padding) of some bytes.
export
base64 : List Bits8 -> String
base64 bytes = pack (go bytes)
  where
    alphabet : List Char
    alphabet = unpack "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    sextet : Int -> Char
    sextet n = fromMaybe '=' (getAt (cast (n `mod` 64)) alphabet)
      where
        getAt : Nat -> List a -> Maybe a
        getAt _ [] = Nothing
        getAt Z (x :: _) = Just x
        getAt (S k) (_ :: xs) = getAt k xs

    go : List Bits8 -> List Char
    go (a :: b :: c :: rest) =
      let n = cast {to = Int} a * 65536 + cast b * 256 + cast c
      in sextet (n `div` 262144) :: sextet (n `div` 4096) :: sextet (n `div` 64) :: sextet n :: go rest
    go [a, b] =
      let n = cast {to = Int} a * 65536 + cast b * 256
      in [sextet (n `div` 262144), sextet (n `div` 4096), sextet (n `div` 64), '=']
    go [a] =
      let n = cast {to = Int} a * 65536
      in [sextet (n `div` 262144), sextet (n `div` 4096), '=', '=']
    go [] = []

||| Put the text (as UTF-8) in the selection of the terminal's desktop
||| (OSC 52). Nothing tells whether the terminal did it.
export
setClipboard : Selection -> String -> String
setClipboard sel text = osc 52 (selectionCode sel ++ ";" ++ base64 (encode (unpack text)))

||| Empty the selection (OSC 52 with an empty text).
export
clearClipboard : Selection -> String
clearClipboard sel = osc 52 (selectionCode sel ++ ";!")
