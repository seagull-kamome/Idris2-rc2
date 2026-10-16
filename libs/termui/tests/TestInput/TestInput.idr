||| Decoding of terminal input: keys, modifiers, bracketed paste, UTF-8 and
||| the handling of incomplete sequences.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.List
import Data.String
import TermUI.Input
import Text.Encoding.UTF8

%default covering

bytesOf : String -> List Bits8
bytesOf = encode . unpack

showRest : List Bits8 -> String
showRest [] = ""
showRest bs = "  rest=" ++ show (map (cast {to = Int}) bs)

tryBytes : (final : Bool) -> List Bits8 -> IO ()
tryBytes final bs = do
  let (evs, rest) = parseInput final bs
  putStrLn (show (map (cast {to = Int}) bs) ++ (if final then " (final)" else "") ++ " -> " ++ show evs ++ showRest rest)

try : (final : Bool) -> String -> IO ()
try final s = do
  let (evs, rest) = parseInput final (bytesOf s)
  putStrLn (show s ++ (if final then " (final)" else "") ++ " -> " ++ show evs ++ showRest rest)

main : IO ()
main = do
  putStrLn "-- plain keys"
  try False "ab"
  try False "A!"
  try False "\r\n\t"
  try False "\DEL\b"
  try False "\x01\x03\x1a"
  try False "\x00"
  try False "\x1c\x1f"
  putStrLn "-- UTF-8"
  try False "あ😀é"
  putStrLn "-- cursor and editing keys"
  try False "\ESC[A\ESC[B\ESC[C\ESC[D"
  try False "\ESC[H\ESC[F\ESC[2~\ESC[3~\ESC[5~\ESC[6~\ESC[1~\ESC[4~"
  try False "\ESC[Z"
  try False "\ESC[15~\ESC[17~\ESC[24~"
  try False "\ESCOP\ESCOS\ESCOA"
  putStrLn "-- modifiers"
  try False "\ESC[1;5C\ESC[1;2A\ESC[1;3D\ESC[3;5~\ESC[1;8H"
  try False "\ESCx\ESC\ESC\ESCあ"
  putStrLn "-- escape and incomplete input"
  try False "\ESC"
  try True "\ESC"
  try False "a\ESC["
  try True "a\ESC["
  try False "\ESC[1;"
  try False "\ESCO"
  try True "\ESCO"
  tryBytes False [0xE3, 0x81]
  tryBytes True [0xE3, 0x81]
  tryBytes False [0xE3, 0x81, 0x82, 0x61]
  tryBytes False [0xFF, 0x61]
  tryBytes False [0xE3, 0x61, 0x62]
  tryBytes False [0xC3, 0x1B, 0x5B, 0x41]
  tryBytes True [0xE3, 0x81, 0x61]
  putStrLn "-- bracketed paste"
  try False "\ESC[200~hello\nworld\ESC[201~x"
  try False "\ESC[200~あい\ESC[201~"
  try False "\ESC[200~partial"
  try True "\ESC[200~partial"
  try False "\ESC[200~\ESC[201~"
  putStrLn "-- mouse"
  try False "\ESC[<0;10;5M\ESC[<0;10;5m"
  try False "\ESC[<1;1;1M\ESC[<2;3;4M"
  try False "\ESC[<32;7;8M\ESC[<35;7;9M"
  try False "\ESC[<64;1;1M\ESC[<65;2;2M\ESC[<66;2;2M"
  try False "\ESC[<4;1;1M\ESC[<8;1;1M\ESC[<16;1;1M\ESC[<28;1;1M"
  try False "\ESC[<0;10;5"
  try False "\ESC[<0;10M"
  try False "x\ESC[<0;120;45My"
  putStrLn "-- ignored"
  try False "\ESC[99~q"
  try False "\ESC[?1;2cq"
  putStrLn "-- split across reads"
  let (e1, r1) = parseInput False (bytesOf "x\ESC[1;")
  let (e2, r2) = parseInput False (r1 ++ bytesOf "5Ay")
  putStrLn (show e1 ++ showRest r1 ++ " | " ++ show e2 ++ showRest r2)
  putStrLn "-- counting clicks"
  let ev = \a, c, r => MkMouseEvent LeftButton a c r noMods 1
      (c1, l1) = countClick Nothing 1000 (ev ButtonDown 3 4)
      (c2, l2) = countClick l1 1200 (ev ButtonDown 3 4)
      (c3, l3) = countClick l2 1300 (ev ButtonDown 3 4)
      (c4, l4) = countClick l3 1400 (ev ButtonDown 3 4)
  putStrLn (show (map (\e => e.clicks) [c1, c2, c3, c4]))
  putStrLn (show (map (\e => e.clicks) [fst (countClick l1 1500 (ev ButtonDown 3 4)), fst (countClick l1 1401 (ev ButtonDown 3 4))]))
  putStrLn (show (fst (countClick l1 1100 (ev ButtonDown 4 4))).clicks ++ " " ++ show (fst (countClick l1 1100 (ev ButtonDown 3 5))).clicks)
  putStrLn (show (fst (countClick l1 1100 (ev Drag 3 4))).clicks ++ " " ++ show (fst (countClick l1 1100 (ev ButtonUp 3 4))).clicks)
  putStrLn (show (fst (countClick l1 1100 (MkMouseEvent RightButton ButtonDown 3 4 noMods 1))).clicks)
  let (_, l5) = countClick l1 1100 (ev Drag 3 4)
  putStrLn (show (fst (countClick l5 1200 (ev ButtonDown 3 4))).clicks)

