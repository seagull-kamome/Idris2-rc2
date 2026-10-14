module Test106TransitiveSpec.LazyFuncSpec

-- Closure specialisation of `Prelude.Types.maybe`/`either`, whose
-- function arguments are `Lazy` and reach the body through a `force`
-- (`Compiler.RC2.SpecClosure.unforceParam`;
-- doc/speculative-closure-specialization.md, "Forcing a closure
-- parameter"). The scrutinees depend on the runtime arguments, so
-- nothing folds away at compile time.

import System

incr : Int -> Int
incr x = x + 3

describe : Int -> String
describe n = if n > 5 then "big" else "small"

-- A constant function and a capturing one.
viaMaybe : Maybe Int -> Int -> Int
viaMaybe m k = maybe k incr m + maybe 0 (\x => x * k) m

-- A function-typed Lazy argument that is forced and applied.
viaEither : Either String Int -> Int -> String
viaEither e k = either (\s => s ++ "!") (\n => describe (n + k)) e

export
run : IO ()
run = do
  args <- getArgs
  let k = cast (length args) + 4
  printLn (viaMaybe (Just 2) k, viaMaybe Nothing k)
  putStrLn (viaEither (Left "left") k ++ " " ++ viaEither (Right 1) k ++ " " ++ viaEither (Right 9) k)
