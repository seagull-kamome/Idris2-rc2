module System.FFI.C.Null

import Decidable.Equality
import Data.So


-------------------------------------------------------------------------------
--

%inline %foreign "CExpr:(NULL)"
export NullAnyPtr : AnyPtr
%inline %foreign "CExpr:(NULL)"
export NullPtr : {0 a : Type} -> Ptr a


%inline %foreign "CExpr:($1 != NULL ? 1 : 0)"
export isNullAnyPtr : AnyPtr -> Bool
%inline %foreign "CExpr:($2 != NULL ? 1 : 0)"
export isNullPtr : {a : Type} -> Ptr a -> Bool



public export
record NonNullAnyPtr where
  constructor MkNonnullAnyPtr
  ptr : AnyPtr
  {auto 0 prf : isNullAnyPtr ptr = False}



public export
record NonNullPtr (a : Type) where
  constructor MkNonnullPtr
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





