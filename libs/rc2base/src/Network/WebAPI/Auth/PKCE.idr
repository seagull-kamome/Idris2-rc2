module Network.WebAPI.Auth.PKCE

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- RFC 7636's S256 code challenge: SHA-256 (FIPS 180-4) and unpadded
-- base64url, written out here because base/contrib have neither and a
-- libcrypto binding would be a dependency for 32 bytes of hashing.

import Data.Bits
import Data.List
import Data.Maybe
import Data.Vect

%default total

rotr : Bits32 -> Bits32 -> Bits32
rotr x n = prim__shr_Bits32 x n .|. prim__shl_Bits32 x (32 - n)

k : List Bits32
k = [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    , 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    , 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    , 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    , 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    , 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    , 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    , 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 ]

chunks : Nat -> List a -> List (List a)
chunks n xs = case splitAt n xs of
    (c, [])   => [c]
    (c, rest) => c :: assert_total (chunks n rest)

word : List Bits8 -> Bits32
word = foldl (\acc, b => prim__shl_Bits32 acc 8 .|. cast b) 0

bytes : Bits32 -> List Bits8
bytes w = map (\s => cast (prim__shr_Bits32 w s)) [24, 16, 8, 0]

schedule : List Bits32 -> List Bits32
schedule ws = go 16 (reverse ws)
  where
    -- `rev` holds w[i-1], w[i-2], ... newest first.
    go : Nat -> List Bits32 -> List Bits32
    go 64 rev = reverse rev
    go i rev = case (getAt 1 rev, getAt 6 rev, getAt 14 rev, getAt 15 rev) of
        (Just w2, Just w7, Just w15, Just w16) =>
            let s0 = rotr w15 7 `xor` rotr w15 18 `xor` prim__shr_Bits32 w15 3
                s1 = rotr w2 17 `xor` rotr w2 19 `xor` prim__shr_Bits32 w2 10
            in assert_total (go (S i) ((w16 + s0 + w7 + s1) :: rev))
        _ => reverse rev

compress : Vect 8 Bits32 -> List Bits32 -> Vect 8 Bits32
compress h ws = zipWith (+) h (foldl round h (zip k (schedule ws)))
  where
    round : Vect 8 Bits32 -> (Bits32, Bits32) -> Vect 8 Bits32
    round [a, b, c, d, e, f, g, hh] (ki, wi) =
        let s1 = rotr e 6 `xor` rotr e 11 `xor` rotr e 25
            ch = (e .&. f) `xor` (complement e .&. g)
            t1 = hh + s1 + ch + ki + wi
            s0 = rotr a 2 `xor` rotr a 13 `xor` rotr a 22
            mj = (a .&. b) `xor` (a .&. c) `xor` (b .&. c)
        in [t1 + s0 + mj, a, b, c, d + t1, e, f, g]

export
sha256 : List Bits8 -> List Bits8
sha256 msg =
    let len    = length msg
        zeros  = (119 `minus` (len `mod` 64)) `mod` 64
        bitLen = cast {to = Bits64} len * 8
        padded = msg ++ [0x80] ++ replicate zeros 0
                     ++ map (\s => cast (prim__shr_Bits64 bitLen s)) [56, 48, 40, 32, 24, 16, 8, 0]
        h0 = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
             , 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ]
    in concatMap bytes (toList (foldl compress h0 (map (map word . chunks 4) (chunks 64 padded))))

||| RFC 4648 section 5, without `=` padding.
export
base64url : List Bits8 -> String
base64url bs = pack (concatMap enc (chunks 3 bs))
  where
    alphabet : String
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

    sym : Bits32 -> Char
    sym i = fromMaybe 'A' (getAt (cast (i .&. 63)) (unpack alphabet))

    enc : List Bits8 -> List Char
    enc grp =
        let n = foldl (\acc, b => prim__shl_Bits32 acc 8 .|. cast b) 0 (take 3 (grp ++ [0, 0]))
        in List.take (S (length grp)) (map (\s => sym (prim__shr_Bits32 n s)) [18, 12, 6, 0])

||| The S256 `code_challenge` for an ASCII `verifier`.
export
challengeS256 : String -> String
challengeS256 = base64url . sha256 . map (cast . ord) . unpack
