# termui design

`termui` is a library for rich terminal UIs in the style of JavaScript's Ink:
a view is described with a layout EDSL, a layout engine computes the screen,
and only the difference from the previous screen is written to the terminal.
It does not use notcurses (which misbehaves under tmux); output is plain ANSI,
using `Control.ANSI.CSI` from contrib for cursor movement and erasing.

## Pipeline

```
Msg ──► update : Model -> Msg -> (Model, Cmd Msg)        (stage 3)
                         │
                  view : Model -> Node Msg                TermUI.Node
                         │
                  layout                                  TermUI.Layout   pure
                         │
                  paint into a Frame                      TermUI.Frame
                         │
                  diff against the previous Frame         TermUI.Output
                         ▼
                  one string, one write(2)
```

Everything up to the diff is independent of a real terminal. A frame can be
dumped as text (`frameLines`), which is how the tests look at results.

## Modules

| Module | Role |
| --- | --- |
| `TermUI.Style` | `Color` (default, 256-colour index, RGB), `Attr`, `Style` |
| `TermUI.Width` | cell width of a character (0, 1 or 2) |
| `TermUI.Node` | the EDSL: `box`, `row`, `column`, `text`, `spacer`, props |
| `TermUI.Layout` | flexbox-like placement, text wrapping |
| `TermUI.Frame` | cell grid, painter, `render` |
| `TermUI.Output` | frame diff to ANSI, SGR generation |
| `TermUI.Input` | decoding of terminal input into key and paste events |
| `TermUI.Terminal` | raw mode, alternate screen, window size, byte I/O |
| `TermUI.Loop` | epoll loop over input, signals and timers, producing `Event`s |

## Layout semantics

A subset of CSS flexbox. Sizes are in cells.

- A box's `width`/`height` are those of its border box (border and padding
  included). Margins lie outside it. `Auto`, `Cells n` and `Percent p` (of the
  parent's inner size) are available.
- The root node fills the screen; its own `width`/`height` are ignored.
- `direction` selects the main axis (`Column` is the default, as in Ink).
  Children get their natural size on the main axis, then leftover space is
  distributed by `grow`, or a deficit is taken back by `shrink` (weighted by
  the base size). Remainders go to the first children, so the result is
  deterministic.
- `justify` places the (possibly leftover) space on the main axis; `align`
  places children on the cross axis. `Stretch` (the default) fills the cross
  axis of children whose size is `Auto`.
- Text wraps at word boundaries (`WrapWords`), at any character (`WrapChars`)
  or is cut (`Truncate`). A word longer than the line is broken, and a
  trailing newline does not start a further line. Text is clipped to its
  box, and children are clipped to the content box of their parent (inside
  border and padding).
- The natural size of a node is computed for a given available width, so
  wrapped text takes the height it needs once its width is known. A row
  first distributes its width among the children and then measures their
  heights at the widths they got.
- A shrinking item never goes below zero; the deficit it cannot absorb is
  redistributed among the others. `JAround` drops the remainder of the
  division, `JBetween` gives it to the first gaps.

Not implemented (stage 1): `wrap` of children onto several lines, absolute

A `Style` applied over another one only adds: attributes are OR-ed, and a
colour left at `Default` is inherited, so a child cannot switch off a
parent's attribute or return to the terminal default colour. The natural size
is recomputed at each level (cost: depth times nodes); cache it if views get
large.positioning, min/max sizes, percentage margins.

## Characters

Widths follow `wcwidth(3)`: control and combining characters take 0 cells,
East Asian wide/fullwidth characters and emoji take 2, the rest 1. A wide
character occupies a cell plus a continuation cell (`'\0'`) with the same
style. Zero-width characters are dropped when painting: grapheme clusters
(combining marks, emoji ZWJ sequences, variation selectors) are not
composed. A wide character that does not fit at the right edge of its box is
replaced by a space.

## Diff output

The painter writes into a fresh `Frame` for every view; `diffFrames` compares
it cell by cell with the previous one.

- Only changed cells are written. A cursor move is emitted when the next
  changed cell is not where the cursor already is; the SGR sequence is
  emitted only when the style differs from the last written cell.
- SGR is always "reset and set" (`ESC[0;...m`), which is robust at a small
  cost in bytes.
- With no previous frame, or after a size change, the screen is erased first
  and cells equal to a blank default cell are skipped.
- After writing the last column the cursor position is considered unknown
  (pending wrap), so the next write always repositions.

## Runtime

`openTerminal` puts the input in raw mode (`cfmakeraw`, `VMIN=1`) and writes
the sequences that switch to the alternate screen, hide the cursor and turn
on bracketed paste; `closeTerminal` undoes all of it. Raw mode turns `ISIG`
off, so Ctrl-C arrives as a key (`Ctrl+KChar 'c'`) and the program decides what
to do with it.

`newLoop` blocks SIGWINCH, SIGINT, SIGTERM and SIGHUP in the calling thread
and reads them through a signalfd; together with the terminal input and the
timerfds of `addTimer` they are waited on with one epoll. `waitEvents`
returns the events as values: `EInput`, `EResize`, `ETimer`, `ETerminate`,
`EEndOfInput`.

Input is decoded by `parseInput`, a pure incremental parser. A byte sequence
that may continue (a lone ESC, a half CSI, a half UTF-8 character, an open
bracketed paste) is kept until the next read; a lone ESC that nothing follows
within 30 ms is the Escape key. Mouse reports and unknown sequences are
dropped.

Only the thread that created the loop receives the signals, so create it in
the main thread. A program killed by SIGKILL (or one that crashes) cannot
restore the terminal.

## Roadmap

1. Pure part: style, width, layout, painting, diff. Done.
2. Runtime: raw mode, key parser, event loop over epoll (input, SIGWINCH,
   timers), alternate screen, restore on exit. Done except for the mouse.
3. Elm-style programs: `Component` (model, msg, update, view, subs), `Cmd`,
   `Sub`, composition by mapping messages. Focus is managed by the runtime.
4. Widgets: input field, list, scroll view, table, spinner, progress bar.
