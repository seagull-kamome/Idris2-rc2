module Main

-- Exercises native (unboxed) representation inference
-- (Compiler.RC2.Types/RC.idr) across every signed/unsigned x
-- 8/16/32/64-bit fixed-width integer type. Each chainX function computes
-- a short same-width arithmetic chain (Add/Mul/Sub[/Neg for signed
-- types]) purely from intermediate let-bindings, so per
-- Compiler.RC2.Types.opResultRep every intermediate should get
-- Rep = RNative X and never touch the heap -- only the final boxed
-- return value (and the two boxed arguments) should ever reach
-- idris2rc2_mk*/dup/drop. Each chain is also deliberately pushed past
-- its type's range (100+100 for Int8, etc.) to pin down two's-complement
-- wraparound correctness per width, not just its C type.

chainInt8 : Int8 -> Int8 -> Int8
chainInt8 x y =
  let a = x + y
      b = a * 2
      c = b - x
      d = negate c
  in d

chainInt16 : Int16 -> Int16 -> Int16
chainInt16 x y =
  let a = x + y
      b = a * 2
      c = b - x
      d = negate c
  in d

chainInt32 : Int32 -> Int32 -> Int32
chainInt32 x y =
  let a = x + y
      b = a * 2
      c = b - x
      d = negate c
  in d

chainInt64 : Int64 -> Int64 -> Int64
chainInt64 x y =
  let a = x + y
      b = a * 2
      c = b - x
      d = negate c
  in d

chainBits8 : Bits8 -> Bits8 -> Bits8
chainBits8 x y =
  let a = x + y
      b = a * 2
      c = b - x
  in c

chainBits16 : Bits16 -> Bits16 -> Bits16
chainBits16 x y =
  let a = x + y
      b = a * 2
      c = b - x
  in c

chainBits32 : Bits32 -> Bits32 -> Bits32
chainBits32 x y =
  let a = x + y
      b = a * 2
      c = b - x
  in c

chainBits64 : Bits64 -> Bits64 -> Bits64
chainBits64 x y =
  let a = x + y
      b = a * 2
      c = b - x
  in c

main : IO ()
main = do
    printLn (chainInt8 100 100)
    printLn (chainInt16 30000 30000)
    printLn (chainInt32 2000000000 2000000000)
    printLn (chainInt64 5000000000000000000 5000000000000000000)
    printLn (chainBits8 200 200)
    printLn (chainBits16 60000 60000)
    printLn (chainBits32 4000000000 4000000000)
    printLn (chainBits64 10000000000000000000 10000000000000000000)
