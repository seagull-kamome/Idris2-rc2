module Main

import Compiler.Common
import Compiler.RC2.RC2
import Idris.Driver

main : IO ()
main = mainWithCodegens [("rc2", codegenRC2)]
