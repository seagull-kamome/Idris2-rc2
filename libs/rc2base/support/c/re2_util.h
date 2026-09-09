#ifndef RE2_UTIL_H
#define RE2_UTIL_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct IDRIS2RC2_Regex IDRIS2RC2_Regex;

// NULL on an invalid pattern (RE2::ok() false) -- no error message
// surfaced; add one later if a caller ever needs to report why a
// pattern was rejected.
IDRIS2RC2_Regex *idris2rc2_regex_compile(const char *pattern);
void idris2rc2_regex_free(IDRIS2RC2_Regex *re);

int idris2rc2_regex_num_groups(IDRIS2RC2_Regex *re);

int idris2rc2_regex_full_match(IDRIS2RC2_Regex *re, const char *text);
int idris2rc2_regex_partial_match(IDRIS2RC2_Regex *re, const char *text);

// Finds the leftmost unanchored match, caching every submatch (index 0
// = whole match, 1..N = capturing groups) for idris2rc2_regex_group/
// _group_present to read afterwards. Returns 0 (no match) or 1. The
// cache is overwritten by the next find() on the same
// IDRIS2RC2_Regex -- read every group needed before calling find()
// again.
int idris2rc2_regex_find(IDRIS2RC2_Regex *re, const char *text);
int idris2rc2_regex_group_count(IDRIS2RC2_Regex *re);
// 0/1; distinguishes "group didn't participate in the match" from "an
// empty string" -- idris2rc2_regex_group returns "" for both, this is
// the only way to tell them apart (also covers an out-of-range index,
// as 0/not-present).
int idris2rc2_regex_group_present(IDRIS2RC2_Regex *re, int index);
// Rc2's own %foreign CFString-return marshaling (idris2rc2_mkString)
// copies immediately at the call site, so a pointer into this
// IDRIS2RC2_Regex's own cache (invalidated by the *next* find() call,
// not by returning from this one) is safe to hand back directly --
// never NULL, unlike a raw C API returning "no such group" as NULL
// would.
const char *idris2rc2_regex_group(IDRIS2RC2_Regex *re, int index);

// Same immediate-copy reasoning: the returned pointer is into a
// thread-local buffer valid until this thread's next call to either
// replace function, which %foreign's copy-on-return already outruns.
const char *idris2rc2_regex_replace(IDRIS2RC2_Regex *re, const char *text, const char *rewrite);
const char *idris2rc2_regex_global_replace(IDRIS2RC2_Regex *re, const char *text, const char *rewrite);

#ifdef __cplusplus
}
#endif

#endif
