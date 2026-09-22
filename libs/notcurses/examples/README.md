# Manual verification examples

Each program below needs a **real terminal** (notcurses' `init` fails
outright against a pipe/file/CI sandbox) -- run these yourself after
`idris2 --install notcurses.ipkg` (see the top-level README.md's
"Build & test"). One build recipe, four programs:

```sh
cd idris2-rc-cg
source ./env.sh
# libidris2rc2notcurses is a static archive -- nothing of its own to
# find at runtime; notcurses-core stays a real shared library
# (support/rc2 has no .so of its own to add here).
INSTALLED_NOTCURSES_LIBDIR="$(nix-shell -p notcurses pkg-config --run 'pkg-config --variable=libdir notcurses-core')"
export LD_LIBRARY_PATH="$INSTALLED_NOTCURSES_LIBDIR:$LD_LIBRARY_PATH"

nix-shell -p gcc gmp pkg-config notcurses --run '
  ./rc2/build/exec/idris2-rc2 --cg rc2 -p notcurses -o Hello  libs/notcurses/examples/Hello.idr
  ./rc2/build/exec/idris2-rc2 --cg rc2 -p notcurses -o Colors libs/notcurses/examples/Colors.idr
  ./rc2/build/exec/idris2-rc2 --cg rc2 -p notcurses -o Boxes  libs/notcurses/examples/Boxes.idr
  ./rc2/build/exec/idris2-rc2 --cg rc2 -p notcurses -o Input  libs/notcurses/examples/Input.idr
'

./build/exec/Hello
./build/exec/Colors
./build/exec/Boxes
./build/exec/Input
```

| Program | Covers | Check for |
|---|---|---|
| `Hello.idr` | `init`/`stop`/`render`/`version`/`stdPlane`/`putStrAt` | Clean fullscreen enter+exit, terminal state fully restored after. |
| `Colors.idr` | `setFgRgb8`/`setBgRgb8`/`setFgAlpha`/`setBgAlpha`/`setStyles` | Gradient renders as actual colors, alpha row visibly fades, each style line looks like its name. |
| `Boxes.idr` | `createPlane`/`destroyPlane`/`movePlane`/`resizePlane`/`perimeterRounded`/`perimeterDouble` | Two distinct border styles, live move+resize on keypress (not a redraw-from-scratch). |
| `Input.idr` | `getBlocking`, `NCInput` fields, `NCKey.*`/`NCKeyMod.*` | Letters vs. special keys decode differently, modifiers show up if your terminal reports them, `q`/Esc quits cleanly. |

If a program exits immediately with `notcurses init failed`, stdout
isn't a real terminal (e.g. it's redirected, or you're running under
something that doesn't allocate a pty) -- run it directly in an actual
terminal emulator instead.
