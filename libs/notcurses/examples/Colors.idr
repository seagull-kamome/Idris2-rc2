||| Manual verification #2: RGB color, alpha blending, and text styles.
|||
||| What to check: a red/green/blue gradient row, an alpha-blended
||| overlay row (each swatch progressively more transparent against
||| the plane's own default background), and one line per style bit
||| (bold/italic/underline/undercurl/struck) actually rendered that
||| way by the terminal in use.
module Main

import System.Notcurses
import Data.List

swatch : NCPlane -> Int -> Int -> IO ()
swatch p row n = do
  let r = cast (n * 255 `div` 15)
  _ <- setBgRgb8 p r (255 - r) 128
  _ <- putStrAt p row (2 + n) "  "
  pure ()

alphaSwatch : NCPlane -> Int -> Int -> IO ()
alphaSwatch p row n = do
  _ <- setBgRgb8 p 80 160 255
  _ <- setBgAlpha p (cast (n * 255 `div` 15))
  _ <- putStrAt p row (2 + n) "  "
  pure ()

styleLine : NCPlane -> Int -> Bits32 -> String -> IO ()
styleLine p row bits label = do
  setStyles p bits
  _ <- putStrAt p row 2 label
  pure ()

main : IO ()
main = do
  Just nc <- init Silent 0 0 0 0
    | Nothing => putStrLn "notcurses init failed -- is stdout a real terminal?"
  std <- stdPlane nc

  _ <- putStrAt std 0 0 "RGB gradient (setBgRgb8):"
  traverse_ (swatch std 1) [0 .. 15]

  _ <- putStrAt std 3 0 "Alpha blend, opaque -> transparent (setBgAlpha):"
  traverse_ (alphaSwatch std 4) [0 .. 15]
  setBgDefault std

  _ <- putStrAt std 6 0 "Styles (NCStyle.*):"
  styleLine std 7 NCStyle.bold "bold"
  styleLine std 8 NCStyle.italic "italic"
  styleLine std 9 NCStyle.underline "underline"
  styleLine std 10 NCStyle.undercurl "undercurl"
  styleLine std 11 NCStyle.struck "struck"
  setStyles std NCStyle.none

  _ <- putStrAt std 13 0 "Press any key to exit..."
  _ <- render nc
  _ <- getBlocking nc
  _ <- stop nc
  pure ()
