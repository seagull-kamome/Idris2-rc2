module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- CLI over `Language.RCExpr.Parser` (rc2base) and this tool's own
-- `Lint`/`Leak`: reads a `--directive dumprcexpr`-produced `.rcexpr` file,
-- parses it, runs the ownership-anomaly and leak checks over every `def`,
-- and prints one line per anomaly found; with `--borrow-stats`, prints
-- `Borrow`'s statistics instead. See the README for what they do and
-- don't catch.

import Language.RCExpr.AST
import Language.RCExpr.Parser
import Borrow
import Leak
import Lint
import Metrics
import Pushdown

import Data.List
import Data.SortedMap
import Data.String
import System
import System.File

usage : String
usage = "usage: rcexpr-lint [--borrow-stats | --pushdown-stats] <file.rcexpr>"

runOn : Maybe (RCProgram -> List String) -> String -> IO ()
runOn stats path = do
    result <- readFile path
    case result of
         Left err => do
             putStrLn ("rcexpr-lint: could not read " ++ path ++ ": " ++ show err)
             exitFailure
         Right content => case parseProgram content of
             Left err => do
                 putStrLn ("rcexpr-lint: " ++ path ++ ": " ++ show err)
                 exitFailure
             Right prog => case stats of
                 Just f => traverse_ putStrLn (f prog)
                 Nothing => reportAnomalies path prog
  where
    isUnknown : Anomaly -> Bool
    isUnknown a = case a.kind of
                       Unknown _ => True
                       _ => False

    -- Cases the leak check could not decide are counted, never failed on.
    unknownSummary : List Anomaly -> String
    unknownSummary us =
        let counts = foldl (\m, a => insertWith (+) (show a.kind) (the Nat 1) m) (the (SortedMap String Nat) empty) us
        in joinBy ", " (map (\(k, n) => k ++ " x" ++ show n) (SortedMap.toList counts))

    reportAnomalies : String -> RCProgram -> IO ()
    reportAnomalies path prog = do
        let (unknowns, anomalies) = partition isUnknown (lintProgram prog ++ leakProgram prog)
        case anomalies of
             [] => putStrLn ("rcexpr-lint: " ++ path ++ ": " ++ show (length prog) ++ " defs, no anomalies found")
             _ => do
                 traverse_ (\a => putStrLn (path ++ ": " ++ show a)) anomalies
                 putStrLn ("rcexpr-lint: " ++ show (length anomalies) ++ " anomalies found")
        unless (null unknowns) $
            putStrLn ("leak check: " ++ show (length unknowns) ++ " cases not decided (" ++ unknownSummary unknowns ++ ")")
        reportMetrics
        unless (null anomalies) exitFailure
      where
        reportMetrics : IO ()
        reportMetrics = do
            putStrLn "metrics (places in the IR, not executions):"
            traverse_ putStrLn (renderMetrics (metricsOf prog))

main : IO ()
main = do
    args <- getArgs
    case args of
         [_, path] => runOn Nothing path
         [_, "--borrow-stats", path] => runOn (Just borrowStats) path
         [_, "--pushdown-stats", path] => runOn (Just pushdownStats) path
         _ => do
             putStrLn usage
             exitFailure
