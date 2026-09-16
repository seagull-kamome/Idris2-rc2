||| Bindings to [notcurses](https://notcurses.com/)' `notcurses-core`
||| API (multimedia excluded -- no ffmpeg dependency). Functions
||| notcurses.h marks `API` (always a real, body-less symbol) bind
||| straight onto `libnotcurses-core` by name; everything else --
||| struct-by-pointer construction, `ncinput`-field caching, and every
||| function that only exists as a `static inline` body in notcurses'
||| own header -- goes through this package's own shim
||| (`support/c/nc_util.c`), the only translation unit that ever
||| touches the real `<notcurses/notcurses.h>` (no `libnotcurses-ffi`
||| dependency needed as a result). See `doc/notcurses.md` for the full
||| rationale and for what this package deliberately does not cover
||| (multimedia, plots, widgets, direct mode, the raw channel/cell
||| API, ...). `examples/` has runnable, manually-verifiable programs
||| covering everything below -- automated tests can only cover
||| build+link+`notcurses_version()`, since a real init needs a real
||| terminal.
module System.Notcurses

-- Copyright 2026, Hattori,Hiroki. All rights reserved.
-- This module was licensed by BSD3.

import System.FFI

-------------------------------------------------------------------------------
-- Raw FFI
-------------------------------------------------------------------------------

data RawNotcurses : Type where [external]
data RawNCPlane : Type where [external]

%foreign "C:idris2_isNull, libidris2_support, idris_support.h"
prim__isNull : AnyPtr -> PrimIO Int

-- idris2rc2notcurses (this package's own shim; struct-by-pointer
-- construction and ncinput-field caching -- see nc_util.h)

%foreign "C:idris2rc2_nc_init, libidris2rc2notcurses, nc_util.h"
prim__ncInit : Int -> Bits32 -> Bits32 -> Bits32 -> Bits32 -> PrimIO AnyPtr

%foreign "C:idris2rc2_ncplane_create, libidris2rc2notcurses, nc_util.h"
prim__ncplaneCreate : Ptr RawNCPlane -> Int -> Int -> Bits32 -> Bits32 -> String -> PrimIO AnyPtr

%foreign "C:idris2rc2_nc_get_blocking, libidris2rc2notcurses, nc_util.h"
prim__ncGetBlocking : Ptr RawNotcurses -> PrimIO Bits32
%foreign "C:idris2rc2_nc_get_nonblock, libidris2rc2notcurses, nc_util.h"
prim__ncGetNonblock : Ptr RawNotcurses -> PrimIO Bits32
%foreign "C:idris2rc2_nc_last_input_y, libidris2rc2notcurses, nc_util.h"
prim__ncLastInputY : PrimIO Int
%foreign "C:idris2rc2_nc_last_input_x, libidris2rc2notcurses, nc_util.h"
prim__ncLastInputX : PrimIO Int
%foreign "C:idris2rc2_nc_last_input_modifiers, libidris2rc2notcurses, nc_util.h"
prim__ncLastInputModifiers : PrimIO Bits32
%foreign "C:idris2rc2_nc_last_input_evtype, libidris2rc2notcurses, nc_util.h"
prim__ncLastInputEvtype : PrimIO Int
%foreign "C:idris2rc2_nc_last_input_utf8, libidris2rc2notcurses, nc_util.h"
prim__ncLastInputUtf8 : PrimIO String

%foreign "C:idris2rc2_nckey_invalid, libidris2rc2notcurses, nc_util.h"
prim__nckeyInvalid : Bits32
%foreign "C:idris2rc2_nckey_resize, libidris2rc2notcurses, nc_util.h"
prim__nckeyResize : Bits32
%foreign "C:idris2rc2_nckey_up, libidris2rc2notcurses, nc_util.h"
prim__nckeyUp : Bits32
%foreign "C:idris2rc2_nckey_down, libidris2rc2notcurses, nc_util.h"
prim__nckeyDown : Bits32
%foreign "C:idris2rc2_nckey_left, libidris2rc2notcurses, nc_util.h"
prim__nckeyLeft : Bits32
%foreign "C:idris2rc2_nckey_right, libidris2rc2notcurses, nc_util.h"
prim__nckeyRight : Bits32
%foreign "C:idris2rc2_nckey_ins, libidris2rc2notcurses, nc_util.h"
prim__nckeyIns : Bits32
%foreign "C:idris2rc2_nckey_del, libidris2rc2notcurses, nc_util.h"
prim__nckeyDel : Bits32
%foreign "C:idris2rc2_nckey_backspace, libidris2rc2notcurses, nc_util.h"
prim__nckeyBackspace : Bits32
%foreign "C:idris2rc2_nckey_pgup, libidris2rc2notcurses, nc_util.h"
prim__nckeyPgup : Bits32
%foreign "C:idris2rc2_nckey_pgdown, libidris2rc2notcurses, nc_util.h"
prim__nckeyPgdown : Bits32
%foreign "C:idris2rc2_nckey_home, libidris2rc2notcurses, nc_util.h"
prim__nckeyHome : Bits32
%foreign "C:idris2rc2_nckey_end, libidris2rc2notcurses, nc_util.h"
prim__nckeyEnd : Bits32
%foreign "C:idris2rc2_nckey_enter, libidris2rc2notcurses, nc_util.h"
prim__nckeyEnter : Bits32
%foreign "C:idris2rc2_nckey_f01, libidris2rc2notcurses, nc_util.h"
prim__nckeyF01 : Bits32
%foreign "C:idris2rc2_nckey_f02, libidris2rc2notcurses, nc_util.h"
prim__nckeyF02 : Bits32
%foreign "C:idris2rc2_nckey_f03, libidris2rc2notcurses, nc_util.h"
prim__nckeyF03 : Bits32
%foreign "C:idris2rc2_nckey_f04, libidris2rc2notcurses, nc_util.h"
prim__nckeyF04 : Bits32

-- libnotcurses-core (always-real, `API`-attributed symbols)

%foreign "C:notcurses_version, libnotcurses-core, nc_util.h"
prim__ncVersion : PrimIO String
%foreign "C:notcurses_stop, libnotcurses-core, nc_util.h"
prim__ncStop : Ptr RawNotcurses -> PrimIO Int
%foreign "C:ncplane_destroy, libnotcurses-core, nc_util.h"
prim__ncplaneDestroy : Ptr RawNCPlane -> PrimIO Int
%foreign "C:notcurses_stdplane, libnotcurses-core, nc_util.h"
prim__ncStdplane : Ptr RawNotcurses -> PrimIO AnyPtr
%foreign "C:ncplane_move_yx, libnotcurses-core, nc_util.h"
prim__ncplaneMoveYx : Ptr RawNCPlane -> Int -> Int -> PrimIO Int
%foreign "C:ncplane_cursor_move_yx, libnotcurses-core, nc_util.h"
prim__ncplaneCursorMoveYx : Ptr RawNCPlane -> Int -> Int -> PrimIO Int
%foreign "C:ncplane_erase, libnotcurses-core, nc_util.h"
prim__ncplaneErase : Ptr RawNCPlane -> PrimIO ()
%foreign "C:ncplane_set_fg_rgb8, libnotcurses-core, nc_util.h"
prim__ncplaneSetFgRgb8 : Ptr RawNCPlane -> Bits32 -> Bits32 -> Bits32 -> PrimIO Int
%foreign "C:ncplane_set_bg_rgb8, libnotcurses-core, nc_util.h"
prim__ncplaneSetBgRgb8 : Ptr RawNCPlane -> Bits32 -> Bits32 -> Bits32 -> PrimIO Int
%foreign "C:ncplane_set_fg_default, libnotcurses-core, nc_util.h"
prim__ncplaneSetFgDefault : Ptr RawNCPlane -> PrimIO ()
%foreign "C:ncplane_set_bg_default, libnotcurses-core, nc_util.h"
prim__ncplaneSetBgDefault : Ptr RawNCPlane -> PrimIO ()
%foreign "C:ncplane_set_fg_alpha, libnotcurses-core, nc_util.h"
prim__ncplaneSetFgAlpha : Ptr RawNCPlane -> Int -> PrimIO Int
%foreign "C:ncplane_set_bg_alpha, libnotcurses-core, nc_util.h"
prim__ncplaneSetBgAlpha : Ptr RawNCPlane -> Int -> PrimIO Int
%foreign "C:ncplane_set_styles, libnotcurses-core, nc_util.h"
prim__ncplaneSetStyles : Ptr RawNCPlane -> Bits32 -> PrimIO ()

-- Functions that only exist as `static inline` bodies in notcurses'
-- own header (previously bound against its separate "-ffi" build
-- variant) -- now wrapped by this package's own shim instead, which
-- confines the real header to nc_util.c alone and drops the
-- libnotcurses-ffi dependency entirely. See doc/notcurses.md.

%foreign "C:idris2rc2_nc_render, libidris2rc2notcurses, nc_util.h"
prim__ncRender : Ptr RawNotcurses -> PrimIO Int
%foreign "C:idris2rc2_ncplane_putstr, libidris2rc2notcurses, nc_util.h"
prim__ncplanePutstr : Ptr RawNCPlane -> String -> PrimIO Int
%foreign "C:idris2rc2_ncplane_putstr_yx, libidris2rc2notcurses, nc_util.h"
prim__ncplanePutstrYx : Ptr RawNCPlane -> Int -> Int -> String -> PrimIO Int
%foreign "C:idris2rc2_ncplane_resize_simple, libidris2rc2notcurses, nc_util.h"
prim__ncplaneResizeSimple : Ptr RawNCPlane -> Bits32 -> Bits32 -> PrimIO Int
%foreign "C:idris2rc2_ncplane_dim_y, libidris2rc2notcurses, nc_util.h"
prim__ncplaneDimY : Ptr RawNCPlane -> PrimIO Bits32
%foreign "C:idris2rc2_ncplane_dim_x, libidris2rc2notcurses, nc_util.h"
prim__ncplaneDimX : Ptr RawNCPlane -> PrimIO Bits32
%foreign "C:idris2rc2_ncplane_cursor_y, libidris2rc2notcurses, nc_util.h"
prim__ncplaneCursorY : Ptr RawNCPlane -> PrimIO Bits32
%foreign "C:idris2rc2_ncplane_cursor_x, libidris2rc2notcurses, nc_util.h"
prim__ncplaneCursorX : Ptr RawNCPlane -> PrimIO Bits32
%foreign "C:idris2rc2_ncplane_perimeter_rounded, libidris2rc2notcurses, nc_util.h"
prim__ncplanePerimeterRounded : Ptr RawNCPlane -> Bits16 -> Bits64 -> Bits32 -> PrimIO Int
%foreign "C:idris2rc2_ncplane_perimeter_double, libidris2rc2notcurses, nc_util.h"
prim__ncplanePerimeterDouble : Ptr RawNCPlane -> Bits16 -> Bits64 -> Bits32 -> PrimIO Int

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

||| Log verbosity for `init`. `Silent` is notcurses' own default (nothing
||| printed to stderr once fullscreen service begins).
public export
data LogLevel = Silent | Panic | Fatal | Error | Warning | Info | Verbose | Debug | Trace

logLevelCode : LogLevel -> Int
logLevelCode Silent = -1
logLevelCode Panic = 0
logLevelCode Fatal = 1
logLevelCode Error = 2
logLevelCode Warning = 3
logLevelCode Info = 4
logLevelCode Verbose = 5
logLevelCode Debug = 6
logLevelCode Trace = 7

namespace NCStyle
  ||| Bits for `setStyles`, notcurses.h's `NCSTYLE_*`. Plain small
  ||| integers (unlike the `NCKEY.*` codes below), stable to hardcode.
  public export
  none, struck, undercurl, underline, italic, bold, mask : Bits32
  none      = 0x0000
  struck    = 0x0001
  underline = 0x0008
  undercurl = 0x0004
  bold      = 0x0002
  italic    = 0x0010
  mask      = 0xffff

namespace NCKeyMod
  ||| Bits for `NCInput.modifiers`, notcurses.h's `NCKEY_MOD_*`. Plain
  ||| small integers, stable to hardcode.
  public export
  shift, alt, ctrl, super, hyper, meta, capslock, numlock : Bits32
  shift    = 1
  alt      = 2
  ctrl     = 4
  super    = 8
  hyper    = 16
  meta     = 32
  capslock = 64
  numlock  = 128

||| Whether an `NCInput` event was a press, a held-key repeat, or a
||| release (`notcurses.h`'s `ncintype_e`; `Unknown` when the terminal
||| protocol in use can't distinguish, e.g. legacy non-Kitty input).
public export
data NCEventType = UnknownEvent | Press | Repeat | Release

ncEventTypeFromCode : Int -> NCEventType
ncEventTypeFromCode 1 = Press
ncEventTypeFromCode 2 = Repeat
ncEventTypeFromCode 3 = Release
ncEventTypeFromCode _ = UnknownEvent

namespace NCKey
  ||| `NCKEY_TAB`/`NCKEY_ESC`: plain ASCII control codes in notcurses.h
  ||| (`0x09`/`0x1b`), not `preterunicode`-derived -- safe to hardcode,
  ||| unlike the rest of this namespace (backed by shim getters; see
  ||| nc_util.h's own comment on why).
  public export
  tab, esc : Bits32
  tab = 0x09
  esc = 0x1b

  export invalid : Bits32
  invalid = prim__nckeyInvalid
  export resize : Bits32
  resize = prim__nckeyResize
  export up : Bits32
  up = prim__nckeyUp
  export down : Bits32
  down = prim__nckeyDown
  export left : Bits32
  left = prim__nckeyLeft
  export right : Bits32
  right = prim__nckeyRight
  export ins : Bits32
  ins = prim__nckeyIns
  export del : Bits32
  del = prim__nckeyDel
  export backspace : Bits32
  backspace = prim__nckeyBackspace
  export pgup : Bits32
  pgup = prim__nckeyPgup
  export pgdown : Bits32
  pgdown = prim__nckeyPgdown
  export home : Bits32
  home = prim__nckeyHome
  export end : Bits32
  end = prim__nckeyEnd
  export enter : Bits32
  enter = prim__nckeyEnter
  export f01 : Bits32
  f01 = prim__nckeyF01
  export f02 : Bits32
  f02 = prim__nckeyF02
  export f03 : Bits32
  f03 = prim__nckeyF03
  export f04 : Bits32
  f04 = prim__nckeyF04

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

||| A live notcurses context. Exactly one per process -- notcurses
||| itself doesn't support more. Not GC-managed (unlike e.g.
||| `Text.Regex.RE2`'s `Regex`): `stop` restores the terminal
||| (alternate screen, cursor, echo, ...) and must run at a
||| deterministic point, not whenever the GC happens to collect it --
||| always pair `init` with `stop`, including on every error/exit path.
export
record Notcurses where
  constructor MkNotcurses
  ptr : Ptr RawNotcurses

||| A plane (the unit notcurses draws to -- the standard plane covering
||| the whole screen, or a sub-plane created with `createPlane`). Not
||| GC-managed, same reasoning as `Notcurses` -- `destroyPlane` an
||| explicitly-created plane once done with it (destroying the standard
||| plane is an error; it goes away with `stop`).
export
record NCPlane where
  constructor MkNCPlane
  ptr : Ptr RawNCPlane

||| Enters fullscreen mode against the current terminal (stdin/stdout).
||| `Nothing` on failure (e.g. `TERM` unset/unsupported, or stdout
||| isn't a real terminal at all -- notcurses needs an actual tty).
||| Margins are in cells, each 0 by default (render to the entire
||| screen).
export
init : (log : LogLevel) -> (marginT, marginR, marginB, marginL : Nat) -> IO (Maybe Notcurses)
init log marginT marginR marginB marginL = do
  raw <- primIO (prim__ncInit (logLevelCode log) (cast marginT) (cast marginR) (cast marginB) (cast marginL))
  isN <- primIO (prim__isNull raw)
  pure $ if isN /= 0 then Nothing else Just (MkNotcurses (prim__castPtr raw))

||| Restores the terminal to its pre-`init` state. `False` on failure
||| (still terminated either way -- there is no recovering `nc`
||| afterward).
export
stop : Notcurses -> IO Bool
stop nc = (== 0) <$> primIO (prim__ncStop nc.ptr)

||| Renders and rasterizes every plane onto the physical terminal.
||| Nothing is visibly drawn until this is called.
export
render : Notcurses -> IO Bool
render nc = (== 0) <$> primIO (prim__ncRender nc.ptr)

||| The running notcurses version string (e.g. `"3.0.17"`).
export
version : IO String
version = primIO prim__ncVersion

||| The plane spanning the whole terminal, created automatically by
||| `init`. Never destroy this one directly.
export
stdPlane : Notcurses -> IO NCPlane
stdPlane nc = MkNCPlane . prim__castPtr <$> primIO (prim__ncStdplane nc.ptr)

-------------------------------------------------------------------------------
-- Planes
-------------------------------------------------------------------------------

||| Creates a new plane bound to `parent` (pass `stdPlane`'s result for
||| a top-level plane), at `(y, x)` relative to `parent`'s origin, sized
||| `rows` x `cols` (both must be positive). `Nothing` on failure.
export
createPlane : (parent : NCPlane) -> (y, x : Int) -> (rows, cols : Nat) -> (name : String) -> IO (Maybe NCPlane)
createPlane parent y x rows cols name = do
  raw <- primIO (prim__ncplaneCreate parent.ptr y x (cast rows) (cast cols) name)
  isN <- primIO (prim__isNull raw)
  pure $ if isN /= 0 then Nothing else Just (MkNCPlane (prim__castPtr raw))

||| Destroys a plane created with `createPlane`. Never call this on
||| `stdPlane`'s result.
export
destroyPlane : NCPlane -> IO Bool
destroyPlane p = (== 0) <$> primIO (prim__ncplaneDestroy p.ptr)

||| `(rows, cols)` of a plane.
export
planeDim : NCPlane -> IO (Nat, Nat)
planeDim p = do
  y <- primIO (prim__ncplaneDimY p.ptr)
  x <- primIO (prim__ncplaneDimX p.ptr)
  pure (cast y, cast x)

||| Resizes a plane in place, keeping its top-left content anchored
||| (see notcurses' own `ncplane_resize_simple` -- content beyond the
||| new size is dropped, new area is blank). `False` on failure.
export
resizePlane : NCPlane -> (rows, cols : Nat) -> IO Bool
resizePlane p rows cols = (== 0) <$> primIO (prim__ncplaneResizeSimple p.ptr (cast rows) (cast cols))

||| Moves a plane to `(y, x)` relative to its parent's origin.
export
movePlane : NCPlane -> (y, x : Int) -> IO Bool
movePlane p y x = (== 0) <$> primIO (prim__ncplaneMoveYx p.ptr y x)

||| Clears a plane's content back to blank cells.
export
erasePlane : NCPlane -> IO ()
erasePlane p = primIO (prim__ncplaneErase p.ptr)

||| Moves the plane-local cursor that `putStr`/`putChar` write from.
export
moveCursor : NCPlane -> (y, x : Int) -> IO Bool
moveCursor p y x = (== 0) <$> primIO (prim__ncplaneCursorMoveYx p.ptr y x)

||| The plane-local cursor position.
export
cursorPos : NCPlane -> IO (Nat, Nat)
cursorPos p = do
  y <- primIO (prim__ncplaneCursorY p.ptr)
  x <- primIO (prim__ncplaneCursorX p.ptr)
  pure (cast y, cast x)

-------------------------------------------------------------------------------
-- Output
-------------------------------------------------------------------------------

||| Writes `str` at the plane's current cursor position, advancing it.
||| Returns the number of columns written (negative on error, per
||| notcurses' own convention).
export
putStr' : NCPlane -> String -> IO Int
putStr' p str = primIO (prim__ncplanePutstr p.ptr str)

||| Like `putStr'`, but moves the cursor to `(y, x)` first.
export
putStrAt : NCPlane -> (y, x : Int) -> String -> IO Int
putStrAt p y x str = primIO (prim__ncplanePutstrYx p.ptr y x str)

-------------------------------------------------------------------------------
-- Color and styling
-------------------------------------------------------------------------------

||| Sets the foreground color for subsequent writes to `p`. `r`/`g`/`b`
||| are clamped to 0-255 by notcurses itself. `False` if the plane
||| can't take direct RGB (e.g. a palette-only terminal).
export
setFgRgb8 : NCPlane -> (r, g, b : Bits32) -> IO Bool
setFgRgb8 p r g b = (== 0) <$> primIO (prim__ncplaneSetFgRgb8 p.ptr r g b)

||| Like `setFgRgb8`, but the background color.
export
setBgRgb8 : NCPlane -> (r, g, b : Bits32) -> IO Bool
setBgRgb8 p r g b = (== 0) <$> primIO (prim__ncplaneSetBgRgb8 p.ptr r g b)

||| Reverts the foreground to the terminal's own default color.
export
setFgDefault : NCPlane -> IO ()
setFgDefault p = primIO (prim__ncplaneSetFgDefault p.ptr)

||| Reverts the background to the terminal's own default color.
export
setBgDefault : NCPlane -> IO ()
setBgDefault p = primIO (prim__ncplaneSetBgDefault p.ptr)

||| Foreground alpha: 0 (opaque) to 255 (fully blended with what's
||| beneath), terminal support permitting. `False` on failure.
export
setFgAlpha : NCPlane -> Int -> IO Bool
setFgAlpha p a = (== 0) <$> primIO (prim__ncplaneSetFgAlpha p.ptr a)

||| Like `setFgAlpha`, but the background.
export
setBgAlpha : NCPlane -> Int -> IO Bool
setBgAlpha p a = (== 0) <$> primIO (prim__ncplaneSetBgAlpha p.ptr a)

||| Sets the active style bits (`NCStyle.bold .|. NCStyle.italic`, ...)
||| for subsequent writes to `p`. Replaces the previous style outright
||| (not a toggle/merge) -- matches notcurses' own `ncplane_set_styles`.
export
setStyles : NCPlane -> Bits32 -> IO ()
setStyles p bits = primIO (prim__ncplaneSetStyles p.ptr bits)

-------------------------------------------------------------------------------
-- Box drawing
-------------------------------------------------------------------------------

||| Draws a border around the whole of `p` using round-cornered box-
||| drawing glyphs (`─│╭╮╰╯`), in `p`'s currently active style
||| (`setStyles`) and the terminal's default border color -- per-edge
||| color isn't exposed by this package (it needs the raw channel-
||| packing API; see doc/notcurses.md). `False` on failure (e.g. `p` is
||| too small for a border at all).
export
perimeterRounded : NCPlane -> IO Bool
perimeterRounded p = (== 0) <$> primIO (prim__ncplanePerimeterRounded p.ptr 0 0 0)

||| Like `perimeterRounded`, but with double-line glyphs (`═║╔╗╚╝`).
export
perimeterDouble : NCPlane -> IO Bool
perimeterDouble p = (== 0) <$> primIO (prim__ncplanePerimeterDouble p.ptr 0 0 0)

-------------------------------------------------------------------------------
-- Input
-------------------------------------------------------------------------------

||| One input event. `codepoint` is either a Unicode codepoint (a
||| plain keypress) or one of the `NCKey.*` synthesized codes (an
||| arrow key, function key, resize notification, ...) -- notcurses
||| deliberately shares one namespace for both, placed far enough into
||| the private-use plane that they never collide with a real
||| codepoint. `utf8` is that same codepoint's UTF-8 encoding when it
||| has one (empty for a bare special key).
public export
record NCInput where
  constructor MkNCInput
  codepoint : Bits32
  y, x      : Int
  modifiers : Bits32
  evtype    : NCEventType
  utf8      : String

readLastInput : Bits32 -> IO NCInput
readLastInput codepoint = do
  y <- primIO prim__ncLastInputY
  x <- primIO prim__ncLastInputX
  m <- primIO prim__ncLastInputModifiers
  e <- primIO prim__ncLastInputEvtype
  u <- primIO prim__ncLastInputUtf8
  pure (MkNCInput codepoint y x m (ncEventTypeFromCode e) u)

||| Blocks until an input event is processed (or a signal, e.g.
||| terminal resize, interrupts it) and returns it.
export
getBlocking : Notcurses -> IO NCInput
getBlocking nc = primIO (prim__ncGetBlocking nc.ptr) >>= readLastInput

||| Like `getBlocking`, but returns immediately with `Nothing` if no
||| event is available yet.
export
getNonblock : Notcurses -> IO (Maybe NCInput)
getNonblock nc = do
  code <- primIO (prim__ncGetNonblock nc.ptr)
  if code == 0 then pure Nothing else Just <$> readLastInput code
