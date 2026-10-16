module System.Posix.Termios

import Data.So
import Data.Vect
import System.FFI
import Data.String.FFI
import System.Posix.File
import System.Posix.FileDesc
import System.Posix.Errno
import System.Posix.Process

%default total

-------------------------------------------------------------------------------
-- 
%inline %foreign "CExpr:(NCCS),libc,termios.h;unistd.h"
export NCCS : Bits32

data RawTermios : Type where [external]
export Termios : Type
Termios = GCPtr RawTermios

%inline %foreign "CExpr:(sizeof(struct termios)),libc,termios.h;unistd.h"
sizeofTermios : Int

export
newTermios : IO Termios
newTermios = do
  p <- malloc sizeofTermios >>= pure . prim__castPtr
  onCollect p (\x => free (prim__forgetPtr x))


%inline %foreign "CExpr:(((struct termios *)($1))->c_iflag),libc,termios.h;unistd.h"
prim__get_c_iflag : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(((struct termios *)($1))->c_oflag),libc,termios.h;unistd.h"
prim__get_c_oflag : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(((struct termios *)($1))->c_cflag),libc,termios.h;unistd.h"
prim__get_c_cflag : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(((struct termios *)($1))->c_lflag),libc,termios.h;unistd.h"
prim__get_c_lflag : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(((struct termios *)($1))->c_cc[$2]),libc,termios.h;unistd.h"
prim__get_c_cc : GCPtr RawTermios -> (i : Bits32) -> PrimIO Bits8

export
getIFlag, getOFlag, getCFlag, getLFlag : Termios -> IO Bits32
getIFlag x = primIO $ prim__get_c_iflag x
getOFlag x = primIO $ prim__get_c_oflag x
getCFlag x = primIO $ prim__get_c_cflag x
getLFlag x = primIO $ prim__get_c_lflag x
export
getCc : Termios -> Bits32 -> IO Bits8
getCc x i = primIO $ prim__get_c_cc x i


%inline %foreign "CExpr:(((struct termios *)($1))->c_iflag = $2),libc,termios.h;unistd.h"
prim__set_c_iflag : GCPtr RawTermios -> Bits32 -> PrimIO ()
%inline %foreign "CExpr:(((struct termios *)($1))->c_oflag = $2),libc,termios.h;unistd.h"
prim__set_c_oflag : GCPtr RawTermios -> Bits32 -> PrimIO ()
%inline %foreign "CExpr:(((struct termios *)($1))->c_cflag = $2),libc,termios.h;unistd.h"
prim__set_c_cflag : GCPtr RawTermios -> Bits32 -> PrimIO ()
%inline %foreign "CExpr:(((struct termios *)($1))->c_lflag = $2),libc,termios.h;unistd.h"
prim__set_c_lflag : GCPtr RawTermios -> Bits32 -> PrimIO ()
%inline %foreign "CExpr:(((struct termios *)($1))->c_cc[$2] = $3),libc,termios.h;unistd.h"
prim__set_c_cc : GCPtr RawTermios -> (i : Bits32) -> Bits8 -> PrimIO ()

export
setIFlag, setOFlag, setCFlag, setLFlag : Termios -> Bits32 -> IO ()
setIFlag x y = primIO $ prim__set_c_iflag x y
setOFlag x y = primIO $ prim__set_c_oflag x y
setCFlag x y = primIO $ prim__set_c_cflag x y
setLFlag x y = primIO $ prim__set_c_lflag x y
export
setCc : Termios -> Bits32 -> Bits8 -> IO ()
setCc x i y = primIO $ prim__set_c_cc x i y




-- c_iflag
%inline %foreign "CExpr:(IGNBRK),libc,termios.h;unistd.h"
export IGNBRK : Bits32
%inline %foreign "CExpr:(BRKINT),libc,termios.h;unistd.h"
export BRKINT : Bits32
%inline %foreign "CExpr:(IGNPAR),libc,termios.h;unistd.h"
export IGNPAR : Bits32
%inline %foreign "CExpr:(PARMRK),libc,termios.h;unistd.h"
export PARMRK : Bits32
%inline %foreign "CExpr:(INPCK),libc,termios.h;unistd.h"
export INPCK : Bits32
%inline %foreign "CExpr:(ISTRIP),libc,termios.h;unistd.h"
export ISTRIP : Bits32
%inline %foreign "CExpr:(INLCR),libc,termios.h;unistd.h"
export INLCR : Bits32
%inline %foreign "CExpr:(IGNCR),libc,termios.h;unistd.h"
export IGNCR : Bits32
%inline %foreign "CExpr:(ICRNL),libc,termios.h;unistd.h"
export ICRNL : Bits32
||| Linux only (System V); not in POSIX.
%inline %foreign "CExpr:(IUCLC),libc,termios.h;unistd.h"
export IUCLC : Bits32
%inline %foreign "CExpr:(IXON),libc,termios.h;unistd.h"
export IXON : Bits32
%inline %foreign "CExpr:(IXANY),libc,termios.h;unistd.h"
export IXANY : Bits32
%inline %foreign "CExpr:(IXOFF),libc,termios.h;unistd.h"
export IXOFF : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(IMAXBEL),libc,termios.h;unistd.h"
export IMAXBEL : Bits32
||| Linux only, not in POSIX.
%inline %foreign "CExpr:(IUTF8),libc,termios.h;unistd.h"
export IUTF8 : Bits32
-- c_oflag
%inline %foreign "CExpr:(OPOST),libc,termios.h;unistd.h"
export OPOST : Bits32
||| Linux only (System V); not in POSIX.
%inline %foreign "CExpr:(OLCUC),libc,termios.h;unistd.h"
export OLCUC : Bits32
%inline %foreign "CExpr:(ONLCR),libc,termios.h;unistd.h"
export ONLCR : Bits32
%inline %foreign "CExpr:(OCRNL),libc,termios.h;unistd.h"
export OCRNL : Bits32
%inline %foreign "CExpr:(ONOCR),libc,termios.h;unistd.h"
export ONOCR : Bits32
%inline %foreign "CExpr:(ONLRET),libc,termios.h;unistd.h"
export ONLRET : Bits32
%inline %foreign "CExpr:(OFILL),libc,termios.h;unistd.h"
export OFILL : Bits32
%inline %foreign "CExpr:(OFDEL),libc,termios.h;unistd.h"
export OFDEL : Bits32
%inline %foreign "CExpr:(NLDLY),libc,termios.h;unistd.h"
export NLDLY : Bits32
%inline %foreign "CExpr:(CRDLY),libc,termios.h;unistd.h"
export CRDLY : Bits32
%inline %foreign "CExpr:(TABDLY),libc,termios.h;unistd.h"
export TABDLY : Bits32
%inline %foreign "CExpr:(BSDLY),libc,termios.h;unistd.h"
export BSDLY : Bits32
%inline %foreign "CExpr:(VTDLY),libc,termios.h;unistd.h"
export VTDLY : Bits32
%inline %foreign "CExpr:(FFDLY),libc,termios.h;unistd.h"
export FFDLY : Bits32
-- c_cflag
||| Linux only, not in POSIX.
%inline %foreign "CExpr:(CBAUD),libc,termios.h;unistd.h"
export CBAUD : Bits32
||| Linux only, not in POSIX.
%inline %foreign "CExpr:(CBAUDEX),libc,termios.h;unistd.h"
export CBAUDEX : Bits32
%inline %foreign "CExpr:(CSIZE),libc,termios.h;unistd.h"
export CSIZE : Bits32
%inline %foreign "CExpr:(CS5),libc,termios.h;unistd.h"
export CS5 : Bits32
%inline %foreign "CExpr:(CS6),libc,termios.h;unistd.h"
export CS6 : Bits32
%inline %foreign "CExpr:(CS7),libc,termios.h;unistd.h"
export CS7 : Bits32
%inline %foreign "CExpr:(CS8),libc,termios.h;unistd.h"
export CS8 : Bits32
%inline %foreign "CExpr:(CSTOPB),libc,termios.h;unistd.h"
export CSTOPB : Bits32
%inline %foreign "CExpr:(CREAD),libc,termios.h;unistd.h"
export CREAD : Bits32
%inline %foreign "CExpr:(PARENB),libc,termios.h;unistd.h"
export PARENB : Bits32
%inline %foreign "CExpr:(PARODD),libc,termios.h;unistd.h"
export PARODD : Bits32
%inline %foreign "CExpr:(HUPCL),libc,termios.h;unistd.h"
export HUPCL : Bits32
%inline %foreign "CExpr:(CLOCAL),libc,termios.h;unistd.h"
export CLOCAL : Bits32
-- Not defined on Linux: kept for the BSD/System V module this moves to.
-- ||| Not defined by glibc (System V); do not use on Linux.
-- %inline %foreign "CExpr:(LOBLK),libc,termios.h;unistd.h"
-- export LOBLK : Bits32
||| Linux only, not in POSIX.
%inline %foreign "CExpr:(CIBAUD),libc,termios.h;unistd.h"
export CIBAUD : Bits32
||| Linux only, not in POSIX.
%inline %foreign "CExpr:(CMSPAR),libc,termios.h;unistd.h"
export CMSPAR : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(CRTSCTS),libc,termios.h;unistd.h"
export CRTSCTS : Bits32
-- c_lflag

%inline %foreign "CExpr:(ISIG),libc,termios.h;unistd.h"
export ISIG : Bits32
%inline %foreign "CExpr:(ICANON),libc,termios.h;unistd.h"
export ICANON : Bits32
||| Linux only (System V); not in POSIX.
%inline %foreign "CExpr:(XCASE),libc,termios.h;unistd.h"
export XCASE : Bits32
%inline %foreign "CExpr:(ECHO),libc,termios.h;unistd.h"
export ECHO : Bits32
%inline %foreign "CExpr:(ECHOE),libc,termios.h;unistd.h"
export ECHOE : Bits32
%inline %foreign "CExpr:(ECHOK),libc,termios.h;unistd.h"
export ECHOK : Bits32
%inline %foreign "CExpr:(ECHONL),libc,termios.h;unistd.h"
export ECHONL : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(ECHOCTL),libc,termios.h;unistd.h"
export ECHOCTL : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(ECHOPRT),libc,termios.h;unistd.h"
export ECHOPRT : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(ECHOKE),libc,termios.h;unistd.h"
export ECHOKE : Bits32
-- Not defined on Linux: kept for the BSD/System V module this moves to.
-- ||| Not defined by glibc (Solaris); do not use on Linux.
-- %inline %foreign "CExpr:(DEFECHO),libc,termios.h;unistd.h"
-- export DEFECHO : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(FLUSHO),libc,termios.h;unistd.h"
export FLUSHO : Bits32
%inline %foreign "CExpr:(NOFLSH),libc,termios.h;unistd.h"
export NOFLSH : Bits32
%inline %foreign "CExpr:(TOSTOP),libc,termios.h;unistd.h"
export TOSTOP : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(PENDIN),libc,termios.h;unistd.h"
export PENDIN : Bits32
%inline %foreign "CExpr:(IEXTEN),libc,termios.h;unistd.h"
export IEXTEN : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(VDISCARD),libc,termios.h;unistd.h"
export VDISCARD : Bits32
-- Not defined on Linux: kept for the BSD/System V module this moves to.
-- ||| BSD only (not defined by glibc); do not use on Linux.
-- %inline %foreign "CExpr:(VDSUSP),libc,termios.h;unistd.h"
-- export VDSUSP : Bits32
%inline %foreign "CExpr:(VEOF),libc,termios.h;unistd.h"
export VEOF : Bits32
%inline %foreign "CExpr:(VEOL),libc,termios.h;unistd.h"
export VEOL : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(VEOL2),libc,termios.h;unistd.h"
export VEOL2 : Bits32
%inline %foreign "CExpr:(VERASE),libc,termios.h;unistd.h"
export VERASE : Bits32
%inline %foreign "CExpr:(VINTR),libc,termios.h;unistd.h"
export VINTR : Bits32
%inline %foreign "CExpr:(VKILL),libc,termios.h;unistd.h"
export VKILL : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(VLNEXT),libc,termios.h;unistd.h"
export VLNEXT : Bits32
%inline %foreign "CExpr:(VMIN),libc,termios.h;unistd.h"
export VMIN : Bits32
%inline %foreign "CExpr:(VQUIT),libc,termios.h;unistd.h"
export VQUIT : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(VREPRINT),libc,termios.h;unistd.h"
export VREPRINT : Bits32
%inline %foreign "CExpr:(VSTART),libc,termios.h;unistd.h"
export VSTART : Bits32
-- Not defined on Linux: kept for the BSD/System V module this moves to.
-- ||| BSD only (not defined by glibc); do not use on Linux.
-- %inline %foreign "CExpr:(VSTATUS),libc,termios.h;unistd.h"
-- export VSTATUS : Bits32
%inline %foreign "CExpr:(VSTOP),libc,termios.h;unistd.h"
export VSTOP : Bits32
%inline %foreign "CExpr:(VSUSP),libc,termios.h;unistd.h"
export VSUSP : Bits32
-- Not defined on Linux: kept for the BSD/System V module this moves to.
-- ||| System V only (glibc spells it VSWTC); do not use on Linux.
-- %inline %foreign "CExpr:(VSWTCH),libc,termios.h;unistd.h"
-- export VSWTCH : Bits32
%inline %foreign "CExpr:(VTIME),libc,termios.h;unistd.h"
export VTIME : Bits32
||| Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(VWERASE),libc,termios.h;unistd.h"
export VWERASE : Bits32
-------------------------------------------------------------------------------
-- 


%inline %foreign "CExpr:(tcgetattr($1, $2)),libc,termios.h;unistd.h"
prim__tcgetattr : Int32 -> GCPtr RawTermios -> PrimIO Int32

public export
tcgetattr : FileDesc -> IO (Either Errno Termios)
tcgetattr fd = do
  p <- newTermios
  r <- primIO $ prim__tcgetattr fd.rawfd  p
  if r < 0
    then pure $ Left !(errno)
    else pure $ Right p



-------------------------------------------------------------------------------
-- 




-------------------------------------------------------------------------------
-- Baud rates (`speed_t`)

||| A baud rate constant (`speed_t`), see `cfsetispeed`.
public export
Speed : Type
Speed = Bits32

||| Baud rate 0.
%inline %foreign "CExpr:(B0),libc,termios.h;unistd.h"
export B0 : Bits32
||| Baud rate 50.
%inline %foreign "CExpr:(B50),libc,termios.h;unistd.h"
export B50 : Bits32
||| Baud rate 75.
%inline %foreign "CExpr:(B75),libc,termios.h;unistd.h"
export B75 : Bits32
||| Baud rate 110.
%inline %foreign "CExpr:(B110),libc,termios.h;unistd.h"
export B110 : Bits32
||| Baud rate 134.
%inline %foreign "CExpr:(B134),libc,termios.h;unistd.h"
export B134 : Bits32
||| Baud rate 150.
%inline %foreign "CExpr:(B150),libc,termios.h;unistd.h"
export B150 : Bits32
||| Baud rate 200.
%inline %foreign "CExpr:(B200),libc,termios.h;unistd.h"
export B200 : Bits32
||| Baud rate 300.
%inline %foreign "CExpr:(B300),libc,termios.h;unistd.h"
export B300 : Bits32
||| Baud rate 600.
%inline %foreign "CExpr:(B600),libc,termios.h;unistd.h"
export B600 : Bits32
||| Baud rate 1200.
%inline %foreign "CExpr:(B1200),libc,termios.h;unistd.h"
export B1200 : Bits32
||| Baud rate 1800.
%inline %foreign "CExpr:(B1800),libc,termios.h;unistd.h"
export B1800 : Bits32
||| Baud rate 2400.
%inline %foreign "CExpr:(B2400),libc,termios.h;unistd.h"
export B2400 : Bits32
||| Baud rate 4800.
%inline %foreign "CExpr:(B4800),libc,termios.h;unistd.h"
export B4800 : Bits32
||| Baud rate 9600.
%inline %foreign "CExpr:(B9600),libc,termios.h;unistd.h"
export B9600 : Bits32
||| Baud rate 19200.
%inline %foreign "CExpr:(B19200),libc,termios.h;unistd.h"
export B19200 : Bits32
||| Baud rate 38400.
%inline %foreign "CExpr:(B38400),libc,termios.h;unistd.h"
export B38400 : Bits32
||| Baud rate 57600. Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(B57600),libc,termios.h;unistd.h"
export B57600 : Bits32
||| Baud rate 115200. Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(B115200),libc,termios.h;unistd.h"
export B115200 : Bits32
||| Baud rate 230400. Linux and BSD, not in POSIX.
%inline %foreign "CExpr:(B230400),libc,termios.h;unistd.h"
export B230400 : Bits32
||| Baud rate 460800. Linux only.
%inline %foreign "CExpr:(B460800),libc,termios.h;unistd.h"
export B460800 : Bits32
||| Baud rate 500000. Linux only.
%inline %foreign "CExpr:(B500000),libc,termios.h;unistd.h"
export B500000 : Bits32
||| Baud rate 576000. Linux only.
%inline %foreign "CExpr:(B576000),libc,termios.h;unistd.h"
export B576000 : Bits32
||| Baud rate 921600. Linux only.
%inline %foreign "CExpr:(B921600),libc,termios.h;unistd.h"
export B921600 : Bits32
||| Baud rate 1000000. Linux only.
%inline %foreign "CExpr:(B1000000),libc,termios.h;unistd.h"
export B1000000 : Bits32
||| Baud rate 1152000. Linux only.
%inline %foreign "CExpr:(B1152000),libc,termios.h;unistd.h"
export B1152000 : Bits32
||| Baud rate 1500000. Linux only.
%inline %foreign "CExpr:(B1500000),libc,termios.h;unistd.h"
export B1500000 : Bits32
||| Baud rate 2000000. Linux only.
%inline %foreign "CExpr:(B2000000),libc,termios.h;unistd.h"
export B2000000 : Bits32
||| Baud rate 2500000. Linux only.
%inline %foreign "CExpr:(B2500000),libc,termios.h;unistd.h"
export B2500000 : Bits32
||| Baud rate 3000000. Linux only.
%inline %foreign "CExpr:(B3000000),libc,termios.h;unistd.h"
export B3000000 : Bits32
||| Baud rate 3500000. Linux only.
%inline %foreign "CExpr:(B3500000),libc,termios.h;unistd.h"
export B3500000 : Bits32
||| Baud rate 4000000. Linux only.
%inline %foreign "CExpr:(B4000000),libc,termios.h;unistd.h"
export B4000000 : Bits32

-------------------------------------------------------------------------------
-- Queue selectors and flow actions

||| `tcflush`: discard data received but not read.
%inline %foreign "CExpr:(TCIFLUSH),libc,termios.h;unistd.h"
export TCIFLUSH : Int32
||| `tcflush`: discard data written but not transmitted.
%inline %foreign "CExpr:(TCOFLUSH),libc,termios.h;unistd.h"
export TCOFLUSH : Int32
||| `tcflush`: discard both.
%inline %foreign "CExpr:(TCIOFLUSH),libc,termios.h;unistd.h"
export TCIOFLUSH : Int32
||| `tcflow`: suspend output.
%inline %foreign "CExpr:(TCOOFF),libc,termios.h;unistd.h"
export TCOOFF : Int32
||| `tcflow`: restart suspended output.
%inline %foreign "CExpr:(TCOON),libc,termios.h;unistd.h"
export TCOON : Int32
||| `tcflow`: send a STOP character.
%inline %foreign "CExpr:(TCIOFF),libc,termios.h;unistd.h"
export TCIOFF : Int32
||| `tcflow`: send a START character.
%inline %foreign "CExpr:(TCION),libc,termios.h;unistd.h"
export TCION : Int32

-------------------------------------------------------------------------------
-- Attributes

%inline %foreign "CExpr:(tcsetattr($1, $2, $3)),libc,termios.h;unistd.h"
prim__tcsetattr : Int32 -> Int32 -> GCPtr RawTermios -> PrimIO Int32

||| When `tcsetattr` takes effect.
public export
data TCSAOptions = MkTCSAOption Int32

%inline %foreign "CExpr:(TCSANOW),libc,termios.h;unistd.h"
prim__TCSANOW : Int32
%inline %foreign "CExpr:(TCSADRAIN),libc,termios.h;unistd.h"
prim__TCSADRAIN : Int32
%inline %foreign "CExpr:(TCSAFLUSH),libc,termios.h;unistd.h"
prim__TCSAFLUSH : Int32

||| Immediately.
%inline public export
TCSANOW : TCSAOptions
TCSANOW = MkTCSAOption prim__TCSANOW
||| After all output written has been transmitted.
%inline public export
TCSADRAIN : TCSAOptions
TCSADRAIN = MkTCSAOption prim__TCSADRAIN
||| After the output is transmitted, discarding the input not yet read.
%inline public export
TCSAFLUSH : TCSAOptions
TCSAFLUSH = MkTCSAOption prim__TCSAFLUSH

||| Turn a C status (0 on success, -1 with `errno` set) into a result.
status : Int32 -> IO (Either Errno ())
status r = if r < 0 then Left <$> errno else pure (Right ())

||| Set the attributes of a terminal.
public export
tcsetattr : FileDesc -> TCSAOptions -> Termios -> IO (Either Errno ())
tcsetattr fd (MkTCSAOption opts) ios =
  primIO (prim__tcsetattr fd.rawfd opts ios) >>= status

-------------------------------------------------------------------------------
-- Line control

%inline %foreign "CExpr:(tcsendbreak($1, $2)),libc,termios.h;unistd.h"
prim__tcsendbreak : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcdrain($1)),libc,termios.h;unistd.h"
prim__tcdrain : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcflush($1, $2)),libc,termios.h;unistd.h"
prim__tcflush : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcflow($1, $2)),libc,termios.h;unistd.h"
prim__tcflow : Int32 -> Int32 -> PrimIO Int32

||| Send a break (zero bits for `duration`; 0 means the usual 0.25 to 0.5 s).
public export
tcsendbreak : FileDesc -> (duration : Int32) -> IO (Either Errno ())
tcsendbreak fd duration = primIO (prim__tcsendbreak fd.rawfd duration) >>= status

||| Wait until all output written has been transmitted.
public export
tcdrain : FileDesc -> IO (Either Errno ())
tcdrain fd = primIO (prim__tcdrain fd.rawfd) >>= status

||| Discard data: `TCIFLUSH`, `TCOFLUSH` or `TCIOFLUSH`.
public export
tcflush : FileDesc -> (queueSelector : Int32) -> IO (Either Errno ())
tcflush fd queueSelector = primIO (prim__tcflush fd.rawfd queueSelector) >>= status

||| Suspend or restart transmission: `TCOOFF`, `TCOON`, `TCIOFF` or `TCION`.
public export
tcflow : FileDesc -> (action : Int32) -> IO (Either Errno ())
tcflow fd action = primIO (prim__tcflow fd.rawfd action) >>= status

-------------------------------------------------------------------------------
-- Raw mode and speeds

%inline %foreign "CExpr:(cfmakeraw($1)),libc,termios.h;unistd.h"
prim__cfmakeraw : GCPtr RawTermios -> PrimIO ()
%inline %foreign "CExpr:(cfgetispeed($1)),libc,termios.h;unistd.h"
prim__cfgetispeed : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(cfgetospeed($1)),libc,termios.h;unistd.h"
prim__cfgetospeed : GCPtr RawTermios -> PrimIO Bits32
%inline %foreign "CExpr:(cfsetispeed($1, $2)),libc,termios.h;unistd.h"
prim__cfsetispeed : GCPtr RawTermios -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(cfsetospeed($1, $2)),libc,termios.h;unistd.h"
prim__cfsetospeed : GCPtr RawTermios -> Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(cfsetspeed($1, $2)),libc,termios.h;unistd.h"
prim__cfsetspeed : GCPtr RawTermios -> Bits32 -> PrimIO Int32

||| Make the attributes those of a raw terminal (no line discipline, 8 bits).
||| Not in POSIX; Linux and BSD.
%inline public export
cfmakeraw : Termios -> IO ()
cfmakeraw ios = primIO $ prim__cfmakeraw ios

||| The input baud rate.
%inline public export
cfgetispeed : Termios -> IO Speed
cfgetispeed ios = primIO $ prim__cfgetispeed ios

||| The output baud rate.
%inline public export
cfgetospeed : Termios -> IO Speed
cfgetospeed ios = primIO $ prim__cfgetospeed ios

||| Set the input baud rate (applied by `tcsetattr`).
%inline public export
cfsetispeed : Termios -> Speed -> IO (Either Errno ())
cfsetispeed ios speed = primIO (prim__cfsetispeed ios speed) >>= status

||| Set the output baud rate (applied by `tcsetattr`).
%inline public export
cfsetospeed : Termios -> Speed -> IO (Either Errno ())
cfsetospeed ios speed = primIO (prim__cfsetospeed ios speed) >>= status

||| Set both baud rates. Not in POSIX; Linux and BSD.
%inline public export
cfsetspeed : Termios -> Speed -> IO (Either Errno ())
cfsetspeed ios speed = primIO (prim__cfsetspeed ios speed) >>= status

-------------------------------------------------------------------------------
-- Terminal identity and process groups

%inline %foreign "CExpr:(isatty($1)),libc,unistd.h"
prim__isatty : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(ttyname_r($1, $2, $3)),libc,unistd.h"
prim__ttyname_r : Int32 -> AnyPtr -> Bits64 -> PrimIO Int32
%inline %foreign "CExpr:(tcgetpgrp($1)),libc,unistd.h"
prim__tcgetpgrp : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcsetpgrp($1, $2)),libc,unistd.h"
prim__tcsetpgrp : Int32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcgetsid($1)),libc,termios.h;unistd.h"
prim__tcgetsid : Int32 -> PrimIO Int32

||| True when the descriptor refers to a terminal.
public export
isatty : FileDesc -> IO Bool
isatty fd = (/= 0) <$> primIO (prim__isatty fd.rawfd)

||| The path of the terminal (`ttyname_r`); `Left ENOTTY` for a descriptor that is not one.
public export
ttyname : FileDesc -> IO (Either Errno String)
ttyname fd = do
  buf <- malloc 4096
  r <- primIO (prim__ttyname_r fd.rawfd buf 4096)
  res <- if r /= 0
           then pure (Left (MkErrno r))
           else pure (maybe (Left (MkErrno 22)) Right (ptrToString buf))
  free buf
  pure res

||| The foreground process group of the terminal.
public export
tcgetpgrp : FileDesc -> IO (Either Errno ProcessID)
tcgetpgrp fd = do
  r <- primIO (prim__tcgetpgrp fd.rawfd)
  if r < 0 then Left <$> errno else pure (Right (MkProcessID r))

||| Make a process group the foreground group of the terminal.
public export
tcsetpgrp : FileDesc -> ProcessID -> IO (Either Errno ())
tcsetpgrp fd (MkProcessID pgrp) = primIO (prim__tcsetpgrp fd.rawfd pgrp) >>= status

||| The session ID of the session leader that controls the terminal.
public export
tcgetsid : FileDesc -> IO (Either Errno ProcessID)
tcgetsid fd = do
  r <- primIO (prim__tcgetsid fd.rawfd)
  if r < 0 then Left <$> errno else pure (Right (MkProcessID r))

-------------------------------------------------------------------------------
-- Window size

%inline %foreign "CExpr:(({ struct winsize w; memset(&w, 0, sizeof(w)); ioctl($1, TIOCGWINSZ, &w) < 0 ? -1 : (int)(w.ws_col | ((unsigned)w.ws_row << 16)); })),libc,sys/ioctl.h;string.h"
prim__tiocgwinsz : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(({ struct winsize w; memset(&w, 0, sizeof(w)); w.ws_col = $2; w.ws_row = $3; ioctl($1, TIOCSWINSZ, &w); })),libc,sys/ioctl.h;string.h"
prim__tiocswinsz : Int32 -> Bits32 -> Bits32 -> PrimIO Int32

||| The size of the terminal in character cells: (columns, rows).
||| Both are at most 32767; a terminal that does not report its size gives (0, 0).
public export
getWinSize : FileDesc -> IO (Either Errno (Nat, Nat))
getWinSize fd = do
  r <- primIO (prim__tiocgwinsz fd.rawfd)
  if r < 0
     then Left <$> errno
     else let v = cast {to = Nat} r in pure (Right (mod v 65536, div v 65536))

||| Set the size of the terminal (columns, rows); a program on the other side
||| of a pseudo-terminal receives SIGWINCH.
public export
setWinSize : FileDesc -> (cols : Bits32) -> (rows : Bits32) -> IO (Either Errno ())
setWinSize fd cols rows = primIO (prim__tiocswinsz fd.rawfd cols rows) >>= status

-------------------------------------------------------------------------------
-- Pseudo-terminals
--
-- These four are declared by glibc only under `_XOPEN_SOURCE`: build the
-- program with `IDRIS2_CFLAGS=-D_GNU_SOURCE` (or `CFLAGS=-D_GNU_SOURCE`) in
-- the environment of the Idris compiler, see "Build flags" in
-- `System.Posix.File`.

%inline %foreign "CExpr:(posix_openpt($1)),libc,stdlib.h;fcntl.h"
prim__posix_openpt : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(grantpt($1)),libc,stdlib.h"
prim__grantpt : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(unlockpt($1)),libc,stdlib.h"
prim__unlockpt : Int32 -> PrimIO Int32
%inline %foreign "CExpr:(ptsname($1)),libc,stdlib.h"
prim__ptsname : Int32 -> PrimIO AnyPtr

||| Open the master side of a new pseudo-terminal. `flags` is `O_RDWR` (2)
||| with optionally `O_NOCTTY`.
||| Needs `_GNU_SOURCE`; see the comment above.
public export
posixOpenpt : (flags : Bits32) -> IO (Either Errno FileDesc)
posixOpenpt flags = primIO (prim__posix_openpt flags) >>= primFdToFileDesc

||| Give the slave side the right owner and mode. Needs `_GNU_SOURCE`; see the comment above.
public export
grantpt : FileDesc -> IO (Either Errno ())
grantpt fd = primIO (prim__grantpt fd.rawfd) >>= status

||| Allow the slave side to be opened. Needs `_GNU_SOURCE`; see the comment above.
public export
unlockpt : FileDesc -> IO (Either Errno ())
unlockpt fd = primIO (prim__unlockpt fd.rawfd) >>= status

||| The path of the slave side of the pseudo-terminal whose master is `fd`.
||| Needs `_GNU_SOURCE`; see the comment above.
public export
ptsname : FileDesc -> IO (Either Errno String)
ptsname fd = do
  p <- primIO (prim__ptsname fd.rawfd)
  case ptrToString p of
    Just s => pure (Right s)
    Nothing => Left <$> errno
