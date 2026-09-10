// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#pragma once

// Read back the process's current LC_CTYPE, so the Idris side can prove
// idris2rc2_rtInit's setlocale(LC_ALL, "") actually ran.
char const *idris2rc2_test82_ctype(void);
