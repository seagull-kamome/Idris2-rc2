||| The pipeline stages `--directive no<stage>` / `%cg rc2 no<stage>` can
||| switch off (`rc2/doc/directives.md`), and the opt-in stages, as types
||| rather than the directive strings they are spelled as: a misspelt
||| stage is a compile error instead of a switch that silently never
||| fires. `toRCDefs` and the callers that build its `disabled` list read
||| this one definition (no second list to drift out of step).
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Compiler.RC2.Stage

import Core.Core

import Data.List.Elem

%default total

||| A stage that runs unless its `no<stage>` directive is given.
public export
data Stage : Type where

     NoInline : Stage
     NoDeadArgs : Stage
     NoArityRaise : Stage
     NoApplyFold : Stage
     NoTrmc : Stage
     NoCtx : Stage
     NoConstFold : Stage
     NoKnownCon : Stage
     NoPushCon : Stage
     NoSpecClosure : Stage
     NoSpecConstCon : Stage
     NoConAltNative : Stage
     NoMutualLoop : Stage
     NoLoop : Stage
     NoEarlyInline : Stage
     NoLateInline : Stage
     NoTinyInline : Stage
     NoPushApply : Stage
     NoSink : Stage
     NoCmpMerge : Stage
     NoDualABI : Stage
     NoBoolRet : Stage
     NoBoolCase : Stage
     NoBoolField : Stage
     NoNullParams : Stage
     NoStructReturn : Stage
     NoMutualStruct : Stage
     NoDeadCode : Stage
     NoPushDown : Stage
     NoDupMerge : Stage
     NoDeadVars : Stage
     NoConstAlias : Stage
     NoLeafTail : Stage
     NoFwdAlias : Stage
     NoFunDedup : Stage
     NoReuseNested : Stage
     NoReuseRecheck : Stage
     NoStackCon : Stage


||| The directive that disables `s`.
export
stageDirective : Stage -> String

stageDirective NoInline = "noinline"
stageDirective NoDeadArgs = "nodeadargs"
stageDirective NoArityRaise = "noarityraise"
stageDirective NoApplyFold = "noapplyfold"
stageDirective NoTrmc = "notrmc"
stageDirective NoCtx = "noctx"
stageDirective NoConstFold = "noconstfold"
stageDirective NoKnownCon = "noknowncon"
stageDirective NoPushCon = "nopushcon"
stageDirective NoSpecClosure = "nospecclosure"
stageDirective NoSpecConstCon = "nospecconstcon"
stageDirective NoConAltNative = "noconaltnative"
stageDirective NoMutualLoop = "nomutualloop"
stageDirective NoLoop = "noloop"
stageDirective NoEarlyInline = "noearlyinline"
stageDirective NoLateInline = "nolateinline"
stageDirective NoTinyInline = "notinyinline"
stageDirective NoPushApply = "nopushapply"
stageDirective NoSink = "nosink"
stageDirective NoCmpMerge = "nocmpmerge"
stageDirective NoDualABI = "nodualabi"
stageDirective NoBoolRet = "noboolret"
stageDirective NoBoolCase = "noboolcase"
stageDirective NoBoolField = "noboolfield"
stageDirective NoNullParams = "nonullparams"
stageDirective NoStructReturn = "nostructreturn"
stageDirective NoMutualStruct = "nomutualstruct"
stageDirective NoDeadCode = "nodeadcode"
stageDirective NoPushDown = "nopushdown"
stageDirective NoDupMerge = "nodupmerge"
stageDirective NoDeadVars = "nodeadvars"
stageDirective NoConstAlias = "noconstalias"
stageDirective NoLeafTail = "noleaftail"
stageDirective NoFwdAlias = "nofwdalias"
stageDirective NoFunDedup = "nofundedup"
stageDirective NoReuseNested = "noreusenested"
stageDirective NoReuseRecheck = "noreuserecheck"
stageDirective NoStackCon = "nostackcon"


||| Every `Stage`; `inAllStages` proves the list is complete.
public export
allStages : List Stage
allStages = [
    NoInline,
    NoDeadArgs,
    NoArityRaise,
    NoApplyFold,
    NoTrmc,
    NoCtx,
    NoConstFold,
    NoKnownCon,
    NoPushCon,
    NoSpecClosure,
    NoSpecConstCon,
    NoConAltNative,
    NoMutualLoop,
    NoLoop,
    NoEarlyInline,
    NoLateInline,
    NoTinyInline,
    NoPushApply,
    NoSink,
    NoCmpMerge,
    NoDualABI,
    NoBoolRet,
    NoBoolCase,
    NoBoolField,
    NoNullParams,
    NoStructReturn,
    NoMutualStruct,
    NoDeadCode,
    NoPushDown,
    NoDupMerge,
    NoDeadVars,
    NoConstAlias,
    NoLeafTail,
    NoFwdAlias,
    NoFunDedup,
    NoReuseNested,
    NoReuseRecheck,
    NoStackCon
  ]


||| Only a completeness check, never used at run time: a new `Stage`
||| constructor not added to `allStages` fails to compile here.
export
inAllStages : (s : Stage) -> Elem s Stage.allStages
inAllStages NoInline = Here
inAllStages NoDeadArgs = There Here
inAllStages NoArityRaise = There (There Here)
inAllStages NoApplyFold = There (There (There Here))
inAllStages NoTrmc = There (There (There (There Here)))
inAllStages NoCtx = There (There (There (There (There Here))))
inAllStages NoConstFold = There (There (There (There (There (There Here)))))
inAllStages NoKnownCon = There (There (There (There (There (There (There Here))))))
inAllStages NoPushCon = There (There (There (There (There (There (There (There Here)))))))
inAllStages NoSpecClosure = There (There (There (There (There (There (There (There (There Here))))))))
inAllStages NoSpecConstCon = There (There (There (There (There (There (There (There (There (There Here)))))))))
inAllStages NoConAltNative = There (There (There (There (There (There (There (There (There (There (There Here))))))))))
inAllStages NoMutualLoop = There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))
inAllStages NoLoop = There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))
inAllStages NoEarlyInline = There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))
inAllStages NoLateInline = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))
inAllStages NoTinyInline = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))
inAllStages NoPushApply = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))
inAllStages NoSink = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))
inAllStages NoCmpMerge = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))
inAllStages NoDualABI = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))
inAllStages NoBoolRet = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))
inAllStages NoBoolCase = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))
inAllStages NoBoolField = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))
inAllStages NoNullParams = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))
inAllStages NoStructReturn = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))
inAllStages NoMutualStruct = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))
inAllStages NoDeadCode = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))
inAllStages NoPushDown = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))))
inAllStages NoDupMerge = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))))
inAllStages NoDeadVars = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))))))
inAllStages NoConstAlias = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))))))
inAllStages NoLeafTail = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))))))))
inAllStages NoFwdAlias = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))))))))
inAllStages NoFunDedup = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))))))))))
inAllStages NoReuseNested = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))))))))))
inAllStages NoReuseRecheck = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here)))))))))))))))))))))))))))))))))))
inAllStages NoStackCon = There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There (There Here))))))))))))))))))))))))))))))))))))

||| A stage that runs only when its directive is given.
public export
data OptIn : Type where
     LatePushCon : OptIn

export
optInDirective : OptIn -> String
optInDirective LatePushCon = "latepushcon"

||| Every `OptIn`.
export
allOptIns : List OptIn
allOptIns = [LatePushCon]

||| The directive strings `compileExpr` keeps for `toRCDefs` (`Compiler.RC2.RC2`).
export
stageDirectiveNames : List String
stageDirectiveNames = map stageDirective allStages ++ map optInDirective allOptIns

||| `s` is switched off by `directives`.
export
stageOff : Stage -> List String -> Bool
stageOff s directives = stageDirective s `elem` directives

||| An opt-in stage `s` is switched on by `directives`.
export
optInOn : OptIn -> List String -> Bool
optInOn s directives = optInDirective s `elem` directives

||| `act` unless one of `offs` is disabled, else the unchanged `skipped`
||| value -- the shape every pass in `toRCDefs` has. `act` is lazy: a
||| switched-off pass must not even build (let alone run) its work, as the
||| `else` branch of the `if` this replaces did not.
export
unlessOff : List Stage -> List String -> (skipped : a) -> Lazy (Core a) -> Core a
unlessOff offs directives skipped act =
    if any (\s => stageOff s directives) offs then pure skipped else act
