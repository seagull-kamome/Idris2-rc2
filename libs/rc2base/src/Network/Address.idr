||| Socket addresses with the names of the `network` package (`SocketAddress`,
||| `Port`, `IPv4Addr`, `Hostname`, `parseIPv4`), without depending on it.
||| `toSockAddr` turns one into the `SockAddr` of `System.Posix.Socket`.
module Network.Address

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.List
import Data.List1
import Data.Maybe
import Data.String
import System.Posix.Errno
import System.Posix.Socket

%default total

||| A TCP port, 0 to 65535.
public export
Port : Type
Port = Int

||| A network address. Only `IPv4Addr` can be used for a socket here: a host
||| name would need a blocking lookup and IPv6 is not supported.
public export
data SocketAddress : Type where
  IPv4Addr : Int -> Int -> Int -> Int -> SocketAddress
  ||| Not implemented.
  IPv6Addr : SocketAddress
  Hostname : String -> SocketAddress
  ||| Used when there's a parse error.
  InvalidAddress : SocketAddress

public export
Eq SocketAddress where
  IPv4Addr a b c d == IPv4Addr e f g h = a == e && b == f && c == g && d == h
  IPv6Addr == IPv6Addr = True
  Hostname a == Hostname b = a == b
  InvalidAddress == InvalidAddress = True
  _ == _ = False

public export
Show SocketAddress where
  show (IPv4Addr a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d
  show IPv6Addr = "NOT IMPLEMENTED YET"
  show (Hostname host) = host
  show InvalidAddress = "Invalid"

||| Whether `port` fits a TCP port (0 to 65535). `toSockAddr` refuses anything else.
export
validPort : Port -> Bool
validPort port = port >= 0 && port <= 65535

||| The address and the port as a socket address. `EAFNOSUPPORT` for anything but
||| an IPv4 address, `EINVAL` for an octet outside 0 to 255 or a bad port.
export
toSockAddr : SocketAddress -> Port -> Either Errno SockAddr
toSockAddr (IPv4Addr a b c d) port =
  if validPort port && all octet [a, b, c, d]
    then Right (SockAddrIn (word a * 16777216 + word b * 65536 + word c * 256 + word d) (cast port))
    else Left EINVAL
  where
    octet : Int -> Bool
    octet n = n >= 0 && n <= 255

    word : Int -> Bits32
    word = cast
toSockAddr _ _ = Left EAFNOSUPPORT

||| Dotted decimal, four numbers from 0 to 255 and nothing else (no leading
||| zeros, which `inet_aton` would read as octal); `InvalidAddress` otherwise.
export
parseIPv4 : String -> SocketAddress
parseIPv4 s = case forget (split (== '.') s) of
    [a, b, c, d] => fromMaybe InvalidAddress [| IPv4Addr (octet a) (octet b) (octet c) (octet d) |]
    _ => InvalidAddress
  where
    octet : String -> Maybe Int
    octet t =
      if null (unpack t) || not (all isDigit (unpack t)) || length t > 3 || (length t > 1 && isPrefixOf "0" t)
        then Nothing
        else case parsePositive {a = Integer} t of
               Just n => if n <= 255 then Just (cast n) else Nothing
               Nothing => Nothing
