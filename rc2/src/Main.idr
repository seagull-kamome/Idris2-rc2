||| Registers `Compiler.RC2.RC2.codegenRC2` as the `rc2` code generation
||| backend with Idris2's driver.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Compiler.Common
import Compiler.RC2.RC2
import Idris.Driver

main : IO ()
main = mainWithCodegens [("rc2", codegenRC2)]
