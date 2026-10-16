||| The terminal as a device: raw mode, alternate screen, size, and raw
||| byte I/O. `closeTerminal` restores the terminal as it was found.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Terminal

import Data.Bits
import Data.Buffer
import Data.List
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Termios
import Text.Encoding.UTF8

%default covering

-------------------------------------------------------------------------------
-- Terminal

||| A terminal in raw mode on an input and an output descriptor.
public export
record Terminal where
  constructor MkTerminal
  input, output : FileDesc
  saved : Termios

-- Alternate screen, hidden cursor, bracketed paste.
enterSequence, leaveSequence : String
enterSequence = "\ESC[?1049h\ESC[?25l\ESC[?2004h\ESC[2J"
leaveSequence = "\ESC[0m\ESC[?2004l\ESC[?25h\ESC[?1049l"

||| Write all the bytes, retrying after a partial write.
export
writeBytes : FileDesc -> List Bits8 -> IO (Either Errno ())
writeBytes _ [] = pure (Right ())
writeBytes fd bytes = do
  let n = length bytes
  Just buf <- newBuffer (cast n)
    | Nothing => pure (Left (MkErrno 12))
  traverse_ (\(i, b) => setBits8 buf (cast i) b) (zip (the (List Nat) [0 .. n `minus` 1]) bytes)
  written <- write fd buf
  if written < 0
     then Left <$> errno
     else writeBytes fd (drop (cast written) bytes)

||| Write a string as UTF-8.
export
writeString : FileDesc -> String -> IO (Either Errno ())
writeString fd s = writeBytes fd (encode (unpack s))

||| Read what is available (at most 4096 bytes). Blocks if nothing is; call it
||| when the descriptor was reported readable. An empty result is end of file.
export
readBytes : FileDesc -> IO (Either Errno (List Bits8))
readBytes fd = do
  Just buf <- newBuffer 4096
    | Nothing => pure (Left (MkErrno 12))
  n <- read fd buf
  if n < 0
     then Left <$> errno
     else Right <$> traverse (getBits8 buf) (map cast (the (List Nat) (if n == 0 then [] else [0 .. cast n `minus` 1])))

||| Put the terminal in raw mode and switch to the alternate screen.
||| `Left ENOTTY` when the input is not a terminal.
export
openTerminal : (input : FileDesc) -> (output : FileDesc) -> IO (Either Errno Terminal)
openTerminal input output = do
  Right saved <- tcgetattr input
    | Left e => pure (Left e)
  Right raw <- tcgetattr input
    | Left e => pure (Left e)
  cfmakeraw raw
  setCc raw VMIN 1
  setCc raw VTIME 0
  Right () <- tcsetattr input TCSADRAIN raw
    | Left e => pure (Left e)
  Right () <- writeString output enterSequence
    | Left e => ignore (tcsetattr input TCSANOW saved) >> pure (Left e)
  pure (Right (MkTerminal input output saved))

||| Leave the alternate screen and restore the terminal attributes.
export
closeTerminal : Terminal -> IO ()
closeTerminal t = do
  _ <- writeString t.output leaveSequence
  _ <- tcsetattr t.input TCSADRAIN t.saved
  pure ()

||| The size in cells (columns, rows); 80 x 24 when the terminal does not say.
export
terminalSize : Terminal -> IO (Nat, Nat)
terminalSize t = do
  r <- getWinSize t.output
  pure $ case r of
    Right (c, r') => if c == 0 || r' == 0 then (80, 24) else (c, r')
    Left _ => (80, 24)
