#!/usr/bin/env bash
# Turn a bench.sh log into the two Markdown tables of a BENCHMARKS.md
# entry, with the previous entry's rc2 times alongside.
#
# Usage: compare.sh <bench log> [BENCHMARKS.md]
#   The previous entry is the first "## " section of BENCHMARKS.md
#   (default: rc2/BENCHMARKS.md of the current git repo).

set -euo pipefail
LOG="$1"
MD="${2:-$(git rev-parse --show-toplevel)/rc2/BENCHMARKS.md}"

awk -v md="$MD" '
function ratio(r, f) { return (r > 0) ? sprintf("%.1f", f / r) : "-" }
BEGIN {
    sec = 0
    while ((getline line < md) > 0) {
        if (line ~ /^## /) { sec++; if (sec > 1) break; continue }
        if (sec != 1) continue
        n = split(line, c, "|")
        if (n < 4) continue
        k = c[2]; gsub(/[ `*]/, "", k); v = c[3]; gsub(/[ *s]/, "", v)
        if (k ~ /^Bench/) { sub(/\.idr$/, "", k); pm[k] = v; w = c[4]; gsub(/[ *s]/, "", w); pf[k] = w }
        else if (k == "rc2" || k == "RefC" || k == "Chez") pc[k] = v
    }
}
/^=== Micro/ { mode = "m"; next }
/^=== idris2-missing/ { mode = "c"; next }
/^===/ { mode = ""; next }
mode == "m" && $1 ~ /^Bench/ && NF >= 3 { name[++nm] = $1; r[$1] = $2; f[$1] = $3 }
mode == "c" && ($1 == "rc2" || $1 == "refc" || $1 == "chez") && NF == 2 { cv[$1] = $2 }
END {
    print "| ベンチマーク | rc2(s) | refc(s) | 倍率(RefC比) | 前回のrc2(s) |"
    print "|---|---|---|---|---|"
    for (i = 1; i <= nm; i++) order[i] = i
    for (i = 1; i <= nm; i++) for (j = i + 1; j <= nm; j++) {
        a = name[order[i]]; b = name[order[j]]
        if (f[b] / (r[b] > 0 ? r[b] : 1e-9) > f[a] / (r[a] > 0 ? r[a] : 1e-9)) { t = order[i]; order[i] = order[j]; order[j] = t }
    }
    for (i = 1; i <= nm; i++) {
        k = name[order[i]]
        printf "| `%s.idr` | %s | %s | %s倍高速 | %s |\n", k, r[k], f[k], ratio(r[k], f[k]), (k in pm) ? pm[k] : "(新規)"
    }
    hdr = 0
    for (i = 1; i <= nm; i++) {
        k = name[order[i]]
        if (!(k in pm) || pm[k] <= 0) continue
        if (r[k] > pm[k] * 1.10 && r[k] - pm[k] > 0.005) {
            if (!hdr) { print ""; print "回帰候補(rc2 >+10% かつ >5ms):"; hdr = 1 }
            printf "- %s: rc2 %s → %s (%+.0f%%), refc %s → %s (%+.0f%%)\n", k, pm[k], r[k], (r[k] / pm[k] - 1) * 100, pf[k], f[k], (pf[k] > 0 ? (f[k] / pf[k] - 1) * 100 : 0)
        }
    }
    if (!hdr) { print ""; print "回帰候補: なし" }
    if (length(cv) == 0) exit
    print ""
    print "| backend | avg(s) | 前回 avg(s) |"
    print "|---|---|---|"
    split("rc2 refc chez", bs, " "); split("rc2 RefC Chez", ls, " ")
    for (i = 1; i <= 3; i++)
        printf "| %s | %.2f | %s |\n", ls[i], cv[bs[i]], (ls[i] in pc) ? pc[ls[i]] : "-"
    printf "\nrc2: RefC比 %.2f倍、Chez比 %.2f倍(>1で rc2 が高速)\n", cv["refc"] / cv["rc2"], cv["chez"] / cv["rc2"]
}' "$LOG"
