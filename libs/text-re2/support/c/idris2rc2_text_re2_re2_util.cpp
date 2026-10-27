#include "idris2rc2_text_re2_re2_util.h"

#include <re2/re2.h>

#include <string>
#include <vector>

struct IDRIS2RC2_Regex {
  RE2 re;

  explicit IDRIS2RC2_Regex(absl::string_view pattern) : re(pattern) {}
};

// The submatches of the last find() on this thread. Kept per thread, not in the
// IDRIS2RC2_Regex: a compiled pattern is shared (RE2 matching is thread-safe,
// and Text.Regex.RE2.find looks pure), so a result stored in it would be
// overwritten, or its vectors reallocated, by another thread's find().
static thread_local std::vector<std::string> tl_lastMatch;
static thread_local std::vector<bool> tl_lastMatchPresent;

static absl::string_view view(const char *s, int64_t len) {
  return absl::string_view(s, len < 0 ? 0 : (size_t)len);
}

static thread_local std::string tl_result;

extern "C" {

IDRIS2RC2_Regex *idris2rc2_re2_compile(const char *pattern, int64_t patternLen) {
  IDRIS2RC2_Regex *re = new IDRIS2RC2_Regex(view(pattern, patternLen));
  if (!re->re.ok()) {
    delete re;
    return nullptr;
  }
  return re;
}

void idris2rc2_re2_free(IDRIS2RC2_Regex *re) {
  delete re;
}

int idris2rc2_re2_num_groups(IDRIS2RC2_Regex *re) {
  return re->re.NumberOfCapturingGroups();
}

int idris2rc2_re2_full_match(IDRIS2RC2_Regex *re, const char *text, int64_t textLen) {
  return RE2::FullMatch(view(text, textLen), re->re) ? 1 : 0;
}

int idris2rc2_re2_partial_match(IDRIS2RC2_Regex *re, const char *text, int64_t textLen) {
  return RE2::PartialMatch(view(text, textLen), re->re) ? 1 : 0;
}

int idris2rc2_re2_find(IDRIS2RC2_Regex *re, const char *text, int64_t textLen) {
  int n = re->re.NumberOfCapturingGroups() + 1;
  std::vector<absl::string_view> submatch((size_t)n);
  absl::string_view subject = view(text, textLen);
  bool ok = re->re.Match(subject, 0, subject.size(), RE2::UNANCHORED, submatch.data(), n);

  tl_lastMatch.clear();
  tl_lastMatchPresent.clear();
  if (!ok) return 0;

  tl_lastMatch.reserve((size_t)n);
  tl_lastMatchPresent.reserve((size_t)n);
  for (int i = 0; i < n; i++) {
    bool present = submatch[(size_t)i].data() != nullptr;
    tl_lastMatchPresent.push_back(present);
    tl_lastMatch.emplace_back(present ? std::string(submatch[(size_t)i]) : std::string());
  }
  return 1;
}

int idris2rc2_re2_group_count(IDRIS2RC2_Regex *re) {
  return (int)tl_lastMatch.size();
}

int idris2rc2_re2_group_present(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= tl_lastMatchPresent.size()) return 0;
  return tl_lastMatchPresent[(size_t)index] ? 1 : 0;
}

void *idris2rc2_re2_group(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= tl_lastMatch.size()) return const_cast<char *>("");
  return tl_lastMatch[(size_t)index].data();
}

int64_t idris2rc2_re2_group_len(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= tl_lastMatch.size()) return 0;
  return (int64_t)tl_lastMatch[(size_t)index].size();
}

void *idris2rc2_re2_replace(IDRIS2RC2_Regex *re, const char *text, int64_t textLen,
                              const char *rewrite, int64_t rewriteLen) {
  tl_result.assign(view(text, textLen));
  RE2::Replace(&tl_result, re->re, view(rewrite, rewriteLen));
  return tl_result.data();
}

void *idris2rc2_re2_global_replace(IDRIS2RC2_Regex *re, const char *text, int64_t textLen,
                                     const char *rewrite, int64_t rewriteLen) {
  tl_result.assign(view(text, textLen));
  RE2::GlobalReplace(&tl_result, re->re, view(rewrite, rewriteLen));
  return tl_result.data();
}

int64_t idris2rc2_re2_result_len(void) {
  return (int64_t)tl_result.size();
}

} // extern "C"
