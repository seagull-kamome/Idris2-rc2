||| Decoding of the bytes a terminal sends into key and paste events.
||| The parser is pure and incremental: bytes that may be the beginning of
||| a longer sequence are handed back to be completed by the next read.
||| Mouse reports and other unknown sequences are dropped.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Input

import Data.List
import Data.Maybe
import Data.String
import Text.Encoding.UTF8

%default total

-------------------------------------------------------------------------------
-- Events

public export
data Key
  = KChar Char
  | KEnter | KTab | KBackTab | KBackspace | KEscape
  | KUp | KDown | KLeft | KRight
  | KHome | KEnd | KPageUp | KPageDown | KInsert | KDelete
  | KF Nat

public export
record Mods where
  constructor MkMods
  shift, ctrl, alt : Bool

public export
noMods : Mods
noMods = MkMods False False False

public export
data MouseButton = LeftButton | MiddleButton | RightButton | WheelUp | WheelDown | NoButton

public export
data MouseAction = ButtonDown | ButtonUp | Drag | Move

||| A mouse report; the position is in cells, from 0 at the top left.
public export
record MouseEvent where
  constructor MkMouseEvent
  button : MouseButton
  action : MouseAction
  column, row : Nat
  mouseMods : Mods

public export
data Input
  = Press Key Mods
  | Paste String
  | Mouse MouseEvent

export
Eq Key where
  KChar a == KChar b = a == b
  KF a == KF b = a == b
  a == b = tag a == tag b
    where
      tag : Key -> Nat
      tag (KChar _) = 0
      tag KEnter = 1
      tag KTab = 2
      tag KBackTab = 3
      tag KBackspace = 4
      tag KEscape = 5
      tag KUp = 6
      tag KDown = 7
      tag KLeft = 8
      tag KRight = 9
      tag KHome = 10
      tag KEnd = 11
      tag KPageUp = 12
      tag KPageDown = 13
      tag KInsert = 14
      tag KDelete = 15
      tag (KF _) = 16

export
Eq Mods where
  MkMods a b c == MkMods a' b' c' = a == a' && b == b' && c == c'

export
Eq MouseEvent where
  MkMouseEvent b a c r m == MkMouseEvent b' a' c' r' m' =
    tagB b == tagB b' && tagA a == tagA a' && c == c' && r == r' && m == m'
    where
      tagB : MouseButton -> Nat
      tagB LeftButton = 0
      tagB MiddleButton = 1
      tagB RightButton = 2
      tagB WheelUp = 3
      tagB WheelDown = 4
      tagB NoButton = 5

      tagA : MouseAction -> Nat
      tagA ButtonDown = 0
      tagA ButtonUp = 1
      tagA Drag = 2
      tagA Move = 3

export
Eq Input where
  Press k m == Press k' m' = k == k' && m == m'
  Paste a == Paste b = a == b
  Mouse a == Mouse b = a == b
  _ == _ = False

export
Show Key where
  show (KChar c) = "KChar " ++ show c
  show (KF n) = "F" ++ show n
  show KEnter = "Enter"
  show KTab = "Tab"
  show KBackTab = "BackTab"
  show KBackspace = "Backspace"
  show KEscape = "Escape"
  show KUp = "Up"
  show KDown = "Down"
  show KLeft = "Left"
  show KRight = "Right"
  show KHome = "Home"
  show KEnd = "End"
  show KPageUp = "PageUp"
  show KPageDown = "PageDown"
  show KInsert = "Insert"
  show KDelete = "Delete"

export
Show Mods where
  show (MkMods s c a) =
    (if c then "Ctrl+" else "") ++ (if a then "Alt+" else "") ++ (if s then "Shift+" else "")

export
Show MouseEvent where
  show (MkMouseEvent b a c r m) = show m ++ btn b ++ " " ++ act a ++ " at " ++ show c ++ "," ++ show r
    where
      btn : MouseButton -> String
      btn LeftButton = "Left"
      btn MiddleButton = "Middle"
      btn RightButton = "Right"
      btn WheelUp = "WheelUp"
      btn WheelDown = "WheelDown"
      btn NoButton = "NoButton"

      act : MouseAction -> String
      act ButtonDown = "down"
      act ButtonUp = "up"
      act Drag = "drag"
      act Move = "move"

export
Show Input where
  show (Press k m) = show m ++ show k
  show (Paste s) = "Paste " ++ show s
  show (Mouse e) = "Mouse " ++ show e

-------------------------------------------------------------------------------
-- Parser

||| What one step of the parser found.
data Step
  = Need                                -- more bytes are needed
  | Got (Maybe Input) (List Int)        -- an event (or none for ignored bytes) and the rest

||| The bytes that open a bracketed paste: ESC [ 2 0 0 ~.
export
pasteStart : List Bits8
pasteStart = [27, 91, 50, 48, 48, 126]

||| The part before the first occurrence of `marker` and the part after it.
export
splitAtMarker : (marker : List Bits8) -> List Bits8 -> Maybe (List Bits8, List Bits8)
splitAtMarker marker = go []
  where
    go : List Bits8 -> List Bits8 -> Maybe (List Bits8, List Bits8)
    go acc [] = Nothing
    go acc xs@(x :: rest) =
      if isPrefixOf marker xs
         then Just (reverse acc, drop (length marker) xs)
         else go (x :: acc) rest

||| The bytes that close a bracketed paste: ESC [ 2 0 1 ~.
export
pasteEnd : List Bits8
pasteEnd = [27, 91, 50, 48, 49, 126]

||| Decode as many events as `bytes` holds. `final` says no more bytes are
||| coming right now, so a lone ESC is the Escape key; otherwise it may start
||| a sequence. The second component is the incomplete tail to prepend to the
||| next read.
export
parseInput : (final : Bool) -> List Bits8 -> (List Input, List Bits8)
parseInput final bytes = loop (length bytes) (map cast bytes) []
  where
    utf8Length : Int -> Nat
    utf8Length b =
      if b >= 0xF0 && b < 0xF8 then 4
      else if b >= 0xE0 && b < 0xF0 then 3
      else if b >= 0xC0 && b < 0xE0 then 2
      else 1

    decodeBytes : List Int -> List Char
    decodeBytes = decode . map (\b => the Bits8 (cast b))

    -- The parameter after `;` is 1 + (shift 1, alt 2, ctrl 4).
    modsOf : Nat -> Mods
    modsOf n =
      let m = cast {to = Integer} (n `minus` 1) in
      MkMods (mod m 2 == 1) (mod (div m 4) 2 == 1) (mod (div m 2) 2 == 1)

    numbers : List Int -> List Nat
    numbers bs = map toNat (splitSemi bs)
      where
        toNat : List Int -> Nat
        toNat = foldl (\acc, d => if d >= 48 && d <= 57 then acc * 10 + cast (d - 48) else acc) 0

        splitSemi : List Int -> List (List Int)
        splitSemi xs = case break (== 59) xs of
                         (a, []) => [a]
                         (a, _ :: rest) => assert_smaller xs a :: splitSemi (assert_smaller xs rest)

    -- A CSI (or SS3) sequence ending in `final` with numeric parameters.
    csiKey : Int -> List Nat -> Maybe Input
    csiKey final ps =
      let mods = case drop 1 ps of
                   (m :: _) => modsOf m
                   [] => noMods
          press = \k => Just (Press k mods)
      in case final of
           65 => press KUp
           66 => press KDown
           67 => press KRight
           68 => press KLeft
           72 => press KHome
           70 => press KEnd
           90 => Just (Press KBackTab ({ shift := True } mods))
           80 => press (KF 1)
           81 => press (KF 2)
           82 => press (KF 3)
           83 => press (KF 4)
           126 => case fromMaybe 0 (head' ps) of
                    1 => press KHome
                    2 => press KInsert
                    3 => press KDelete
                    4 => press KEnd
                    5 => press KPageUp
                    6 => press KPageDown
                    7 => press KHome
                    8 => press KEnd
                    n => if n >= 11 && n <= 15 then press (KF (n `minus` 10))
                         else if n >= 17 && n <= 21 then press (KF (n `minus` 11))
                         else if n >= 23 && n <= 24 then press (KF (n `minus` 12))
                         else Nothing
           _ => Nothing

    -- Control characters and printable ASCII.
    asciiKey : Int -> Input
    asciiKey 13 = Press KEnter noMods
    asciiKey 10 = Press KEnter noMods
    asciiKey 9 = Press KTab noMods
    asciiKey 8 = Press KBackspace noMods
    asciiKey 127 = Press KBackspace noMods
    asciiKey 0 = Press (KChar ' ') (MkMods False True False)
    asciiKey b =
      if b >= 1 && b <= 26 then Press (KChar (chr (b + 96))) (MkMods False True False)
      else if b >= 28 && b <= 31 then Press (KChar (chr (b + 64))) (MkMods False True False)
      else Press (KChar (chr b)) noMods

    splitPaste : List Int -> Maybe (List Int, List Int)
    splitPaste xs =
      map (\(a, b) => (map cast a, map cast b))
          (splitAtMarker pasteEnd (map cast xs))

    -- ESC [ < code ; column ; row M (press, motion) or m (release).
    sgrMouse : (released : Bool) -> List Nat -> Maybe Input
    sgrMouse released [code, col, r] =
      let c = cast {to = Integer} code
          bits = mod c 4
          wheel = mod (div c 64) 2 == 1
          motion = mod (div c 32) 2 == 1
          mods = MkMods (mod (div c 4) 2 == 1) (mod (div c 16) 2 == 1) (mod (div c 8) 2 == 1)
          button = if wheel then (if bits == 0 then WheelUp else if bits == 1 then WheelDown else NoButton)
                   else if bits == 0 then LeftButton
                   else if bits == 1 then MiddleButton
                   else if bits == 2 then RightButton
                   else NoButton
          action = if released then ButtonUp
                   else if motion then (if bits == 3 then Move else Drag)
                   else ButtonDown
      in if wheel && bits > 1 then Nothing
         else Just (Mouse (MkMouseEvent button action (col `minus` 1) (r `minus` 1) mods))
    sgrMouse _ _ = Nothing

    -- `bs` follows ESC [.
    csiStep : Bool -> List Int -> Step
    csiStep final bs =
      let (pb, rest) = span (\b => b >= 0x20 && b <= 0x3F) bs in
      case rest of
        [] => if final then Got Nothing [] else Need
        (f :: after) =>
          if f < 0x40 || f > 0x7E then Got Nothing rest
          else if (f == 77 || f == 109) && head' pb == Just 60
            then Got (sgrMouse (f == 109) (numbers pb)) after
          else if f == 126 && pb == [50, 48, 48]
            then case splitPaste after of
                   Just (text, post) => Got (Just (Paste (pack (decodeBytes text)))) post
                   Nothing => if final then Got (Just (Paste (pack (decodeBytes after)))) [] else Need
            else Got (csiKey f (numbers pb)) after

    step : Bool -> List Int -> Step
    step _ [] = Got Nothing []
    step final (27 :: rest) =
      case rest of
        [] => if final then Got (Just (Press KEscape noMods)) [] else Need
        (91 :: more) => csiStep final more
        [79] => if final then Got Nothing [] else Need
        (79 :: c :: more) => Got (csiKey c []) more
        (27 :: more) => Got (Just (Press KEscape (MkMods False False True))) more
        _ => case step final rest of
               Got (Just (Press k m)) r => Got (Just (Press k ({ alt := True } m))) r
               other => other
    step final (b :: rest) =
      if b < 0x80 then Got (Just (asciiKey b)) rest
      else
        let n = utf8Length b
            conts = takeWhile isCont (take (n `minus` 1) rest)
        in if length conts + 1 < n
              then -- a continuation byte is missing: wait for it only if the
                   -- bytes so far could still be completed
                   if length conts == length (take (n `minus` 1) rest) && not final && length rest + 1 < n
                      then Need
                      else Got (Just (Press (KChar '\xFFFD') noMods)) (drop (length conts) rest)
              else case decodeBytes (b :: conts) of
                     (c :: _) => Got (Just (Press (KChar c) noMods)) (drop (n `minus` 1) rest)
                     [] => Got Nothing rest
      where
        isCont : Int -> Bool
        isCont x = x >= 0x80 && x < 0xC0


    loop : Nat -> List Int -> List Input -> (List Input, List Bits8)
    loop Z bs acc = (reverse acc, map cast bs)
    loop (S fuel) bs acc =
      case bs of
        [] => (reverse acc, [])
        _ => case step final bs of
               Need => (reverse acc, map cast bs)
               Got ev rest =>
                 loop fuel rest (maybe acc (:: acc) ev)
