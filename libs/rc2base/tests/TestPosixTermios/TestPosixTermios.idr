module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Termios against a pseudo-terminal: the c_iflag/c_oflag/
-- c_cflag/c_lflag/c_cc constants (Linux values), reading and changing the
-- attributes of a pty slave with tcgetattr/tcsetattr, cfmakeraw and the
-- speed accessors, the tc* control calls, and ENOTTY on a regular file.
-- The pty is opened through /dev/ptmx and the TIOC* ioctls, because
-- posix_openpt and friends need _XOPEN_SOURCE.

import Data.Bits
import System.Directory
import System.File
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Termios

%foreign "CExpr:(ioctl($1, TIOCSPTLCK, &(int){0})),libc,sys/ioctl.h"
prim__unlockpt : Bits32 -> PrimIO Int32

%foreign "CExpr:(({ unsigned n = 0; ioctl($1, TIOCGPTN, &n); n; })),libc,sys/ioctl.h"
prim__ptsNumber : Bits32 -> PrimIO Bits32

c : String -> Bits32 -> IO ()
c n v = putStrLn (n ++ "=" ++ show v)

yes : String -> Bool -> IO ()
yes n b = putStrLn (n ++ ": " ++ show b)

set : Bits32 -> Bits32 -> Bool
set flags bit = (flags .&. bit) /= 0

scratch : String
scratch = "TestPosixTermios.scratch"

-----------------------------------------------------------------------------
-- Setup and teardown (System.Posix.File and ioctl, not under test)
-----------------------------------------------------------------------------

||| Open a pty: the master and the slave side.
setup : IO (Maybe (FileDesc, FileDesc))
setup = do
  Right master <- openFile "/dev/ptmx" (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open ptmx: " ++ show e) >> pure Nothing
  _ <- primIO (prim__unlockpt master.rawfd)
  n <- primIO (prim__ptsNumber master.rawfd)
  Right slave <- openFile ("/dev/pts/" ++ show n) (2 .|. O_NOCTTY) 0
    | Left e => putStrLn ("open slave: " ++ show e) >> pure Nothing
  pure (Just (master, slave))

||| Close both sides and remove the scratch file.
teardown : (FileDesc, FileDesc) -> IO ()
teardown (master, slave) = do
  _ <- close slave
  _ <- close master
  _ <- removeFile scratch
  pure ()

-----------------------------------------------------------------------------
-- Tests (System.Posix.Termios under test)
-----------------------------------------------------------------------------

||| The termios constants.
testConstants : IO ()
testConstants = do
  c "NCCS" NCCS
  c "IGNBRK" IGNBRK
  c "BRKINT" BRKINT
  c "IGNPAR" IGNPAR
  c "PARMRK" PARMRK
  c "INPCK" INPCK
  c "ISTRIP" ISTRIP
  c "INLCR" INLCR
  c "IGNCR" IGNCR
  c "ICRNL" ICRNL
  c "IUCLC" IUCLC
  c "IXON" IXON
  c "IXANY" IXANY
  c "IXOFF" IXOFF
  c "IMAXBEL" IMAXBEL
  c "IUTF8" IUTF8
  c "OPOST" OPOST
  c "OLCUC" OLCUC
  c "ONLCR" ONLCR
  c "OCRNL" OCRNL
  c "ONOCR" ONOCR
  c "ONLRET" ONLRET
  c "OFILL" OFILL
  c "OFDEL" OFDEL
  c "NLDLY" NLDLY
  c "CRDLY" CRDLY
  c "TABDLY" TABDLY
  c "BSDLY" BSDLY
  c "VTDLY" VTDLY
  c "FFDLY" FFDLY
  c "CBAUD" CBAUD
  c "CBAUDEX" CBAUDEX
  c "CSIZE" CSIZE
  c "CS5" CS5
  c "CS6" CS6
  c "CS7" CS7
  c "CS8" CS8
  c "CSTOPB" CSTOPB
  c "CREAD" CREAD
  c "PARENB" PARENB
  c "PARODD" PARODD
  c "HUPCL" HUPCL
  c "CLOCAL" CLOCAL
  c "CIBAUD" CIBAUD
  c "CMSPAR" CMSPAR
  c "CRTSCTS" CRTSCTS
  c "ISIG" ISIG
  c "ICANON" ICANON
  c "XCASE" XCASE
  c "ECHO" ECHO
  c "ECHOE" ECHOE
  c "ECHOK" ECHOK
  c "ECHONL" ECHONL
  c "ECHOCTL" ECHOCTL
  c "ECHOPRT" ECHOPRT
  c "ECHOKE" ECHOKE
  c "FLUSHO" FLUSHO
  c "NOFLSH" NOFLSH
  c "TOSTOP" TOSTOP
  c "PENDIN" PENDIN
  c "IEXTEN" IEXTEN
  c "VDISCARD" VDISCARD
  c "VEOF" VEOF
  c "VEOL" VEOL
  c "VEOL2" VEOL2
  c "VERASE" VERASE
  c "VINTR" VINTR
  c "VKILL" VKILL
  c "VLNEXT" VLNEXT
  c "VMIN" VMIN
  c "VQUIT" VQUIT
  c "VREPRINT" VREPRINT
  c "VSTART" VSTART
  c "VSTOP" VSTOP
  c "VSUSP" VSUSP
  c "VTIME" VTIME
  c "VWERASE" VWERASE

||| Default attributes of a fresh pty slave (cooked mode).
testDefaults : FileDesc -> IO ()
testDefaults slave = do
  Right ios <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr: " ++ show e)
  l <- getLFlag ios
  o <- getOFlag ios
  i <- getIFlag ios
  yes "ICANON" (set l ICANON)
  yes "ECHO" (set l ECHO)
  yes "ISIG" (set l ISIG)
  yes "OPOST" (set o OPOST)
  yes "ONLCR" (set o ONLCR)
  yes "ICRNL" (set i ICRNL)
  for_ [("VINTR", VINTR), ("VQUIT", VQUIT), ("VERASE", VERASE), ("VKILL", VKILL), ("VEOF", VEOF), ("VSTART", VSTART), ("VSTOP", VSTOP), ("VSUSP", VSUSP)] $ \(n, v) =>
    getCc ios v >>= \x => putStrLn (n ++ " char: " ++ show x)

||| Change flags and control characters, write them, read them back.
testSetAttr : FileDesc -> IO ()
testSetAttr slave = do
  Right ios <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr: " ++ show e)
  l <- getLFlag ios
  setLFlag ios (l .&. complement (ICANON .|. ECHO))
  setCc ios VMIN 5
  setCc ios VTIME 2
  tcsetattr slave TCSANOW ios >>= \r => putStrLn ("tcsetattr: " ++ show r)
  Right back <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr again: " ++ show e)
  l' <- getLFlag back
  yes "ICANON after" (set l' ICANON)
  yes "ECHO after" (set l' ECHO)
  yes "ISIG after" (set l' ISIG)
  getCc back VMIN >>= \x => putStrLn ("VMIN: " ++ show x)
  getCc back VTIME >>= \x => putStrLn ("VTIME: " ++ show x)

||| cfmakeraw clears the line discipline; the input speed round trip.
testRawAndSpeed : FileDesc -> IO ()
testRawAndSpeed slave = do
  Right ios <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr: " ++ show e)
  cfmakeraw ios
  l <- getLFlag ios
  o <- getOFlag ios
  cf <- getCFlag ios
  yes "raw ICANON" (set l ICANON)
  yes "raw ECHO" (set l ECHO)
  yes "raw ISIG" (set l ISIG)
  yes "raw OPOST" (set o OPOST)
  yes "raw CS8" ((cf .&. CSIZE) == CS8)
  cfsetispeed ios 13 >>= \r => putStrLn ("cfsetispeed 9600: " ++ show r)
  tcsetattr slave TCSAFLUSH ios >>= \r => putStrLn ("tcsetattr TCSAFLUSH: " ++ show r)
  Right back <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr again: " ++ show e)
  cfgetispeed back >>= \r => putStrLn ("cfgetispeed: " ++ show r)

||| tcdrain / tcflush / tcflow / tcsendbreak on the slave.
testControl : FileDesc -> IO ()
testControl slave = do
  tcdrain slave >>= \r => putStrLn ("tcdrain: " ++ show r)
  tcflush slave 0 >>= \r => putStrLn ("tcflush TCIFLUSH: " ++ show r)
  tcflow slave 1 >>= \r => putStrLn ("tcflow TCOON: " ++ show r)
  tcsendbreak slave 0 >>= \r => putStrLn ("tcsendbreak: " ++ show r)

||| A regular file is not a terminal: ENOTTY.
testNotATty : IO ()
testNotATty = do
  _ <- removeFile scratch
  Right () <- writeFile scratch "x"
    | Left _ => putStrLn "writeFile failed"
  Right fd <- openFile scratch 0 0
    | Left e => putStrLn ("open: " ++ show e)
  r <- tcgetattr fd
  case r of
    Left e => putStrLn ("tcgetattr on a file: " ++ show (e == ENOTTY))
    Right _ => putStrLn "tcgetattr on a file succeeded"
  _ <- close fd
  pure ()

-----------------------------------------------------------------------------
-- main
-----------------------------------------------------------------------------

main : IO ()
main = do
  testConstants
  Just (master, slave) <- setup
    | Nothing => putStrLn "no pty"
  testDefaults slave
  testSetAttr slave
  testRawAndSpeed slave
  testControl slave
  testNotATty
  teardown (master, slave)
  putStrLn "done"
