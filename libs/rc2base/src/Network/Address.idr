||| IPv4 addresses for the socket modules, without the `network` package.
||| `toSockAddr` turns one into the `SockAddr` of `System.Posix.Socket`.
module Network.Address

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.List
import Data.List1
import Data.String
import System.Posix.Socket

%default total

||| An IPv4 address, one byte at a time.
public export
data Address = IPv4 Bits8 Bits8 Bits8 Bits8

public export
Eq Address where
  IPv4 a b c d == IPv4 e f g h = a == e && b == f && c == g && d == h

public export
Show Address where
  show (IPv4 a b c d) = show a ++ "." ++ show b ++ "." ++ show c ++ "." ++ show d

||| `127.0.0.1`.
public export
loopbackAddress : Address
loopbackAddress = IPv4 127 0 0 1

||| `0.0.0.0`: every interface.
public export
anyAddress : Address
anyAddress = IPv4 0 0 0 0

||| The address as the number `SockAddr` holds (`127.0.0.1` is `0x7f000001`).
export
addressWord : Address -> Bits32
addressWord (IPv4 a b c d) = cast a * 16777216 + cast b * 65536 + cast c * 256 + cast d

||| Whether `port` fits a TCP port (0 to 65535). `toSockAddr` keeps only the low
||| 16 bits, so the socket calls refuse anything else with `EINVAL`.
export
validPort : Int -> Bool
validPort port = port >= 0 && port <= 65535

||| The address and a port (0 to 65535) as a socket address.
export
toSockAddr : Address -> (port : Int) -> SockAddr
toSockAddr addr port = SockAddrIn (addressWord addr) (cast port)

||| Dotted decimal, four numbers from 0 to 255 and nothing else (no leading
||| zeros, which `inet_aton` would read as octal).
export
parseAddress : String -> Maybe Address
parseAddress s = case forget (split (== '.') s) of
    [a, b, c, d] => [| IPv4 (byte a) (byte b) (byte c) (byte d) |]
    _ => Nothing
  where
    byte : String -> Maybe Bits8
    byte t =
      if null (unpack t) || not (all isDigit (unpack t)) || length t > 3 || (length t > 1 && isPrefixOf "0" t)
        then Nothing
        else case parsePositive {a = Integer} t of
               Just n => if n <= 255 then Just (cast n) else Nothing
               Nothing => Nothing
