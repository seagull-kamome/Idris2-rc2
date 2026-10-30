||| The type of a TCP or UDP port number, apart from `System.Posix.Socket` so
||| that `Network.Address` can re-export it alone.
module System.Posix.Socket.Port

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

%default total

||| A port number, 0 to 65535: 16 bits, as in `struct sockaddr_in`.
public export
Port : Type
Port = Bits16
