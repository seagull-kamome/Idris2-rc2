module Main

-- Regression check for Compiler.RC2.RC2's own source-level `%cg rc2
-- <directive>` pragma support -- previously wired up to CLI
-- `--directive` flags only (via `getSession`), silently ignoring any
-- `%cg rc2 ...` pragma written directly in source (see RC2.idr's own
-- `directiveList` doc comment). This test's own `%cg rc2 dumpdualabi`
-- pragma below is the ONLY thing that can produce this build's own
-- `.dualabi` dump file: `rc2/tests/verify.sh` never passes `--directive
-- dumpdualabi` on the CLI for any smoke test (only `--directive
-- dumprcexpr`, baked in for every test) -- verify.sh asserts that dump
-- file's existence directly, see its own Test30CgPragma special case.

%cg rc2 dumpdualabi

loop : Nat -> Int -> Int
loop Z acc = acc
loop (S k) acc = loop k (acc + 1)

main : IO ()
main = printLn (loop 1000 0)
