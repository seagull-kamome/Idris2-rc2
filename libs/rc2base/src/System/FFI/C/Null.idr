module System.FFI.C.Null

import Decidable.Equality
import Data.So


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(NULL)"
export NullAnyPtr : AnyPtr
%inline %foreign "CExpr:(NULL)"
export NullPtr : {0 a : Type} -> Ptr a

-- A `Bool` result is not a C type (it would be read as `void *`), so the
-- comparison is done on the Prelude's own `prim__nullAnyPtr`.

||| True when the pointer is NULL.
export
isNullAnyPtr : AnyPtr -> Bool
isNullAnyPtr p = prim__nullAnyPtr p /= 0

||| True when the pointer is NULL.
export
isNullPtr : {0 a : Type} -> Ptr a -> Bool
isNullPtr p = prim__nullAnyPtr (prim__forgetPtr p) /= 0



public export
record NonNullAnyPtr where
  constructor MkNonNullAnyPtr
  ptr : AnyPtr
  {auto 0 prf : isNullAnyPtr ptr = False}


public export
record NonNullPtr (a : Type) where
  constructor MkNonNullPtr
  ptr : Ptr a
  {auto 0 prf : isNullPtr ptr = False}



-------------------------------------------------------------------------------
--

public export
0 isNullAnyPtrNullAnyPtr : {p : AnyPtr} -> So (isNullAnyPtr p) -> p = NullAnyPtr
isNullAnyPtrNullAnyPtr _ = believe_me $ Refl {x=NullAnyPtr}

public export
0 nullAnyPtrIsNullAnyPtr : {p : AnyPtr} -> p = NullAnyPtr -> So (isNullAnyPtr p)
nullAnyPtrIsNullAnyPtr _ = believe_me Oh




public export
0 isNullPtrNullPtr : {p : Ptr a} -> So (isNullPtr p) -> p = NullPtr
isNullPtrNullPtr _ = believe_me $ Refl {x=NullPtr{a}}

public export
0 nullPtrIsNullPtr : {p : Ptr a} -> p = NullPtr -> So (isNullPtr p)
nullPtrIsNullPtr _ = believe_me Oh





