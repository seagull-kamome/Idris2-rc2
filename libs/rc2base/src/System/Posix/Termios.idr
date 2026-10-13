module System.Posix.Termios

import Data.So
import Data.Vect
import System.FFI
import System.Posix.FileDesc
import System.Posix.Errno

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
prim__tcgetattr : Bits32 -> GCPtr RawTermios -> PrimIO Int32

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

%inline %foreign "CExpr:(TCSANOW),libc,termios.h;unistd.h"
prim__TCSANOW : Int32
%inline %foreign "CExpr:(TCSADRAIN),libc,termios.h;unistd.h"
prim__TCSADRAIN : Int32
%inline %foreign "CExpr:(TCSAFLUSH),libc,termios.h;unistd.h"
prim__TCSAFLUSH : Int32

export data TCSAOptions = MkTCSAOption Int32
%inline public export
TCSANOW, TCSADRAIN, TCSAFLUSH : TCSAOptions
TCSANOW = MkTCSAOption prim__TCSANOW
TCSADRAIN = MkTCSAOption prim__TCSADRAIN
TCSAFLUSH = MkTCSAOption prim__TCSAFLUSH



%inline %foreign "CExpr:(tcsetattr($1, $2, $3)),libc,termios.h;unistd.h"
prim__tcsetattr : Bits32 -> Int32 -> GCPtr RawTermios -> PrimIO Int32

public export
tcsetattr : FileDesc -> TCSAOptions -> Termios -> IO Int32
tcsetattr fd (MkTCSAOption opts) ios =
  primIO $ prim__tcsetattr fd.rawfd opts ios




-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(tcsendbreak($1, $2)),libc,termios.h;unistd.h"
prim__tcsendbreak : Bits32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcdrain($1)),libc,termios.h;unistd.h"
prim__tcdrain : Bits32 -> PrimIO Int32
%inline %foreign "CExpr:(tcflush($1, $2)),libc,termios.h;unistd.h"
prim__tcflush : Bits32 -> Int32 -> PrimIO Int32
%inline %foreign "CExpr:(tcflow($1, $2)),libc,termios.h;unistd.h"
prim__tcflow : Bits32 -> Int32 -> PrimIO Int32

public export
tcsendbreak : FileDesc -> Int32 -> IO Int32
tcsendbreak fd duration = primIO $ prim__tcsendbreak fd.rawfd duration

public export
tcdrain : FileDesc -> IO Int32
tcdrain fd = primIO $ prim__tcdrain fd.rawfd

public export
tcflush : FileDesc -> Int32 -> IO Int32
tcflush fd queueSelector = primIO $ prim__tcflush fd.rawfd queueSelector

public export
tcflow : FileDesc -> Int32 -> IO Int32
tcflow fd action = primIO $ prim__tcflow fd.rawfd action



-------------------------------------------------------------------------------
-- 

%inline %foreign "CExpr:(cfmakeraw($1)),libc,termios.h;unistd.h"
prim__cfmakeraw : GCPtr RawTermios -> PrimIO ()
%inline %foreign "CExpr:(cfgetispeed($1)),libc,termios.h;unistd.h"
prim__cfgetispeed : GCPtr RawTermios -> PrimIO Int32
%inline %foreign "CExpr:(cfsetispeed($1, $2)),libc,termios.h;unistd.h"
prim__cfsetispeed : GCPtr RawTermios -> Int32 -> PrimIO Int32

%inline public export
cfmakeraw : Termios -> IO ()
cfmakeraw ios = primIO $ prim__cfmakeraw ios

%inline public export
cfgetispeed : Termios -> IO Int32
cfgetispeed ios = primIO $ prim__cfgetispeed ios

%inline public export
cfsetispeed : Termios -> Int32 -> IO Int32
cfsetispeed ios speed = primIO $ prim__cfsetispeed ios speed


