module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- CLI over `Language.RCExpr.Parser` (rc2base) and this tool's own
-- `Lint`: reads a `--directive dumprcexpr`-produced `.rcexpr` file,
-- parses it, runs the ownership-anomaly check over every `def`, and
-- prints one line per anomaly found. See `Lint`'s own module note for
-- what it does and doesn't catch.

import Language.RCExpr.AST
import Language.RCExpr.Parser
import Lint
import Metrics

import System
import System.File

usage : String
usage = "usage: rcexpr-lint <file.rcexpr>"

runOn : String -> IO ()
runOn path = do
    result <- readFile path
    case result of
         Left err => do
             putStrLn ("rcexpr-lint: could not read " ++ path ++ ": " ++ show err)
             exitFailure
         Right content => case parseProgram content of
             Left err => do
                 putStrLn ("rcexpr-lint: " ++ path ++ ": " ++ show err)
                 exitFailure
             Right prog => reportAnomalies path prog
  where
    reportAnomalies : String -> RCProgram -> IO ()
    reportAnomalies path prog =
        let anomalies = lintProgram prog in
        case anomalies of
             [] => do
                 putStrLn ("rcexpr-lint: " ++ path ++ ": " ++ show (length prog) ++ " defs, no anomalies found")
                 reportMetrics
             _ => do
                 traverse_ (\a => putStrLn (path ++ ": " ++ show a)) anomalies
                 putStrLn ("rcexpr-lint: " ++ show (length anomalies) ++ " anomalies found")
                 reportMetrics
                 exitFailure
      where
        reportMetrics : IO ()
        reportMetrics = do
            putStrLn "metrics (places in the IR, not executions):"
            traverse_ putStrLn (renderMetrics (metricsOf prog))

main : IO ()
main = do
    args <- getArgs
    case args of
         [_, path] => runOn path
         _ => do
             putStrLn usage
             exitFailure
