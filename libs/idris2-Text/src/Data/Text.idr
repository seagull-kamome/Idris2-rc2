module Data.Text

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

||| The Text type, representing a Unicode codepoint sequence.
public export
data Text = MkText GCAnyPtr

%foreign "C:idris2rc2_utf8_to_codepoints,libidris2text,text_util.h"
prim__utf8ToCodepoints : String -> PrimIO GCAnyPtr

%foreign "C:idris2rc2_free_text_buffer,libidris2text,text_util.h"
prim__freeTextBuffer : GCAnyPtr -> PrimIO ()

||| Convert a String to Text.
export
fromString : String -> IO Text
fromString str = do
  ptr <- primIO $ prim__utf8ToCodepoints str
  pure (MkText ptr)

||| Free a Text buffer.
export
free : Text -> IO ()
free (MkText ptr) = primIO $ prim__freeTextBuffer ptr
