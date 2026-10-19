# Borrow inference: measured and shelved (2026-10-07, numbers of 2026-10-14)

Moved from `TODO.md`, which keeps the conclusion. (Japanese: `ja/borrow-inference.md`.)

An inference that makes read-only arguments borrowed, to cut `dup`/`drop`, was examined.

- **Inferring before annotation (the pre-RC IR) does not fit rc2.** Most of the facts that decide borrowing
  (constructor reuse in `Reuse`, loop conversion in `MutualLoop`/`Loop`, the arguments `DualABI` makes native,
  `LateInline`) are settled after annotation, so the inference could only guess conservatively. On idris2-lsp it
  borrowed 5.9% of the arguments and cut the callers' `dup`s by 0.6%. Predicting whether a tail call becomes a
  loop is dangerous, so that is not done. The diagnostic code was set aside as
  `tmp/BorrowMeasure_preannotate.idr`.
- **Counting after annotation (the final IR)** with `tools/rcexpr-lint --borrow-stats` (an argument of a tail
  call is not borrowed; the callee gets ownership). 2026-10-14, master e4517c8, 12,705 definitions of
  idris2-lsp: 16.2% of the Boxed arguments can be borrowed (5,490 of 33,692). What blocks the rest: stored
  9,677, passed to an owning position 8,450, argument of a tail call that is not a loop 6,638, reused 1,252,
  `apply`/FFI 994, argument changed by the loop 613, returned 578, several reasons 5,433.
- **The effect.** Callee `drop`s removed 11,261 (530 in loops), callee `dup`s removed 510 (81), caller `dup`s
  removed 3,457 (1,042); against that, caller `drop`s added 7,081 (1,806, of which 2,906 are tail calls that
  stop being tail calls). The static net reduction is 8,147, 3.2% of all 251,732 `dup`/`drop`s. The weight
  inside loops is -153 (more is added than removed, so it can be a loss at run time). Definitions that need a
  wrapper with the owning convention (those referenced indirectly): 1,430. `dup`s of `case` fields (not counted
  as a net reduction under borrowing): 4,089 (1,859 in loops).
- **The trend.** The net reduction was 9,321 on 10-07 (3.2% of 284,067), 9,031 on 10-08 (3.5% of 256,350) and
  8,147 on 10-14 (3.2% of 251,732). Borrowing is not getting more effective; the change in the ratio comes from
  the denominator (PushDown, unboxing and FunDedup removed definitions and `dup`/`drop`s).
- **Decision:** not adopted in its current form. To revisit, start with two points: definitions that are only a
  `callRep` wrapper are excluded by "tail call that is not a loop", which may be too strict because at run time
  they are not trampolined; and whether the `dup` of a `case` field can be handled by borrowing (it can collide
  with reuse).
- **If the exclusion of tail-call arguments is lifted** (`--borrow-tail-stats`, idris2-lsp of 2026-10-08, the
  numbers as of then): keeping only candidates whose callee can borrow, the net reduction grows by +1,900 to
  +2,600 (0.7-1.0% of all), and the weight in loops goes from -214 to between -34 and -38, still negative. About
  70% of the gain is the tail-call `drop`s that are already counted and would disappear; only 27 credits fall
  inside loops. Most of the 13,905 excluded arguments (10,093 sites whose callee is an owning position) move
  only if borrow inference is widened to other arguments (fewer owning positions).
