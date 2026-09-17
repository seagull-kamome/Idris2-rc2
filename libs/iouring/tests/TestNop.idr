||| Automated smoke test: ring init -> prep a tagged nop -> submit ->
||| wait for its completion -> check `userData` round-tripped and
||| `res == 0` -> tear down. Exercises the whole submit/complete
||| machinery without touching the filesystem or network at all.
module Main

import System.IO.Uring

main : IO ()
main = do
  Just ring <- init 8
    | Nothing => putStrLn "FAIL: init failed"
  Just sqe <- getSqe ring
    | Nothing => putStrLn "FAIL: getSqe failed"
  prepNop sqe
  setUserData sqe 0xdeadbeef
  n <- submit ring
  if n /= 1
     then putStrLn $ "FAIL: submit returned " ++ show n ++ ", expected 1"
     else do
       Just completion <- waitCompletion ring
         | Nothing => putStrLn "FAIL: waitCompletion failed"
       exit ring
       if completion.userData == 0xdeadbeef && completion.res == 0
          then putStrLn "PASS: nop round-trip"
          else putStrLn $ "FAIL: unexpected completion " ++
                 show (completion.userData, completion.res, completion.flags)
