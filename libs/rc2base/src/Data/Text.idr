module Data.Text

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A length-indexed rope over Data.TextBuffer chunks, backed by a 2-3
-- finger tree (Hinze/Paterson). TextBuffer's own (++) is O(n) (it
-- memcpys both sides into a fresh buffer every time), which makes
-- repeated small concatenations O(n^2) overall; wrapping chunks in a
-- finger tree instead makes (++) O(log(min(n,m))).
--
-- The finger tree engine below (Digit/Node/FingerTree, consTree/
-- snocTree/addTree0) is an ordinary, non-Nat-indexed set of types --
-- deliberately NOT dependently typed, mirroring idris2's own
-- contrib package (Data.Seq.Internal, adapted here from the same
-- containers/Data.Sequence algorithm it itself credits). Trying to
-- carry an exact Nat *sum* as a type index through every internal
-- node runs into constant associativity/identity mismatches (`a+b+c`
-- vs `a+(b+c)`, `n` vs `n+0`, ...) that need a proof at nearly every
-- constructor. The standard, much lighter answer -- used by
-- Data.Seq.Internal itself -- is to cache a plain runtime Nat (via
-- the `Sized` interface, Control.WellFounded) at each Node/Deep
-- instead, and to only put a *phantom* Nat index on the outermost
-- public wrapper (`Text`), exactly like `Data.TextBuffer.TextBuffer`
-- already does for its own FFI-backed length. That single boundary
-- is the only place trusting "this Nat matches the real content"
-- rather than proving it, matching `Data.TextBuffer.lengthCorrect`'s
-- own documented rationale.
--
-- Every operation that isn't fundamentally about concatenation
-- (substr, words, trim, ...) is implemented by flattening to a single
-- TextBuffer and delegating to Data.TextBuffer's own (already-correct)
-- implementation -- same asymptotic cost as TextBuffer itself, no
-- better, no worse; only (++) and the handful of operations built
-- from it (concat, joinBy, unwords, unlines, singleton, replicate)
-- get the tree's win.

import Control.WellFounded
import Data.TextBuffer
import Data.Fin
import Data.List

-- ---------------------------------------------------------------------------
-- The finger tree engine. Ordinary (non-dependent) types; every
-- Node2/Node3/Deep caches its own already-computed total as a plain
-- Nat field instead of proving anything about it.

data Digit : Type -> Type where
  One   : e -> Digit e
  Two   : e -> e -> Digit e
  Three : e -> e -> e -> Digit e
  Four  : e -> e -> e -> e -> Digit e

data Node : Type -> Type where
  Node2 : Nat -> e -> e -> Node e
  Node3 : Nat -> e -> e -> e -> Node e

Sized e => Sized (Node e) where
  size (Node2 s _ _) = s
  size (Node3 s _ _ _) = s

node2 : Sized e => e -> e -> Node e
node2 a b = Node2 (size a + size b) a b

node3 : Sized e => e -> e -> e -> Node e
node3 a b c = Node3 (size a + size b + size c) a b c

data FingerTree : Type -> Type where
  Empty  : FingerTree e
  Single : e -> FingerTree e
  Deep   : Nat -> Digit e -> FingerTree (Node e) -> Digit e -> FingerTree e

Sized e => Sized (FingerTree e) where
  size Empty = 0
  size (Single a) = size a
  size (Deep s _ _ _) = s

digitSize : Sized e => Digit e -> Nat
digitSize (One a) = size a
digitSize (Two a b) = size a + size b
digitSize (Three a b c) = size a + size b + size c
digitSize (Four a b c d) = size a + size b + size c + size d

deep : Sized e => Digit e -> FingerTree (Node e) -> Digit e -> FingerTree e
deep pr m sf = Deep (digitSize pr + size m + digitSize sf) pr m sf

consTree : Sized e => e -> FingerTree e -> FingerTree e
consTree a Empty = Single a
consTree a (Single b) = deep (One a) Empty (One b)
consTree a (Deep s (One b) m sf) = Deep (size a + s) (Two a b) m sf
consTree a (Deep s (Two b c) m sf) = Deep (size a + s) (Three a b c) m sf
consTree a (Deep s (Three b c d) m sf) = Deep (size a + s) (Four a b c d) m sf
consTree a (Deep s (Four b c d f) m sf) = Deep (size a + s) (Two a b) (consTree (node3 c d f) m) sf

snocTree : Sized e => FingerTree e -> e -> FingerTree e
snocTree Empty a = Single a
snocTree (Single a) b = deep (One a) Empty (One b)
snocTree (Deep s pr m (One a)) f = Deep (s + size f) pr m (Two a f)
snocTree (Deep s pr m (Two a b)) f = Deep (s + size f) pr m (Three a b f)
snocTree (Deep s pr m (Three a b c)) f = Deep (s + size f) pr m (Four a b c f)
snocTree (Deep s pr m (Four a b c d)) f = Deep (s + size f) pr (snocTree m (node3 a b c)) (Two d f)

-- Regroups the up-to-8 elements of two adjacent digits (plus, at
-- deeper recursion levels, up to 4 already-built Nodes carried
-- between them) into 1-4 Node2/Node3s, splicing them into the middle
-- tree. Direct port of Data.Seq.Internal's addDigitsK/appendTreeK
-- mutual block (itself adapted from the `containers` package's
-- Data.Sequence) -- the natural node-count bound (>=1 needs 1 extra
-- node, up to 4 extra needs up to 4) is why this bottoms out at K=4
-- rather than needing a generic list.
mutual
  addDigits4 : Sized e => FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
  addDigits4 m1 (One a) b c d e (One f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits4 m1 (One a) b c d e (Two f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits4 m1 (One a) b c d e (Three f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits4 m1 (One a) b c d e (Four f g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits4 m1 (Two a b) c d e f (One g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits4 m1 (Two a b) c d e f (Two g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits4 m1 (Two a b) c d e f (Three g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits4 m1 (Two a b) c d e f (Four g h i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
  addDigits4 m1 (Three a b c) d e f g (One h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits4 m1 (Three a b c) d e f g (Two h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits4 m1 (Three a b c) d e f g (Three h i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
  addDigits4 m1 (Three a b c) d e f g (Four h i j k) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2
  addDigits4 m1 (Four a b c d) e f g h (One i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits4 m1 (Four a b c d) e f g h (Two i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
  addDigits4 m1 (Four a b c d) e f g h (Three i j k) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2
  addDigits4 m1 (Four a b c d) e f g h (Four i j k l) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node3 j k l) m2

  appendTree4 : Sized e => FingerTree (Node e) -> Node e -> Node e -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree4 Empty a b c d xs = consTree a (consTree b (consTree c (consTree d xs)))
  appendTree4 xs a b c d Empty = snocTree (snocTree (snocTree (snocTree xs a) b) c) d
  appendTree4 (Single x) a b c d xs = consTree x (consTree a (consTree b (consTree c (consTree d xs))))
  appendTree4 xs a b c d (Single x) = snocTree (snocTree (snocTree (snocTree (snocTree xs a) b) c) d) x
  appendTree4 (Deep s1 pr1 m1 sf1) a b c d (Deep s2 pr2 m2 sf2) = Deep (s1 + size a + size b + size c + size d + s2) pr1 (addDigits4 m1 sf1 a b c d pr2 m2) sf2

  addDigits3 : Sized e => FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
  addDigits3 m1 (One a) b c d (One e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits3 m1 (One a) b c d (Two e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits3 m1 (One a) b c d (Three e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits3 m1 (One a) b c d (Four e f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits3 m1 (Two a b) c d e (One f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits3 m1 (Two a b) c d e (Two f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits3 m1 (Two a b) c d e (Three f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits3 m1 (Two a b) c d e (Four f g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits3 m1 (Three a b c) d e f (One g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits3 m1 (Three a b c) d e f (Two g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits3 m1 (Three a b c) d e f (Three g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits3 m1 (Three a b c) d e f (Four g h i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
  addDigits3 m1 (Four a b c d) e f g (One h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits3 m1 (Four a b c d) e f g (Two h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits3 m1 (Four a b c d) e f g (Three h i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2
  addDigits3 m1 (Four a b c d) e f g (Four h i j k) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node3 g h i) (node2 j k) m2

  appendTree3 : Sized e => FingerTree (Node e) -> Node e -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree3 Empty a b c xs = consTree a (consTree b (consTree c xs))
  appendTree3 xs a b c Empty = snocTree (snocTree (snocTree xs a) b) c
  appendTree3 (Single x) a b c xs = consTree x (consTree a (consTree b (consTree c xs)))
  appendTree3 xs a b c (Single x) = snocTree (snocTree (snocTree (snocTree xs a) b) c) x
  appendTree3 (Deep s1 pr1 m1 sf1) a b c (Deep s2 pr2 m2 sf2) = Deep (s1 + size a + size b + size c + s2) pr1 (addDigits3 m1 sf1 a b c pr2 m2) sf2

  addDigits2 : Sized e => FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
  addDigits2 m1 (One a) b c (One d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
  addDigits2 m1 (One a) b c (Two d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits2 m1 (One a) b c (Three d e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits2 m1 (One a) b c (Four d e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits2 m1 (Two a b) c d (One e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits2 m1 (Two a b) c d (Two e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits2 m1 (Two a b) c d (Three e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits2 m1 (Two a b) c d (Four e f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits2 m1 (Three a b c) d e (One f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits2 m1 (Three a b c) d e (Two f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits2 m1 (Three a b c) d e (Three f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits2 m1 (Three a b c) d e (Four f g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits2 m1 (Four a b c d) e f (One g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits2 m1 (Four a b c d) e f (Two g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits2 m1 (Four a b c d) e f (Three g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2
  addDigits2 m1 (Four a b c d) e f (Four g h i j) m2 = appendTree4 m1 (node3 a b c) (node3 d e f) (node2 g h) (node2 i j) m2

  appendTree2 : Sized e => FingerTree (Node e) -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree2 Empty a b xs = consTree a (consTree b xs)
  appendTree2 xs a b Empty = snocTree (snocTree xs a) b
  appendTree2 (Single x) a b xs = consTree x (consTree a (consTree b xs))
  appendTree2 xs a b (Single x) = snocTree (snocTree (snocTree xs a) b) x
  appendTree2 (Deep s1 pr1 m1 sf1) a b (Deep s2 pr2 m2 sf2) = Deep (s1 + size a + size b + s2) pr1 (addDigits2 m1 sf1 a b pr2 m2) sf2

  addDigits1 : Sized e => FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
  addDigits1 m1 (One a) b (One c) m2 = appendTree1 m1 (node3 a b c) m2
  addDigits1 m1 (One a) b (Two c d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
  addDigits1 m1 (One a) b (Three c d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits1 m1 (One a) b (Four c d e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits1 m1 (Two a b) c (One d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
  addDigits1 m1 (Two a b) c (Two d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits1 m1 (Two a b) c (Three d e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits1 m1 (Two a b) c (Four d e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits1 m1 (Three a b c) d (One e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
  addDigits1 m1 (Three a b c) d (Two e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits1 m1 (Three a b c) d (Three e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits1 m1 (Three a b c) d (Four e f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits1 m1 (Four a b c d) e (One f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
  addDigits1 m1 (Four a b c d) e (Two f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
  addDigits1 m1 (Four a b c d) e (Three f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2
  addDigits1 m1 (Four a b c d) e (Four f g h i) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node3 g h i) m2

  appendTree1 : Sized e => FingerTree (Node e) -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree1 Empty a xs = consTree a xs
  appendTree1 xs a Empty = snocTree xs a
  appendTree1 (Single x) a xs = consTree x (consTree a xs)
  appendTree1 xs a (Single x) = snocTree (snocTree xs a) x
  appendTree1 (Deep s1 pr1 m1 sf1) a (Deep s2 pr2 m2 sf2) = Deep (s1 + size a + s2) pr1 (addDigits1 m1 sf1 a pr2 m2) sf2

addDigits0 : Sized e => FingerTree (Node e) -> Digit e -> Digit e -> FingerTree (Node e) -> FingerTree (Node e)
addDigits0 m1 (One a) (One b) m2 = appendTree1 m1 (node2 a b) m2
addDigits0 m1 (One a) (Two b c) m2 = appendTree1 m1 (node3 a b c) m2
addDigits0 m1 (One a) (Three b c d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (One a) (Four b c d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Two a b) (One c) m2 = appendTree1 m1 (node3 a b c) m2
addDigits0 m1 (Two a b) (Two c d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (Two a b) (Three c d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Two a b) (Four c d e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Three a b c) (One d) m2 = appendTree2 m1 (node2 a b) (node2 c d) m2
addDigits0 m1 (Three a b c) (Two d e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Three a b c) (Three d e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Three a b c) (Four d e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits0 m1 (Four a b c d) (One e) m2 = appendTree2 m1 (node3 a b c) (node2 d e) m2
addDigits0 m1 (Four a b c d) (Two e f) m2 = appendTree2 m1 (node3 a b c) (node3 d e f) m2
addDigits0 m1 (Four a b c d) (Three e f g) m2 = appendTree3 m1 (node3 a b c) (node2 d e) (node2 f g) m2
addDigits0 m1 (Four a b c d) (Four e f g h) m2 = appendTree3 m1 (node3 a b c) (node3 d e f) (node2 g h) m2

addTree0 : Sized e => FingerTree e -> FingerTree e -> FingerTree e
addTree0 Empty xs = xs
addTree0 xs Empty = xs
addTree0 (Single x) xs = consTree x xs
addTree0 xs (Single x) = snocTree xs x
addTree0 (Deep s1 pr1 m1 sf1) (Deep s2 pr2 m2 sf2) = Deep (s1 + s2) pr1 (addDigits0 m1 sf1 pr2 m2) sf2

-- Foldable instances, mirroring Data.Seq.Internal's own: ordinary
-- structural recursion, `m`'s own Foldable dispatch (a DIFFERENT
-- instance -- Node e's, not FingerTree e's own) handles the one-level-
-- deeper nesting without needing any explicit recursive helper here.
Foldable Digit where
  foldr f z (One a) = a `f` z
  foldr f z (Two a b) = a `f` (b `f` z)
  foldr f z (Three a b c) = a `f` (b `f` (c `f` z))
  foldr f z (Four a b c d) = a `f` (b `f` (c `f` (d `f` z)))

Foldable Node where
  foldr f z (Node2 _ a b) = a `f` (b `f` z)
  foldr f z (Node3 _ a b c) = a `f` (b `f` (c `f` z))

Foldable FingerTree where
  foldr _ z Empty = z
  foldr f z (Single x) = x `f` z
  foldr f z (Deep _ pr m sf) = foldr f (foldr (flip (foldr f)) (foldr f z sf) m) pr

-- Walks the tree collecting its leaves, in order.
treeToList : FingerTree e -> List e
treeToList = foldr (::) []

-- ---------------------------------------------------------------------------
-- The public, length-indexed API. `Text`'s own Nat index is a phantom,
-- exactly like `Data.TextBuffer.TextBuffer`'s own -- trusted by
-- construction (every function below that changes a Text's length
-- computes the new length independently, via TextBuffer's own already-
-- correct arithmetic, and only ties it back to the finger tree's
-- actual content via `believe_me`, never by proving the finger tree
-- engine's own internals match it step by step).

Chunk : Type
Chunk = (k ** TextBuffer k)

Sized Chunk where
  size (_ ** tb) = TextBuffer.length tb

export
data Text : Nat -> Type where
  MkText : FingerTree Chunk -> Text n

||| O(1). The length of a Text.
export
length : Text n -> Nat
length (MkText t) = size t

||| O(1). Wrap an existing TextBuffer as a single-chunk Text.
export
fromTextBuffer : {n : Nat} -> TextBuffer n -> Text n
fromTextBuffer {n} tb = MkText (Single (n ** tb))

||| Convert a String to Text.
export
fromString : (s : String) -> (n ** Text n)
fromString s = let (n ** tb) = TextBuffer.fromString s in (n ** fromTextBuffer tb)

-- Collapses a Text's chunks back into a single TextBuffer -- the
-- boundary every operation below that isn't fundamentally about
-- concatenation crosses to reuse Data.TextBuffer's own algorithms.
flatten : Text n -> (m ** TextBuffer m)
flatten (MkText t) = TextBuffer.concat (treeToList t)

||| Convert a Text back to a String.
export
toString : Text n -> String
toString t = let (_ ** tb) = flatten t in TextBuffer.toString tb

||| O(log(min(n,m))). Concatenate two Texts.
export
(++) : Text n -> Text m -> Text (n + m)
(++) (MkText t1) (MkText t2) = believe_me (MkText {n=0} (addTree0 t1 t2))

||| A Text of a single character.
export
singleton : Char -> Text 1
singleton c = fromTextBuffer (TextBuffer.singleton c)

||| A Text of `n` copies of a character.
export
replicate : (n : Nat) -> Char -> Text n
replicate n c = fromTextBuffer (TextBuffer.replicate n c)

||| Concatenate a list of Texts into one, O(log) chunk at a time.
export
concat : List (n ** Text n) -> (m ** Text m)
concat = foldl (\(a ** acc), (b ** t) => (a + b ** acc ++ t)) (0 ** MkText Empty)

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : {k : Nat} -> Text k -> List (n ** Text n) -> (m ** Text m)
joinBy sep xs = Data.Text.concat (intersperse (k ** sep) xs)

||| Join with single spaces.
export
unwords : List (n ** Text n) -> (m ** Text m)
unwords xs = let (_ ** sep) = Data.Text.fromString " " in joinBy sep xs

||| Join, appending a newline after each piece (including the last).
export
unlines : List (n ** Text n) -> (m ** Text m)
unlines xs =
  let (_ ** nl) = Data.Text.fromString "\n"
  in Data.Text.concat (concatMap (\(_ ** t) => [(_ ** t), (_ ** nl)]) xs)

-- ---------------------------------------------------------------------------
-- Everything below flattens to a single TextBuffer and delegates to
-- Data.TextBuffer's own implementation -- same asymptotic cost as
-- TextBuffer itself (no tree-shape reuse), see this file's own header.

||| Get the character at the given index.
export
index : {n : Nat} -> Text n -> Fin n -> Char
index t i = let (_ ** tb) = flatten t in TextBuffer.index tb (believe_me i)

||| Uppercase every character. Length-preserving.
export
toUpper : Text n -> Text n
toUpper t = let (_ ** tb) = flatten t in believe_me (fromTextBuffer (TextBuffer.toUpper tb))

||| Lowercase every character. Length-preserving.
export
toLower : Text n -> Text n
toLower t = let (_ ** tb) = flatten t in believe_me (fromTextBuffer (TextBuffer.toLower tb))

||| Extract a substring of the given length, starting at the given
||| offset. Clamped to the source Text's actual bounds.
export
substr : (start, len : Nat) -> Text n -> (m ** Text m)
substr start len t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.substr start len tb
  in (_ ** fromTextBuffer tb')

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long).
export
padLeft : (width : Nat) -> Char -> Text n -> (m ** Text m)
padLeft width c t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.padLeft width c tb
  in (_ ** fromTextBuffer tb')

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long).
export
padRight : (width : Nat) -> Char -> Text n -> (m ** Text m)
padRight width c t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.padRight width c tb
  in (_ ** fromTextBuffer tb')

||| Strip whitespace from the left.
export
ltrim : Text n -> (m ** Text m)
ltrim t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.ltrim tb
  in (_ ** fromTextBuffer tb')

||| Strip whitespace from the right.
export
rtrim : Text n -> (m ** Text m)
rtrim t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.rtrim tb
  in (_ ** fromTextBuffer tb')

||| Strip whitespace from both ends.
export
trim : Text n -> (m ** Text m)
trim t =
  let (_ ** tb) = flatten t
      (_ ** tb') = TextBuffer.trim tb
  in (_ ** fromTextBuffer tb')

||| Split on runs of whitespace, dropping empty pieces.
export
words : Text n -> List (m ** Text m)
words t =
  let (_ ** tb) = flatten t
  in map (\(_ ** w) => (_ ** fromTextBuffer w)) (TextBuffer.words tb)

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece.
export
lines : Text n -> List (m ** Text m)
lines t =
  let (_ ** tb) = flatten t
  in map (\(_ ** l) => (_ ** fromTextBuffer l)) (TextBuffer.lines tb)

||| Split into the longest prefix satisfying the predicate, and the
||| rest.
export
span : (Char -> Bool) -> Text n -> ((p ** Text p), (q ** Text q))
span p t =
  let (_ ** tb) = flatten t
      ((_ ** a), (_ ** b)) = TextBuffer.span p tb
  in ((_ ** fromTextBuffer a), (_ ** fromTextBuffer b))

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> Text n -> ((p ** Text p), (q ** Text q))
break p t =
  let (_ ** tb) = flatten t
      ((_ ** a), (_ ** b)) = TextBuffer.break p tb
  in ((_ ** fromTextBuffer a), (_ ** fromTextBuffer b))

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> Text n -> List (m ** Text m)
split p t =
  let (_ ** tb) = flatten t
  in map (\(_ ** s) => (_ ** fromTextBuffer s)) (TextBuffer.split p tb)
