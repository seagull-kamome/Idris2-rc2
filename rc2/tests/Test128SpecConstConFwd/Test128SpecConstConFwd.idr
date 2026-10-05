module Main

import System

-- Transitive constant-constructor specialization
-- (`Compiler.RC2.SpecClosure.applySpecConstCon`, see
-- `doc/constant-constructor-specialization.md`, "Transitive
-- specialisation"): a dictionary parameter that is only handed on to
-- another function's dictionary parameter -- a *forwarding site* --
-- is eligible too, so the chain is cloned and redirected link by link.
--
-- Everything on the chain is `%noinline`; otherwise
-- `Compiler.RC2.Inline` erases the very shape under test.
--
--   chain2 -> chain1 -> classify      pure forwarders, then the one
--                                     function that scrutinises
--   countAll -> countOne              a *recursive* pure forwarder
--                                     (it carries the dictionary along
--                                     its own recursion, no `case` of
--                                     its own) onto a scrutiniser
--   stash                             stores the dictionary in its
--                                     result as well as scrutinising
--                                     it: not eligible, stays generic
--                                     and must still give right answers

record Cmp a where
  constructor MkCmp
  eq : a -> a -> Bool
  lt : a -> a -> Bool

%noinline
eqInt : Int -> Int -> Bool
eqInt a b = a == b

%noinline
ltInt : Int -> Int -> Bool
ltInt a b = a < b

%noinline
eqFlip : Int -> Int -> Bool
eqFlip a b = a /= b

%noinline
ltFlip : Int -> Int -> Bool
ltFlip a b = a > b

plain : Cmp Int
plain = MkCmp eqInt ltInt

flipped : Cmp Int
flipped = MkCmp eqFlip ltFlip

%noinline
classify : Cmp Int -> Int -> Int -> String
classify c x y =
    if c.eq x y then "eq"
    else if c.lt x y then "lt"
    else "gt"

%noinline
chain1 : Cmp Int -> Int -> Int -> String
chain1 c x y = classify c x y

%noinline
chain2 : Cmp Int -> Int -> Int -> String
chain2 c x y = chain1 c y x

%noinline
countOne : Cmp Int -> Int -> Int -> Nat
countOne c x y = if c.eq x y then 1 else 0

%noinline
countAll : Cmp Int -> Int -> List Int -> Nat
countAll c x [] = 0
countAll c x (y :: ys) = countOne c x y + countAll c x ys

%noinline
stash : Cmp Int -> Int -> Int -> (Cmp Int, String)
stash c x y = (c, if c.eq x y then "E" else "N")

main : IO ()
main = do
    putStrLn (chain2 plain 1 2)
    putStrLn (chain2 plain 2 2)
    putStrLn (chain2 plain 3 2)
    putStrLn (chain2 flipped 1 2)
    putStrLn (chain2 flipped 2 2)
    putStrLn (chain2 flipped 3 2)
    -- Direct callers of the inner links, with a dictionary only known at
    -- run time: they keep `Inline`'s only-call-site criterion from splicing
    -- the chain away, and leave `chain1`/`classify` reachable by
    -- forwarding alone for the constant dictionaries.
    as <- getArgs
    let dyn = if length as > 100 then plain else flipped
    putStrLn (chain1 dyn 5 5)
    putStrLn (classify dyn 6 5)
    printLn (countAll plain 2 [1, 2, 2, 3, 4])
    printLn (countAll flipped 2 [1, 2, 2, 3, 4])
    let (d, s) = stash plain 2 2
    putStrLn s
    putStrLn (if d.lt 1 2 then "lt" else "ge")
    let (d', s') = stash flipped 2 2
    putStrLn s'
    putStrLn (if d'.lt 1 2 then "lt" else "ge")
