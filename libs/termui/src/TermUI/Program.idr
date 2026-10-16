||| The Elm architecture on a terminal: a `Program` is a model, an `update`
||| from messages, a `view` built with the layout EDSL, and subscriptions.
||| `runProgram` owns the terminal: it decodes events into messages, applies
||| `update`, runs the commands, manages the keyboard focus and redraws only
||| what changed. A child component is embedded with `mapNode`, `mapCmd` and
||| `mapSub` over its own messages.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Program

import Data.IORef
import Data.List
import Data.Maybe
import System.Posix.Errno
import System.Posix.Signal
import System.Posix.FileDesc
import System.Posix.Termios
import TermUI.Frame
import TermUI.Input
import TermUI.Layout
import TermUI.Loop
import TermUI.Node
import TermUI.Output
import TermUI.Terminal

%default covering

-------------------------------------------------------------------------------
-- Commands and subscriptions

||| What `update` asks the runtime to do.
public export
data Cmd msg
  = NoCmd
  | Batch (List (Cmd msg))
  | Quit
  | Emit msg                     -- deliver a message at once
  | After Nat msg                -- deliver a message after some milliseconds
  | Perform (IO msg)             -- run an action now and deliver its result
  | Suspend                      -- stop the program, as Ctrl-Z does in a shell

||| What a model listens to; `subs` is re-evaluated after every update.
public export
data Sub msg
  = OnInput (Input -> Maybe msg)       -- keys the focused node did not take, and pastes
  | OnMouse (MouseEvent -> Maybe msg)  -- also turns mouse reporting on
  | MouseFocus                         -- clicks move the focus, the wheel goes to the node under the pointer; turns reporting on
  | OnResize (Nat -> Nat -> msg)
  | Every String Nat msg               -- a key naming the timer, the period in ms, the message
  | OnTerminate msg                    -- SIGINT, SIGTERM or SIGHUP; without it they quit

export covering
mapCmd : (a -> b) -> Cmd a -> Cmd b
mapCmd _ NoCmd = NoCmd
mapCmd f (Batch cs) = Batch (map (mapCmd f) cs)
mapCmd _ Quit = Quit
mapCmd f (Emit m) = Emit (f m)
mapCmd f (After ms m) = After ms (f m)
mapCmd f (Perform io) = Perform (map f io)
mapCmd _ Suspend = Suspend

export
mapSub : (a -> b) -> Sub a -> Sub b
mapSub f (OnInput g) = OnInput (map f . g)
mapSub f (OnMouse g) = OnMouse (map f . g)
mapSub _ MouseFocus = MouseFocus
mapSub f (OnResize g) = OnResize (\c, r => f (g c r))
mapSub f (Every k ms m) = Every k ms (f m)
mapSub f (OnTerminate m) = OnTerminate (f m)

||| Put the timers of a component's subscriptions under a name of their own:
||| two components may then use the same `Every` key. Apply it to the whole
||| list the component returns, after `mapSub`.
export
scopeSub : (scope : String) -> Sub msg -> Sub msg
scopeSub scope (Every k ms m) = Every (scope ++ "/" ++ k) ms m
scopeSub _ s = s

-------------------------------------------------------------------------------
-- Program

public export
record Program model msg where
  constructor MkProgram
  init : (model, Cmd msg)
  update : msg -> model -> (model, Cmd msg)
  view : model -> Node msg
  subs : model -> List (Sub msg)

-------------------------------------------------------------------------------
-- Focus

-- Replace every `Focusable` by its body, built for the focused one of them;
-- returns the handlers in tree order.
resolve : (focus : Nat) -> Node msg -> (Node msg, List (Input -> Maybe msg))
resolve focus root = let (n, hs, _) = go 0 root in (n, hs)
  where
    -- The box of a focusable is marked, so that its place can be found after
    -- the layout; a node that is not a box (or is marked already) gets one.
    tag : Nat -> Node msg -> Node msg
    tag i (Box p ks) =
      case p.pTag of
        Nothing => Box ({ pTag := Just i } p) ks
        Just _ => Box ({ pTag := Just i } defaultProps) [Box p ks]
    tag i n = Box ({ pTag := Just i } defaultProps) [n]

    mutual
      go : Nat -> Node msg -> (Node msg, List (Input -> Maybe msg), Nat)
      go i n@(Text _ _ _) = (n, [], i)
      go i (Focusable body h) =
        let (inner, hs, next) = go (i + 1) (body (i == focus)) in
        (tag i inner, h :: hs, next)
      go i (Box p kids) =
        let (kids', hs, next) = goList i kids in (Box p kids', hs, next)

      goList : Nat -> List (Node msg) -> (List (Node msg), List (Input -> Maybe msg), Nat)
      goList i [] = ([], [], i)
      goList i (k :: ks) =
        let (k', hs, i') = go i k
            (ks', hs', i'') = goList i' ks
        in (k' :: ks', hs ++ hs', i'')

-------------------------------------------------------------------------------
-- Runtime

record Env model msg where
  constructor MkEnv
  prog : Program model msg
  loop : Loop
  term : Terminal
  output : FileDesc
  modelRef : IORef model
  focus : IORef Nat
  handlers : IORef (List (Input -> Maybe msg))
  prev : IORef (Maybe Frame)
  size : IORef (Nat, Nat)
  quit : IORef Bool
  oneShots : IORef (List (Nat, msg))
  nextShot : IORef Nat
  everys : IORef (List (String, Nat))     -- (key, period) of the running timers
  keyIds : IORef (List (String, Nat))     -- the timer id of every key seen
  queue : IORef (List msg)                -- messages waiting for `update`, first first
  draining : IORef Bool
  mouseOn : IORef Bool
  skipResume : IORef Bool                 -- the SIGCONT that ends our own Suspend was handled already
  rects : IORef (List (Nat, Rect))
  shownCursor : IORef (Maybe (Bool, Nat, Nat))

-- The timer id of an `Every` key, the same for as long as the program runs;
-- even, while the ids of `After` are odd.
everyId : Env model msg -> String -> IO Nat
everyId env key = do
  ids <- readIORef env.keyIds
  case lookup key ids of
    Just i => pure i
    Nothing => do
      let i = 2 * length ids
      writeIORef env.keyIds (ids ++ [(key, i)])
      pure i

-- After a stop the terminal is as the shell left it: raw mode, the alternate
-- screen, the mouse and the whole picture are done again.
resumeEnv : Env model msg -> IO ()
resumeEnv env = do
  resumeTerminal env.term
  writeIORef env.mouseOn False
  writeIORef env.prev Nothing
  writeIORef env.shownCursor Nothing

mutual
  -- Messages are handled in the order they were sent, one `update` at a time:
  -- what `Emit` and `Perform` produce while one is handled waits its turn.
  dispatch : Env model msg -> msg -> IO ()
  dispatch env m = do
    modifyIORef env.queue (++ [m])
    busy <- readIORef env.draining
    if busy
       then pure ()
       else do
         writeIORef env.draining True
         drain env
         writeIORef env.draining False

  drain : Env model msg -> IO ()
  drain env = do
    q <- readIORef env.queue
    case q of
      [] => pure ()
      (m :: rest) => do
        writeIORef env.queue rest
        stopped <- readIORef env.quit
        if stopped
           then writeIORef env.queue []
           else do
             model <- readIORef env.modelRef
             let (model', cmd) = env.prog.update m model
             writeIORef env.modelRef model'
             runCmd env cmd
             drain env

  runCmd : Env model msg -> Cmd msg -> IO ()
  runCmd _ NoCmd = pure ()
  runCmd env (Batch cs) = go cs
    where
      go : List (Cmd msg) -> IO ()
      go [] = pure ()
      go (c :: rest) = do
        q <- readIORef env.quit
        if q then pure () else runCmd env c *> go rest
  runCmd env Quit = writeIORef env.quit True
  runCmd env (Emit m) = dispatch env m
  runCmd env (After ms m) = do
    n <- readIORef env.nextShot
    writeIORef env.nextShot (n + 1)
    modifyIORef env.oneShots ((2 * n + 1, m) ::)
    ignore (addOneShot env.loop (2 * n + 1) ms)
  runCmd env (Perform io) = io >>= dispatch env
  runCmd env Suspend = do
    closeTerminal env.term
    writeIORef env.skipResume True
    _ <- raise SIGSTOP
    resumeEnv env

-- Start, stop and retime the timers the current subscriptions ask for.
syncTimers : Env model msg -> IO ()
syncTimers env = do
  model <- readIORef env.modelRef
  let wanted = nub (mapMaybe period (env.prog.subs model))
  active <- readIORef env.everys
  traverse_ (\(k, _) => everyId env k >>= cancelTimer env.loop) (filter (\a => not (elem a wanted)) active)
  traverse_ (\(k, ms) => do i <- everyId env k
                            ignore (addTimer env.loop i ms)) (filter (\w => not (elem w active)) wanted)
  writeIORef env.everys wanted
  let wantMouse = any isMouse (env.prog.subs model)
  was <- readIORef env.mouseOn
  when (wantMouse /= was) $ do
    setMouseReporting env.output wantMouse
    writeIORef env.mouseOn wantMouse
  where
    isMouse : Sub msg -> Bool
    isMouse (OnMouse _) = True
    isMouse MouseFocus = True
    isMouse _ = False

    period : Sub msg -> Maybe (String, Nat)
    period (Every k ms _) = Just (k, ms)
    period _ = Nothing

-- Build the view for the current model and focus; the handlers are the ones
-- of this very view, so they are refreshed after every event.
currentView : Env model msg -> IO (Node msg)
currentView env = do
  model <- readIORef env.modelRef
  focus <- readIORef env.focus
  let view = env.prog.view model
      (node, hs) = resolve focus view
      count = length hs
  if focus >= count && focus > 0
     then do
       let focus' = count `minus` 1
           (node', hs') = resolve focus' view
       writeIORef env.focus focus'
       writeIORef env.handlers hs'
       pure node'
     else do
       writeIORef env.handlers hs
       pure node

-- The part of `a` inside `b`.
within : Rect -> Rect -> Rect
within a b =
  let x0 = max a.x b.x
      y0 = max a.y b.y
      x1 = min (a.x + a.w) (b.x + b.w)
      y1 = min (a.y + a.h) (b.y + b.h)
  in MkRect x0 y0 (x1 `minus` x0) (y1 `minus` y0)

-- Where the focusables are (in tree order), cut to what is visible, and where
-- the terminal cursor goes.
scan : Rect -> Laid -> (List (Nat, Rect), Maybe (Nat, Nat))
scan _ (LText _ _ _) = ([], Nothing)
scan clip (LBox r p kids) =
  let own = maybe [] (\i => [(i, within r clip)]) p.pTag
      cursor = if p.pCursor then Just (r.x, r.y) else Nothing
      (rs, c) = scanAll (within (innerRect p r) clip) kids
  in (own ++ rs, maybe c Just cursor)
  where
    scanAll : Rect -> List Laid -> (List (Nat, Rect), Maybe (Nat, Nat))
    scanAll _ [] = ([], Nothing)
    scanAll inner (k :: ks) =
      let (r1, c1) = scan inner k
          (r2, c2) = scanAll inner ks
      in (r1 ++ r2, maybe c2 Just c1)

draw : Env model msg -> IO ()
draw env = do
  node <- currentView env
  (w, h) <- readIORef env.size
  (frame, laid) <- renderLaid node w h
  let (rects, cursor) = scan (MkRect 0 0 w h) laid
      (x, y) = fromMaybe (0, h `minus` 1) cursor
      target = (isJust cursor, x, y)
  writeIORef env.rects rects
  old <- readIORef env.prev
  out <- diffFrames old frame
  shown <- readIORef env.shownCursor
  -- the diff leaves the cursor wherever it wrote last; an input method puts its
  -- window at the cursor, so it is put back where the user is typing
  if out == "" && shown == Just target
     then writeIORef env.prev (Just frame)
     else do
       r <- writeString env.output (out ++ cursorSequence target)
       writeIORef env.prev (either (const Nothing) (const (Just frame)) r)
       writeIORef env.shownCursor (either (const Nothing) (const (Just target)) r)
  where
    cursorSequence : (Bool, Nat, Nat) -> String
    cursorSequence (visible, x, y) =
      "\ESC[" ++ show (y + 1) ++ ";" ++ show (x + 1) ++ "H" ++ (if visible then "\ESC[?25h" else "\ESC[?25l")

moveFocus : Env model msg -> Bool -> IO ()
moveFocus env forward = do
  hs <- readIORef env.handlers
  f <- readIORef env.focus
  let n = length hs
  when (n > 0) $
    writeIORef env.focus (if forward then (if f + 1 >= n then 0 else f + 1) else (if f == 0 then n `minus` 1 else f `minus` 1))

onInput : Env model msg -> Input -> IO ()
onInput env (Mouse e) = do
  model <- readIORef env.modelRef
  let subs = env.prog.subs model
  when (any isMouseFocus subs) $ do
    rects <- readIORef env.rects
    case last' (filter (\(_, r) => inside r e.column e.row) rects) of
      Nothing => pure ()
      Just (i, r) => do
        when (isLeftDown e) $ writeIORef env.focus i
        hs <- readIORef env.handlers
        -- the handler sees the position relative to the top left of its node
        let rel = { column := e.column `minus` r.x, row := e.row `minus` r.y } e
        traverse_ (dispatch env) (getAt i hs >>= \h => h (Mouse rel))
  traverse_ (dispatch env) (mapMaybe fromSub subs)
  where
    fromSub : Sub msg -> Maybe msg
    fromSub (OnMouse g) = g e
    fromSub _ = Nothing

    isMouseFocus : Sub msg -> Bool
    isMouseFocus MouseFocus = True
    isMouseFocus _ = False

    isLeftDown : MouseEvent -> Bool
    isLeftDown ev = case (ev.button, ev.action) of
                      (LeftButton, ButtonDown) => True
                      _ => False

    inside : Rect -> Nat -> Nat -> Bool
    inside r c rw = c >= r.x && c < r.x + r.w && rw >= r.y && rw < r.y + r.h

onInput env inp = do
  hs <- readIORef env.handlers
  f <- readIORef env.focus
  let taken = (\h => h inp) =<< getAt f hs
  case taken of
    Just m => dispatch env m
    Nothing =>
      if isTab inp && not (null hs)
         then moveFocus env (not (isBackTab inp))
         else do
           model <- readIORef env.modelRef
           traverse_ (dispatch env) (mapMaybe (fromSub inp) (env.prog.subs model))
  where
    isTab : Input -> Bool
    isTab (Press KTab _) = True
    isTab (Press KBackTab _) = True
    isTab _ = False

    isBackTab : Input -> Bool
    isBackTab (Press KBackTab _) = True
    isBackTab (Press KTab m) = m.shift
    isBackTab _ = False

    fromSub : Input -> Sub msg -> Maybe msg
    fromSub i (OnInput g) = g i
    fromSub _ _ = Nothing

onEvent : Env model msg -> Event -> IO ()
onEvent env (EInput i) = onInput env i
onEvent env (EResize c r) = do
  writeIORef env.size (c, r)
  writeIORef env.prev Nothing
  writeIORef env.shownCursor Nothing
  model <- readIORef env.modelRef
  traverse_ (\s => case s of
                     OnResize g => dispatch env (g c r)
                     _ => pure ()) (env.prog.subs model)
onEvent env (ETimer ident) =
  if mod (cast {to = Integer} ident) 2 == 0
     then do
       model <- readIORef env.modelRef
       ids <- readIORef env.keyIds
       traverse_ (\s => case s of
                          Every k _ m => if lookup k ids == Just ident then dispatch env m else pure ()
                          _ => pure ()) (env.prog.subs model)
     else do
       shots <- readIORef env.oneShots
       cancelTimer env.loop ident
       case lookup ident shots of
         Nothing => pure ()
         Just m => do
           writeIORef env.oneShots (filter (\(i, _) => i /= ident) shots)
           dispatch env m
onEvent env EResume = do
  skip <- readIORef env.skipResume
  writeIORef env.skipResume False
  if skip then pure () else resumeEnv env
onEvent env ETerminate = do
  model <- readIORef env.modelRef
  case mapMaybe terminating (env.prog.subs model) of
    [] => writeIORef env.quit True
    ms => traverse_ (dispatch env) ms
  where
    terminating : Sub msg -> Maybe msg
    terminating (OnTerminate m) = Just m
    terminating _ = Nothing
onEvent env EEndOfInput = writeIORef env.quit True

loopUntilQuit : Env model msg -> IO ()
loopUntilQuit env = do
  syncTimers env
  draw env
  evs <- waitEvents env.loop (-1)
  handleAll evs
  q <- readIORef env.quit
  if q then pure () else loopUntilQuit env
  where
    -- The handlers of a later event see the model the earlier ones made, and
    -- nothing is handled after a Quit.
    handleAll : List Event -> IO ()
    handleAll [] = pure ()
    handleAll (e :: es) = do
      onEvent env e
      q <- readIORef env.quit
      if q then pure () else currentView env *> handleAll es

||| Run a program on a terminal (the descriptors must be a terminal in the
||| calling thread's session) until it asks to `Quit`, and return the final
||| model. The terminal is restored before returning.
export
runProgramOn : (input : FileDesc) -> (output : FileDesc) -> Program model msg -> IO (Either Errno model)
runProgramOn input output prog = do
  True <- isatty input
    | False => pure (Left ENOTTY)
  True <- isatty output
    | False => pure (Left ENOTTY)
  Right loop <- newLoop input output
    | Left e => pure (Left e)
  Right term <- openTerminal input output
    | Left e => closeLoop loop >> pure (Left e)
  let (model0, cmd0) = prog.init
  size <- terminalSize term
  env <- MkEnv prog loop term output <$> newIORef model0 <*> newIORef 0 <*> newIORef []
           <*> newIORef Nothing <*> newIORef size <*> newIORef False
           <*> newIORef [] <*> newIORef 0 <*> newIORef [] <*> newIORef [] <*> newIORef [] <*> newIORef False
           <*> newIORef False <*> newIORef False <*> newIORef [] <*> newIORef Nothing
  runCmd env cmd0
  -- the size is told to the program once at the start, as at every resize
  current <- readIORef env.modelRef
  traverse_ (\sub => case sub of
                       OnResize g => dispatch env (uncurry g size)
                       _ => pure ()) (prog.subs current)
  q <- readIORef env.quit
  when (not q) $ loopUntilQuit env
  closeTerminal term
  closeLoop loop
  Right <$> readIORef env.modelRef

||| `runProgramOn` the process's standard input and output
||| (`Left ENOTTY` when they are not a terminal).
export
runProgram : Program model msg -> IO (Either Errno model)
runProgram prog = do
  Right i <- primFdToFileDesc 0
    | Left e => pure (Left e)
  Right o <- primFdToFileDesc 1
    | Left e => pure (Left e)
  runProgramOn i o prog
