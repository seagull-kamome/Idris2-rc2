#include "re2_util.h"

#include <re2/re2.h>

#include <string>
#include <vector>

struct IDRIS2RC2_Regex {
  RE2 re;
  std::vector<std::string> lastMatch;
  std::vector<bool> lastMatchPresent;

  explicit IDRIS2RC2_Regex(const char *pattern) : re(pattern) {}
};

extern "C" {

IDRIS2RC2_Regex *idris2rc2_regex_compile(const char *pattern) {
  IDRIS2RC2_Regex *re = new IDRIS2RC2_Regex(pattern);
  if (!re->re.ok()) {
    delete re;
    return nullptr;
  }
  return re;
}

void idris2rc2_regex_free(IDRIS2RC2_Regex *re) {
  delete re;
}

int idris2rc2_regex_num_groups(IDRIS2RC2_Regex *re) {
  return re->re.NumberOfCapturingGroups();
}

int idris2rc2_regex_full_match(IDRIS2RC2_Regex *re, const char *text) {
  return RE2::FullMatch(text, re->re) ? 1 : 0;
}

int idris2rc2_regex_partial_match(IDRIS2RC2_Regex *re, const char *text) {
  return RE2::PartialMatch(text, re->re) ? 1 : 0;
}

int idris2rc2_regex_find(IDRIS2RC2_Regex *re, const char *text) {
  int n = re->re.NumberOfCapturingGroups() + 1;
  std::vector<absl::string_view> submatch((size_t)n);
  absl::string_view subject(text);
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

int idris2rc2_regex_group_count(IDRIS2RC2_Regex *re) {
  return (int)re->lastMatch.size();
}

int idris2rc2_regex_group_present(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= re->lastMatchPresent.size()) return 0;
  return re->lastMatchPresent[(size_t)index] ? 1 : 0;
}

const char *idris2rc2_regex_group(IDRIS2RC2_Regex *re, int index) {
  if (index < 0 || (size_t)index >= re->lastMatch.size()) return "";
  return re->lastMatch[(size_t)index].c_str();
}

const char *idris2rc2_regex_replace(IDRIS2RC2_Regex *re, const char *text, const char *rewrite) {
  static thread_local std::string result;
  result.assign(text);
  RE2::Replace(&result, re->re, rewrite);
  return result.c_str();
}

const char *idris2rc2_regex_global_replace(IDRIS2RC2_Regex *re, const char *text, const char *rewrite) {
  static thread_local std::string result;
  result.assign(text);
  RE2::GlobalReplace(&result, re->re, rewrite);
  return result.c_str();
}

} // extern "C"
