#ifndef IDRIS2RC2_TEXT_RE2_RE2_UTIL_H
#define IDRIS2RC2_TEXT_RE2_RE2_UTIL_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IDRIS2RC2_Regex IDRIS2RC2_Regex;

// Every string goes in as a pointer and a byte length (the Idris side
// passes Data.String.RC2.byteLength), and every string result comes back
// as a pointer plus a separate length accessor, so a NUL byte is data
// like any other in both directions.
//
// Named idris2rc2_re2_*, not idris2rc2_regex_*: rc2base's POSIX regex binding
// uses that prefix, and a program linking both would get its functions.

// NULL on an invalid pattern (RE2::ok() false) -- no error message
// surfaced; add one later if a caller ever needs to report why a
// pattern was rejected.
IDRIS2RC2_Regex *idris2rc2_re2_compile(const char *pattern, int64_t patternLen);
void idris2rc2_re2_free(IDRIS2RC2_Regex *re);

int idris2rc2_re2_num_groups(IDRIS2RC2_Regex *re);

int idris2rc2_re2_full_match(IDRIS2RC2_Regex *re, const char *text, int64_t textLen);
int idris2rc2_re2_partial_match(IDRIS2RC2_Regex *re, const char *text, int64_t textLen);

// Finds the leftmost unanchored match, caching every submatch (index 0
// = whole match, 1..N = capturing groups) for idris2rc2_re2_group/
// _group_len/_group_present to read afterwards. Returns 0 (no match) or
// 1. The cache is overwritten by the next find() on the same
// IDRIS2RC2_Regex -- read every group needed before calling find()
// again.
int idris2rc2_re2_find(IDRIS2RC2_Regex *re, const char *text, int64_t textLen);
int idris2rc2_re2_group_count(IDRIS2RC2_Regex *re);
// 0/1; distinguishes "group didn't participate in the match" from "an
// empty string" -- idris2rc2_re2_group gives an empty string for both,
// this is the only way to tell them apart (also covers an out-of-range
// index, as 0/not-present).
int idris2rc2_re2_group_present(IDRIS2RC2_Regex *re, int index);
// The bytes of group `index`, valid until the next find() on `re`;
// idris2rc2_re2_group_len gives their count. Never NULL. `void *`, not
// `const char *`: the Idris side takes it as an AnyPtr, and must only
// read it.
void *idris2rc2_re2_group(IDRIS2RC2_Regex *re, int index);
int64_t idris2rc2_re2_group_len(IDRIS2RC2_Regex *re, int index);

// The rewritten text, in a thread-local buffer valid until this thread's
// next call to either replace function; idris2rc2_re2_result_len gives
// its byte count.
void *idris2rc2_re2_replace(IDRIS2RC2_Regex *re, const char *text, int64_t textLen,
                                  const char *rewrite, int64_t rewriteLen);
void *idris2rc2_re2_global_replace(IDRIS2RC2_Regex *re, const char *text, int64_t textLen,
                                         const char *rewrite, int64_t rewriteLen);
int64_t idris2rc2_re2_result_len(void);

#ifdef __cplusplus
}
#endif

#endif
