module Main

-- Constant-constructor specialization of a dictionary that a
-- continuation captures (`Compiler.RC2.SpecClosure`, `underAppSites`): in
-- `twice` the dictionary is used again after the first `>>=`, so the
-- lifted continuation holds it in a partial application. That used to
-- count as an escaping use and kept `twice` generic, with every method
-- called through `apply`. The same shape is `modifyIORef`, `newIORef`
-- and the other `HasIO io =>` functions of the libraries.

interface Monad m => Log m where
  logIt : String -> m ()

Log IO where
  logIt s = putStrLn ("log " ++ s)

%noinline
twice : Log m => Int -> m Int
twice n = do
  logIt "a"
  x <- pure (n + 1)
  logIt "b"
  pure (x * 2)

main : IO ()
main = do
  r <- twice 20
  printLn r
  s <- twice 1
  printLn s
