||| GNU gettext message catalogs: `gettext`, `dgettext`, `dcgettext`,
||| `ngettext`, `dngettext`, `dcngettext`, `textdomain`, `bindtextdomain` and
||| `bind_textdomain_codeset`.
|||
||| A message with no translation is returned as it was given. Translation
||| needs the process locale to name a language (not `C`), and a catalog
||| (`<dir>/<language>/LC_MESSAGES/<domain>.mo`) found through `bindtextdomain`;
||| the `LANGUAGE` variable can rank more languages. rc2 programs start with
||| the locale of the environment (`rc2/doc/runtime-lifecycle.md`).
|||
||| The C functions return a pointer to storage of the library, valid until the
||| next call that changes the domain, so each call here copies the text before
||| returning. A `String` is UTF-8, so `bindtextdomain` also asks for the
||| catalogs of the domain in UTF-8.
module System.Posix.Gettext

import Data.Maybe
import Data.String.FFI
import System.FFI
import System.Posix.Errno

%default total

||| A locale category for `dcgettext`: `LC_MESSAGES` for the usual messages.
||| (`LC_ALL` is not a category a lookup can use.)
public export
Category : Type
Category = Int32

%inline %foreign "CExpr:(LC_CTYPE),libc,locale.h"
export LC_CTYPE : Category
%inline %foreign "CExpr:(LC_NUMERIC),libc,locale.h"
export LC_NUMERIC : Category
%inline %foreign "CExpr:(LC_TIME),libc,locale.h"
export LC_TIME : Category
%inline %foreign "CExpr:(LC_COLLATE),libc,locale.h"
export LC_COLLATE : Category
%inline %foreign "CExpr:(LC_MONETARY),libc,locale.h"
export LC_MONETARY : Category
%inline %foreign "CExpr:(LC_MESSAGES),libc,locale.h"
export LC_MESSAGES : Category

%inline %foreign "CExpr:(gettext($1)),libc,libintl.h"
prim__gettext : String -> PrimIO String
%inline %foreign "CExpr:(dgettext($1, $2)),libc,libintl.h"
prim__dgettext : String -> String -> PrimIO String
%inline %foreign "CExpr:(dcgettext($1, $2, $3)),libc,libintl.h"
prim__dcgettext : String -> String -> Category -> PrimIO String
%inline %foreign "CExpr:(ngettext($1, $2, $3)),libc,libintl.h"
prim__ngettext : String -> String -> Bits64 -> PrimIO String
%inline %foreign "CExpr:(dngettext($1, $2, $3, $4)),libc,libintl.h"
prim__dngettext : String -> String -> String -> Bits64 -> PrimIO String
%inline %foreign "CExpr:(dcngettext($1, $2, $3, $4, $5)),libc,libintl.h"
prim__dcngettext : String -> String -> String -> Bits64 -> Category -> PrimIO String

%inline %foreign "CExpr:(textdomain(NULL)),libc,libintl.h"
prim__getTextdomain : PrimIO AnyPtr
%inline %foreign "CExpr:(textdomain($1)),libc,libintl.h"
prim__textdomain : String -> PrimIO AnyPtr
%inline %foreign "CExpr:(bindtextdomain($1, NULL)),libc,libintl.h"
prim__getBindtextdomain : String -> PrimIO AnyPtr
%inline %foreign "CExpr:(bindtextdomain($1, $2)),libc,libintl.h"
prim__bindtextdomain : String -> String -> PrimIO AnyPtr
%inline %foreign "CExpr:(bind_textdomain_codeset($1, NULL)),libc,libintl.h"
prim__getCodeset : String -> PrimIO AnyPtr
%inline %foreign "CExpr:(bind_textdomain_codeset($1, $2)),libc,libintl.h"
prim__setCodeset : String -> String -> PrimIO AnyPtr

||| The translation of a message in the current domain (`textdomain`), or the
||| message itself.
export
gettext : (msgid : String) -> IO String
gettext msgid = primIO (prim__gettext msgid)

||| `gettext` in a named domain.
export
dgettext : (domain : String) -> (msgid : String) -> IO String
dgettext domain msgid = primIO (prim__dgettext domain msgid)

||| `dgettext` for the messages of a locale category.
export
dcgettext : (domain : String) -> (msgid : String) -> Category -> IO String
dcgettext domain msgid category = primIO (prim__dcgettext domain msgid category)

||| The form of a message for the count `n`: a catalog says which of its forms
||| fits a count (`Plural-Forms`); with no translation it is `singular` for 1
||| and `plural` for any other count.
export
ngettext : (singular, plural : String) -> (n : Bits64) -> IO String
ngettext singular plural n = primIO (prim__ngettext singular plural n)

||| `ngettext` in a named domain.
export
dngettext : (domain : String) -> (singular, plural : String) -> (n : Bits64) -> IO String
dngettext domain singular plural n = primIO (prim__dngettext domain singular plural n)

||| `dngettext` for the messages of a locale category.
export
dcngettext : (domain : String) -> (singular, plural : String) -> (n : Bits64) -> Category -> IO String
dcngettext domain singular plural n category =
  primIO (prim__dcngettext domain singular plural n category)

-- The result of these C functions is NULL only when memory ran out (and, for a
-- query, when nothing is set).
failed : IO (Either Errno a)
failed = Left <$> errno

||| The domain `gettext` uses now: `messages` until `textdomain` sets another.
export
getTextdomain : IO String
getTextdomain = do
  p <- primIO prim__getTextdomain
  fromMaybe "messages" <$> ptrToString p

||| Sets the domain `gettext` and `ngettext` use; returns it.
export
textdomain : (domain : String) -> IO (Either Errno String)
textdomain domain = do
  p <- primIO (prim__textdomain domain)
  maybe failed (pure . Right) =<< ptrToString p

||| The directory the catalogs of a domain are looked up in, as set by
||| `bindtextdomain` (the system default when not set).
export
getBindtextdomain : (domain : String) -> IO (Maybe String)
getBindtextdomain domain = primIO (prim__getBindtextdomain domain) >>= ptrToString

||| The charset the strings of a domain are returned in, `Nothing` while none is set.
export
getTextdomainCodeset : (domain : String) -> IO (Maybe String)
getTextdomainCodeset domain = primIO (prim__getCodeset domain) >>= ptrToString

||| Sets the charset the strings of a domain are returned in; returns it.
export
bindTextdomainCodeset : (domain, codeset : String) -> IO (Either Errno String)
bindTextdomainCodeset domain codeset = do
  p <- primIO (prim__setCodeset domain codeset)
  maybe failed (pure . Right) =<< ptrToString p

||| Looks the catalogs of a domain up in `dir`, and has them return UTF-8
||| (the encoding of a `String`); returns the directory.
export
bindtextdomain : (domain, dir : String) -> IO (Either Errno String)
bindtextdomain domain dir = do
  p <- primIO (prim__bindtextdomain domain dir)
  maybe failed (\d => map (const d) <$> bindTextdomainCodeset domain "UTF-8")
        =<< ptrToString p
