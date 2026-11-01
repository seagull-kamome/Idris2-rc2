||| The `rc2` code generation backend with a driver that has no REPL
||| (`idris2-rc2-norepl`). See doc/norepl.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module NoRepl.Main

import Compiler.Common
import Compiler.RC2.RC2
import NoRepl.Driver
import NoRepl.SchemeStubs

main : IO ()
main = mainNoRepl [("rc2", codegenRC2)]
