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
| `TermUI.Widget.TextInput` | single-line text field |
| `TermUI.Widget.TextArea` | multi-line text editor |
| `TermUI.Widget.LineEdit` | what the text field and the editor share (characters kept, horizontal scrolling, cell to character) |
| `TermUI.Widget.Scroll` | read-only scrolling view of lines, with a scroll bar |
| `TermUI.Widget.Scrolling` | what the scrolling widgets share: the messages, the arithmetic, the keys |
| `TermUI.Widget.Table` | table that scrolls under a fixed header |
| `TermUI.Widget.ScrollBar` | the scroll bar |
| `TermUI.Widget.Select` | scrolling list with a selection |
| `TermUI.Widget.Display` | spinner, progress bar, table |

## Layout semantics

A subset of CSS flexbox. Sizes are in cells.

Sizes, coordinates and offsets on the screen are `Len` (`TermUI.Len`, an alias
of `Int32`), not `Nat`: a terminal is nowhere near 2^31 cells wide, and `Int32`
is a native `int32_t` in the code rc2 generates, where a `Nat` is a boxed
`Integer`. `Len` can be negative: `monus` is the subtraction that stops at 0, which the
layout uses where a size must not go below zero, and the property builders
(`width`, `padding`, `gap`, `top` ...), `newFrame`, `getCell` and `setCell` treat
a negative size as 0 and a negative position as outside. Counts and indexes
of items (a tab, a line of text) stay `Nat`, except in the list widgets
(`Select`, `Scroll`, `Table`), which keep their window and selection as `Len`.
`TextArea` still counts in `Nat` inside and takes `Len` at its edges.

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
  wrapped text takes the height it needs once its width is known. The widths
  of the children are decided first from what each wants when nothing limits
  it (`maxContent`: text not wrapped, linear in the size of the subtree), and
  distributed (a row by `grow`/`shrink`, a column by the alignment); then each
  child is measured once, at the width it got. Text that wraps therefore takes
  the width it is offered (as `fit-content` does in CSS), not the width of its
  longest line, so an `align Center` or `JEnd` does not shrink it into a narrower
  block; give the box a width to get that. The cost grows with the size of the
  tree times the square of its depth at worst (a 640-deep chain takes under a
  second); it used to double with every level.
- `minWidth`/`maxWidth`/`minHeight`/`maxHeight` bound the border box (the
  minimum wins over the maximum). They are applied to the base size of a child.
  A child that the bounds change after the distribution is fixed at the size
  they give and the room it frees or takes is shared among the others (the
  distribution is repeated until no bound is violated).
- `wrapChildren` on a row: the children go on in a new line when the next one
  does not fit in the width (as `flex-wrap`); the lines are `gap` apart, each
  line is distributed and justified by itself and the cross axis (`align`) is
  that of the line. A child wider than the row has a line of its own. A column
  wraps the same way, in the height it is placed in: its children go on in a new
  column to the right, `gap` apart, each column as wide as its widest child
  (`align` places the children across it). It needs a height of its own for its
  natural size; `maxContent` (the width a parent decides from) counts only its
  widest child, so give a wrapping column a width when it is among others.
- `absolute` takes a box out of the flow: it takes no room and does not move
  its siblings, and `top`/`right`/`bottom`/`left` place it in the content box of
  its parent (two opposite sides stretch an `Auto` size; a side not given is
  free; none given means the start). Its margins move it away from the sides
  it is placed by. It is drawn after the flow, so it covers what it overlaps. An overlay that centres its child is
  `box [absolute, top 0, left 0, right 0, bottom 0, align Center, justify JCenter] [child]`.
- A shrinking item never goes below zero; the deficit it cannot absorb is
  redistributed among the others. `JAround` drops the remainder of the
  division, `JBetween` gives it to the first gaps.

- `marginPercent`/`marginPercentXY` give margins in percent of the content width of
  the parent (on all sides, as in CSS), added to those in cells. The width a
  parent is sized by (`maxContent`) does not count them.

Not implemented: `Percent` for the height of a row's children before the
row's height is known.

A `Style` is a colour for the foreground and one for the background, the
attributes switched on and the attributes switched off. Applied over its
parent's style (`over`), a colour left at `Inherit` (the default) is the
parent's, `Default` is the terminal's own colour, an attribute switched on or
off by `withAttr`/`withoutAttr` wins and the others are the parent's. So a child
can turn off a parent's bold or go back to the terminal's colour. At the root
what is still inherited is the terminal's own (`settle`), and that is the style
a cell stores.

## Characters

Widths follow `wcwidth(3)`: control and combining characters take 0 cells,
East Asian wide/fullwidth characters and emoji take 2, the rest 1. A wide
character occupies a cell plus a continuation cell (`'\0'`) with the same
style. A combining mark (accents and the like, `isMark`) is kept with the cell
of the character before it, so that the terminal draws it there; it needs that
character in the same `Text` (one that starts a text has nothing to join and is
dropped). Other zero-width characters are dropped when painting: emoji ZWJ
sequences and variation selectors are not composed, because a terminal may
compose or widen what is around them and the cell grid could not follow. A
wide character that does not fit at the right edge of its box is replaced by a
space.

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
SIGHUP, SIGPIPE, SIGCONT, SIGTTOU and SIGTTIN in the calling thread and reads them through a signalfd;
together with the terminal input and the timerfds of `addTimer`/`addOneShot`
they are waited on with one epoll. `waitEvents` returns the events as values:
`EInput`, `EResize`, `ETimer`, `ETerminate` (at most one per wake-up),
`EResume` (SIGCONT), `EEndOfInput` (the input was closed or failed; SIGPIPE is dropped, so a
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
timer. Unknown sequences are dropped.

Teardown: `closeTerminal` first, then `closeLoop`, which takes the signals still
pending before it unblocks them. Signals blocked in the creating thread do not
reach it, but threads started before the loop was created still get the default
action, so create the loop in the main thread before starting others. A
program killed by SIGKILL, SIGQUIT, or one that crashes, cannot restore the
terminal.

A SIGTSTP sent from outside (`kill -TSTP`; raw mode turns the key Ctrl-Z into a
plain key, so the terminal never sends it) is blocked with the other signals and
read as the event `ESuspend`, which the runtime answers as it does a `Suspend`:
the terminal is restored before the program stops, so the shell can be used.

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
  `OnMouse` (see below),
  `OnResize` (the size is delivered once at the start as well), `Every key ms msg` (a periodic timer; the runtime starts, stops
  and retimes timers when the list returned by `subs` changes, keyed by the
  string `key`; a component wraps its subscriptions in `scopeSub name` so that
  its keys cannot meet those of another component; within a scope a key names one
  timer, and the runtime keeps every key it has seen, so the keys should come from a
  bounded set),
  `OnTerminate` (without it SIGINT/SIGTERM/SIGHUP and end of input quit).
- Messages are handled in the order they were sent, one `update` at a time. The
  messages an event or the `init` command send (`Batch [Emit B, Emit C]`, or
  several subscriptions answering one key) are queued first, and what handling
  them produces comes behind them: B, C, then the `D` that B emitted. `Perform` runs at once and blocks the loop
  (signals wait too) until it returns. After a `Quit` the rest of the batch, the
  queue and the events that arrived with it are dropped.
- `RunTask t` runs a `Control.Task` task beside the program (the scheduler is
  `rc2base`'s `Control.Task.Scheduler`, one per program): the message it ends
  with is delivered like that of `Emit`, and the loop does not stop while the
  task waits for a descriptor, a timer or other tasks, as it does for `Perform`.
  The scheduler's `pollFd` is one more descriptor of the loop (`watchFd`,
  event `EReady`), readable when a task was started, a completion or a timer
  is waiting; the loop then calls `turn sched 0`. Tasks run on the thread of
  the loop; `blocking` (`Control.Task`) runs an action that may block on one of
  up to four worker threads, started when the first one is needed (so a program
  that never uses it stays single-threaded), and the result comes back to the
  loop as the message of the task. `RunTaskAs key t`
  gives up the running task of that name first, and `CancelTask key` gives it up
  (what it waits for is cancelled; a step that has started is not interrupted).
  Tasks still running at the end of the program are forgotten.
- `SetClipboard text` puts the text in the clipboard of the desktop with OSC 52
  (`System.Console.Xterm`). Nothing tells whether the terminal did it: tmux needs
  `set-clipboard on` and many terminals ask for an option. `A.copyText msg model`
  and `T.copyText msg model` give the text a `Copy` or `Cut` is about to take, so an
  application answers with `maybe NoCmd SetClipboard (A.copyText e m.text)` next to
  `A.update e`. Reading the clipboard (a query the terminal answers) is not done.
- `Suspend` stops the program as a shell's Ctrl-Z would: the terminal is
  restored, the whole process group is stopped with SIGSTOP (so a program started
  by another one, as `idris2 --exec` does, stops with it and the shell sees the
  job stop) and, when continued, goes
  back to raw mode and draws the whole picture again. Raw mode turns Ctrl-Z
  into a key, so a program decides for itself to answer it with `Suspend`. A
  SIGCONT that arrives some other way (the program was stopped from outside by SIGSTOP)
  is the event `EResume` and does the same. If the terminal was resized while
  the program was stopped (nobody tells a stopped job), the new size is found
  out on the continue and `OnResize` is told.
- Components compose as in Elm: a parent holds the child's model and wraps
  its messages, using `mapNode`, `mapCmd` and `mapSub` to embed the child's
  view, commands and subscriptions.

### Mouse

`Mouse` is an `Input`: a `MouseEvent` has the button (`LeftButton`,
`MiddleButton`, `RightButton`, `WheelUp`, `WheelDown`, `NoButton`), the action
(`ButtonDown`, `ButtonUp`, `Drag`, `Move`), the position in cells from 0 at the
top left, and the modifiers. It is decoded from the SGR encoding (`ESC [ <
code ; column ; row M/m`). Reporting is switched on (`?1002h` and `?1006h`)
only while some `OnMouse` subscription exists, because it takes the mouse away
from the terminal's own text selection; it is switched off again when the
subscriptions go away and when the terminal is closed. Mouse events go to the
`OnMouse` subscriptions, never to `OnInput`.

`MouseFocus` is a subscription too: it turns reporting on and lets the runtime
use the mouse for the focus. The layout is kept after every draw, and the box
of every focusable is marked, so the runtime knows where each one is. A left
click moves the focus to the focusable under the pointer (the innermost, or the
later one where they overlap), and every mouse event over a focusable is also
offered to its handler, with the position made relative to the top left of
that node, so a widget can tell what was clicked: `Select` selects the clicked
line and takes the wheel as Up and Down, `TextInput` and `TextArea` put the cursor
under the pointer.

A press of the left button also carries `clicks`: the runtime counts the presses
at one cell that follow each other within 400 ms (`countClick`, pure and tested
with given times) and numbers them 1, 2, 3 and then 1 again; other events have 1.
`TextInput` and `TextArea` select the word under a double click, and the line
(for `TextInput`, the whole text) under a triple click.

The positions in a `MouseEvent` are absolute for `OnMouse` and relative to the
node's top left for a handler. The place of a focusable is cut to what is visible
(what its ancestors clip), and is renewed at every draw, so a click that arrives in
the same batch as an event that changes the layout is matched with the layout of
the previous draw.

### The terminal cursor

The cursor is hidden while the screen is drawn, but an input method (IME)
puts its candidate window at the cursor, wherever it was left, so the runtime
places it after every draw. A box marked with `cursorHere` says where: the focused
`TextInput` marks its cursor cell, and the cursor is shown there (an inverse cell
is drawn as well). With no such box the cursor is hidden and parked at the
bottom left. The position is sent only when it, or the screen, changed.

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
`keyed "name" widget` gives the focusable at the top of a node a key, and the
runtime remembers the key of the focused one: when the view changes, the focus
goes to the widget with that key wherever it is now (if it is gone, back to the
index). Keys are looked up in tree order; give each a different one.

The screen is redrawn after every batch of events; the differ keeps the cost
proportional to what changed. A failed write makes the next draw a full one.

## Widgets

A widget is a component in the Elm sense: a `Model`, a `Msg`, an `update` and
views. The stateful ones (`TextInput`, `Select`) also have `keyMsg : Input ->
Maybe Msg` and a view that wraps itself in `focusable`, so a parent writes

```idris
T.field Edit (Just Add) model.input   -- Edit : T.Msg -> AppMsg, Add on Enter
```

and gets the focus handling, the key handling and the cursor drawing. Keys the
widget has no meaning for (Tab, Alt-keys, Ctrl-C, Esc) are left to the focus
ring and to the `OnInput` subscriptions. Enter goes to the widget's `submit`
message if it has one; a field's Enter is therefore not seen by `OnInput`
while the field has the focus.

- `TextInput`: insert, Backspace, Delete, arrows, Home/End, Ctrl-A/E/B/F/K/U/D,
  paste. Shift with Left/Right/Home/End or a mouse drag selects (typing,
  Backspace, Delete or a paste replace the selection); Alt-A selects all, Alt-W
  copies, Ctrl-W cuts and Ctrl-Y pastes from a clipboard the model keeps, and
  Ctrl-_ / Ctrl-^ undo and redo (a run of typing is one step), as in `TextArea`.
  Line breaks and tabs become spaces and other control characters are
  dropped (also by `fromString`). The model knows the width of the field and
  how far it is scrolled, so the text scrolls only when the cursor would leave
  the field, and widths are counted in cells (a wide character takes two,
  a combining one none). The cursor is an inverse cell; over a character with no
  width it is a blank inverse cell. Grapheme clusters are not composed, so
  the cursor moves over each combining mark separately.
- `TextArea`: the keys of `TextInput` for the current line (Ctrl-A/E/K/U move to
  or delete up to the ends of the line), Enter for a line break, Up/Down with the
  column kept (in cells) across short lines, PageUp/PageDown (which move the
  viewport by a page together with the cursor), Ctrl-Home/Ctrl-End, Backspace and
  Delete that join lines, paste with line breaks (CR LF and a lone CR count as
  one), the mouse. By default lines are not wrapped; the view scrolls horizontally and
  vertically as little as needed (a line that fits is shown from its start) and
  has a scroll bar, whose column ignores clicks. `setWrap True` breaks long
  lines into rows instead (at the last space that fits, else where the width
  runs out; a space right after the full row hangs at its end). The row width is
  two cells less than the editor's, for the scroll bar and for the cursor at the
  end of a row. Up/Down and PageUp/PageDown then go by a row and keep the
  column, and clicks and drags land on rows; Home/End, Ctrl-A/E and
  Ctrl-Home/End stay on the logical line and the text. The viewport is
  `top` (a line) and `topRow` (a row of it), and the scroll bar counts
  logical lines. The model keeps the number of
  lines and the cursor line, so typing, Enter, the arrows, Backspace and Delete
  cost the length of the cursor line, not of the text. Replacing a selection,
  cutting, pasting, select-all, Ctrl-Home/End, paging and clicking far from the
  cursor line cost the size of the text (or the distance and the line length);
  `value` and `selectedText` too. `resize` changes the viewport. A combining mark
  is kept in the text and takes no cell; it is not drawn (the terminal cannot be
  asked to compose it, see the layout notes).
  - *Selection.* Shift with a move key (arrows, Home/End, PageUp/PageDown,
    Ctrl-Shift-Home/End) stretches it; so does dragging with the left button.
    Alt-A selects all. Typing, Enter or a paste replaces it, Backspace, Delete,
    Ctrl-K and Ctrl-U only remove it; a move without Shift drops it. Selected cells are drawn on a blue
    background, the cursor is inverse.
  - *Clipboard.* Alt-W copies, Ctrl-W cuts, Ctrl-Y pastes the editor's own
    clipboard (`clipboard` reads it, for a program that wants to hand it to
    the terminal); what the terminal pastes arrives as a bracketed paste.
  - *Undo.* Ctrl-_ undoes and Ctrl-^ redoes. A run of typed characters, of
    Backspaces or of Deletes is one step, any move starts a new one, a replaced
    selection is a step of its own (what is typed after it is another); an edit
    that changes nothing (Backspace at the start, an empty paste) leaves the
    history alone; a new edit forgets what could be redone; 100 steps are kept.
    Ctrl-Z is left to the application (the editor example suspends on it).
  - Columns for vertical moves are counted in cells, a click and a drag put the
    cursor under the cell.
- `Scroll`: a read-only list of lines in a window, scrolled by the arrows,
  PageUp/PageDown, Home/End and the wheel (three lines a notch); the bar on its
  right shows the position. `ScrollBar.scrollBar` is the bar alone.
- `Table`: a header that stays and a body that scrolls like `Scroll` (same messages
  and keys), with the bar on the right of the body. `Display.table` is the static
  version and `Display.tableRow` one row of either.

The height of the window of `Select`, `Scroll`, `Table` and `TextArea` is part of
their model (`fromList rows ...`, `resize rows`), so `update` and `view` cannot be
given different ones.
- `Select`: Up/Down, PageUp/PageDown, Home/End, a click on a line (a click below
  the last item is ignored) and the wheel, on a window that follows the selection;
  the selected line is inverse when focused, marked with `>` otherwise. A scroll
  bar sits on its right, outside of what takes keys and clicks. Keys with Ctrl,
  Alt or Shift are not taken. `setItems` keeps the selection where it still makes
  sense and `resize` changes the height of the window.
- `Checkbox`: `checkbox label checked toggle` draws `[x] label` or `[ ] label`
  and sends `toggle` for Enter, Space or a click; the parent keeps the Bool. The
  focused box is inverse. `Button`: `button look label press`, with `look` one
  of `Framed` (a rounded frame, heavy while focused), `Flat` (a grey
  background) and `Link` (underlined, bright blue, as a hyperlink); a focused
  button has an inverse label and sends `press` for Enter, Space or a click. Both
  are as wide as their text (they sit in a row), and a key with Ctrl or Alt is
  left to the application (`Activate.activates`).
- `MenuBar`: `menuBar wrap model` is a bar of titles with drop-down menus.
  A `Menu` has a title and `Entry`s: `Item label msg` or `Separator`. The bar
  is a focusable `absolute` box at the top left of its parent, in flow with
  the open menu, so the menu drops over what is below. A box clips its
  children, so the parent must be tall enough: the root of the view, or a
  box as tall as the screen; the application leaves the first row of it free.
  Left/Right move between titles, Down opens (Up and Down then move over the
  items and skip separators, wrapping), Enter or Space opens or chooses,
  Escape closes (when nothing is open it is left to the application), and a
  click on a title opens or closes its menu, on an item chooses it, anywhere
  else in the menu's box closes it. The menu is drawn open only while it has
  the focus. `update : Msg -> Model msg -> (Model msg, Maybe msg)` also returns
  the message of the item chosen, which the application sends on with `Emit`.
- `KeyGuide`: a row of function-key hints, `F1 Help  F2 Save`, the keys inverse.
  A list of `MkHint fkey label msg` draws the row (`keyGuide`) and gives the
  messages. The row takes the left mouse button itself: a click on a hint sends
  its message, a click between hints does nothing. It takes no key, so Tab moves
  on from it, but being a focusable it is one stop of the focus ring. The keys
  are the application's: `keyInput hints` for an `OnInput` subscription turns an
  F-key into the message of its hint (a key with Ctrl, Alt or Shift is not
  taken). `keyClick hints column` is the lookup behind the click, for an
  `OnMouse` subscription of one's own.
- `TabStrip`: ` One │ Two │ Three `, one tab active (inverse while the strip has
  the focus, bold and underlined otherwise). Left/Right, Home/End and a click
  choose the tab. The strip says which tab is active and the application shows
  its content; `tabbed wrap model contents` does that, the strip above a
  framed pane with the content of the active tab. A strip wider than its box
  is cut at the edge. The active tab is a `Fin (length titles)`, so it cannot
  go past the last tab (`activeIndex` reads it, `select` sets it, clamping to the
  last tab); a strip has at least one tab.
- `Splitter`: two panes with a divider between them, side by side (`LeftRight`)
  or stacked (`TopBottom`). The first pane has `size` cells (between `lo` and
  `hi`) and the second takes the rest. The divider is a one-cell grey strip,
  blue while it has the focus; the arrow keys along the split move it by a
  cell, and pressing it with the mouse holds it. A focusable only gets mouse
  events over itself, so while the divider is held a transparent cover over the
  whole splitter takes its place (with the same key) and turns the pointer
  position into the new size; Escape or a button let go ends the drag. A
  button let go outside the splitter is not seen by the cover: subscribe to
  `OnMouse (map wrap . releasing model)` while `held`. It needs mouse
  reporting (`MouseFocus`). Give each splitter its own `name`. The size is `lo` plus a `Fin (S span)`, so it stays
  between `lo` and `hi` whatever is done to the model (`size` and `hi` read them).
- `Display`: `spinner tick` (advance `tick` from an `Every` subscription),
  `progressBar cells percent` (never wraps), and `table columns rows` (cells cut
  at the column width, missing cells empty, extra cells dropped).

`examples/Demo.idr` puts the field, list and display widgets together;
`examples/Editor.idr` is a small editor with a help viewer.

## Roadmap

1. Pure part: style, width, layout, painting, diff. Done.
2. Runtime: raw mode, key parser, event loop over epoll (input, SIGWINCH,
   timers), alternate screen, restore on exit. Done except for the mouse.
3. Elm-style programs: `Program`, `Cmd`, `Sub`, composition by mapping
   messages, focus managed by the runtime. Done.
4. Widgets: input field, multi-line editor, list, scroll view, table, spinner,
   progress bar. Done; an asynchronous `Cmd` (a worker thread posting its
   result) is not.
