module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for Language.RCExpr.{AST,Lexer,Parser}: parses a
-- hand-written `.rcexpr` sample covering the awkward shapes actually
-- found while building this parser against real `--directive
-- dumprcexpr` output from rc2's own refc-suite (see the parser's own
-- module note for the full rationale of each). Each of these was a
-- real parse failure (or, for the `dup vN xM` case, a silent
-- miscount) this test now pins down as a regression:
--   - `dup vN xM` -- the count is glued onto `x` as one token
--     (`x2`, not `x` then `2`); reading it as two separate tokens
--     silently undercounted every multi-dup by its own extra amount.
--   - `#Name@tag(args)` (`RCConstCon`) -- recursive, `(`/`)` nested
--     with the outer list's own `[`/`]`.
--   - `#'"'` -- a `Show Char` constant whose own character is `"`
--     itself; naively lexed, the `"` looks like the start of a
--     quoted string.
--   - `Prelude.Types.SnocList.(<>>)` -- an operator's own namespaced
--     display, syntactically identical up to the `(` to a
--     `RCConstCon`'s own args list.
--   - `bufferData'` -- an ordinary identifier with a trailing prime.
--   - `Foo.Bar at Foo:1:1--2:2` -- `Core.Name`'s own `Show` can
--     suffix a display name with source-location text.
--   - `callFFIInline`'s own `ret= IORes String` -- `CFType`'s own
--     `Show` is not always a single bare word.
--   - `neg Double`/`op_strcons`/`==Int` -- a `PrimFn`'s own `Show` is
--     sometimes two words, sometimes glued to its type, never
--     predictable from the keyword alone.

import Language.RCExpr.AST
import Language.RCExpr.Parser
import Data.List

sample : String
sample = """
def Main.example  (fun args= ["v2:Boxed"] ret= Boxed)
  let v10 : Boxed =
    #_builtin.CONS@Just 1([#Prelude.Interfaces.MkMonad@Just 0([#{{csegen:1}:0}/1~closure]), #7])
  dup v10 x3
  let v9 : Boxed =
    op neg Double [#1.5]
  let v8 : Boxed =
    op op_strcons [#'"', v2]
  let v7 : Boxed =
    op ==Int [#1, #2]
  let v6 : Boxed =
    call Prelude.Types.SnocList.(<>>) [v10, v9]
  let v5 : Boxed =
    call Data.Buffer.bufferData' [v6]
  let v4 : Boxed =
    callFFIInline ["scheme:blodwen-arg", "C:foo"] [Int, %World] -> IORes String postDrop= [] [v5, v2]
  case v10 of
    Foo.Bar at Foo:1:1--2:2 [record] tag= Just 0 args= [v3, _] ->
      dup v3
      drop [v10]
      v3
    _ ->
      drop [v10]
      v4

def Main.emptyCon  (con tag= Nothing arity= 0 newtype= Nothing)

def Main.foreignStub  (foreign scheme:blodwen-noop [] -> Unit)
"""

main : IO ()
main = case parseProgram sample of
    Left err => putStrLn ("PARSE ERROR: " ++ show err)
    Right prog => do
        printLn (length prog == 3)
        case lookup "Main.example" prog of
             Just (RCFun _ _ _ body) => case body of
                 RLetIn 10 Boxed _ (RDupNode (RVar 10) 3 rest) => printLn (checkRest rest)
                 _ => putStrLn ("unexpected body shape: " ++ show (describeTop body))
             _ => putStrLn "Main.example not found or not a RCFun"
  where
    describeTop : RCExp -> String
    describeTop (RLetIn v _ _ _) = "RLetIn v" ++ show v
    describeTop (RDupNode _ _ _) = "RDupNode"
    describeTop _ = "other"
    -- Just confirms the rest of the body parsed into *some* RLetIn
    -- chain ending in a RConCaseNode -- the point of this test is
    -- that parsing succeeds and the dup count came through as 3, not
    -- a full structural re-check of every downstream node (those are
    -- exercised by simply not crashing/erroring above).
    checkRest : RCExp -> Bool
    checkRest (RLetIn _ _ _ next) = checkRest next
    checkRest (RConCaseNode (RVar 10) _ (Just _)) = True
    checkRest _ = False
