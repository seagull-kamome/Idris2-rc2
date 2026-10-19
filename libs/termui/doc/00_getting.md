# termui: a tour

**Describe the screen. termui draws it.**

```
╭──────────────────────────────────────────╮
│                                          │
│ todo                                   ⠸ │
│                                          │
│ add: ┌──────────────────────────────┐    │
│      │buy tea                       │    │
│      └──────────────────────────────┘    │
│                                          │
│ ┌──────────────────────────────────────┐ │
│ │> milk                                │ │
│ │  bread                               │ │
│ │  eggs                                │ │
│ │                                      │ │
│ │                                      │ │
│ └──────────────────────────────────────┘ │
│                                          │
│ Tab: switch   Enter: add   Esc: quit     │
│                                          │
╰──────────────────────────────────────────╯
```

That is a working to-do list: a text field, a list you can walk with the
arrow keys, a spinner on a timer, Tab to move between the parts, mouse
clicks too. The whole program is about 50 lines, and it is in
[section 6](#6-widgets-and-focus).

You never move a cursor and never print an escape sequence. You write a
function from your program's state to a tree of boxes. termui computes the
layout, paints it, and writes only the cells that changed.

This tour is for someone who has never used termui. You need Idris2. You do
not need to know the Elm architecture or CSS flexbox; both are explained as
far as termui uses them. Every program in this guide was compiled and run.

| | |
|---|---|
| [1. Try it](#1-try-it) | build and run the demo in three commands |
| [2. Draw a view](#2-draw-a-view) | the layout language, with no terminal needed |
| [3. A first program](#3-a-first-program) | a counter: model, update, view |
| [4. Layout](#4-layout) | rows, columns, borders, overlays |
| [5. Colour and text](#5-colour-and-text) | styles, wide characters |
| [6. Widgets and focus](#6-widgets-and-focus) | the to-do list above |
| [7. Commands and subscriptions](#7-commands-and-subscriptions) | timers, tasks, quitting |
| [8. The mouse](#8-the-mouse) | clicks, wheel, double click |
| [9. Gotchas](#9-gotchas) | what surprises people |
| [10. Next](#10-next) | examples and the reference |

## 1. Try it

termui is the package `libs/termui`, built for the `rc2` backend (it depends
on `contrib` and `rc2base`).

```sh
source env.sh                                    # at the repository root
(cd libs/termui && idris2 --install termui.ipkg)  # install the package
cd libs/termui/examples && ./rundemo.sh          # run the demo
```

`rundemo.sh` compiles `Demo.idr` and runs it. Press Tab, click around, type
into the field, press Esc to leave.

To build your own file:

```sh
idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -o hello Hello.idr
./build/exec/hello
```

> **Always pass `--cg rc2`.** Without it Idris2 falls back to its default
> backend, which cannot build programs that use `rc2base`. To compile and run
> in one step use `--exec main` instead of `-o hello`.

A program that takes over the terminal must be started from one. If standard
input or output is not a terminal, `runProgram` returns `Left ENOTTY` and
draws nothing.

## 2. Draw a view

Start with no terminal at all. `render` lays a view out on a screen of a given
size and gives you the cells; `frameLines` turns them into text.

```idris
module Main

import TermUI.Frame
import TermUI.Node
import TermUI.Style

main : IO ()
main = do
  frame <- render view 30 8
  frameLines frame >>= traverse_ putStrLn
  where
    view : Node ()
    view =
      box [border Rounded, padding 1, gap 1]
        [ styled (withAttr Bold plain) "Hello, termui"
        , row [justify JBetween] [ text "left", text "right" ]
        ]
```

```
╭────────────────────────────╮
│                            │
│ Hello, termui              │
│                            │
│ left                 right │
│                            │
│                            │
╰────────────────────────────╯
```

- A view is a tree of `Node msg`. Leaves are `text "..."` and
  `styled style "..."`. `box props children` stacks children top to bottom;
  `row props children` puts them side by side.
- `msg` is the type of message the widgets in the tree can send. A tree with
  no widgets can have any `msg`; here it is `()`.
- The root fills the whole screen, which is why the frame is 30 cells wide
  though the text is shorter. Nodes are clipped at the edge of their parent,
  so give the screen enough rows. With 5 rows the example above would show
  only the frame.
- `border Rounded` is a `Prop`, a function `Props -> Props`. `box` applies the
  list in order, so a later property overrides an earlier one.

This is the quickest way to experiment with layout: change the view, rerun,
read the picture.

## 3. A first program

An interactive program is a **model**, a way to **update** it, and a **view**
of it. That is the Elm architecture. A `Program model msg` has four fields:

| field    | type                               | role                                  |
|----------|------------------------------------|---------------------------------------|
| `init`   | `(model, Cmd msg)`                 | the starting state and a first command |
| `update` | `msg -> model -> (model, Cmd msg)` | the new state after a message         |
| `view`   | `model -> Node msg`                | what the screen shows for a state     |
| `subs`   | `model -> List (Sub msg)`          | which events the program listens to   |

The runtime turns key presses, timers and so on into messages, feeds them to
`update` one at a time, calls `view` on the new model and draws the
difference. Nothing else touches the screen.

A counter:

```
╭──────────────────────────────╮
│                              │
│ count = 2                    │
│ + / -: change   q: quit      │
│                              │
╰──────────────────────────────╯
```

```idris
module Main

import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style

%default covering

data AppMsg = Inc | Dec | Quit'

appUpdate : AppMsg -> Int -> (Int, Cmd AppMsg)
appUpdate Inc n = (n + 1, NoCmd)
appUpdate Dec n = (n - 1, NoCmd)
appUpdate Quit' n = (n, Quit)

appView : Int -> Node AppMsg
appView n =
  box [border Rounded, padding 1]
    [ styled (withAttr Bold plain) ("count = " ++ show n)
    , styled (withAttr Dim plain) "+ / -: change   q: quit"
    ]

appSubs : Int -> List (Sub AppMsg)
appSubs _ = [ OnInput key ]
  where
    key : Input -> Maybe AppMsg
    key (Press (KChar '+') _) = Just Inc
    key (Press (KChar '-') _) = Just Dec
    key (Press (KChar 'q') _) = Just Quit'
    key (Press (KChar 'c') mods) = if mods.ctrl then Just Quit' else Nothing
    key _ = Nothing

main : IO ()
main = do
  r <- runProgram (MkProgram (0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("needs a terminal: " ++ show e)
    Right n => putStrLn ("final count: " ++ show n)
```

Build it as in section 1, press `+`, `-`, then `q`.

How it works:

- **`OnInput f`** is a subscription. Each key press (and paste) that no
  focused widget took goes to `f`. `Just msg` sends `msg` to `update`;
  `Nothing` ignores the key. A key is `Press key mods`: `key` is `KChar c`,
  `KEnter`, `KEscape`, `KUp`, `KF 1` and so on, and `mods` has the flags
  `shift`, `ctrl` and `alt`.
- **Ctrl-C is just a key.** The terminal is in raw mode, so it does not
  interrupt the program. It arrives as `Press (KChar 'c')` with `ctrl` set,
  and you decide what it means. If you ignore it, the user cannot get out.
- **`Quit`** is a command. `update` returns it next to the model and the
  runtime stops. `runProgram` restores the terminal and then returns
  `Right finalModel`, so you can print a result on a normal screen.
- **`Left`** from `runProgram` is the "not a terminal" case of section 1.

> **Naming.** Call your functions `appUpdate`, `appView`, `appSubs`, not
> `update`, `view`, `subs`: those are the field names of `Program`, in scope
> after `import TermUI.Program`, and a top-level `update` gives baffling type
> errors. For the same reason name your model and message types `AppModel` and
> `AppMsg` when you import widgets, since every widget module has its own
> `Model` and `Msg`.

## 4. Layout

termui implements a small subset of CSS flexbox. A box lays its children out
along its **main axis**: down for `box` (also called `column`), across for
`row`. All sizes are in terminal cells.

```idris
box [border Single, padding 1, gap 1]   -- a column inside a frame
  [ text "title"
  , row [gap 2] [ text "a", text "b" ]  -- side by side, 2 cells apart
  , spacer                              -- takes all the leftover space
  , text "footer"
  ]
```

The properties to reach for first:

| property | effect |
|----------|--------|
| `border b` | `Single`, `Rounded`, `DoubleLine`, `Heavy`, `Ascii` or `NoBorder` |
| `borderColor c` | colour of the border |
| `padding n`, `paddingXY x y` | space inside the border |
| `margin n`, `marginXY x y` | space outside the box |
| `gap n` | space between children |
| `width d`, `height d` | `Auto` (default), `Cells n`, or `Percent p` of the parent |
| `minWidth`, `maxWidth`, `minHeight`, `maxHeight` | bounds on the size |
| `grow n`, `shrink n` | share of the leftover space taken, or given back |
| `justify j` | along the main axis: `JStart`, `JCenter`, `JEnd`, `JBetween`, `JAround` |
| `align a` | across it: `Start`, `Center`, `End`, `Stretch` (default) |
| `style s` | the box's style; its background fills the box, the rest is inherited |
| `wrapChildren` | a row that is too full goes on in a new line |
| `absolute`, `top`, `left`, `right`, `bottom` | take the box out of the flow and place it |

Rules of thumb:

- A box's width and height include its border and padding. Margins lie
  outside.
- Children get their natural size first. Leftover space is shared by `grow`:
  one child with `grow 1` takes all of it; `grow 1` and `grow 2` share it one
  to two. A deficit is taken back by `shrink`.
- Across the main axis a child is stretched by default. In a column a box fills
  the width of its parent unless you give it a `width` or an `align`.
- Text wraps at words when it is wider than its box. `truncated style "..."`
  cuts it instead; `charWrapped` wraps at any character.

### Overlays

An `absolute` box leaves the flow, moves none of its siblings and is drawn
over them. This centres a dialog over the whole screen:

```idris
box [absolute, top 0, left 0, right 0, bottom 0, align Center, justify JCenter]
  [ box [border DoubleLine, padding 1] [ text "Are you sure?" ] ]
```

```
┌────────────────────────────────┐
│                                │
│ main p╔═══════════════╗        │
│       ║               ║        │
│       ║ Are you sure? ║        │
│       ║               ║        │
│       ╚═══════════════╝        │
│                                │
└────────────────────────────────┘
```

Put it last among the children so it is drawn on top. Since a view is a plain
function of the model, showing and hiding a dialog is an `if`:

```idris
box [] ([ mainPart ] ++ (if m.help then [ helpDialog ] else []))
```

Every rule, including how sizes are decided, is in the "Layout semantics"
section of [`design.md`](design.md).

## 5. Colour and text

`styled style "text"` draws text in a `Style`; a newline starts a new line. A
`Style` begins as `plain` (everything inherited) and you add to it:

```idris
withAttr Bold plain                          -- bold
fgColor red (withAttr Underline plain)       -- red and underlined
bgColor (RGB 0 40 80) plain                  -- 24-bit background
```

- **Attributes:** `Bold`, `Dim`, `Italic`, `Underline`, `Inverse`, `Strike`.
- **Colours:** the eight ANSI names (`black`, `red`, `green`, `yellow`,
  `blue`, `magenta`, `cyan`, `white`), `bright red` and so on, `Indexed n`
  for the 256-colour palette, and `RGB r g b`.
- **Inheritance:** a style set on a box with `style s` flows to everything
  inside it. A colour left at `Inherit` is the parent's; `Default` is the
  terminal's own colour. `withoutAttr` switches off an attribute the parent
  has on.

**Wide characters just work.** Widths follow `wcwidth`: Japanese and other East
Asian wide characters and emoji take two cells, and layout and cursor movement
count cells, not characters. A combining mark needs its base character in the
same `text`.

## 6. Widgets and focus

Keys do not go to `OnInput` first. They go to the **focused** node. A node
that can take the focus is a `focusable`, and widgets such as text fields and
lists wrap themselves in one. The runtime numbers the focusables in tree order
and keeps one focused. Tab and Shift-Tab move the focus, and so does a mouse
click. A key the focused widget does not use (Tab, Escape, Ctrl-C and others)
falls through to the `OnInput` subscriptions.

A widget is a small Elm program of its own: a `Model`, a `Msg`, an `update`
and a view. The parent keeps the widget's model, wraps the widget's messages
in one of its own, and hands them back to the widget's `update`.

Here is the to-do list from the top of this page: a field to add items, a
list, and a spinner while a pretend save runs.

```idris
module Main

import Data.List
import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Widget.Display
import TermUI.Widget.Select as S
import TermUI.Widget.TextInput as T

%default covering

record AppModel where
  constructor MkModel
  input : T.Model
  items : S.Model
  tick : Nat
  busy : Bool

data AppMsg = Edit T.Msg | Pick S.Msg | Add | Tick | Saved | Quit'

appUpdate : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
appUpdate (Edit e) m = ({ input $= T.update e } m, NoCmd)
appUpdate (Pick p) m = ({ items $= S.update p } m, NoCmd)
appUpdate Add m =
  case T.value m.input of
    "" => (m, NoCmd)
    s => ({ input := T.empty 30, busy := True, items $= S.setItems (m.items.items ++ [s]) } m,
          After 800 Saved)
appUpdate Tick m = ({ tick $= S } m, NoCmd)
appUpdate Saved m = ({ busy := False } m, NoCmd)
appUpdate Quit' m = (m, Quit)

appView : AppModel -> Node AppMsg
appView m =
  box [border Rounded, padding 1, gap 1]
    [ row [justify JBetween]
        [ styled (withAttr Bold plain) "todo"
        , if m.busy then spinner m.tick else text "saved"
        ]
    , row [gap 1] [ text "add:", box [border Single] [T.field Edit (Just Add) m.input] ]
    , box [border Single, height (Cells 7)] [S.list Pick m.items]
    , styled (withAttr Dim plain) "Tab: switch   Enter: add   Esc: quit"
    ]

appSubs : AppModel -> List (Sub AppMsg)
appSubs m =
  [ OnInput (\i => case i of
                     Press KEscape _ => Just Quit'
                     _ => Nothing)
  ] ++ (if m.busy then [Every "spin" 100 Tick] else [])

main : IO ()
main = do
  let m0 = MkModel (T.empty 30) (S.fromList 5 []) 0 False
  r <- runProgram (MkProgram (m0, NoCmd) appUpdate appView appSubs)
  case r of
    Left e => putStrLn ("needs a terminal: " ++ show e)
    Right m => putStrLn ("bye, " ++ show (length m.items.items) ++ " items")
```

Type something and press Enter. Tab moves between the field and the list; Up
and Down choose an item.

What to take from it:

- `import ... as T` keeps each widget's `Model`, `Msg` and `update` apart.
- `T.field Edit (Just Add) m.input` is the view of a text field. `Edit` wraps
  the field's messages into yours. `Just Add` is the message sent when Enter
  is pressed in the field; pass `Nothing` for no reaction. A field takes Enter
  while it has the focus, so `OnInput` does not see it.
- In `appUpdate` each widget message goes to that widget's own `update`.
  `{ input $= T.update e } m` applies the function to the `input` field of `m`.
- **The state decides the screen and the events.** `spinner` is drawn only
  while `busy`, and `Every` is subscribed only while `busy`. No code starts or
  stops the timer; the runtime compares the subscription list after each
  update.

### The widget shelf

| module | widget | what it is |
|--------|--------|------------|
| `TermUI.Widget.TextInput` | `field` | one-line field with selection, undo and a clipboard of its own |
| `TermUI.Widget.TextArea` | `area` | multi-line editor, optionally with soft wrapping |
| `TermUI.Widget.Select` | `list` | scrolling list with one selected item |
| `TermUI.Widget.Scroll` | `viewer` | read-only scrolling text |
| `TermUI.Widget.Table` | `table` | table with a fixed header and a scrolling body |
| `TermUI.Widget.Checkbox` | `checkbox` | `[x] label`; the parent keeps the Bool and flips it on the message |
| `TermUI.Widget.Button` | `button` | `Framed`, `Flat` or `Link` (underlined, like a hyperlink) |
| `TermUI.Widget.MenuBar` | `menuBar` | a bar of titles with drop-down menus; put it last in the root box and leave its first row free |
| `TermUI.Widget.KeyGuide` | `keyGuide` | a row such as `F1 Help  F2 Save`; clicking a hint sends its message, and `keyInput` turns the F-keys into the same messages |
| `TermUI.Widget.TabStrip` | `tabStrip`, `tabbed` | tabs with one active; `tabbed` adds the framed pane of its content |
| `TermUI.Widget.Splitter` | `splitter` | two panes with a divider you move with the arrow keys or drag with the mouse |
| `TermUI.Widget.Display` | `spinner`, `progressBar`, `table` | static pieces without focus; `spinner` advances with a tick you count |

The height of a list, viewer, table or editor is part of its model
(`S.fromList 5 items` shows five rows), so a widget and its view always agree
on it. The key bindings of each widget are in the "Widgets" section of
[`design.md`](design.md).

If focusables of the same kind come and go while the program runs, give them
names with `keyed "name" node`. The focus then stays with the widget of that
name instead of a position in the tree.

## 7. Commands and subscriptions

`update` answers each message with a new model and a **`Cmd`**: something for
the runtime to do. `subs` says which events to listen to.

### Commands

| command | meaning |
|---------|---------|
| `NoCmd` | nothing |
| `Batch [c1, c2]` | several commands, in order |
| `Quit` | stop; the rest of the queue is dropped |
| `Emit msg` | send a message to `update`, behind those already waiting |
| `After ms msg` | send a message after `ms` milliseconds |
| `Perform io` | run `io : IO msg` now and send its result; the screen waits, so keep it short |
| `RunTask task` | run a `Control.Task` task beside the program and send the message it ends with; the screen stays alive |
| `RunTaskAs name task`, `CancelTask name` | the same, with a name, so a newer task replaces the older one |
| `SetClipboard text` | put text in the desktop clipboard (OSC 52; some terminals ignore it) |
| `Suspend` | stop as Ctrl-Z does in a shell, and redraw on return |

For slow work (a network request, a big file) use `RunTask`. `blocking` from
`Control.Task` runs an action that may block on a worker thread and brings the
result back as a message; see `libs/rc2base/doc/task.md`.

### Subscriptions

| subscription | meaning |
|--------------|---------|
| `OnInput f` | keys and pastes the focused widget did not take |
| `OnMouse f` | every mouse event; turns mouse reporting on |
| `MouseFocus` | clicks move the focus, the wheel goes to the widget under the pointer; turns reporting on |
| `OnResize f` | the screen size, once at the start and after each change |
| `Every key ms msg` | send `msg` every `ms` milliseconds; `key` names the timer |
| `OnTerminate msg` | SIGINT, SIGTERM and SIGHUP arrive as a message; without it they quit the program |

`subs` is evaluated again after every update. A timer starts when its `Every`
appears in the list and stops when it leaves.

**Order.** Messages are handled one at a time, in the order sent. If handling
A returns `Emit B` and `Emit C`, they run behind any message already waiting,
then B, then C, and whatever B emitted comes behind C.

**Parts.** To split a program, give each part its own `Model`, `Msg`,
`update`, `view` and `subs`. The parent embeds a part with `mapNode`,
`mapCmd` and `mapSub`, which wrap the part's messages in the parent's. If two
parts use the same timer key, wrap each part's subscriptions in
`scopeSub "name"`. The widgets are built this way.

## 8. The mouse

Mouse reporting is off by default, because it takes the mouse away from the
terminal's own text selection. Add **`MouseFocus`** to `subs` for what most
programs want: a click moves the focus to the widget under the pointer, the
wheel scrolls it, and a click in a field or editor puts the cursor there. A
double click selects a word, a triple click the line.

For raw events use `OnMouse`. A `MouseEvent` has `button`, `action`, a `column`
and `row` counted from 0 at the top left, the modifiers and the click count.
Mouse events never reach `OnInput`.

## 9. Gotchas

- **Ctrl-C is a key.** See section 3. Always handle it, and consider
  `OnTerminate` so `kill` is treated the same way.
- **There is no `main` loop to write, and no `putStrLn` while running.**
  Printing to standard output would draw over the screen. Put what you have to
  say in the model and show it in the view, or print after `runProgram`
  returns.
- **Never block in `update` or `view`.** Both must return at once. Use `After`
  for delays and `RunTask` for slow work.
- **The cursor is not where you drew.** The real cursor stays hidden and
  parked, except in a focused text field, where it is placed so that an input
  method (IME) can show its candidates next to it. Put it elsewhere by marking
  a box with `cursorHere`.
- **Give a box a height if it must keep one.** An `Auto` height shrinks to the
  content. Lists and viewers take their height from the model, but the box
  around one needs a `height` or a `grow`.
- **Sizes are `Len`, not `Nat`.** Widths, heights, columns and rows are `Int32`
  (the alias `Len`, which `TermUI.Node` exports). A literal such as `Cells 7`
  needs no change; a `length` of a list does: use `count xs`, or `cast`.
- **Keep `Every` keys to a small set.** The runtime remembers every key it has
  seen, so a key built from an ever-growing counter is a leak.
- **Compile with `rc2` and run under a UTF-8 locale.** rc2 programs need one
  for wide characters to come out right.
- **A killed program leaves the terminal in raw mode.** `kill -9` and a crash
  cannot restore it. Type `reset`, even if you cannot see what you type.

## 10. Next

- [`examples/Demo.idr`](../examples/Demo.idr): field, list, editor, spinner,
  progress bar and a dialog together. Run it with `examples/rundemo.sh`.
- [`examples/Editor.idr`](../examples/Editor.idr): a small text editor with a
  help viewer, clipboard and Suspend.
- [`design.md`](design.md): the reference. Layout rules, the input parser, how
  the diff is written, every widget's key bindings, and how focus, mouse and
  signals are handled.
- `libs/rc2base/doc/task.md`: `Control.Task`, behind `RunTask`.
- `tests/`: each directory is a small program that drives one feature and
  checks the output. They also show the pure functions (`render`, `layout`,
  `parseInput`) used on their own.
