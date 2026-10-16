# termui design

`termui` is a library for rich terminal UIs in the style of JavaScript's Ink:
a view is described with a layout EDSL, a layout engine computes the screen,
and only the difference from the previous screen is written to the terminal.
It does not use notcurses (which misbehaves under tmux); output is plain ANSI,
using `Control.ANSI.CSI` from contrib for cursor movement and erasing.

## Pipeline

```
Msg ──► update : Msg -> Model -> (Model, Cmd Msg)        TermUI.Program
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
| `TermUI.Program` | Elm-style `Program`, `Cmd`, `Sub`, focus, `runProgram` |

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

Not implemented: wrapping of children onto several lines, absolute
positioning, min/max sizes, percentage margins.

A `Style` applied over another one only adds: attributes are OR-ed, and a
colour left at `Default` is inherited, so a child cannot switch off a
parent's attribute or return to the terminal default colour. The natural size
is recomputed at each level (cost: depth times nodes); cache it if views get
large.

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

`newLoop` is called before `openTerminal`. It blocks SIGWINCH, SIGINT, SIGTERM,
SIGHUP and SIGPIPE in the calling thread and reads them through a signalfd;
together with the terminal input and the timerfds of `addTimer`/`addOneShot`
they are waited on with one epoll. `waitEvents` returns the events as values:
`EInput`, `EResize`, `ETimer`, `ETerminate` (at most one per wake-up),
`EEndOfInput` (the input was closed or failed; SIGPIPE is dropped, so a
closed output shows up as a failed write instead of killing the process).
A timer of 0 ms fires after 1 ms (an all-zero timerfd value would disarm it).

Input is decoded by `parseInput`, a pure incremental parser. A byte sequence
that may continue (a lone ESC, a half CSI, a half UTF-8 character) is kept until
the next read. The loop arms an internal 30 ms one-shot timer whenever such a
tail exists, so a lone ESC becomes the Escape key after 30 ms of silence on
the input even if timers or signals keep the loop busy; an incomplete CSI is
dropped at that time. An invalid UTF-8 sequence gives U+FFFD and decoding resumes
at the next byte that is not a continuation. A bracketed paste is accumulated
by the loop itself (the body in chunks, with the last five bytes held back so
that the closing sequence can be found across reads) and is never cut by the
timer. Mouse reports and unknown sequences are dropped.

Teardown: `closeTerminal` first, then `closeLoop`, which takes the signals still
pending before it unblocks them. Signals blocked in the creating thread do not
reach it, but threads started before the loop was created still get the default
action, so create the loop in the main thread before starting others. A
program killed by SIGKILL, SIGQUIT, or one that crashes, cannot restore the
terminal; SIGTSTP/SIGCONT are not handled (the screen is not redrawn).

## Programs

A `Program model msg` is `init : (model, Cmd msg)`, `update : msg -> model ->
(model, Cmd msg)`, `view : model -> Node msg` and `subs : model -> List (Sub msg)`.
`runProgram` (or `runProgramOn` for explicit descriptors) opens the terminal,
runs the commands of `init`, and then repeats: draw, wait for events, turn
them into messages, `update`. It returns the final model after a `Quit`, with
the terminal restored.

- `Cmd`: `Quit`, `Emit msg` (deliver at once), `After ms msg` (one-shot
  timer), `Perform (IO msg)` (run now, deliver the result; it blocks the loop,
  so it is meant for short actions), `Batch`.
- `Sub`: `OnInput` (keys, and pastes, that the focused node did not take),
  `OnResize`, `Every key ms msg` (a periodic timer; the runtime starts, stops
  and retimes timers when the list returned by `subs` changes, keyed by `key`;
  the key is global to the program, so components embedded in one another must
  not use the same one),
  `OnTerminate` (without it SIGINT/SIGTERM/SIGHUP and end of input quit).
- `Emit` and `Batch` run depth first, not through a queue, and `Perform`
  blocks the loop (signals wait too) until it returns. After a `Quit` the rest
  of the batch and of the events that arrived with it are dropped.
- Components compose as in Elm: a parent holds the child's model and wraps
  its messages, using `mapNode`, `mapCmd` and `mapSub` to embed the child's
  view, commands and subscriptions.

### Focus

The view marks nodes with `focusable (\focused => node) handler`. The runtime
numbers the focusables in tree order, keeps the index of the focused one
(clamped when the view changes) and builds the view again with `focused` set for
exactly that one. A key goes first to the handler of the focused node; if it
returns `Nothing` and the key is Tab or Shift+Tab, the focus moves (and wraps);
otherwise the key goes to the `OnInput` subscriptions. A handler that wants Tab
for itself (an editor) returns `Just` for it.

The handlers are rebuilt from the view after every event, so a handler
always sees the model the previous event produced. The focus is an index: if
focusables appear or disappear before the focused one, the focus moves to
whichever widget now has that index (it is clamped when there are fewer).

The screen is redrawn after every batch of events; the differ keeps the cost
proportional to what changed. A failed write makes the next draw a full one.

## Roadmap

1. Pure part: style, width, layout, painting, diff. Done.
2. Runtime: raw mode, key parser, event loop over epoll (input, SIGWINCH,
   timers), alternate screen, restore on exit. Done except for the mouse.
3. Elm-style programs: `Program`, `Cmd`, `Sub`, composition by mapping
   messages, focus managed by the runtime. Done.
4. Widgets: input field, list, scroll view, table, spinner, progress bar.
