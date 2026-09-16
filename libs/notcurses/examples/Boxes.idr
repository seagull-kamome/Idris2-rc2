||| Manual verification #3: sub-planes, moving/resizing them, and
||| border drawing.
|||
||| What to check: two bordered boxes (one rounded-corner, one double-
||| line) appear at distinct positions with distinct sizes over the
||| standard plane's own background text; on each keypress the rounded
||| box moves one column right and grows one row taller (both via real
||| notcurses calls, not redraws from scratch), until it walks off the
||| right edge, then the program exits.
module Main

import System.Notcurses

loopMove : Notcurses -> NCPlane -> Int -> IO ()
loopMove nc box x = do
  moved <- movePlane box 3 x
  (_, cols) <- planeDim box
  _ <- resizePlane box (3 + cast (x `div` 4)) cols
  _ <- render nc
  if not moved || x > 40
     then pure ()
     else do
       _ <- getBlocking nc
       loopMove nc box (x + 1)

main : IO ()
main = do
  Just nc <- init Silent 0 0 0 0
    | Nothing => putStrLn "notcurses init failed -- is stdout a real terminal?"
  std <- stdPlane nc
  _ <- putStrAt std 0 0 "Background text behind the boxes below."
  _ <- putStrAt std 10 0 "Rounded box: press any key to move it right / grow it; off-edge to quit."

  Just doubleBox <- createPlane std 2 2 4 20 "double-box"
    | Nothing => putStrLn "createPlane failed"
  _ <- perimeterDouble doubleBox
  _ <- putStrAt doubleBox 1 2 "double-line"

  Just roundedBox <- createPlane std 3 2 3 20 "rounded-box"
    | Nothing => putStrLn "createPlane failed"
  _ <- perimeterRounded roundedBox
  _ <- putStrAt roundedBox 1 2 "rounded"

  _ <- render nc
  loopMove nc roundedBox 2

  _ <- destroyPlane roundedBox
  _ <- destroyPlane doubleBox
  _ <- stop nc
  pure ()
