// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#pragma once

// Read back the process's current locale for a category, so the Idris
// side can prove idris2rc2_rtInit's setlocale calls actually ran.
char const *idris2rc2_test82_ctype(void);
char const *idris2rc2_test82_numeric(void);
