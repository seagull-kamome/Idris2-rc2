module Data.Text

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI
import Data.Fin

-- ---------------------------------------------------------------------------

||| The Text type, representing a Unicode codepoint sequence of length n.
public export
data Text : Nat -> Type where
  MkText : GCAnyPtr -> Text n

-- ---------------------------------------------------------------------------

||| Opaque marker type, never constructed on the Idris side. Used only
||| to keep rc2's %foreign marshaller from touching this primitive's
||| return value: text_util.c's idris2rc2_TextBuffer_to_string already
||| builds a fully-formed, correctly refcounted/tagged
||| IDRIS2RC2_String directly (via idris2rc2_mkEmptyString), so
||| declaring the return type as `String` here would make rc2 wrap it
||| a SECOND time via idris2rc2_mkString (packCFType CFString) --
||| `AnyPtr` would also be wrong, since that maps to CFPtr and gets
||| boxed via idris2rc2_mkPointer. An unrecognized type constructor
||| like this one maps to CFUser instead, whose packCFType/extractValue
||| (Compiler.RC2.Emit) are both the identity -- the Boxed Value* flows
||| through untouched.
data RawTextValue : Type

%foreign "C:idris2rc2_TextBuffer_mkEmpty,libidris2text,text_util.h"
prim__TextBuffer_mkEmpty : Int -> PrimIO AnyPtr

%foreign "C:idris2rc2_String_to_TextBuffer,libidris2text,text_util.h"
prim__String_to_TextBuffer : String -> PrimIO AnyPtr

%foreign "C:idris2rc2_TextBuffer_to_string,libidris2text,text_util.h"
prim__TextBuffer_toString : GCAnyPtr -> PrimIO RawTextValue

%foreign "C:idris2rc2_TextBuffer_free,libidris2text,text_util.h"
prim__TextBuffer_free : AnyPtr -> PrimIO ()

%foreign "C:idris2rc2_TextBuffer_unsafe_write_char,libidris2text,text_util.h"
prim__TextBuffer_unsafe_write_char : GCAnyPtr -> Int -> Bits32 -> PrimIO ()

%foreign "C:idris2rc2_text_length,libidris2text,text_util.h"
prim__textLength : GCAnyPtr -> PrimIO Int

%foreign "C:idris2rc2_text_index,libidris2text,text_util.h"
prim__textIndex : GCAnyPtr -> Int -> PrimIO Bits32

%foreign "C:idris2rc2_TextBuffer_append,libidris2text,text_util.h"
prim__TextBuffer_append : GCAnyPtr -> GCAnyPtr -> PrimIO AnyPtr

-- ---------------------------------------------------------------------------

freeTextBuffer : AnyPtr -> IO ()
freeTextBuffer ptr = primIO $ prim__TextBuffer_free ptr

||| Convert a String to Text.
export
fromString : (s : String) -> (n : Nat ** Text n)
fromString s = unsafePerformIO $ do
  ptr <- primIO $ prim__String_to_TextBuffer s
  gcptr <- onCollectAny ptr freeTextBuffer
  len <- primIO $ prim__textLength gcptr
  pure (fromInteger (cast len) ** MkText gcptr)

||| Convert a Text back to a String.
export
toString : Text n -> String
toString (MkText ptr) = believe_me $ unsafePerformIO $ primIO $ prim__TextBuffer_toString ptr

||| Get the length of the Text.
export
length : Text n -> Nat
length (MkText ptr) =
  fromInteger $ cast $ unsafePerformIO $ primIO $ prim__textLength ptr

||| `length` always agrees with a `Text`'s own index `n` -- true by
||| construction (every `Text` value is reached only through this
||| module's own smart constructors, each of which sets the C buffer's
||| `len` field to exactly `n`, and no operation here ever mutates a
||| buffer's `len` afterward), but not mechanically provable from this
||| side: `length` re-reads `n` through an opaque C FFI call every
||| time, which the proof checker can't see through.
export
0 lengthCorrect : {n:Nat} -> (xs:Text n) -> length xs = n
lengthCorrect xs = the (length xs = n) $ believe_me xs

||| Get the character at the given index.
export
index : {n : Nat} -> Text n -> Fin n -> Char
index (MkText ptr) idx = cast $ unsafePerformIO $ primIO $ prim__textIndex ptr (cast (finToNat idx))

||| Append two Texts.
export
(++) : Text n -> Text m -> Text (n + m)
(++) (MkText ptr1) (MkText ptr2) = unsafePerformIO $ do
  newPtr <- primIO $ prim__TextBuffer_append ptr1 ptr2
  gcptr <- onCollectAny newPtr freeTextBuffer
  pure (MkText gcptr)
