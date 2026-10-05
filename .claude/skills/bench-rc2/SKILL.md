---
name: bench-rc2
description: Measure rc2's performance with rc2/tests/bench.sh (micro-benchmarks vs upstream RefC, optionally the idris2-missing-containers external benchmark vs RefC and Chez) and record the results as a new dated entry at the top of rc2/BENCHMARKS.md, compared with the previous entry. Use whenever the user asks to benchmark rc2, "ベンチマークを取って", update BENCHMARKS.md, re-measure missing-containers, or asks whether rc2 got faster or regressed since the last measurement — even if they only mention one of these.
---

# Benchmark rc2 and update rc2/BENCHMARKS.md

Paths are relative to the `idris2-rc-cg` repo root. The file is
`rc2/BENCHMARKS.md` (plural), even if the user says "BENCHMARK.md".

## 1. Run bench.sh

```sh
LOG=install/bench-$(date +%Y%m%d).log
{ echo "rc2-cg: $(git rev-parse --short HEAD)$(git diff --quiet HEAD -- rc2/src rc2/support || echo ' (dirty)')"
  echo "missing-containers: $(git -C install/idris2-missing-containers rev-parse --short HEAD)"
} > "$LOG"
source env.sh && (cd rc2/tests && \
  { gcc --version | head -1; ./bench.sh --runs 5 --missing-containers; }) \
  >> "$LOG" 2>&1; echo "exit=$?" >> "$LOG"
```

The first lines of the log then say which commits and gcc were
measured, so the entry can quote them even if HEAD moves before it is
written. For an older log without them, write the current HEAD but say
so in the entry.

- **Source `env.sh` first.** bench.sh checks
  `command -v idris2` before it sources env.sh itself, so without this
  it stops at once with "no 'idris2' on PATH" (exit 2).
- `--runs 5` matches past entries; keep it so numbers stay comparable.
  Drop `--missing-containers` (which needs Chez Scheme as `scheme` on PATH) only if the user asks for
  micro-benchmarks alone.
- It rebuilds idris2-rc2 first and takes well over ten minutes. Start
  it with Bash `run_in_background` and wait for the completion notice
  (or on its PID). Don't poll with `pgrep -f`; the pattern matches the
  watcher itself.
- Don't run `rc2/tests/verify.sh` at the same time: both clean and use
  `rc2/tests/build/`.
- The log lives in `install/` (gitignored), never `/tmp`.

When it ends, check the log's last line is `exit=0` and that both the
`=== Micro-benchmarks` and `=== idris2-missing-containers` tables are
there. If not, report the failure from the log instead of writing an
entry.

## 2. Build the tables

```sh
.claude/skills/bench-rc2/compare.sh install/bench-YYYYMMDD.log
```

It prints the micro-benchmark table (sorted by speedup, with the
previous entry's rc2 time or `(新規)`), the regression candidates
with the matching refc change, the missing-containers table
with the previous averages, and the rc2 ratios. The previous entry is
the first `## ` section of BENCHMARKS.md, so run it **before** adding
the new section. Paste its tables as they are rather than retyping
numbers: rounding by hand has already produced a wrong ratio once.
Ignore the log's own `speedup` column; compare.sh recomputes it.

Full-suite entries (`## YYYY-MM-DD 追記`) go at the top, newest first.
The sections at the end of the file (e.g. 2026-09-24〜26) are notes on
single optimizations with their own A/B timings, taken differently;
don't use them as the previous entry.

## 3. Gather context

- Commits and gcc: from the head of the log (step 1).
- Changes since the previous entry: `git log --since=<its date>
  --oneline -- rc2/src`. Group them into a handful of themes; don't
  list every commit.

## 4. Write the entry

Insert right after the file's `# ` title line, above the previous
entry. Write in Japanese, matching the existing entries:

```markdown
## YYYY-MM-DD 追記: <what this measurement covers>

計測時点: idris2-rc-cg `<hash>`、idris2-missing-containers `<hash>`、<gcc version>。
`rc2/tests/bench.sh --runs 5 --missing-containers`(壁時計5回平均)。

<previous date>以降の`rc2/src`への主な変更(<N>コミット):

- ...

### マイクロベンチマーク一式(rc2 vs 本家`idris2 --cg refc`、壁時計5回平均)

<table from compare.sh>

<findings>

### 外部パッケージベンチマーク(idris2-missing-containers)

<table from compare.sh>

<findings>
```

Findings are short and factual:

- Regressions first: any benchmark present last time whose rc2 time
  grew beyond noise (say >10% and >5 ms). Name it; if none, say
  「回帰は無い」. Check that benchmark's refc time against the previous
  entry as well: refc is the same compiler both times, so if it slowed
  by a similar ratio the machine was slower, and only the excess is
  rc2's. Give the likely commits from the log, but don't claim a cause
  you haven't bisected.
- Notable gains, and whether rc2 vs Chez flipped.
- Times of a few ms are near the timer's resolution; say their ratios
  are only indicative.
- RefC and Chez themselves didn't change, so a shift of a few percent
  in their times is environment noise; mention it only as that.

## 5. Report, don't commit

Summarize for the user: the missing-containers numbers and ratios, any
regression, and where the entry went. Commit only when asked.
