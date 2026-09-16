||| Manual verification #4: blocking input, key codes vs. codepoints,
||| modifiers, and event type.
|||
||| What to check: every keypress (plain letters, arrow keys, function
||| keys, held-modifier combos your terminal actually reports) prints
||| a line describing it correctly; a plain letter shows its own UTF-8
||| and codepoint, an arrow/F-key shows its `NCKey.*` code with an
||| empty `utf8`, and `modifiers` reflects Shift/Ctrl/Alt when your
||| terminal emulator supports reporting them (many don't, outside a
||| Kitty-protocol-aware one). Quits on 'q' or Esc.
module Main

import System.Notcurses
import Data.Bits
import Data.String

describeKey : Bits32 -> String
describeKey k =
  if      k == NCKey.up        then "NCKey.up"
  else if k == NCKey.down      then "NCKey.down"
  else if k == NCKey.left      then "NCKey.left"
  else if k == NCKey.right     then "NCKey.right"
  else if k == NCKey.enter     then "NCKey.enter"
  else if k == NCKey.backspace then "NCKey.backspace"
  else if k == NCKey.f01       then "NCKey.f01"
  else if k == NCKey.f02       then "NCKey.f02"
  else if k == NCKey.f03       then "NCKey.f03"
  else if k == NCKey.f04       then "NCKey.f04"
  else if k == NCKey.resize    then "NCKey.resize"
  else if k == cast NCKey.tab  then "NCKey.tab"
  else if k == cast NCKey.esc  then "NCKey.esc"
  else "codepoint " ++ show k

describeMods : Bits32 -> String
describeMods m = unwords $
  [ "shift" | (m .&. NCKeyMod.shift) /= 0 ] ++
  [ "alt"   | (m .&. NCKeyMod.alt)   /= 0 ] ++
  [ "ctrl"  | (m .&. NCKeyMod.ctrl)  /= 0 ]

describeEvtype : NCEventType -> String
describeEvtype UnknownEvent = "unknown"
describeEvtype Press = "press"
describeEvtype Repeat = "repeat"
describeEvtype Release = "release"

loop : Notcurses -> NCPlane -> Int -> IO ()
loop nc p row = do
  ev <- getBlocking nc
  let line = describeKey ev.codepoint ++
             "  utf8=" ++ show ev.utf8 ++
             "  mods=[" ++ describeMods ev.modifiers ++ "]" ++
             "  evtype=" ++ describeEvtype ev.evtype ++
             "  at=(" ++ show ev.y ++ "," ++ show ev.x ++ ")"
  erasePlane p
  _ <- putStrAt p 0 0 "Press keys to see how they decode; 'q' or Esc quits."
  _ <- putStrAt p (row `mod` 20 + 2) 0 line
  _ <- render nc
  if ev.codepoint == cast NCKey.esc || ev.utf8 == "q"
     then pure ()
     else loop nc p (row + 1)

main : IO ()
main = do
  Just nc <- init Silent 0 0 0 0
    | Nothing => putStrLn "notcurses init failed -- is stdout a real terminal?"
  std <- stdPlane nc
  _ <- putStrAt std 0 0 "Press keys to see how they decode; 'q' or Esc quits."
  _ <- render nc
  loop nc std 0
  _ <- stop nc
  pure ()
