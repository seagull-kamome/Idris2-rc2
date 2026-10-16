# termui

Rich terminal UIs for Idris2, in the spirit of Ink: describe a view with a
layout EDSL, let the layout engine compute the screen, and write only what
changed. Plain ANSI output (no notcurses), `rc2` backend (the runtime part
will use `rc2base`).

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

Status: the pure part (style, width, layout, painting, frame diff) is
implemented; the terminal runtime and the Elm-style program model are next.
See [`doc/design.md`](doc/design.md).

## Build & test

```sh
source ../../env.sh
tests/verify.sh      # type-check, install into install/, run the tests with rc2
```
