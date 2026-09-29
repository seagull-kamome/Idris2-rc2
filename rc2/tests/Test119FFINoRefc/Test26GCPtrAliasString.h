// Copyright 2026, Hattori,Hiroki. All rights reserved.
// This module was licensed by BSD3.

#ifndef TEST26_GCPTR_ALIAS_STRING_H
#define TEST26_GCPTR_ALIAS_STRING_H

void *idris2rc2_test26_alloc(void);
void idris2rc2_test26_free(void *p);
char *idris2rc2_test26_read_str(void *p);

// absorbed from former Test29GCAnyPtrReturn.h
void *idris2rc2_test29_alloc(void);
long idris2rc2_test29_read(void *p);
void idris2rc2_test29_free(void *p);

#endif
