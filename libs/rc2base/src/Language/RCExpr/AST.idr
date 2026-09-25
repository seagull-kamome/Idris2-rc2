module Language.RCExpr.AST

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

||| A standalone parsed representation of rc2's own `--directive
||| dumprcexpr` output (`Compiler.RC2.Pretty`'s own text format,
||| `rc2/src/Compiler/RC2/Pretty.idr` -- the single authoritative
||| source for this grammar; every constructor here corresponds to
||| exactly one `prettyExp`/`prettyDef` clause there). rc2base can't
||| depend on the compiler's own `Compiler.RC2.RCExp` (that lives in
||| `idris2-rc-cg`'s own `rc2` package, not something an ordinary
||| `--cg rc2` program links against), so this is an independent
||| mirror of its shape -- built for `Language.RCExpr.Lint`'s own
||| ownership-anomaly checking, not as a general-purpose compiler AST.
|||
||| Several fields print via *upstream* Idris2 `Show` instances this
||| project doesn't own (a definition/constructor `Name`, an `ROp`/
||| `RCmpCase`'s own primitive operator, a `RCConst`'s own `Constant`,
||| a constructor's own `ConInfo`/tag). Fully replicating every one of
||| their exact print formats (including nested compiler-generated
||| name braces like `{{__mainExpression:0}:0}`) would be a large,
||| low-value undertaking: the ownership-anomaly checks this module
||| exists for only need `RCLocal` identity and the tree's own shape,
||| never what a name or constant *means*. Every such field is instead
||| an opaque `String` here -- captured verbatim (precise enough to
||| render back in a diagnostic), never parsed further.

||| Mirrors `Compiler.RC2.RCExp.RCLocal`'s own five-way `Show` split
||| exactly (`RCExp.idr`'s own `Show RCLocal`):
||| `RCLoc 0` -> `"_"`, `RCLoc i` -> `"v" ++ show i`, `RCNull` ->
||| `"[__]"`, `RCConst`/`RCEmptyCon`/`RCConstCon`/`RCConstClosure` ->
||| each own `"#..."`-prefixed form. Only `RVar` is ever a genuine
||| refcounted heap value `Language.RCExpr.Lint` needs to track --
||| the other four are immortal/constant-shaped locals with no
||| refcount to drop, exactly like the compiler's own `splitBorrows`/
||| `boxedOperands` treat them (see that module's own doc comments).
public export
data RCLocal : Type where
  RVar        : Int -> RCLocal
  RUnderscore : RCLocal              -- a `dumprcexpr`-rendered dead RConAlt field (Compiler.RC2.DeadVars), or literally `RCLoc 0`
  RNull       : RCLocal
  RConst      : String -> RCLocal    -- the raw text after `#`, e.g. `"12345.6789"` (with its own quotes) or `42`
  ROpaqueCon  : String -> RCLocal    -- `RCEmptyCon`/`RCConstCon`/`RCConstClosure` -- raw text after `#`

public export
Eq RCLocal where
  RVar a == RVar b = a == b
  RUnderscore == RUnderscore = True
  RNull == RNull = True
  RConst a == RConst b = a == b
  ROpaqueCon a == ROpaqueCon b = a == b
  _ == _ = False

public export
Ord RCLocal where
  compare (RVar a) (RVar b) = compare a b
  compare (RVar _) _ = LT
  compare _ (RVar _) = GT
  compare RUnderscore RUnderscore = EQ
  compare RUnderscore _ = LT
  compare _ RUnderscore = GT
  compare RNull RNull = EQ
  compare RNull _ = LT
  compare _ RNull = GT
  compare (RConst a) (RConst b) = compare a b
  compare (RConst _) _ = LT
  compare _ (RConst _) = GT
  compare (ROpaqueCon a) (ROpaqueCon b) = compare a b

public export
Show RCLocal where
  show (RVar i) = "v" ++ show i
  show RUnderscore = "_"
  show RNull = "[__]"
  show (RConst s) = "#" ++ s
  show (ROpaqueCon s) = "#" ++ s

||| Only the two shapes `Language.RCExpr.Lint` needs to tell apart --
||| a `Boxed` local has a real refcount to track, anything else
||| (`Native`/`InlineNative`, whatever the payload type turns out to
||| be) never does, exactly like `Compiler.RC2.RC`'s own
||| `alwaysUnboxedBoxedLocalsR`-adjacent machinery. The native type
||| itself is opaque -- this module never needs to know *which*
||| native type, only that it isn't `Boxed`.
public export
data RRep = Boxed | NativeRep String

public export
Show RRep where
  show Boxed = "Boxed"
  show (NativeRep t) = t

-- One parsed top-level definition body, one constructor per
-- `Pretty.idr` `prettyExp` clause. `FC`s are never printed by
-- `Pretty.idr` at all, so there's nothing to parse or carry here.
-- `RCExp` and `RConAlt`/`RConstAlt` refer to each other (a case
-- alt's own body is an `RCExp`, and `RCExp`'s own case nodes hold a
-- list of alts) so all three sit in one `mutual` block.
mutual
  ||| One parsed top-level definition body, one constructor per
  ||| `Pretty.idr` `prettyExp` clause. `FC`s are never printed by
  ||| `Pretty.idr` at all, so there's nothing to parse or carry here.
  public export
  data RCExp : Type where
    RV           : RCLocal -> RCExp
    RCall        : (isLazy : Bool) -> (name : String) -> List RCLocal -> RCExp
    RCallRep     : (name : String) -> (sig : String) -> (postDrop : List RCLocal) -> List RCLocal -> RCExp
    RCallFFI     : (desc : String) -> (postDrop : List RCLocal) -> List RCLocal -> RCExp
    RPartial     : (name : String) -> (missing : String) -> List RCLocal -> RCExp
    RApply       : (isLazy : Bool) -> RCLocal -> List RCLocal -> RCExp
    RLetIn       : (var : Int) -> RRep -> (value : RCExp) -> (body : RCExp) -> RCExp
    RConstruct   : (name : String) -> (tag : String) -> List RCLocal -> (reuseFrom : Maybe RCLocal) -> RCExp
    ||| `retpack`: a struct built in a struct-returning worker's tail
    ||| (rc2's `doc/struct-return.md`); the field, if any, is consumed.
    RRetPackNode : (name : String) -> (tag : String) -> (field : Maybe RCLocal) -> RCExp
    ROpNode      : (isLazy : Bool) -> (op : String) -> List RCLocal -> (postDrop : List RCLocal) -> RCExp
    RExtPrimNode : (isLazy : Bool) -> (prim : String) -> List RCLocal -> (postDrop : List RCLocal) -> RCExp
    RStructGetNode : (structVar : RCLocal) -> (field : String) -> (postDrop : List RCLocal) -> RCExp
    RStructSetNode : (structVar : RCLocal) -> (field : String) -> (value : RCLocal) -> (postDrop : List RCLocal) -> RCExp
    RCmp         : (op : String) -> List RCLocal -> (postDrop : List RCLocal) -> (whenTrue : RCExp) -> (whenFalse : RCExp) -> RCExp
    RConCaseNode : (scrutinee : RCLocal) -> List RConAlt -> (defBody : Maybe RCExp) -> RCExp
    RConstCaseNode : (scrutinee : RCLocal) -> List RConstAlt -> (defBody : Maybe RCExp) -> RCExp
    RPrim        : (const_ : String) -> RCExp
    RErasedNode  : RCExp
    RCrashNode   : (msg : String) -> RCExp
    RDupNode     : (var : RCLocal) -> (count : Int) -> (body : RCExp) -> RCExp
    RDropNode    : (vars : List RCLocal) -> (body : RCExp) -> RCExp
    RFreeNode    : (var : RCLocal) -> (body : RCExp) -> RCExp
    RReleaseReuseNode : (var : RCLocal) -> (body : RCExp) -> RCExp
    RReuseOfferNode : (scrutinee : RCLocal) -> (dupOnShared : List RCLocal) -> (dropOnUnique : List RCLocal) -> (body : RCExp) -> RCExp
    RLoopNode    : (params : List (Int, RRep)) -> (initial : List RCLocal) -> (prologueDrop : List RCLocal) -> (body : RCExp) -> RCExp
    RLoopContinueNode : (args : List RCLocal) -> (postDrop : List RCLocal) -> RCExp
    RMemoizeNode : (name : String) -> RRep -> (body : RCExp) -> RCExp

  ||| `Compiler.RC2.RCExp.RConAlt` -- `args` are always plain `RCLoc`
  ||| variable ids (`Pretty.idr`'s own `map RCLoc args`), never one of
  ||| the other four `RCLocal` shapes.
  public export
  record RConAlt where
    constructor MkRConAlt
    conName : String
    tag     : String
    args    : List Int
    altBody : RCExp

  public export
  record RConstAlt where
    constructor MkRConstAlt
    constVal : String
    altBody  : RCExp

||| `Compiler.RC2.RCExp.RCDef`, one constructor per `Pretty.idr`
||| `prettyDef` clause.
public export
data RCDef : Type where
  RCFun     : (args : List (Int, RRep)) -> (retRep : RRep) -> (isWorker : Bool) -> (body : RCExp) -> RCDef
  RCCon     : (tag : String) -> (arity : String) -> (newtype_ : String) -> RCDef
  RCForeign : (desc : String) -> RCDef
  RCErrorDef : (body : RCExp) -> RCDef

||| One `(name, def)` pair per `def ... ` block in the dump, in file
||| order.
public export
RCProgram : Type
RCProgram = List (String, RCDef)
