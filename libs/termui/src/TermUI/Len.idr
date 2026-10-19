||| The type of sizes, coordinates and offsets on the screen. A terminal is
||| nowhere near 2^31 cells wide, and `Int32` is native in the generated code.
||| Unlike `Nat` it can be negative; `monus` is the subtraction that stops at 0.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Len

%default total

public export
Len : Type
Len = Int32

||| `a - b`, or 0 if that is negative.
public export
monus : Len -> Len -> Len
monus a b = if a > b then a - b else 0

||| The number of elements, as a `Len`.
public export
count : List a -> Len
count xs = cast (length xs)
