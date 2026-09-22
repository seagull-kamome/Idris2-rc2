#ifndef POSIX_REGEX_H
#define POSIX_REGEX_H

// Bindings to POSIX <regex.h> (regcomp/regexec/regfree/regerror) for
// Text.Regex.POSIX. libc only -- no external dependency, unlike
// text-re2's RE2 engine.

// regcomp `pattern` with `cflags` into a malloc'd regex_t. Returns the
// pointer on success. Returns NULL on a compile error (or OOM), having
// stashed the message where idris2rc2_regex_compile_errmsg can read it;
// the regex_t is freed internally in that case.
void *idris2rc2_regex_compile(const char *pattern, int cflags);

// regerror text for the most recent failed idris2rc2_regex_compile on
// this thread. Valid until the next compile call on this thread.
const char *idris2rc2_regex_compile_errmsg(void);

// ((regex_t*)preg)->re_nsub -- capturing groups, not counting group 0.
int idris2rc2_regex_nsub(void *preg);

// regfree + free.
void idris2rc2_regex_free(void *preg);

// regexec(preg, s + start_byte, nsub+1, <thread-local pmatch>, eflags),
// with REG_NOTBOL folded in when start_byte > 0. Returns 1 on match,
// 0 on REG_NOMATCH, -1 on any other error (including OOM growing the
// thread-local match buffer). Offsets are stashed thread-locally; read
// them with the accessors below.
int idris2rc2_regex_exec(void *preg, const char *s, int start_byte);

// rm_so / rm_eo of group `i` from the last idris2rc2_regex_exec on this
// thread, as an offset into the whole original string (start_byte added
// back). -1 for a group that did not participate, or `i` out of range.
int idris2rc2_regex_group_so(int i);
int idris2rc2_regex_group_eo(int i);

// Platform REG_* constants.
int idris2rc2_regex_extended(void);
int idris2rc2_regex_icase(void);
int idris2rc2_regex_newline(void);

#endif
