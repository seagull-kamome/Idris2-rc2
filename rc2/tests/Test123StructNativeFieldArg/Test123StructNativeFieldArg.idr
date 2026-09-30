module Main

-- A struct's native field passed to a native worker parameter, then used
-- again (rc2/doc/struct-return.md, "Native fields"). `litTy` returns its
-- `Just` in a `Ret1:1=Bits8` struct, so `ty` in `pick` is a native local
-- that owns nothing. DualABI's call-site rewrite used to take it for a
-- Boxed argument and list it in the `==` worker call's `postDrop`, and
-- the generated C then passed a `uint8_t` to `idris2rc2_drop` and did
-- not compile.

data Ty = TA | TB | TC | TD | TE | TF | TG | TH | TI | TJ | TK

Eq Ty where
  TA == TA = True
  TB == TB = True
  TC == TC = True
  TD == TD = True
  TE == TE = True
  TF == TF = True
  TG == TG = True
  TH == TH = True
  TI == TI = True
  TJ == TJ = True
  TK == TK = True
  _ == _ = False

data Lit = LA Int | LB Int | LC Int | LD Int | LE Int | LF Int | LG Int | LH Int | LI Int | LJ Int | LK Int | LS String

litTy : Lit -> Maybe Ty
litTy (LA _) = Just TA
litTy (LB _) = Just TB
litTy (LC _) = Just TC
litTy (LD _) = Just TD
litTy (LE _) = Just TE
litTy (LF _) = Just TF
litTy (LG _) = Just TG
litTy (LH _) = Just TH
litTy (LI _) = Just TI
litTy (LJ _) = Just TJ
litTy (LK _) = Just TK
litTy _ = Nothing

data Rep = Native Ty | Boxed

pick : Lit -> Ty -> Rep
pick l want = case litTy l of
  Nothing => Boxed
  Just ty => if ty == want then Native ty else Boxed

showRep : Rep -> String
showRep (Native TA) = "native A"
showRep (Native TC) = "native C"
showRep (Native _) = "native other"
showRep Boxed = "boxed"

countTy : Ty -> List Lit -> Nat
countTy t [] = 0
countTy t (l :: ls) = case litTy l of
  Just u => if u == t then S (countTy t ls) else countTy t ls
  Nothing => countTy t ls

main : IO ()
main = do
  putStrLn (showRep (pick (LA 1) TA))
  putStrLn (showRep (pick (LC 1) TA))
  putStrLn (showRep (pick (LC 2) TC))
  putStrLn (showRep (pick (LS "x") TC))
  putStrLn (showRep (pick (LK 3) TK))
  printLn (countTy TC [LC 1, LA 2, LC 3, LS "y"])

