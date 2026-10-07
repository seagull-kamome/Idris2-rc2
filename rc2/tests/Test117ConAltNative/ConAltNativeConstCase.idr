module Test117ConAltNative.ConAltNativeConstCase

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A constructor-destructured field that is both read natively
-- (arithmetic / comparison) and the scrutinee of a constant `case`:
-- ConAltNative's shadow must leave the boxed field's reference owned by
-- every alt of that case (rc2/doc/con-alt-native.md, bug #4). The Int
-- values are >= 2^62, so they are heap-allocated and a lost reference
-- is a real leak under valgrind.

safeDiv : Int -> Int -> Maybe Int
safeDiv _ 0 = Nothing
safeDiv x y = Just (x `div` y)

data J = JNum Double | JStr String

kind : J -> Maybe Int
kind (JNum d) = case d of
                     1.0 => Just 0
                     2.0 => Just 1
                     _ => Nothing
kind _ = Nothing

kindArith : J -> Maybe Double
kindArith (JNum d) = case d of
                          1.5 => Nothing
                          _ => Just (d * 2.0 + d)
kindArith _ = Nothing

export
run : IO ()
run = do
  n <- pure 5
  let xs = map (\k => 4611686018427387904 + cast k) [1 .. n]
  printLn (map (safeDiv 100) (0 :: xs))
  printLn (map (safeDiv 4611686018427387905) (0 :: xs))
  let js = map (\k => JNum (cast k * 0.5)) [1 .. n]
  printLn (map kind js)
  printLn (map kindArith (JStr "x" :: js))
