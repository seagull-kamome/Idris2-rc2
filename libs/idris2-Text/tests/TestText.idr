module Main

import Data.Text

main : IO ()
main = do
  putStrLn "Creating Text from string..."
  txt <- fromString "Hello, Idris2-Text!"
  putStrLn "Text created successfully."
  
  putStrLn "Freeing Text..."
  free txt
  putStrLn "Text freed successfully."
