# termui

Rich terminal UIs for Idris2, in the spirit of Ink: describe a view with a
layout EDSL, let the layout engine compute the screen, and write only what
changed. Plain ANSI output (no notcurses), `rc2` backend; the runtime uses `rc2base`.

```idris
view : Node ()
view =
  box [border Rounded, padding 1, gap 1]
    [ styled (withAttr Bold plain) "termui"
    , row [justify JBetween] [ text "left", text "right" ]
    ]

main : IO ()
main = do
  frame <- render view 40 6
  frameLines frame >>= traverse_ putStrLn
```

Status: the pure part (style, width, layout, painting, frame diff), the
terminal runtime (raw mode, key and mouse input, resize, timers, signals) and the
Elm-style program model with runtime-managed focus are implemented, with a
few widgets (text field, list, spinner, progress bar, table). A demo is in
[`examples/Demo.idr`](examples/Demo.idr).
See [`doc/design.md`](doc/design.md).

## Build & test

```sh
source ../../env.sh
tests/verify.sh      # type-check, install into install/, run the tests with rc2
```
