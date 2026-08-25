module Data.Text

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- A rope over Data.TextBuffer chunks, backed by a 2-3 finger tree
-- (Hinze/Paterson). TextBuffer's own (++) is O(n) (it memcpys both
-- sides into a fresh buffer every time), which makes repeated small
-- concatenations O(n^2) overall; wrapping chunks in a finger tree
-- instead makes (++) O(log(min(n,m))).
--
-- The finger tree engine below (Digit/Node/FingerTree, consTree/
-- snocTree/addTree0) is an ordinary, non-Nat-indexed set of types --
-- deliberately NOT dependently typed, mirroring idris2's own
-- contrib package (Data.Seq.Internal, adapted here from the same
-- containers/Data.Sequence algorithm it itself credits). Unlike
-- Data.Seq.Internal (and containers' own Data.Sequence), this tree
-- carries no per-node size cache at all: every branch decision in
-- consTree/snocTree/appendTreeK/addDigitsK/addTree0 is driven purely
-- by which Digit constructor (One/Two/Three/Four) is in hand, never
-- by a running total, so there was nothing for a cached Nat to buy
-- except a faster `length` -- and no index-based split/search that
-- would need one is implemented here (every non-concatenation
-- operation flattens to a single TextBuffer first, see below). `Text`
-- itself is plain `Type`, exactly like `Data.TextBuffer.TextBuffer`;
-- `length` walks the tree structurally (via `Foldable FingerTree`,
-- O(chunk count), no data copied) and is the one source of truth for
-- how long a given `Text` is. A function that genuinely needs to
-- relate a `Nat` to a specific `Text`'s length (just `index`'s `Fin`
-- bound, here) takes an explicit, erased `(0 _ : n = length t)`
-- witness for exactly that purpose instead of indexing the whole type
-- by it.
--
-- Every operation that isn't fundamentally about concatenation
-- (substr, words, trim, ...) is implemented by flattening to a single
-- TextBuffer and delegating to Data.TextBuffer's own (already-correct)
-- implementation -- same asymptotic cost as TextBuffer itself, no
-- better, no worse; only (++) and the handful of operations built
-- from it (concat, joinBy, unwords, unlines, singleton, replicate)
-- get the tree's win.

import Data.TextBuffer
import Data.Fin
import Data.List

-- ---------------------------------------------------------------------------
-- The finger tree engine. Ordinary (non-dependent), unsized types --
-- no node caches a running total; every Node2/Node3/Deep is just a
-- plain structural grouping.

data Digit : Type -> Type where
  One   : e -> Digit e
  Two   : e -> e -> Digit e
  Three : e -> e -> e -> Digit e
  Four  : e -> e -> e -> e -> Digit e

data Node : Type -> Type where
  Node2 : e -> e -> Node e
  Node3 : e -> e -> e -> Node e

node2 : e -> e -> Node e
node2 = Node2

node3 : e -> e -> e -> Node e
node3 = Node3

data FingerTree : Type -> Type where
  Empty  : FingerTree e
  Single : e -> FingerTree e
  Deep   : Digit e -> FingerTree (Node e) -> Digit e -> FingerTree e

deep : Digit e -> FingerTree (Node e) -> Digit e -> FingerTree e
deep pr m sf = Deep pr m sf

consTree : e -> FingerTree e -> FingerTree e
consTree a Empty = Single a
consTree a (Single b) = deep (One a) Empty (One b)
consTree a (Deep (One b) m sf) = Deep (Two a b) m sf
consTree a (Deep (Two b c) m sf) = Deep (Three a b c) m sf
consTree a (Deep (Three b c d) m sf) = Deep (Four a b c d) m sf
consTree a (Deep (Four b c d f) m sf) = Deep (Two a b) (consTree (node3 c d f) m) sf

snocTree : FingerTree e -> e -> FingerTree e
snocTree Empty a = Single a
snocTree (Single a) b = deep (One a) Empty (One b)
snocTree (Deep pr m (One a)) f = Deep pr m (Two a f)
snocTree (Deep pr m (Two a b)) f = Deep pr m (Three a b f)
snocTree (Deep pr m (Three a b c)) f = Deep pr m (Four a b c f)
snocTree (Deep pr m (Four a b c d)) f = Deep pr (snocTree m (node3 a b c)) (Two d f)

-- Regroups the up-to-8 elements of two adjacent digits (plus, at
-- deeper recursion levels, up to 4 already-built Nodes carried
-- between them) into 1-4 Node2/Node3s, splicing them into the middle
-- tree. Direct port of Data.Seq.Internal's addDigitsK/appendTreeK
-- mutual block (itself adapted from the `containers` package's
-- Data.Sequence) -- the natural node-count bound (>=1 needs 1 extra
-- node, up to 4 extra needs up to 4) is why this bottoms out at K=4
-- rather than needing a generic list.
mutual
  addDigits4 : FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
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

  appendTree4 : FingerTree (Node e) -> Node e -> Node e -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree4 Empty a b c d xs = consTree a (consTree b (consTree c (consTree d xs)))
  appendTree4 xs a b c d Empty = snocTree (snocTree (snocTree (snocTree xs a) b) c) d
  appendTree4 (Single x) a b c d xs = consTree x (consTree a (consTree b (consTree c (consTree d xs))))
  appendTree4 xs a b c d (Single x) = snocTree (snocTree (snocTree (snocTree (snocTree xs a) b) c) d) x
  appendTree4 (Deep pr1 m1 sf1) a b c d (Deep pr2 m2 sf2) = Deep pr1 (addDigits4 m1 sf1 a b c d pr2 m2) sf2

  addDigits3 : FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
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

  appendTree3 : FingerTree (Node e) -> Node e -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree3 Empty a b c xs = consTree a (consTree b (consTree c xs))
  appendTree3 xs a b c Empty = snocTree (snocTree (snocTree xs a) b) c
  appendTree3 (Single x) a b c xs = consTree x (consTree a (consTree b (consTree c xs)))
  appendTree3 xs a b c (Single x) = snocTree (snocTree (snocTree (snocTree xs a) b) c) x
  appendTree3 (Deep pr1 m1 sf1) a b c (Deep pr2 m2 sf2) = Deep pr1 (addDigits3 m1 sf1 a b c pr2 m2) sf2

  addDigits2 : FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
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

  appendTree2 : FingerTree (Node e) -> Node e -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree2 Empty a b xs = consTree a (consTree b xs)
  appendTree2 xs a b Empty = snocTree (snocTree xs a) b
  appendTree2 (Single x) a b xs = consTree x (consTree a (consTree b xs))
  appendTree2 xs a b (Single x) = snocTree (snocTree (snocTree xs a) b) x
  appendTree2 (Deep pr1 m1 sf1) a b (Deep pr2 m2 sf2) = Deep pr1 (addDigits2 m1 sf1 a b pr2 m2) sf2

  addDigits1 : FingerTree (Node (Node e)) -> Digit (Node e) -> Node e -> Digit (Node e) -> FingerTree (Node (Node e)) -> FingerTree (Node (Node e))
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

  appendTree1 : FingerTree (Node e) -> Node e -> FingerTree (Node e) -> FingerTree (Node e)
  appendTree1 Empty a xs = consTree a xs
  appendTree1 xs a Empty = snocTree xs a
  appendTree1 (Single x) a xs = consTree x (consTree a xs)
  appendTree1 xs a (Single x) = snocTree (snocTree xs a) x
  appendTree1 (Deep pr1 m1 sf1) a (Deep pr2 m2 sf2) = Deep pr1 (addDigits1 m1 sf1 a pr2 m2) sf2

addDigits0 : FingerTree (Node e) -> Digit e -> Digit e -> FingerTree (Node e) -> FingerTree (Node e)
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

addTree0 : FingerTree e -> FingerTree e -> FingerTree e
addTree0 Empty xs = xs
addTree0 xs Empty = xs
addTree0 (Single x) xs = consTree x xs
addTree0 xs (Single x) = snocTree xs x
addTree0 (Deep pr1 m1 sf1) (Deep pr2 m2 sf2) = Deep pr1 (addDigits0 m1 sf1 pr2 m2) sf2

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
  foldr f z (Node2 a b) = a `f` (b `f` z)
  foldr f z (Node3 a b c) = a `f` (b `f` (c `f` z))

Foldable FingerTree where
  foldr _ z Empty = z
  foldr f z (Single x) = x `f` z
  foldr f z (Deep pr m sf) = foldr f (foldr (flip (foldr f)) (foldr f z sf) m) pr

-- Walks the tree collecting its leaves, in order.
treeToList : FingerTree e -> List e
treeToList = foldr (::) []

-- ---------------------------------------------------------------------------
-- The public API. `TextBuffer` itself is already a plain `Type` (see
-- Data.TextBuffer's own header), so it sits directly as the finger
-- tree's leaf type with no existential wrapping and no separate
-- `Chunk` alias needed.

export
data Text : Type where
  MkText : FingerTree TextBuffer -> Text

||| O(chunk count). The length of a Text, summed by walking the tree
||| structurally (via `Foldable FingerTree`) -- no data is copied,
||| contrast with `flatten` below, which builds a single buffer.
export
length : Text -> Nat
length (MkText t) = foldr (\c, acc => TextBuffer.length c + acc) 0 t

||| O(1). Wrap an existing TextBuffer as a single-chunk Text.
export
fromTextBuffer : TextBuffer -> Text
fromTextBuffer tb = MkText (Single tb)

||| Convert a String to Text.
export
fromString : String -> Text
fromString s = fromTextBuffer (TextBuffer.fromString s)

-- Collapses a Text's chunks back into a single TextBuffer -- the
-- boundary every operation below that isn't fundamentally about
-- concatenation crosses to reuse Data.TextBuffer's own algorithms.
-- Folds with TextBuffer's own native (++) rather than calling
-- TextBuffer.concat on the chunk list: the overwhelmingly common case
-- is a single-chunk Text (nothing appended to it yet), where this
-- fold is free (foldl returns the one chunk unchanged) but
-- TextBuffer.concat would still allocate and copy into a fresh
-- buffer.
flatten : Text -> TextBuffer
flatten (MkText t) = case treeToList t of
  [] => TextBuffer.fromString ""
  (x :: xs) => foldl (TextBuffer.(++)) x xs

||| Convert a Text back to a String.
export
toString : Text -> String
toString t = TextBuffer.toString (flatten t)

||| O(log(min(n,m))). Concatenate two Texts.
export
(++) : Text -> Text -> Text
(++) (MkText t1) (MkText t2) = MkText (addTree0 t1 t2)

||| A Text of a single character.
export
singleton : Char -> Text
singleton c = fromTextBuffer (TextBuffer.singleton c)

||| A Text of `n` copies of a character.
export
replicate : (n : Nat) -> Char -> Text
replicate n c = fromTextBuffer (TextBuffer.replicate n c)

||| Concatenate a list of Texts into one, O(log) chunk at a time.
export
concat : List Text -> Text
concat = foldl (Data.Text.(++)) (MkText Empty)

||| Join a list of Texts, inserting `sep` between each pair.
export
joinBy : Text -> List Text -> Text
joinBy sep xs = Data.Text.concat (intersperse sep xs)

||| Join with single spaces.
export
unwords : List Text -> Text
unwords xs = joinBy (Data.Text.fromString " ") xs

||| Join, appending a newline after each piece (including the last).
export
unlines : List Text -> Text
unlines xs = Data.Text.concat (concatMap (\t => [t, Data.Text.fromString "\n"]) xs)

-- ---------------------------------------------------------------------------
-- Everything below flattens to a single TextBuffer and delegates to
-- Data.TextBuffer's own implementation -- same asymptotic cost as
-- TextBuffer itself (no tree-shape reuse), see this file's own header.

||| Get the character at the given index.
export
index : (t : Text) -> {0 n : Nat} -> {auto 0 prf : n = length t} -> Fin n -> Char
index t i = let tb = flatten t in TextBuffer.index tb {prf = believe_me ()} i

||| Uppercase every character. Length-preserving.
export
toUpper : Text -> Text
toUpper t = fromTextBuffer (TextBuffer.toUpper (flatten t))

||| Lowercase every character. Length-preserving.
export
toLower : Text -> Text
toLower t = fromTextBuffer (TextBuffer.toLower (flatten t))

||| Extract a substring of the given length, starting at the given
||| offset. Clamped to the source Text's actual bounds.
export
substr : (start, len : Nat) -> Text -> Text
substr start len t =
  let tb = flatten t
      copyLen = min len (TextBuffer.length tb `minus` start)
  in fromTextBuffer (TextBuffer.substr start copyLen tb {n = TextBuffer.length tb} {prf = believe_me ()} {ok = believe_me ()})

||| Pad on the left with `c` up to `width` (a no-op if already at
||| least that long).
export
padLeft : (width : Nat) -> Char -> Text -> Text
padLeft width c t = fromTextBuffer (TextBuffer.padLeft width c (flatten t))

||| Pad on the right with `c` up to `width` (a no-op if already at
||| least that long).
export
padRight : (width : Nat) -> Char -> Text -> Text
padRight width c t = fromTextBuffer (TextBuffer.padRight width c (flatten t))

||| Strip whitespace from the left.
export
ltrim : Text -> Text
ltrim t = fromTextBuffer (TextBuffer.ltrim (flatten t))

||| Strip whitespace from the right.
export
rtrim : Text -> Text
rtrim t = fromTextBuffer (TextBuffer.rtrim (flatten t))

||| Strip whitespace from both ends.
export
trim : Text -> Text
trim t = fromTextBuffer (TextBuffer.trim (flatten t))

||| Split on runs of whitespace, dropping empty pieces.
export
words : Text -> List Text
words t = map fromTextBuffer (TextBuffer.words (flatten t))

||| Split on newlines (`\n`, `\r`, or `\r\n`). A trailing newline
||| doesn't produce a trailing empty piece.
export
lines : Text -> List Text
lines t = map fromTextBuffer (TextBuffer.lines (flatten t))

||| Split into the longest prefix satisfying the predicate, and the
||| rest.
export
span : (Char -> Bool) -> Text -> (Text, Text)
span p t =
  let (a, b) = TextBuffer.span p (flatten t)
  in (fromTextBuffer a, fromTextBuffer b)

||| Split into the longest prefix *not* satisfying the predicate, and
||| the rest.
export
break : (Char -> Bool) -> Text -> (Text, Text)
break p t =
  let (a, b) = TextBuffer.break p (flatten t)
  in (fromTextBuffer a, fromTextBuffer b)

||| Split wherever the predicate holds, dropping the separator
||| characters themselves.
export
split : (Char -> Bool) -> Text -> List Text
split p t = map fromTextBuffer (TextBuffer.split p (flatten t))
