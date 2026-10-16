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
  putStrLn "-- ignored"
  try False "\ESC[<0;10;5Mq"
  try False "\ESC[99~q"
  try False "\ESC[?1;2cq"
  putStrLn "-- split across reads"
  let (e1, r1) = parseInput False (bytesOf "x\ESC[1;")
  let (e2, r2) = parseInput False (r1 ++ bytesOf "5Ay")
  putStrLn (show e1 ++ showRest r1 ++ " | " ++ show e2 ++ showRest r2)
