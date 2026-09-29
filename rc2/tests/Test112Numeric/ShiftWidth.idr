module Test112Numeric.ShiftWidth

-- Shifts by the type's width or more give 0 (or -1 for a negative value
-- shifted right), as on Chez; C leaves them undefined, and x86 used to
-- give back the value itself. SipHash32 in idris2-missing-containers
-- shifts a Bits32 by 32. Each type is shifted both natively (locals in
-- one function) and boxed (values read out of a list).

import Data.Bits
import Data.String

counts : List Nat
counts = [0, 1, 7, 8, 15, 16, 31, 32, 33, 63, 64, 65]

-- Native: the operands stay in C locals.
b32 : Bits32 -> Bits32 -> String
b32 x c = show (prim__shl_Bits32 x c) ++ "/" ++ show (prim__shr_Bits32 x c)

b8 : Bits8 -> Bits8 -> String
b8 x c = show (prim__shl_Bits8 x c) ++ "/" ++ show (prim__shr_Bits8 x c)

b16 : Bits16 -> Bits16 -> String
b16 x c = show (prim__shl_Bits16 x c) ++ "/" ++ show (prim__shr_Bits16 x c)

b64 : Bits64 -> Bits64 -> String
b64 x c = show (prim__shl_Bits64 x c) ++ "/" ++ show (prim__shr_Bits64 x c)

i32 : Int32 -> Int32 -> String
i32 x c = show (prim__shl_Int32 x c) ++ "/" ++ show (prim__shr_Int32 x c)

i64 : Int64 -> Int64 -> String
i64 x c = show (prim__shl_Int64 x c) ++ "/" ++ show (prim__shr_Int64 x c)

int : Int -> Int -> String
int x c = show (prim__shl_Int x c) ++ "/" ++ show (prim__shr_Int x c)

-- Boxed: the operands come out of a list.
boxed32 : List (Bits32, Bits32) -> List Bits32
boxed32 = map (\(x, c) => prim__shr_Bits32 x c + prim__shl_Bits32 x c)

boxed64 : List (Int, Int) -> List Int
boxed64 = map (\(x, c) => prim__shr_Int x c + prim__shl_Int x c)

export
run : IO ()
run = do
  putStrLn $ unwords $ map (\c => b32 0xdeadbeef (cast c)) counts
  putStrLn $ unwords $ map (\c => b8 0xa5 (cast c)) counts
  putStrLn $ unwords $ map (\c => b16 0xa5a5 (cast c)) counts
  putStrLn $ unwords $ map (\c => b64 0xdeadbeefcafebabe (cast c)) counts
  putStrLn $ unwords $ map (\c => i32 (-12345) (cast c)) counts
  putStrLn $ unwords $ map (\c => i64 (-1234567890123) (cast c)) counts
  putStrLn $ unwords $ map (\c => int 1234567890123 (cast c)) counts
  printLn (boxed32 (map (\c => (0x80000001, cast c)) counts))
  printLn (boxed64 (map (\c => (-7, cast c)) counts))
