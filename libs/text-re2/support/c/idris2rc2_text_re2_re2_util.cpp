#include "idris2rc2_text_re2_re2_util.h"

#include <re2/re2.h>

#include <string>
#include <vector>

struct IDRIS2RC2_Regex {
  RE2 re;
  std::vector<std::string> lastMatch;
  std::vector<bool> lastMatchPresent;

  explicit IDRIS2RC2_Regex(absl::string_view pattern) : re(pattern) {}
};

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

  re->lastMatch.clear();
  re->lastMatchPresent.clear();
  if (!ok) return 0;

  re->lastMatch.reserve((size_t)n);
  re->lastMatchPresent.reserve((size_t)n);
  for (int i = 0; i < n; i++) {
    bool present = submatch[(size_t)i].data() != nullptr;
    re->lastMatchPresent.push_back(present);
    re->lastMatch.emplace_back(present ? std::string(submatch[(size_t)i]) : std::string());
  }
  return 1;
}

int idris2rc2_re2_group_count(IDRIS2RC2_Regex *re) {
  return (int)re->lastMatch.size();
}

int idris2rc2_re2_group_present(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= re->lastMatchPresent.size()) return 0;
  return re->lastMatchPresent[(size_t)index] ? 1 : 0;
}

void *idris2rc2_re2_group(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= re->lastMatch.size()) return const_cast<char *>("");
  return re->lastMatch[(size_t)index].data();
}

int64_t idris2rc2_re2_group_len(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= re->lastMatch.size()) return 0;
  return (int64_t)re->lastMatch[(size_t)index].size();
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
