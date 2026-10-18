||| Packed and normalized colour representations, and the conversions
||| between them.
|||
||| Two packed 8-bit forms -- `ARGB8` and `CMYK8`, four channels in a
||| `Bits32`, most-significant channel first -- and two floating-point
||| forms, `AHSV` and `CMYK`. In the floating-point forms each colour
||| component is in `[0, 1]`; `AHSV`'s `hue` is the exception, in
||| degrees `[0, 360)`. Alpha is carried through every conversion that
||| has somewhere to put it; `CMYK` has no alpha channel, so
||| `ARGB8 -> CMYK` drops it.
module Data.ColorCode

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Data.Bits


-------------------------------------------------------------------------------
-- Packed 8-bit ARGB

namespace ARGB
  ||| Four 8-bit channels packed most-significant-first: alpha in bits
  ||| 24-31, red in 16-23, green in 8-15, blue in 0-7.
  public export data ARGB8 = MkARGB8 Bits32
  ||| Extract a channel as its raw 8-bit value (never normalized).
  public export
  (.alpha), (.red), (.green), (.blue) : ARGB8 -> Bits8
  (.alpha) (MkARGB8 x) = cast $ (x `shiftR` 24)
  (.red)   (MkARGB8 x) = cast $ (x `shiftR` 16)
  (.green) (MkARGB8 x) = cast $ (x `shiftR` 8)
  (.blue)  (MkARGB8 x) = cast $ x .&. 0xff

  ||| Pack four channels (`a r g b` order) into one `ARGB8`.
  public export
  toARGB8 : (a : Bits8) -> (r : Bits8) -> (g : Bits8) -> (b : Bits8) -> ARGB8
  toARGB8 a r g b = MkARGB8 $ ((cast a) `shiftL` 24) .|. ((cast r) `shiftL` 16)
                         .|. ((cast g) `shiftL` 8) .|. (cast b)


-------------------------------------------------------------------------------
-- Normalized floating-point AHSV

namespace AHSV
  ||| Hue in degrees in `[0, 360)`; `alpha`, `saturation` and `value` in
  ||| `[0, 1]`.
  public export
  record AHSV where
    constructor MkAHSV
    alpha, hue, saturation, value : Double




-------------------------------------------------------------------------------
-- CMYK (floating-point and packed 8-bit)

namespace CMYK
  ||| Each component in `[0, 1]`. No alpha channel -- an ARGB concept
  ||| this one does not carry.
  public export
  record CMYK where
    constructor MkCMYK
    cyan, magenta, yellow, keyPlate : Double


  ||| Four 8-bit channels packed most-significant-first: cyan in bits
  ||| 24-31, magenta in 16-23, yellow in 8-15, key plate in 0-7.
  public export data CMYK8 = MkCMYK8 Bits32
  ||| Extract a channel as its raw 8-bit value (never normalized).
  public export
  (.cyan), (.magenta), (.yellow), (.keyPlate) : CMYK8 -> Bits8
  (.cyan)     (MkCMYK8 x) = cast $ (x `shiftR` 24)
  (.magenta)  (MkCMYK8 x) = cast $ (x `shiftR` 16)
  (.yellow)   (MkCMYK8 x) = cast $ (x `shiftR` 8)
  (.keyPlate) (MkCMYK8 x) = cast $ x .&. 0xff

  ||| Pack four channels (`c m y k` order) into one `CMYK8`.
  public export
  toCMYK8 : Bits8 -> Bits8 -> Bits8 -> Bits8 -> CMYK8
  toCMYK8 c m y k = MkCMYK8 $ ((cast c) `shiftL` 24) .|. ((cast m) `shiftL` 16)
                        .|. ((cast y) `shiftL` 8) .|. (cast k)

-------------------------------------------------------------------------------
-- Cast

||| `[0, 255]` -> `[0, 1]`.
normalize8Bit : Bits8 -> Double
normalize8Bit x = cast {to=Double} (cast {to=Int} x) / 255.0

||| `[0, 1]` -> `[0, 255]`, clamping the input to `[0, 1]` and rounding
||| to the nearest integer.
denormalizeTo8Bit : Double -> Bits8
denormalizeTo8Bit val =
  let clamped = max 0.0 (min 1.0 val)
  in cast {to=Bits8} (cast {to=Int} (clamped * 255.0 + 0.5))


||| RGB -> HSV. `value` is the largest normalized RGB component and
||| `saturation` is `delta / value` (0 when `value == 0`). Achromatic
||| input (`delta == 0`) reports hue 0.
public export
Cast ARGB8 AHSV where
  cast rgb =
    let r = normalize8Bit rgb.red
        g = normalize8Bit rgb.green
        b = normalize8Bit rgb.blue
        --
        cmax = max r (max g b)
        cmin = min r (min g b)
        delta = cmax - cmin
        --
        v = cmax
        s = if cmax == 0.0 then 0.0 else delta / cmax
        h' = if delta == 0.0 
                then 0.0
                else if cmax == r 
                        then 60.0 * ((g - b) / delta)
                        else if cmax == g 
                                then 60.0 * (((b - r) / delta) + 2.0)
                                else 60.0 * (((r - g) / delta) + 4.0)
        h = if h' < 0.0 then h' + 360.0 else h'
    in MkAHSV (normalize8Bit rgb.alpha) h s cmax



||| RGB -> CMYK by the naive formula, with no black generation:
||| `k = 1 - value`, `c = (value - r) / value`. Fully black input maps
||| to `k = 1`. `CMYK` has no alpha channel, so `ARGB8`'s alpha is
||| dropped here, unlike in the `AHSV` conversion.
public export
Cast ARGB8 CMYK where
  cast rgb =
    let r = normalize8Bit rgb.red
        g = normalize8Bit rgb.green
        b = normalize8Bit rgb.blue
        cmax = max r (max g b)
    in if cmax == 0.0
          then MkCMYK 0.0 0.0 0.0 1.0
          else let 
            c = (cmax - r) / cmax
            m = (cmax - g) / cmax
            y = (cmax - b) / cmax
          in MkCMYK c m y (1.0 - cmax)


||| HSV -> RGB. The hue is nudged into `[0, 360)` by a single `+-360`
||| shift before a sector is chosen, so it must not be arbitrarily far
||| out of range. Achromatic input (`s == 0`) yields the grey
||| `(v, v, v)`.
public export
Cast AHSV ARGB8 where
  cast hsv =
    let h = hsv.hue
        v = hsv.value
        s = hsv.saturation
        h_norm = if h >= 360.0
                    then h - 360.0
                    else if h < 0.0 then h + 360.0 else h
        h' = h_norm / 60.0
        hi = cast {to=Int} h'
        hi_mod = hi `mod` 6
        --
        f = h' - cast {to=Double} hi
        --
        p = v * (1.0 - s)
        q = v * (1.0 - f * s)
        t = v * (1.0 - (1.0 - f) * s)
        --
        (r, g, b) = if s == 0.0 
                       then (v, v, v)
                       else case hi_mod of
                                 0 => (v, t, p)
                                 1 => (q, v, p)
                                 2 => (p, v, t)
                                 3 => (p, q, v)
                                 4 => (t, p, v)
                                 _ => (v, p, q)
    in toARGB8 (denormalizeTo8Bit hsv.alpha) 
               (denormalizeTo8Bit r) 
               (denormalizeTo8Bit g) 
               (denormalizeTo8Bit b)


||| Packed 8-bit CMYK -> normalized CMYK.
public export
Cast CMYK8 CMYK where
  cast x = MkCMYK {
    cyan = normalize8Bit x.cyan,
    magenta = normalize8Bit x.magenta,
    yellow = normalize8Bit x.yellow,
    keyPlate = normalize8Bit x.keyPlate
    }

||| Normalized CMYK -> packed 8-bit CMYK.
public export
Cast CMYK CMYK8 where
  cast x = toCMYK8 (denormalizeTo8Bit x.cyan)   (denormalizeTo8Bit x.magenta)
                   (denormalizeTo8Bit x.yellow) (denormalizeTo8Bit x.keyPlate)



