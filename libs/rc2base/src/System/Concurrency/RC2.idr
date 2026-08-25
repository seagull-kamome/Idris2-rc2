module System.Concurrency.RC2

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.Concurrency

%foreign_impl System.Concurrency.prim__makeMutex
  "C:idris2rc2_mutex_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__mutexAcquire
  "C:idris2rc2_mutex_acquire,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__mutexRelease
  "C:idris2rc2_mutex_release,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__makeCondition
  "C:idris2rc2_condition_make,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionWait
  "C:idris2rc2_condition_wait,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionSignal
  "C:idris2rc2_condition_signal,libidris2rc2base,concurrency_util.h"
%foreign_impl System.Concurrency.prim__conditionBroadcast
  "C:idris2rc2_condition_broadcast,libidris2rc2base,concurrency_util.h"
