module Data.Queue

import Decidable.Equality
import Data.List

%default total

-------------------------------------------------------------------------------
-- Types

export
record Queue a where
  constructor MkQueue
  front : List a
  back : List a


-------------------------------------------------------------------------------
-- Basic operations

namespace Queue

    public export empty : Queue a
    empty = MkQueue [] []

    public export singleton : a -> Queue a
    singleton x = MkQueue [x] []

    
    public export enqueue : a -> Queue a -> Queue a
    enqueue x (MkQueue f b) = MkQueue f (x :: b)

    public export dequeue : Queue a -> Maybe (a, Queue a)
    dequeue (MkQueue [] b) = case reverse b of
      [] => Nothing
      (x :: f) => Just (x, MkQueue f [])
    dequeue (MkQueue (x :: f) b) = Just (x, MkQueue f b)

    public export fromList : List a -> Queue a
    fromList xs = MkQueue xs []

    public export toList : Queue a -> List a
    toList (MkQueue f b) = f ++ reverse b

    public export length : Queue a -> Nat
    length (MkQueue f b) = length f + length b

    Functor Queue where
      map f (MkQueue f1 b) = MkQueue (map f f1) (map f b)

    Semigroup (Queue a) where
      (MkQueue f1 b1) <+> (MkQueue f2 b2) = MkQueue (f1 ++ f2) (b1 ++ b2)

    Monoid (Queue a) where
      neutral = empty

    DecEq a => DecEq (Queue a) where
      decEq (MkQueue f1 b1) (MkQueue f2 b2) =
        case decEq f1 f2 of
          Yes Refl =>
            case decEq b1 b2 of
              Yes Refl => Yes Refl
              No contra => No $ \Refl => contra Refl
          No contra => No $ \Refl => contra Refl


-------------------------------------------------------------------------------
-- Properties

namespace Properties


    public export
    0 toList_enqueue  : (x : a) -> (q : Queue a) -> toList (enqueue x q) = toList q ++ [x]
    toList_enqueue x (MkQueue f b) =
      rewrite sym (revAppend [x] b) in
      appendAssociative f (reverse b) [x]

    public export
    0 toList_dequeue : (q : Queue a) -> case dequeue q of
      Nothing => toList q = []
      Just (x, q') => toList q = x :: toList q'
    toList_dequeue (MkQueue [] []) = Refl
    toList_dequeue (MkQueue [] b) with (reverse b) proof p
      _ | [] = p
      _ | (x :: f) = rewrite p in cong (x ::) (sym (appendNilRightNeutral f))
    toList_dequeue (MkQueue (x :: f) b) = Refl


    public export
    0 toList_fromList : (q:Queue a) -> toList (fromList (toList q)) = toList q
    toList_fromList (MkQueue f b) =
      rewrite appendNilRightNeutral (f ++ reverseOnto [] b) in
      Refl


