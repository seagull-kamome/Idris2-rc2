||| `%foreign` and `%export` C-wrapper generation.
||| Everything that turns a `MkRCForeign` declaration into its C wrapper
||| function (the generic pack/call/unpack shape, rc2's own leak-free
||| `fastPack`/`fastConcat` diversion, the missing-implementation stub),
||| turns a validated `%export` declaration into its externally-callable
||| C entry point, and the small shared marshalling primitives
||| (`ffiRawCall`, `resolveForeignTarget`, `peelIORes`, the `CFChar`
||| native-cast helpers) that `Compiler.RC2.Emit`'s own inline-FFI call
||| lowering (`emitAppFFIInlineInto`, `emitNativeValue`'s `RAppFFIInline`
||| case) also reaches for. Split out of `Emit.idr` to keep that module
||| on RCExp-to-C lowering; the dependency runs one way only,
||| `Emit -> EmitForeign -> EmitUtil`.
module Compiler.RC2.Emit.Foreign
-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import Compiler.RC2.RCExp
import Compiler.RC2.Types
import Compiler.RC2.Emit.Util
import Compiler.RC2.Util

import Compiler.CompileExpr
import Compiler.Common

import Core.Context

import Libraries.Data.DList
import Data.List
import Data.SortedMap
import Data.SortedSet
import Data.String
import Data.Vect

%default covering

getArgsNrList : List ty -> Nat -> List Nat
getArgsNrList [] _ = []
getArgsNrList (x :: xs) k = k :: getArgsNrList xs (S k)

varNamesFromList : List ty -> Nat -> List String
varNamesFromList str k = map (("var_" ++) . show) (getArgsNrList str k)

discardLastArgument : List ty -> List ty
discardLastArgument [] = []
discardLastArgument xs@(_ :: _) = init xs

||| `CFChar`-only cast a native argument needs at a `%foreign` call
||| site: `nativeCType CharType` (this backend's own `uint32_t` native
||| Char representation) disagrees with `cTypeOfCFType CFChar`
||| (`char`), the one `CFType` where those two differ.
nativeCharArgExpr : String -> String
nativeCharArgExpr vn = "(char)" ++ vn

||| Widens a `CFChar`-returning `%foreign` call's own `char` result
||| back up to this backend's own native `uint32_t` Char
||| representation. Goes through `unsigned char` first, not a direct
||| `(uint32_t)` cast, so a `char` whose top bit is set zero-extends
||| instead of sign-extending into three bogus `0xff` bytes -- the same
||| `(unsigned char)` step every other `Char`-producing site in this
||| runtime already takes (e.g. `idris2rc2_strings.c`'s
||| `idris2rc2_mkChar((unsigned char)s[idx])`).
export
nativeCharRetExpr : String -> String
nativeCharRetExpr retVar = "(uint32_t)(unsigned char)" ++ retVar

||| `ret`'s own peeled type -- `CFIORes t`'s payload `t`, or `ret`
||| itself for a non-IO (pure) `%foreign` declaration. Mirrors
||| `Compiler.RC2.DualABI`'s own `peelIORes` -- kept as its own tiny
||| re-derivation here rather than shared across modules, same
||| reasoning as `RAppFFIInline`'s own doc comment in RCExp.idr gives
||| for not storing this on the IR node itself: cheap enough to
||| re-derive per use, including per module.
export
peelIORes : CFType -> CFType
peelIORes (CFIORes t) = t
peelIORes t = t

||| `(cLang, fctName)` for a `%foreign` declaration's own `ccs` tag
||| list. Shared by `emitGenericForeignWrapper` (which additionally
||| consults the same `parseCC` result for the library/header options
||| `extLibOpts` carries, and the always-Boxed wrapper's own emission)
||| and the new `emitAppFFIInlineInto`/`emitNativeValue`'s own
||| `RAppFFIInline` case below, which need only the resolved call
||| target itself -- no header/library registration of their own,
||| since the wrapper for the same declaration already did that once,
||| regardless of how many inline call sites end up calling this same
||| target.
export
resolveForeignTarget : List String -> Core (CLang, Name)
resolveForeignTarget ccs =
    case parseCC ffiTags ccs of
         Just (lang, fctForeignName :: _) =>
             pure ( if lang == "RefC" || lang == "RC2" then CLangRefC else CLangC
                  , UN $ Basic $ fctForeignName)
         _ => throw $ InternalError "[rc2] FFI not found for foreign declaration"

||| Marshal every one of `fargs`'s own positions, call `fctName`, and
||| produce the raw (un-packed, un-widened) C return-value expression
||| text -- `""` for a `CFIORes CFUnit` declaration, whose call is
||| emitted here as its own statement instead (C forbids a
||| `void`-returning call as a subexpression; `packCFType CFUnit`
||| ignores its own argument regardless, so an empty placeholder is
||| always safe to feed it). Shared by `emitAppFFIInlineInto` (wants
||| this value Boxed, via `packCFType`) and `emitNativeValue`'s own
||| `RAppFFIInline` case (wants it left native, via a plain
||| `CFChar`-aware widen) -- both then finish it off differently, so
||| this only carries the part identical either way, avoiding
||| triplicating the marshalling logic.
|||
||| Also returns every genuinely-`RBoxed`-typed argument position
||| (`CFWorld`'s own trailing slot on a `CFIORes`-returning declaration
||| included), already rendered to its own drop-ready C expression text
||| (`marshalArg`'s own doc comment) -- mirrors the old
||| `emitFFIWorker`'s own unconditional `removeVars boxedVars`, now paid
||| at the call site directly since no worker function exists any more
||| to pay it internally (see `emitAppFFIInlineInto`'s own doc comment
||| for the ownership hazard this closes). `discardLastArgument` only
||| ever trims the text actually passed to `fctName(...)` -- the
||| trailing `CFWorld` slot still contributes to this drop set
||| regardless, since it's still an ordinarily-owned Idris-level
||| reference even though the raw C function itself takes one fewer
||| parameter.
export
ffiRawCall : {auto a : Ref ArgCounter Nat}
          -> {auto oft : Ref OutfileText Output}
          -> {auto il : Ref IndentLevel Nat}
          -> {auto _ : Ref ConstDef (SortedMap Constant ConstDef)}
          -> {auto cc : Ref ConstConDef (SortedMap RCLocal String, List String)}
          -> {auto r : Ref RepMap (SortedMap Int Rep)}
          -> {auto lm : Ref InlineMap (SortedMap Int (String, List String))}
          -> CLang -> Name -> List CFType -> CFType -> List RCLocal -> Core (String, List String)
ffiRawCall cLang fctName fargs ret args = do
    let paramsInfo = zip fargs args
    marshalled <- traverse (uncurry marshalArg) paramsInfo
    let argExprs = map fst marshalled
        boxedArgDrop = concatMap snd marshalled
    let callWith : List String -> String
        callWith es = "\{cName fctName}(\{showSep ", " es})"
    -- `Compiler.RC2.Emit.Util`'s own `packCFType` CFInteger case doc
    -- comment has the full rationale: allocate a fresh
    -- `IDRIS2RC2_Integer` *before* the call, pass its own `->v` as an
    -- extra *leading* argument the callee writes its result into --
    -- GMP's own out-parameter idiom, `rop` always first
    -- (`mpz_add(rop, op1, op2)`, `mpz_set_str(rop, str, base)`, etc.),
    -- not merely "an out-param somewhere" -- so a declaration can bind
    -- directly to a real GMP function's own signature with no wrapper
    -- of its own needed. Emit the call as a bare statement (its real C
    -- return type is `void`), and hand the fresh Integer back as this
    -- call's own "result" -- already fully formed, no further packing
    -- needed (`packCFType CFInteger` is a bare passthrough for exactly
    -- this reason).
    let ffiIntegerOutParam : List String -> Core String
        ffiIntegerOutParam es = do
            retVar <- getNewVarThatWillNotBeFreedAtEndOfBlock
            emit emptyFC "IDRIS2RC2_Integer *\{retVar} = idris2rc2_mkInteger();"
            emit emptyFC "\{callWith ("\{retVar}->v" :: es)};"
            pure retVar
    rawExpr <- case ret of
         CFIORes CFUnit    => do
             emit emptyFC "\{callWith (discardLastArgument argExprs)};"
             pure ""
         CFIORes CFInteger => ffiIntegerOutParam (discardLastArgument argExprs)
         CFInteger         => ffiIntegerOutParam argExprs
         CFIORes _ => pure $ callWith (discardLastArgument argExprs)
         _          => pure $ callWith argExprs
    pure (rawExpr, boxedArgDrop)
  where
    ||| One argument, marshalled per its own `CFType` (mirrors the old
    ||| `emitFFIWorker`'s own `argExprFor`): `CFChar` needs
    ||| `nativeCharArgExpr`'s own narrow cast; any other native-eligible
    ||| type reads directly via `rcVarToNativeC`; anything else is
    ||| genuinely Boxed, read via `rcVarToBoxedC` then narrowed via
    ||| `extractValue`. Also hands back its own drop target (folded
    ||| into `pending`) -- unlike an ordinary `postDrop` entry, a raw
    ||| FFI argument can itself be a literal `RCConst` with no enclosing
    ||| `let`, needing this same constant-staging-aware rendering to
    ||| drop correctly.
    marshalArg : CFType -> RCLocal -> Core (String, List String)
    marshalArg CFChar v = do
        (e, pending) <- rcVarToNativeC CharType v
        pure (nativeCharArgExpr e, pending)
    marshalArg farg v = case cfTypeNative farg of
        Just ty => rcVarToNativeC ty v
        Nothing => do
            (boxedExpr, pending) <- rcVarToBoxedC v
            pure (extractValue cLang farg boxedExpr, boxedExpr :: pending)

||| Turn a `%foreign` lib field ("libcurl", "libc 6", ...) into the
||| bare name a linker's own `-l` flag needs: drop the "lib" prefix
||| (this project's own FFI convention -- matches how Chez's own
||| `loadLib` treats the same field) and any trailing " <version>"
||| hint (a Chez-only dynamic-load version pin, meaningless to a
||| static linker). `Nothing` for a lib field that doesn't start
||| with "lib" at all -- not expected in practice, left unlinked
||| rather than guessed at.
export
linkLibName : String -> Maybe String
linkLibName lib =
    let base = fst (Data.String.break isSpace lib)
    in if isPrefixOf "lib" base
          then Just (substr 3 (length base `minus` 3) base)
          else Nothing

||| `Prelude.Types.fastPack`/`fastConcat` leak their own raw `malloc`'d
||| `char *` return through the generic `CFString`-return FFI wrapper
||| codegen (`emitGenericForeignWrapper`, `createCFunctions`'s own
||| `MkRCForeign` case) -- it copies into a fresh `IDRIS2RC2_String` via
||| `packCFType` and never frees the original -- correct for a real
||| external library's `char *` return, wrong for these two, which
||| `malloc` a buffer this project itself owns). `rc2/support/rc2/
||| idris2rc2_strings.c` already has leak-free replacements
||| (`idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed`, returning an already-fully-built
||| `IDRIS2RC2_Value*` directly, the same way any `CFUser` return is
||| already passed straight through with no copy). See `KNOWN-BUGS.md`
||| and `rc2/doc/fastpack-fix.md` for the full writeup, including why
||| this is intercepted here (at C-emission time, universally, for
||| every call site project-wide -- including ones already baked into
||| precompiled `network`/`base` code) rather than via upstream's own
||| `%transform` mechanism (which only ever rewrites a call site within
||| the rewriting definition's own elaboration/import scope, and so can
||| never reach a call site inside another package's own separately-
||| compiled `.ttc`).
|||
||| Checked by FULL namespace + base name (not just base name, unlike
||| `Compiler.RC2.ConstFold`'s own `constExtPrimValue`) precisely
||| so this never misfires on some unrelated future function that merely
||| happens to share the base name "fastPack"/"fastConcat" in a
||| different namespace. Every caller also checks this def's own
||| signature shape (`CFString`-returning, single `CFUser` argument) as
||| a second layer of defensive scoping. Shared by `createCFunctions`
||| (dispatch to `emitFastPackFixedWrapper`) and `collectDeclarations`
||| (must skip this def's own parseCC/HeaderFiles/ForeignLibs
||| registration exactly when `createCFunctions` will too).
export
fastPackFixedReplacement : Name -> Maybe String
fastPackFixedReplacement (NS ns (UN (Basic "fastPack"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastPackFixed" else Nothing
fastPackFixedReplacement (NS ns (UN (Basic "fastConcat"))) =
    if ns == mkNamespace "Prelude.Types" then Just "idris2rc2_fastConcatFixed" else Nothing
fastPackFixedReplacement _ = Nothing

||| Lower a `MkRCForeign` declaration to its C wrapper function -- the
||| `createCFunctions` `MkRCForeign` clause's whole body, standalone so
||| it can live outside `Emit.idr`. `fastPackFixedReplacement`'s own doc
||| comment has the full writeup on the leak-free-diversion check; both
||| defensive checks (name via that function, signature shape here) must
||| hold before diverting away from the generic FFI-wrapper codegen path
||| every other `%foreign` declaration still goes through unconditionally.
export
emitForeignDef : {auto oft : Ref OutfileText Output}
              -> {auto il : Ref IndentLevel Nat}
              -> Name -> (ccs : List String) -> (fargs : List CFType) -> (ret : CFType) -> Core ()
emitForeignDef n ccs fargs ret =
  case (fastPackFixedReplacement n, ret, fargs) of
       (Just fixedFnName, CFString, [CFUser _ _]) => emitFastPackFixedWrapper fixedFnName
       _ => emitGenericForeignWrapper
  where
    createFFIArgList : List CFType
                    -> Core $ List (String, String, CFType)
    createFFIArgList cftypeList = do
        let sList = map cTypeOfCFType cftypeList
        let varList = varNamesFromList cftypeList 1
        pure $ zip3 sList varList cftypeList

    emitFDef : (funcName:Name)
            -> (arglist:List (String, String, CFType))
            -> Core ()
    emitFDef funcName [] = emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName ++ "(void)"
    emitFDef funcName ((varType, varName, varCFType) :: xs) = do
        emit EmptyFC $ "IDRIS2RC2_Value *" ++ cName funcName
        emit EmptyFC "("
        increaseIndentation
        emit EmptyFC $ "  IDRIS2RC2_Value *" ++ varName
        traverse_ (\(varType, varName, varCFType) => emit EmptyFC $ ", IDRIS2RC2_Value *" ++ varName) xs
        decreaseIndentation
        emit EmptyFC ")"

    ||| `Nothing` for an always-Boxed FFI wrapper argument whose own
    ||| `CFType` maps to `Types.alwaysUnboxed` (a tagged pointer at the
    ||| C level -- `idris2rc2_drop` on it is a guaranteed runtime no-op),
    ||| `Just` its own variable name otherwise. Filters `removeVars`'
    ||| own drop list so such an argument's drop call isn't generated at
    ||| all instead of merely being cheap once generated.
    alwaysUnboxedDropVar : (String, String, CFType) -> Maybe String
    alwaysUnboxedDropVar (_, varName, vt) =
        case cfTypeNative vt of
             Just ty => if alwaysUnboxed ty then Nothing else Just varName
             Nothing => Just varName

    additionalFFIStub : Name -> List CFType -> CFType -> String
    additionalFFIStub name argTypes (CFIORes retType) = additionalFFIStub name (discardLastArgument argTypes) retType
    -- A real C function returning `Integer` is actually declared `void`,
    -- taking an extra trailing `mpz_t` out-parameter instead (see
    -- `Compiler.RC2.Emit.Util`'s own `packCFType` CFInteger case) --
    -- `cTypeOfCFType CFInteger` ("mpz_t") is only ever valid in
    -- parameter position, never as a function(-pointer)'s own return
    -- type (illegal C: a function cannot return an array type), so this
    -- stub's declared shape has to match the real one, not the generic
    -- fallback below.
    additionalFFIStub name argTypes CFInteger =
        "void (*" ++ cName name ++ ")(" ++
        (concat $ intersperse ", " $ "mpz_t" :: map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"
    additionalFFIStub name argTypes retType =
        cTypeOfCFType retType ++
        " (*" ++ cName name ++ ")(" ++
        (concat $ intersperse ", " $ map cTypeOfCFType argTypes) ++ ") = (void*)idris2rc2_missingForeign;\n"

    ||| Same external name/declared signature `emitGenericForeignWrapper`
    ||| would have produced (so every existing call site anywhere --
    ||| including ones already baked into precompiled `network`/`base`
    ||| code -- keeps linking against the same symbol, unmodified), but
    ||| the body calls rc2's own leak-free `idris2rc2_fastPackFixed`/
    ||| `idris2rc2_fastConcatFixed` (`idris2rc2_strings.c`) instead of the leaking
    ||| `fastPack`/`fastConcat`, and returns its result directly --
    ||| skipping `packCFType`/`idris2rc2_mkString` entirely, the same
    ||| way a bare `CFUser` return is already passed straight through
    ||| with no copy (see `EmitUtil.idr`'s own `packCFType` `CFUser`
    ||| case) -- since `idris2rc2_fastPackFixed`/`idris2rc2_fastConcatFixed` already return
    ||| a fully-formed, correctly-owned `IDRIS2RC2_Value*` themselves.
    emitFastPackFixedWrapper : String -> Core ()
    emitFastPackFixedWrapper fixedFnName = do
        typeVarNameArgList <- createFFIArgList fargs

        emitFDef n typeVarNameArgList
        emit EmptyFC "{"
        increaseIndentation
        emit EmptyFC $ " // rc2's own leak-free replacement for " ++ show n ++ " -- see KNOWN-BUGS.md / rc2/doc/fastpack-fix.md"
        let removeVarsArgList = removeVars (mapMaybe alwaysUnboxedDropVar typeVarNameArgList)
        emit EmptyFC $ "IDRIS2RC2_Value *retVal = " ++ fixedFnName
                    ++ "("
                    ++ showSep ", " (map (\(_, vn, vt) => extractValue CLangC vt vn) typeVarNameArgList)
                    ++ ");"
        removeVarsArgList
        emit EmptyFC "return retVal;"
        decreaseIndentation
        emit EmptyFC "}"

    emitGenericForeignWrapper : Core ()
    emitGenericForeignWrapper = do
      case parseCC ffiTags ccs of
          Just (lang, _ :: _) => do
              let isStandardFFI = elem lang ffiTags
              -- "RC2" (rc2-specific %foreign_impl patches, e.g.
              -- System.Concurrency.RC2/Data.Buffer.RC2) targets our own
              -- runtime exactly like "RefC" does -- both need
              -- CFBuffer's header-aware unwrap (EmitUtil.idr's
              -- `extractValue CLangRefC CFBuffer`), not the generic
              -- flat-data-pointer one "C" gets. Before this, every
              -- "RC2:"-tagged call fell into the `else` branch below
              -- and got the wrong (CLangC) unwrap for any CFBuffer
              -- argument -- never caught earlier because
              -- System.Concurrency.RC2's own patches never took one.
              (cLang, fctName) <- resolveForeignTarget ccs
              when (not isStandardFFI) $ emit EmptyFC $ additionalFFIStub fctName fargs ret
              typeVarNameArgList <- createFFIArgList fargs

              emitFDef n typeVarNameArgList
              emit EmptyFC "{"
              increaseIndentation
              emit EmptyFC $ " // ffi call to " ++ cName fctName
              let removeVarsArgList = removeVars (mapMaybe alwaysUnboxedDropVar typeVarNameArgList)
              -- The raw C function's own parameter list omits a
              -- `CFIORes` declaration's trailing `%World` slot (real at
              -- the Idris level, erased here); `init` commutes with the
              -- `extractValue` map, so trimming the rendered list is the
              -- same as trimming the triples first.
              let dropWorld : Bool = case ret of CFIORes _ => True; _ => False
              let renderedArgs = map (\(_, vn, vt) => extractValue cLang vt vn) typeVarNameArgList
              let callArgs = if dropWorld then discardLastArgument renderedArgs else renderedArgs
              let mkCall : List String -> String
                  mkCall es = cName fctName ++ "(" ++ showSep ", " es ++ ")"
              -- A bare (non-`CFIORes`) `CFUnit` return deliberately still
              -- falls through to the generic `payloadTy` arm -- matching
              -- this backend's existing behaviour, unusual as that C is.
              case ret of
                CFIORes CFUnit => do
                    emit EmptyFC $ mkCall callArgs ++ ";"
                    removeVarsArgList
                    emit EmptyFC "return NULL;"
                _ => case peelIORes ret of
                  -- `Compiler.RC2.Emit.Util`'s own `packCFType` CFInteger
                  -- case has the full rationale: GMP's own `mpz_t` has
                  -- no "return by value" C shape, so a fresh
                  -- `IDRIS2RC2_Integer` is allocated *before* the call
                  -- and its own `->v` passed as an extra *leading*
                  -- argument (GMP's own `rop`-always-first
                  -- out-parameter idiom -- `mpz_add(rop, op1, op2)`,
                  -- etc. -- not merely "an out-param somewhere", so a
                  -- declaration can bind directly to a real GMP
                  -- function's own signature) the real C function
                  -- (declared `void`) writes its result into, rather
                  -- than assigning from the call's own (nonexistent)
                  -- return value.
                  CFInteger => do
                      emit EmptyFC "IDRIS2RC2_Integer *retVal = idris2rc2_mkInteger();"
                      emit EmptyFC $ mkCall ("retVal->v" :: callArgs) ++ ";"
                      emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType CFInteger "retVal" ++ ";"
                      removeVarsArgList
                      emit EmptyFC "return packedRet;"
                  -- Pack retVal before dropping the args: a CFString/CFBuffer
                  -- retVal may alias memory owned by one of those args (e.g.
                  -- a C function that just returns a pointer it was handed),
                  -- so packCFType must read through it while the arg (and
                  -- whatever finalizer freeing that memory) is still alive.
                  payloadTy => do
                      emit EmptyFC $ cTypeOfCFType payloadTy ++ " retVal = " ++ mkCall callArgs ++ ";"
                      emit EmptyFC $ "IDRIS2RC2_Value *packedRet = (IDRIS2RC2_Value*)" ++ packCFType payloadTy "retVal" ++ ";"
                      removeVarsArgList
                      emit EmptyFC "return packedRet;"

              decreaseIndentation
              emit EmptyFC "}"
          _ => throw $ InternalError "[rc2] FFI not found for \{cName n}"

||| The C wrapper synthesised for one validated `%export` declaration
||| (`Compiler.RC2.RC2.validateExport`'s own result): under the
||| user-given `exportedCName`, with native C parameter/return types,
||| boxing each argument, calling the original always-Boxed entry point
||| (`cName !(getFullName n)`, never itself touched/converted -- see
||| `rc2/doc/export-support.md`), then unboxing the trampolined result.
||| Never `static` -- nothing in generated C calls it; it exists purely
||| for an external caller, hand-written C included (see
||| `Test59Export/Test59Export.c`). A boxed `IDRIS2RC2_Value*` return is
||| explicitly `idris2rc2_drop`ped right after `extractValue` reads its
||| payload out (safe and a no-op for every already-unboxed scalar, see
||| `idris2rc2_drop`'s own `idris2rc2_is_unboxed` check) -- unlike
||| `main`'s own footer, which can get away with never dropping its
||| final result because the process exits immediately after, this
||| wrapper can be called arbitrarily many times from external C, so a
||| real heap-allocating return (`CFInt`/`CFInt64`/`CFUnsigned64`/
||| `CFDouble`) would otherwise leak on every call.
|||
||| Three argument/return positions can't use that generic pack-then-
||| call / call-then-extract-then-drop shape as-is, and are special-
||| cased below: a `CFInteger` argument (a raw incoming `mpz_t`, not
||| already an `IDRIS2RC2_Integer*` the way `packCFType`'s own identity-
||| passthrough CFInteger case assumes -- see its doc comment), a
||| `CFInteger` return (GMP's `mpz_t` has no by-value C return shape at
||| all, so the whole wrapper signature gains a leading `mpz_t out`
||| parameter and turns `void`, mirroring `emitGenericForeignWrapper`'s
||| own identical convention for a `%foreign` Integer return), and a
||| `CFString` return (`extractValue`'s own CFString case aliases the
||| Boxed value's own malloc'd buffer -- returning that pointer and
||| *then* dropping the Boxed value it came from would hand the C
||| caller a dangling pointer, so an independent copy is made first).
export
emitExportWrapper : {auto c : Ref Ctxt Defs}
                  -> {auto oft : Ref OutfileText Output}
                  -> {auto il : Ref IndentLevel Nat}
                  -> Name -> String -> List CFType -> CFType -> Core ()
emitExportWrapper n exportedCName fargs ret = do
    let ret' = peelIORes ret
    let isIntegerReturn = case ret' of CFInteger => True; _ => False
    let isStringReturn = case ret' of CFString => True; _ => False
    -- A `CFString` return is a plain, independently-`malloc`'d buffer the
    -- C caller must `free()` (see the CFString case below) -- declaring
    -- it `const char *` (the shared `cTypeOfCFType CFString` mapping,
    -- meant for %foreign's borrowed-immutable-view convention) would
    -- make that `free()` call discard a qualifier for no reason.
    let retC = the String (if isIntegerReturn then "void"
                            else if isStringReturn then "char *"
                            else cTypeOfCFType ret')
    let params = zip (getArgsNrList fargs 0) fargs
    let paramDecls = map (\(i, ty) => cTypeOfCFType ty ++ " p_\{show i}") params
    let allParamDecls = if isIntegerReturn then "mpz_t out" :: paramDecls else paramDecls
    let sig = "\{retC} \{exportedCName}("
            ++ (if isNil allParamDecls then "void" else showSep ", " allParamDecls)
            ++ ")"
    emit EmptyFC sig
    emit EmptyFC "{"
    increaseIndentation
    traverse_ (\(i, ty) => emit EmptyFC "IDRIS2RC2_Value *a_\{show i} = \{argPack ty i};") params
    -- `ret`'s own un-peeled shape: an `IO`/`IORes`-returning declaration's
    -- compiled entry point carries one extra trailing World parameter
    -- rc2's own `%export` validation (`Compiler.RC2.RC2.validateExport`)
    -- already confirmed is real, not erased -- see that doc comment and
    -- `rc2/doc/export-support.md`'s "World argument" note. `CFWorld`'s
    -- own boxed representation is always NULL, matching `packCFType`/
    -- `extractValue`'s existing CFWorld case exactly.
    let worldArg = case ret of CFIORes _ => ["(IDRIS2RC2_Value *)NULL"]; _ => []
    let boxedArgs = map (\(i, _) => "a_" ++ show i) params ++ worldArg
    fulln <- getFullName n
    let callExpr = "\{cName fulln}(\{showSep ", " boxedArgs})"
    let ranExpr = "idris2rc2_trampoline(\{callExpr})"
    case ret' of
         CFUnit => emit EmptyFC "(void)\{ranExpr};"
         CFInteger => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "mpz_init(out);"
             emit EmptyFC "mpz_set(out, \{extractValue CLangC CFInteger "r"});"
             emit EmptyFC "idris2rc2_drop(r);"
             emit EmptyFC "return;"
         CFString => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "const char *raw = \{extractValue CLangC CFString "r"};"
             emit EmptyFC "size_t len = strlen(raw) + 1;"
             emit EmptyFC "char *result = malloc(len);"
             emit EmptyFC "memcpy(result, raw, len);"
             emit EmptyFC "idris2rc2_drop(r);"
             -- `result` is a plain, independently-allocated buffer, not
             -- an IDRIS2RC2_String -- the C caller now owns it and must
             -- free() it themselves; never pass it to any idris2rc2_*
             -- function.
             emit EmptyFC "return result;"
         _ => do
             emit EmptyFC "IDRIS2RC2_Value *r = \{ranExpr};"
             emit EmptyFC "\{retC} result = \{extractValue CLangC ret' "r"};"
             emit EmptyFC "idris2rc2_drop(r);"
             emit EmptyFC "return result;"
    decreaseIndentation
    emit EmptyFC "}"
  where
    -- `packCFType`'s own CFInteger case is a bare passthrough that
    -- assumes an `IDRIS2RC2_Integer*` was already built elsewhere (real
    -- for a `%foreign` call site's own out-parameter convention, see
    -- its doc comment) -- but here `p_i` is the raw incoming `mpz_t`
    -- itself, so a fresh, independently-owned `IDRIS2RC2_Integer` has
    -- to be copied in first.
    -- `(IDRIS2RC2_Value *)`-cast unconditionally: several `packCFType`
    -- cases (CFPtr/CFGCPtr/CFStruct) return an `IDRIS2RC2_Pointer*`/
    -- `IDRIS2RC2_GCPointer*`-typed call expression, not a bare
    -- `IDRIS2RC2_Value*` one -- every other call site in this module
    -- assigning a `packCFType` result already carries this same cast
    -- (e.g. `emitGenericForeignWrapper`'s own `packedRet` lines) for
    -- exactly this reason; this one just never had an argument-
    -- position CFPtr/CFGCPtr/CFStruct to expose the gap before.
    argPack : CFType -> Nat -> String
    argPack CFInteger i = "(IDRIS2RC2_Value *)idris2rc2_mkIntegerFromMpz(p_\{show i})"
    argPack ty i = "(IDRIS2RC2_Value *)" ++ packCFType ty ("p_" ++ show i)

||| A `%foreign` declaration rc2 can actually implement: either
||| diverted to rc2's own native `fastPack`/`fastConcat` replacement
||| (`fastPackFixedReplacement`, regardless of what its own `ccs` says
||| -- rc2 supplies a native body either way) or carrying a calling
||| convention `parseCC` actually recognizes (`"C:..."`/`"RefC:..."`/
||| `"RC2:..."`). A declaration with neither -- e.g.
||| `Prelude.IO.prim__threadWait`'s `%foreign "scheme:blodwen-thread-wait"`
||| only, no C-family convention at all since only Chez ever needed one
||| -- is a hard whole-program compile error today
||| (`collectDeclarations`'s own `MkRCForeign` case), unreachable in
||| practice since `DeadCode.pruneDeadDefs` already removes an unused
||| declaration like this before `collectDeclarations` ever sees it --
||| deliberately kept as a hard, immediately-attributable error for
||| whole-program mode (naming the exact Idris function) rather than
||| softened into a link-time failure too: if it's ever genuinely
||| reachable there, something in the program truly calls a function
||| rc2 has no way to implement, and that's worth surfacing immediately
||| and unambiguously, not as a mystery "undefined reference" to a
||| mangled C name. Incremental mode, in contrast, deliberately never
||| runs `DeadCode` at all (see rc2/doc/incremental-compile.md's "What
||| actually needs to change") -- every module's *entire* `toIR`, used
||| or not, real convention or not, reaches `collectDeclarations`
||| regardless of whether anything anywhere ever actually calls it, so
||| the same hard error would trip on every unused-in-this-module
||| declaration like this one across the whole standard library. Only
||| there (`dropUnimplementableForeign = True`, `Compiler.RC2.RC2`'s
||| own `incCompile`) is a declaration like this dropped from `defs`
||| silently instead, before this module owns anything to declare --
||| see rc2/doc/incremental-compile.md's "Bugs found while implementing"
||| #3 for the full reasoning and the deliberate whole-program/
||| incremental split. Any real caller (if one exists) still gets a
||| plain `extern` prototype via `externalFunctionRefsD` below, since a
||| dropped name is indistinguishable from an ordinary externally-
||| defined one at that point -- the failure becomes a link-time
||| "undefined reference" there instead of either a compile-time stop
||| or a runtime crash.
export
hasUsableForeignImpl : (Name, RCDef) -> Bool
hasUsableForeignImpl (n, MkRCForeign ccs fargs ret) =
    case (fastPackFixedReplacement n, ret, fargs) of
         (Just _, CFString, [CFUser _ _]) => True
         _ => isJust (parseCC ffiTags ccs)
hasUsableForeignImpl _ = True
