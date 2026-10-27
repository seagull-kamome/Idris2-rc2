module Main

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

-- Regression test for System.FFI.C.Memory's <memory.h>/<string.h>
-- bindings: allocate with the module's own malloc, exercise every
-- binding (memcpy/memmove/memset/memcmp/memchr and the str* family),
-- and read the results back with Data.String.FFI.ptrToString.

import Data.String.FFI
import System
import System.FFI.C.Memory
import System.FFI.C.Null
import System.Posix.Errno

-- The allocations below are not expected to fail; report the errno
-- loudly instead of handing NULL to a C function.
mustAlloc : Either Errno NonNullAnyPtr -> IO AnyPtr
mustAlloc (Right p) = pure p.ptr
mustAlloc (Left e) = die $ "unexpected allocation failure: " ++ show e

cstring : String -> IO AnyPtr
cstring s = strdupString s >>= mustAlloc

main : IO ()
main = do
  putStrLn "--- Testing System.FFI.C.Memory ---"

  -- memset / strlen / memcpy / memcmp
  buf <- malloc 65 >>= mustAlloc
  memset buf 0 65
  printLn (!(strlen buf) == 0)

  -- calloc zeroes; a failed allocation is Left ENOMEM. (A size of 0 does not
  -- type-check: `malloc 0` is not an error, but may return NULL.)
  zeroed <- calloc 4 8 >>= mustAlloc
  printLn (!(memcmp zeroed buf 8) == 0 && !(strlen zeroed) == 0)
  huge <- malloc 0x7fffffffffffffff
  printLn (either (== ENOMEM) (const False) huge)
  free zeroed

  hello <- cstring "hello"
  memcpy buf hello 6
  printLn (!(strlen buf) == 5)
  printLn (!(ptrToString buf) == Just "hello")
  printLn (!(memcmp buf hello 6) == 0)

  -- memchr respects the size limit; 'l' is 108 and sits at index 2.
  printLn (isNullAnyPtr !(memchr hello 108 2))
  rest <- memchr hello 108 3
  printLn (!(ptrToString rest) == Just "llo")

  -- memmove between two disjoint regions.
  dst <- malloc 6 >>= mustAlloc
  memmove dst hello 6
  printLn (!(ptrToString dst) == Just "hello")

  -- memset with a non-zero byte (zero the rest first: dst still holds
  -- "hello" from the memmove above).
  memset dst 0 6
  memset dst 120 4
  printLn (!(ptrToString dst) == Just "xxxx")
  free dst

  -- strcpy / strcat / strncat
  strcpy buf hello
  printLn (!(ptrToString buf) == Just "hello")
  strcat buf hello
  printLn (!(ptrToString buf) == Just "hellohello")
  strcpy buf hello
  strncat buf hello 3
  printLn (!(ptrToString buf) == Just "hellohel")

  -- strncpy without a terminator: memset first so the check cannot
  -- pass just because the previous contents happened to match.
  memset buf 65 64
  strncpy buf hello 3
  printLn (!(strlen buf) == 64)
  printLn (!(strncmp buf hello 3) == 0)

  -- strncpy with NUL padding.
  memset buf 65 64
  strncpy buf hello 8
  printLn (!(ptrToString buf) == Just "hello")

  -- strcmp / strncmp
  abc <- cstring "abc"
  abd <- cstring "abd"
  printLn (!(strcmp abc abc) == 0)
  printLn (!(strcmp abc abd) < 0)
  printLn (!(strncmp abc abd 2) == 0)
  printLn (!(strncmp abc abd 3) < 0)

  -- strchr / strrchr / strstr / NULL results
  msg <- cstring "hello world"
  wor <- cstring "wor"
  xyz <- cstring "xyz"
  firstL <- strchr msg 108
  printLn (!(ptrToString firstL) == Just "llo world")
  lastL <- strrchr msg 108
  printLn (!(ptrToString lastL) == Just "ld")
  world <- strstr msg wor
  printLn (!(ptrToString world) == Just "world")
  printLn (isNullAnyPtr !(strchr msg 122))
  printLn (isNullAnyPtr !(strstr msg xyz))

  -- strdup of a foreign string, and strdupString of an Idris String.
  dup <- strdup hello >>= mustAlloc
  printLn (!(ptrToString dup) == Just "hello")
  free dup
  fromIdris <- cstring "from Idris"
  printLn (!(ptrToString fromIdris) == Just "from Idris")
  free fromIdris

  free hello
  free abc
  free abd
  free msg
  free wor
  free xyz
  free buf

  putStrLn "--- Tests finished ---"
