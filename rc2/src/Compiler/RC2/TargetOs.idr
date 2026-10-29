||| Folding `prim__os` to a constant (`--directive target-os=<name>`).
||| The compiler decides once which OS the generated C is built for, folds the
||| `System.Info.os` primitive to that name, and makes the C compiler check
||| the claim. See rc2/doc/directives.md.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.TargetOs

import Compiler.RC2.RCExp
import Compiler.RC2.Types

import Core.TT

import Data.List
import Data.String

import System
import System.File
import System.Info

%default total

-------------------------------------------------------------------------------
-- The OS names
-- `runtimeName` and `cMacro` mirror the chain in rc2/support/rc2/idris2rc2_ioprims.h.

public export
data TargetOs = Windows | MacOS | Linux | FreeBSD | OpenBSD | NetBSD | OtherUnix | Other

||| The string the runtime's `idris2rc2_osString` holds on that OS.
export
runtimeName : TargetOs -> String
runtimeName Windows = "windows"
runtimeName MacOS = "macOS"
runtimeName Linux = "Linux"
runtimeName FreeBSD = "FreeBSD"
runtimeName OpenBSD = "OpenBSD"
runtimeName NetBSD = "NetBSD"
runtimeName OtherUnix = "Unix"
runtimeName Other = "Other"

cMacro : TargetOs -> String
cMacro Windows = "IDRIS2RC2_OS_IS_WINDOWS"
cMacro MacOS = "IDRIS2RC2_OS_IS_MACOS"
cMacro Linux = "IDRIS2RC2_OS_IS_LINUX"
cMacro FreeBSD = "IDRIS2RC2_OS_IS_FREEBSD"
cMacro OpenBSD = "IDRIS2RC2_OS_IS_OPENBSD"
cMacro NetBSD = "IDRIS2RC2_OS_IS_NETBSD"
cMacro OtherUnix = "IDRIS2RC2_OS_IS_UNIX"
cMacro Other = "IDRIS2RC2_OS_IS_OTHER"

||| Spellings of an OS name, case-insensitive: the runtime's own names, the
||| ones `System.Info.os` returns elsewhere (`darwin`, `mingw32`...), and
||| the lower-case `unix` the Chez backend returns for every Unix but macOS.
export
parseTargetOs : String -> Maybe TargetOs
parseTargetOs s = case toLower (trim s) of
  "windows" => Just Windows
  "mingw32" => Just Windows
  "cygwin32" => Just Windows
  "macos" => Just MacOS
  "darwin" => Just MacOS
  "linux" => Just Linux
  "freebsd" => Just FreeBSD
  "openbsd" => Just OpenBSD
  "netbsd" => Just NetBSD
  "unix" => Just OtherUnix
  "other" => Just Other
  _ => Nothing

-------------------------------------------------------------------------------
-- The directive

key : String
key = "target-os"

||| The values of every `target-os=` among the directives, in order.
values : List String -> List String
values = mapMaybe value
  where
    value : String -> Maybe String
    value d = case break (== '=') d of
      (k, v) => if trim k == key && not (null v) then Just (trim (assert_total (strTail v))) else Nothing

||| What `withTargetOs` left in the list: `Nothing` when `prim__os` is read at run time.
export
targetOsOf : List String -> Maybe TargetOs
targetOsOf ds = case reverse (values ds) of
  v :: _ => parseTargetOs v
  [] => Nothing

||| The OS the compiler itself runs on. The Chez backend only tells
||| `unix` for everything but macOS and Windows, so that one is refined with
||| `uname -s`. `Nothing` when it can't be told.
hostOs : IO (Maybe TargetOs)
hostOs = if os == "unix" then uname else pure (parseTargetOs os)
  where
    uname : IO (Maybe TargetOs)
    uname = do
      Right f <- popen "uname -s 2>/dev/null" Read
        | Left _ => pure Nothing
      line <- fGetLine f
      _ <- pclose f
      pure $ case line of
        Right l => case parseTargetOs l of
          Just OtherUnix => Nothing
          r => r
        Left _ => Nothing

||| Settles `target-os` for the whole compilation: an absent value is `host`,
||| and the result is the one canonical `target-os=<runtime name>` (or
||| `target-os=dynamic`) in place of what the user gave, so that
||| `targetOsOf` is all the later stages need. Conflicting values are an error.
export
withTargetOs : List String -> IO (Either String (List String))
withTargetOs ds = case nub (map toLower (values ds)) of
    [] => settle "host"
    [v] => settle v
    vs => pure (Left "conflicting target-os directives: \{joinBy ", " vs}")
  where
    rest : List String
    rest = filter (\d => null (values [d])) ds

    set : String -> Either String (List String)
    set v = Right (rest ++ ["\{key}=\{v}"])

    settle : String -> IO (Either String (List String))
    settle "dynamic" = pure (set "dynamic")
    settle "host" = pure (set (maybe "dynamic" runtimeName !hostOs))
    settle v = pure $ case parseTargetOs v of
      Just t => set (runtimeName t)
      Nothing => Left "unknown target-os '\{v}' (windows, macOS, Linux, FreeBSD, OpenBSD, NetBSD, Unix, Other, host or dynamic)"

-------------------------------------------------------------------------------
-- Using it

||| Replaces each read of `prim__os` with the name of `t`.
export covering
foldTargetOs : TargetOs -> RCExp -> RCExp
foldTargetOs t (RExtPrim fc _ (NS _ (UN (Basic "prim__os"))) [] _) = RPrimVal fc (Str (runtimeName t))
foldTargetOs t e = mapChildren (foldTargetOs t) e

||| The check the generated C starts with when it relies on `t`: a C compiler for
||| another OS (a cross compiler) stops the build instead of running with a
||| wrong name.
export
guardLines : TargetOs -> List String
guardLines t =
  [ "#ifndef \{cMacro t}"
  , "#error \"rc2: prim__os was folded to \\\"\{runtimeName t}\\\" (target-os), but this C compiler targets another OS; pass --directive target-os=<name> or target-os=dynamic\""
  , "#endif"
  ]

||| `foldTargetOs` over a definition's body.
export covering
foldTargetOsDef : TargetOs -> RCDef -> RCDef
foldTargetOsDef t (MkRCFun args retRep isWorker body) = MkRCFun args retRep isWorker (foldTargetOs t body)
foldTargetOsDef t (MkRCError body) = MkRCError (foldTargetOs t body)
foldTargetOsDef _ d = d
