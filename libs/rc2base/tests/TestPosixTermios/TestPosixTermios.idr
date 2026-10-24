module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- System.Posix.Termios against a pseudo-terminal: the c_iflag/c_oflag/
-- c_cflag/c_lflag/c_cc constants (Linux values), reading and changing the
-- attributes of a pty slave with tcgetattr/tcsetattr, cfmakeraw and the
-- speed accessors, the tc* control calls, and ENOTTY on a regular file.
-- The pty comes from posix_openpt/grantpt/unlockpt/ptsname, which glibc
-- declares only under _GNU_SOURCE: verify.sh builds this test with
-- IDRIS2_CFLAGS=-D_GNU_SOURCE.

import Data.Bits
import Data.List
import Data.String
import System.Directory
import System.File
import System.Posix.Errno
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Process
import System.Posix.Termios

c : String -> Bits32 -> IO ()
c n v = putStrLn (n ++ "=" ++ show v)

ci : String -> Int32 -> IO ()
ci n v = putStrLn (n ++ "=" ++ show v)

ok : String -> Either Errno () -> IO ()
ok n (Right ()) = putStrLn (n ++ ": ok")
ok n (Left e)   = putStrLn (n ++ ": error " ++ show e)

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
  Right master <- posixOpenpt (2 .|. O_NOCTTY)
    | Left e => putStrLn ("posixOpenpt: " ++ show e) >> pure Nothing
  ok "grantpt" =<< grantpt master
  ok "unlockpt" =<< unlockpt master
  Right name <- ptsname master
    | Left e => putStrLn ("ptsname: " ++ show e) >> pure Nothing
  yes "ptsname under /dev/pts" (isPrefixOf "/dev/pts/" name)
  Right slave <- openFile name (2 .|. O_NOCTTY) 0
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

||| Baud rates (their values differ between glibc versions, so only their
||| properties are checked) and the tcflush/tcflow selectors.
testBaudConstants : IO ()
testBaudConstants = do
  let rates : List Bits32 = [B0, B50, B75, B110, B134, B150, B200, B300, B600, B1200, B1800, B2400, B4800, B9600, B19200, B38400, B57600, B115200, B230400, B460800, B500000, B576000, B921600, B1000000, B1152000, B1500000, B2000000, B2500000, B3000000, B3500000, B4000000]
  yes "baud rates are distinct" (length (nub rates) == length rates)
  yes "B0 is zero" (B0 == 0)
  ci "TCIFLUSH" TCIFLUSH
  ci "TCOFLUSH" TCOFLUSH
  ci "TCIOFLUSH" TCIOFLUSH
  ci "TCOOFF" TCOOFF
  ci "TCOON" TCOON
  ci "TCIOFF" TCIOFF
  ci "TCION" TCION


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
  ok "tcsetattr" =<< tcsetattr slave TCSANOW ios
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
  ok "cfsetispeed B9600" =<< cfsetispeed ios B9600
  ok "tcsetattr TCSAFLUSH" =<< tcsetattr slave TCSAFLUSH ios
  Right back <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr again: " ++ show e)
  cfgetispeed back >>= \r => yes "cfgetispeed == B9600" (r == B9600)

||| tcdrain / tcflush / tcflow / tcsendbreak on the slave.
testControl : FileDesc -> IO ()
testControl slave = do
  ok "tcdrain" =<< tcdrain slave
  ok "tcflush TCIFLUSH" =<< tcflush slave TCIFLUSH
  ok "tcflush TCIOFLUSH" =<< tcflush slave TCIOFLUSH
  ok "tcflow TCOON" =<< tcflow slave TCOON
  ok "tcsendbreak" =<< tcsendbreak slave 0
  Left e <- tcflush slave 99
    | Right _ => putStrLn "tcflush with a bad selector succeeded"
  yes "tcflush 99 gives EINVAL" (e == EINVAL)

||| The input and output baud rates, together and apart.
testSpeeds : FileDesc -> IO ()
testSpeeds slave = do
  Right ios <- tcgetattr slave
    | Left e => putStrLn ("tcgetattr: " ++ show e)
  ok "cfsetospeed B19200" =<< cfsetospeed ios B19200
  -- Check the output rate before touching the input rate: some libcs
  -- (glibc included) make cfsetispeed update the output-speed bits too.
  cfgetospeed ios >>= \r => yes "cfgetospeed == B19200" (r == B19200)
  ok "cfsetispeed B4800" =<< cfsetispeed ios B4800
  cfgetispeed ios >>= \r => yes "cfgetispeed == B4800" (r == B4800)
  ok "cfsetspeed B115200" =<< cfsetspeed ios B115200
  cfgetospeed ios >>= \r => yes "cfsetspeed sets the output rate" (r == B115200)
  cfgetispeed ios >>= \r => yes "cfsetspeed sets the input rate" (r == B115200)

||| isatty / ttyname / the foreground process group of a terminal that is not ours.
testIdentity : FileDesc -> IO ()
testIdentity slave = do
  isatty slave >>= yes "isatty slave"
  Right name <- ttyname slave
    | Left e => putStrLn ("ttyname: " ++ show e)
  yes "ttyname under /dev/pts" (isPrefixOf "/dev/pts/" name)
  -- opened with O_NOCTTY, so it is not this process's controlling terminal
  Left e1 <- tcgetpgrp slave
    | Right _ => putStrLn "tcgetpgrp succeeded"
  yes "tcgetpgrp: ENOTTY" (e1 == ENOTTY)
  Left e2 <- tcgetsid slave
    | Right _ => putStrLn "tcgetsid succeeded"
  yes "tcgetsid: ENOTTY" (e2 == ENOTTY)

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
  isatty fd >>= yes "isatty file"
  Left e <- ttyname fd
    | Right _ => putStrLn "ttyname of a file succeeded"
  yes "ttyname of a file: ENOTTY" (e == ENOTTY)
  _ <- close fd
  pure ()

-----------------------------------------------------------------------------
-- main
-----------------------------------------------------------------------------

||| The window size set through the master is read back from the slave.
testWinSize : FileDesc -> FileDesc -> IO ()
testWinSize master slave = do
  ok "setWinSize" =<< setWinSize master 100 31
  r <- getWinSize slave
  putStrLn ("getWinSize: " ++ either (\e => "error " ++ show e) show r)

main : IO ()
main = do
  testConstants
  testBaudConstants
  Just (master, slave) <- setup
    | Nothing => putStrLn "no pty"
  testDefaults slave
  testSetAttr slave
  testRawAndSpeed slave
  testControl slave
  testSpeeds slave
  testIdentity slave
  testWinSize master slave
  testNotATty
  teardown (master, slave)
  putStrLn "done"
