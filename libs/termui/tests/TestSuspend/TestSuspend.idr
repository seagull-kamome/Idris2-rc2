||| Suspending a program as a shell's Ctrl-Z does: the program runs as a child
||| on a pseudo-terminal, asks to be suspended (`Suspend`), stops itself with
||| SIGSTOP and, once continued, puts the terminal in raw mode again and draws
||| the whole picture. The parent watches the child stop and the state of the
||| terminal at each point.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Data.Bits
import Data.List
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Process
import System.Posix.Signal
import System.Posix.Termios
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Terminal
import Text.Encoding.UTF8

%default covering

data Msg = Go | Stopped | Back | Done | Typed

record Model where
  constructor MkModel
  resumed : Bool

visible : List Bits8 -> String
visible bs = concatMap esc (decode bs)
  where
    esc : Char -> String
    esc '\ESC' = "<ESC>"
    esc c = if ord c >= 32 then pack [c] else "<" ++ show (ord c) ++ ">"

-- The tty layer hands output written to the slave to the master
-- asynchronously: read until the marker has arrived.
readUntil : FileDesc -> String -> IO (List Bits8)
readUntil master marker = go []
  where
    want : List Bits8
    want = encode (unpack marker)

    go : List Bits8 -> IO (List Bits8)
    go acc =
      if isSuffixOf want acc
         then pure acc
         else do
           Right more <- readBytes master
             | Left _ => pure acc
           if null more then pure acc else go (acc ++ more)

program : (master : FileDesc) -> Program Model Msg
program master = MkProgram
  (MkModel False, Perform (ignore (writeString master "\x1a") >> pure Go))
  update
  (\m => text (if m.resumed then "resumed" else "start"))
  (\_ => [ OnInput key, Every "safety" 5000 Done ])
  where
    update : Msg -> Model -> (Model, Cmd Msg)
    update Go m = (m, NoCmd)
    update Typed m = (m, NoCmd)
    update Stopped m = (m, Batch [Suspend, Emit Back])
    update Back m = ({ resumed := True } m, NoCmd)
    update Done m = (m, Quit)

    key : Input -> Maybe Msg
    key (Press (KChar 'z') mods) = if mods.ctrl then Just Stopped else Nothing
    key (Press (KChar 'q') _) = Just Done
    key _ = Nothing

isStop : Signal -> Bool
isStop (MkSignal a) = case SIGSTOP of MkSignal b => a == b

canonical : FileDesc -> IO String
canonical fd = do
  Right ios <- tcgetattr fd
    | Left e => pure ("tcgetattr: " ++ show e)
  lf <- getLFlag ios
  pure (if (lf .&. ICANON) /= 0 then "cooked" else "raw")

main : IO ()
main = do
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e)
  _ <- grantpt master
  _ <- unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e)
  _ <- setWinSize master 20 3
  pid <- fork
  case pid of
    MkProcessID 0 => do
      _ <- runProgramOn slave slave (program master)
      exitNow 0
    _ => do
      Right (_, st1) <- waitpid pid WUNTRACED
        | Left e => putStrLn ("waitpid: " ++ show e)
      putStrLn ("child stopped by SIGSTOP: " ++ show (maybe False isStop (stoppedBy st1)))
      out1 <- readUntil master "\ESC[?1049l"
      putStrLn ("output until the stop: " ++ visible out1)
      canonical slave >>= \c => putStrLn ("terminal while stopped: " ++ c)
      _ <- kill pid SIGCONT
      -- the child redraws everything; "q" then ends it
      out2 <- readUntil master "\ESC[3;1H\ESC[?25l"
      putStrLn ("output after the continue: " ++ visible out2)
      canonical slave >>= \c => putStrLn ("terminal after the continue: " ++ c)
      _ <- writeString master "q"
      Right (_, st2) <- waitpid pid 0
        | Left e => putStrLn ("waitpid: " ++ show e)
      putStrLn ("child exited with: " ++ show (exitedWith st2))
