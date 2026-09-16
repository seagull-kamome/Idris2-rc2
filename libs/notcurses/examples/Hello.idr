||| Manual verification #1: lifecycle + plain text output.
|||
||| What to check: a fullscreen alternate-screen UI appears showing a
||| version string and a greeting; on any keypress, the terminal is
||| restored exactly to how it looked before running this (no leftover
||| garbage, cursor back where it was, scrollback intact).
module Main

import System.Notcurses

main : IO ()
main = do
  Just nc <- init Silent 0 0 0 0
    | Nothing => putStrLn "notcurses init failed -- is stdout a real terminal?"
  std <- stdPlane nc
  (rows, cols) <- planeDim std
  _ <- putStrAt std 0 0 ("notcurses " ++ !version ++ " -- " ++ show rows ++ "x" ++ show cols)
  _ <- putStrAt std 2 0 "Hello from System.Notcurses!"
  _ <- putStrAt std 4 0 "Press any key to exit..."
  _ <- render nc
  _ <- getBlocking nc
  _ <- stop nc
  pure ()
