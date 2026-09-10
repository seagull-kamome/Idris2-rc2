#include "posix_regex.h"

#include <regex.h>
#include <stdio.h>
#include <stdlib.h>

static _Thread_local char tl_errbuf[256];

void *idris2rc2_regex_compile(const char *pattern, int cflags) {
  regex_t *preg = malloc(sizeof(regex_t));
  if (!preg) {
    snprintf(tl_errbuf, sizeof tl_errbuf, "out of memory");
    return NULL;
  }
  int rc = regcomp(preg, pattern, cflags);
  if (rc != 0) {
    regerror(rc, preg, tl_errbuf, sizeof tl_errbuf);
    regfree(preg);
    free(preg);
    return NULL;
  }
  return preg;
}

const char *idris2rc2_regex_compile_errmsg(void) {
  return tl_errbuf;
}

int idris2rc2_regex_nsub(void *preg) {
  return (int)((const regex_t *)preg)->re_nsub;
}

void idris2rc2_regex_free(void *preg) {
  if (!preg) return;
  regfree((regex_t *)preg);
  free(preg);
}

// Match offsets from the last exec on this thread. Grown as needed; the
// slots are relative to (s + start_byte), so the accessors add start
// back to report whole-string offsets.
static _Thread_local regmatch_t *tl_pm = NULL;
static _Thread_local size_t tl_pm_cap = 0;
static _Thread_local int tl_nmatch = 0;
static _Thread_local int tl_start = 0;

int idris2rc2_regex_exec(void *preg, const char *s, int start_byte) {
  regex_t *rx = (regex_t *)preg;
  size_t nmatch = rx->re_nsub + 1;
  if (nmatch > tl_pm_cap) {
    regmatch_t *np = realloc(tl_pm, nmatch * sizeof(regmatch_t));
    if (!np) return -1;
    tl_pm = np;
    tl_pm_cap = nmatch;
  }
  int eflags = start_byte > 0 ? REG_NOTBOL : 0;
  int rc = regexec(rx, s + start_byte, nmatch, tl_pm, eflags);
  if (rc == 0) {
    tl_nmatch = (int)nmatch;
    tl_start = start_byte;
    return 1;
  }
  return rc == REG_NOMATCH ? 0 : -1;
}

int idris2rc2_regex_group_so(int i) {
  if (i < 0 || i >= tl_nmatch) return -1;
  regoff_t so = tl_pm[i].rm_so;
  return so < 0 ? -1 : (int)(so + tl_start);
}

int idris2rc2_regex_group_eo(int i) {
  if (i < 0 || i >= tl_nmatch) return -1;
  regoff_t eo = tl_pm[i].rm_eo;
  return eo < 0 ? -1 : (int)(eo + tl_start);
}

int idris2rc2_regex_extended(void) { return REG_EXTENDED; }
int idris2rc2_regex_icase(void)    { return REG_ICASE; }
int idris2rc2_regex_newline(void)  { return REG_NEWLINE; }
