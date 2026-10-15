||| File name patterns: `fnmatch` and `glob`.
module System.Posix.Glob

import System.FFI

%default covering

||| An `or` of `FNM_*` bits.
public export
FnmatchFlags : Type
FnmatchFlags = Int32

||| `\` is an ordinary character.
%inline %foreign "CExpr:(FNM_NOESCAPE),libc,fnmatch.h"
export FNM_NOESCAPE : FnmatchFlags
||| A slash in the string matches only a slash in the pattern.
%inline %foreign "CExpr:(FNM_PATHNAME),libc,fnmatch.h"
export FNM_PATHNAME : FnmatchFlags
||| A leading period in the string matches only a period in the pattern.
%inline %foreign "CExpr:(FNM_PERIOD),libc,fnmatch.h"
export FNM_PERIOD : FnmatchFlags

%inline %foreign "CExpr:(fnmatch($1, $2, $3)),libc,fnmatch.h"
prim__fnmatch : String -> String -> FnmatchFlags -> PrimIO Int32

||| Whether the string matches the shell pattern. A pattern that `fnmatch`
||| rejects does not match.
export
fnmatch : (pattern : String) -> String -> FnmatchFlags -> IO Bool
fnmatch pattern str flags = (== 0) <$> primIO (prim__fnmatch pattern str flags)

||| An `or` of `GLOB_*` bits.
public export
GlobFlags : Type
GlobFlags = Int32

||| Stop at a directory that cannot be read.
%inline %foreign "CExpr:(GLOB_ERR),libc,glob.h"
export GLOB_ERR : GlobFlags
||| Append a slash to each directory.
%inline %foreign "CExpr:(GLOB_MARK),libc,glob.h"
export GLOB_MARK : GlobFlags
||| Do not sort the result.
%inline %foreign "CExpr:(GLOB_NOSORT),libc,glob.h"
export GLOB_NOSORT : GlobFlags
||| Return the pattern itself when nothing matches.
%inline %foreign "CExpr:(GLOB_NOCHECK),libc,glob.h"
export GLOB_NOCHECK : GlobFlags
||| `\` is an ordinary character.
%inline %foreign "CExpr:(GLOB_NOESCAPE),libc,glob.h"
export GLOB_NOESCAPE : GlobFlags

||| Why `glob` failed. A pattern that matches nothing is not a failure.
public export
data GlobError = GlobNoSpace | GlobAborted | GlobOther Int32

export
Show GlobError where
  show GlobNoSpace = "GlobNoSpace"
  show GlobAborted = "GlobAborted"
  show (GlobOther n) = "GlobOther " ++ show n

export
Eq GlobError where
  GlobNoSpace == GlobNoSpace = True
  GlobAborted == GlobAborted = True
  GlobOther a == GlobOther b = a == b
  _ == _ = False

%inline %foreign "CExpr:(GLOB_NOSPACE),libc,glob.h"
prim__GLOB_NOSPACE : Int32
%inline %foreign "CExpr:(GLOB_ABORTED),libc,glob.h"
prim__GLOB_ABORTED : Int32
%inline %foreign "CExpr:(GLOB_NOMATCH),libc,glob.h"
prim__GLOB_NOMATCH : Int32

%inline %foreign "CExpr:(sizeof(glob_t)),libc,glob.h"
prim__sizeofGlob : Int
%inline %foreign "CExpr:(({ memset((glob_t *)($1), 0, sizeof(glob_t)); 0; })),libc,glob.h;string.h"
prim__zeroGlob : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(glob($1, $2, NULL, (glob_t *)($3))),libc,glob.h"
prim__glob : String -> GlobFlags -> AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(({ globfree((glob_t *)($1)); 0; })),libc,glob.h"
prim__globfree : AnyPtr -> PrimIO Int32
%inline %foreign "CExpr:(((glob_t *)($1))->gl_pathc),libc,glob.h"
prim__gl_pathc : AnyPtr -> PrimIO Int
%inline %foreign "CExpr:(((glob_t *)($1))->gl_pathv[$2]),libc,glob.h"
prim__gl_pathv : AnyPtr -> Int -> PrimIO String

||| The paths that match a pattern, in the order `glob` gives them (sorted
||| unless `GLOB_NOSORT`). No match gives `Right []`.
export
glob : (pattern : String) -> GlobFlags -> IO (Either GlobError (List String))
glob pattern flags = do
  g <- malloc prim__sizeofGlob
  _ <- primIO (prim__zeroGlob g)
  rc <- primIO (prim__glob pattern flags g)
  res <- if rc == 0
            then do n <- primIO (prim__gl_pathc g)
                    Right <$> traverse (primIO . prim__gl_pathv g) [0 .. n - 1]
            else pure (if rc == prim__GLOB_NOMATCH then Right []
                       else Left (if rc == prim__GLOB_NOSPACE then GlobNoSpace
                                  else if rc == prim__GLOB_ABORTED then GlobAborted
                                  else GlobOther rc))
  -- After a failed `glob`, glibc has freed everything itself.
  when (rc == 0) $ ignore (primIO (prim__globfree g))
  free g
  pure res
