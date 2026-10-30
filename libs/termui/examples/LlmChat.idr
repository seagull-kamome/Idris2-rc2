||| Chat with a language model that serves the OpenAI chat completions API (LM
||| Studio, llama.cpp's llama-server, Ollama ...): type a line, press Enter, and
||| the reply appears a piece at a time as the model writes it. The history is
||| sent with every question. The reply is read by a task of the program
||| (`Network.HTTP.Client.WebAPI.AI.OpenAIStream`), one piece per message, so
||| the terminal stays alive while the model thinks: scroll the log (Page
||| Up/Down, the wheel), resize the window, and stop
||| a reply with Esc. Ctrl-Z suspends, Ctrl-C quits. Enter sends; Alt+Enter
||| (or Esc, Enter) starts a new line, and so does pasting text with line breaks; the input grows with its
||| lines, up to eight.
|||
||| The messages are shown as Markdown (`TermUI.Widget.MarkdownView`), the
||| reply as it arrives. Headings, code blocks, quotes and lists fold: a
||| click on the mark `[-]` in the left column, or F2 on the block that
||| Alt+Up / Alt+Down picked (its mark is in reverse), folds or opens it; F3
||| folds all and F4 opens all. A message folds into its heading.
|||
||| Usage: llmchat [--url URL] [--model NAME] [--system TEXT]
|||   --url     where the API is, `http(s)://host[:port]/v1`; the program
|||             adds `/chat/completions` (default http://127.0.0.1:1234/v1, or $LLM_URL)
|||   --model   the model name the server knows (default $LLM_MODEL)
|||   --system  a system prompt
||| The key, if the server wants one, is in $LLM_API_KEY.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p web -p rc2base -p contrib -p network -o llmchat LlmChat.idr
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module Main

import Control.Task
import Data.List
import Data.List1
import Data.Maybe
import Data.String
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.OpenAIStream
import Network.Socket.Data
import System
import System.File
import System.Posix.Errno
import TermUI.Input
import TermUI.Len
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Markdown.Theme
import TermUI.Widget.MarkdownView as V
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.TextArea as A

%default covering

-------------------------------------------------------------------------------
-- The command line

record Settings where
  constructor MkSettings
  url : String
  model : String
  system : Maybe String

usage : String
usage = "usage: llmchat [--url URL] [--model NAME] [--system TEXT]\n"
     ++ "  --url     http(s)://host[:port]/v1   (default http://127.0.0.1:1234/v1, or $LLM_URL)\n"
     ++ "  --model   the model name the server knows       (default $LLM_MODEL)\n"
     ++ "  --system  a system prompt\n"
     ++ "  the key, if the server wants one, is in $LLM_API_KEY"

parseArgs : Settings -> List String -> Either String Settings
parseArgs s [] = Right s
parseArgs s ("--url" :: v :: rest) = parseArgs ({ url := v } s) rest
parseArgs s ("--model" :: v :: rest) = parseArgs ({ model := v } s) rest
parseArgs s ("--system" :: v :: rest) = parseArgs ({ system := if v == "" then Nothing else Just v } s) rest
parseArgs _ [flag] = Left (flag ++ " needs a value, or is not an option")
parseArgs _ (flag :: _) = Left ("cannot use " ++ flag)

-------------------------------------------------------------------------------
-- The program

data Phase = Idle | Connecting | Receiving ChatStream

data AppMsg
  = Edit A.Msg | Send | Resized Len Len | View V.ViewMsg
  | Opened (Either ApiError ChatStream)
  | Piece (Either ApiError (Maybe Delta))
  | Stop | Pause | Quit' | Done

record AppModel where
  constructor MkModel
  settings : Settings
  endpoint : Endpoint
  log : V.Model
  input : A.Model
  size : (Len, Len)               -- the columns and rows of the terminal
  history : List Message          -- what the model is sent, the last first
  phase : Phase
  reply : String                  -- what the model has said so far in this turn

dim : Style
dim = withAttr Dim plain

-- The replies are Markdown. Each message is a segment that starts with a
-- heading (the section of it folds): `ai` is a level 1 heading and `you` a
-- level 2 one, so that the headings inside a reply do not end the section of
-- the `ai` unless they are of level 1.
theme : MdTheme
theme = { headingMark := const ""
        , heading := (\n => case n of
                              1 => withAttr Bold (fgColor cyan plain)
                              2 => withAttr Bold (fgColor green plain)
                              _ => defaultTheme.heading n) } defaultTheme

-- Characters that mean something in Markdown, made plain.
escape : String -> String
escape = pack . concatMap (\c => if elem c (unpack "\\*_`[]~<>") then ['\\', c] else [c]) . unpack

-- A line that begins with `#` is not a heading, so it cannot end the section of
-- the message.
plainHash : List Char -> List Char
plainHash cs =
  case span (== ' ') cs of
    (sp, '#' :: rest) => sp ++ ('\\' :: '#' :: rest)
    _ => cs

-- The lines the user typed are lines of the message.
youText : String -> String
youText t = "## you\n\n" ++ joinBy "  \n" (map (pack . plainHash . unpack) (forget (split (== '\n') t)))

aiHead : String
aiHead = "# ai\n\n"

-- A note on one line.
noteText : String -> String
noteText t = "**" ++ escape (pack (map (\c => if c == '\n' then ' ' else c) (unpack t))) ++ "**"

-- The input is as high as its text, up to eight rows.
maxInputRows : Len
maxInputRows = 8

-- The width of the editor inside the border.
inputCells : Len -> Len
inputCells cols = max 4 (cols `monus` 2)

wantedRows : Len -> A.Model -> Len
wantedRows cols a = min maxInputRows (max 1 (cast (A.wrappedRows (cast (inputCells cols)) a)))

-- The input has the rows its text needs and the log what is left: all but the
-- status line and the input with its border.
layoutFor : AppModel -> AppModel
layoutFor m =
  let (cols, rows) = m.size
      want = wantedRows cols m.input
  in { input $= A.resize (inputCells cols) want
     , log $= V.resize (rows `monus` (3 + want)) cols } m

newInput : Len -> A.Model
newInput cols = A.setWrap True (A.empty (inputCells cols) 1)

request : AppModel -> ChatRequest
request m =
  let system = maybe [] (\t => [MkMessage System t]) m.settings.system
  in chatRequest m.settings.model (system ++ reverse m.history)

-- The model's turn is over: what it said goes to the history. A question that
-- was not answered at all is taken back, so that two questions never follow
-- each other (some servers refuse that).
finish : AppModel -> AppModel
finish m =
  { phase := Idle, reply := ""
  , history := if m.reply == "" then drop 1 m.history else MkMessage Assistant m.reply :: m.history } m

closing : Phase -> Cmd AppMsg
closing (Receiving cs) = RunTask (closeChat cs *> pure Done)
closing _ = NoCmd

nextPiece : ChatStream -> Cmd AppMsg
nextPiece cs = RunTaskAs "chat" (Piece <$> nextDelta cs)

update : AppMsg -> AppModel -> (AppModel, Cmd AppMsg)
update (Edit e) m = (layoutFor ({ input $= A.update e } m), NoCmd)
update Send m =
  let entered = A.value m.input in
  case m.phase of
    Idle =>
      if trim entered == "" then (m, NoCmd)
      else
        let m' = layoutFor ({ input := newInput (fst m.size)
                 , history := MkMessage User entered :: m.history
                 , phase := Connecting
                 , log $= V.update (V.Scroll Sc.ToEnd) . V.addSegment aiHead . V.addSegment (youText entered) } m)
        in (m', RunTaskAs "chat" (Opened <$> chatStream m'.endpoint (request m')))
    _ => (m, NoCmd)
update (Opened (Left e)) m =
  case m.phase of
    Connecting => (finish ({ log $= V.addSegment (noteText ("error: " ++ show e)) } m), NoCmd)
    _ => (m, NoCmd)
update (Opened (Right cs)) m =
  case m.phase of
    Connecting => ({ phase := Receiving cs } m, nextPiece cs)
    _ => (m, closing (Receiving cs))     -- the reply was given up while it was opened
update (Piece p) m =
  case m.phase of
    Receiving cs =>
      case p of
        Right (Just d) =>
          let more = d.content ++ (if d.finish == Just "length" then "\n\n**[cut off: the length limit]**" else "")
          in ({ reply := m.reply ++ d.content, log $= V.extendSegment more } m, nextPiece cs)
        Right Nothing => (finish m, closing m.phase)
        Left e => (finish ({ log $= V.addSegment (noteText ("error: " ++ show e)) } m), closing m.phase)
    _ => (m, NoCmd)
update Stop m =
  case m.phase of
    Idle => (m, NoCmd)
    p => (finish ({ log $= V.addSegment (noteText "(stopped)") } m), Batch [CancelTask "chat", closing p])
update (Resized c r) m = (layoutFor ({ size := (c, r) } m), NoCmd)
update (View v) m = ({ log $= V.update v } m, NoCmd)
update Done m = (m, NoCmd)
update Pause m = (m, Suspend)
update Quit' m = (m, Quit)

status : AppModel -> String
status m =
  case m.phase of
    Idle => "Enter sends, Alt+Enter: new line, Esc: stop, F2: fold/open, Alt+Up/Down: pick, F3/F4: fold/open all, Ctrl-Z, Ctrl-C.   " ++ m.settings.model ++ " @ " ++ m.settings.url
    Connecting => "waiting for the model ..."
    Receiving _ => "the model is writing (Esc stops it) ..."

-- Enter sends, Alt+Enter is a line break, Page Up/Down scroll the log, the rest
-- is the editor's.
inputKeys : Input -> Maybe AppMsg
inputKeys (Press KEnter mods) = Just (if mods.alt || mods.shift then Edit A.Newline else Send)
inputKeys (Press KPageUp _) = Just (View (V.Scroll Sc.PageUp))
inputKeys (Press KPageDown _) = Just (View (V.Scroll Sc.PageDown))
inputKeys i = Edit <$> A.keyMsg i

view : AppModel -> Node AppMsg
view m =
  column []
    [ box [grow 1] [V.view m.log]
    , truncated dim (status m)
    , box [border Single] [focusable (\f => A.view f m.input) inputKeys]
    ]

subs : AppModel -> List (Sub AppMsg)
subs _ =
  [ MouseFocus
  , OnResize Resized
  , OnMouse (\e => View <$> V.mouseMsg 0 0 e)
  , OnInput (\i => case i of
                     Press KEscape _ => Just Stop
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                     Press (KChar 'z') mods => if mods.ctrl then Just Pause else Nothing
                     Press KUp mods => if mods.alt then Just (View V.PrevUnit) else View . V.Scroll <$> Sc.keyMsg i
                     Press KDown mods => if mods.alt then Just (View V.NextUnit) else View . V.Scroll <$> Sc.keyMsg i
                     Press (KF 2) _ => Just (View V.Toggle)
                     Press (KF 3) _ => Just (View V.FoldAll)
                     Press (KF 4) _ => Just (View V.UnfoldAll)
                     _ => View . V.Scroll <$> Sc.keyMsg i)
  ]

-- A failure to start: the message to stderr and exit status 2 (a wrong command
-- line) or 1 (no terminal).
die : (usageError : Bool) -> String -> IO ()
die usageError msg = do
  _ <- fPutStrLn stderr msg
  exitWith (if usageError then ExitFailure 2 else ExitFailure 1)

main : IO ()
main = do
  args <- getArgs
  envUrl <- getEnv "LLM_URL"
  envModel <- getEnv "LLM_MODEL"
  key <- getEnv "LLM_API_KEY"
  let nonEmpty = \v => v >>= \t => if t == "" then Nothing else Just t
  let defaults = MkSettings (fromMaybe "http://127.0.0.1:1234/v1" (nonEmpty envUrl)) (fromMaybe "" (nonEmpty envModel)) Nothing
  if any (\a => a == "--help" || a == "-h") args then putStrLn usage else
    case parseArgs defaults (drop 1 args) of
      Left e => die True (e ++ "\n" ++ usage)
      Right s =>
        if s.model == "" then die True ("no model: give --model NAME (or $LLM_MODEL)\n" ++ usage)
        else case endpointUrl s.url of
          Left e => die True ("--url: " ++ e ++ "\n" ++ usage)
          Right _ => do
            let auth = pure (Right (maybe [] (\k => [("Authorization", "Bearer " ++ k)]) (nonEmpty key)))
                greeting = V.addSegment (aiHead ++ "Hello! Say something to " ++ escape s.model ++ ".") (V.empty theme 20 70)
            r <- runProgram (MkProgram (layoutFor (MkModel s (MkEndpoint s.url auth) greeting (newInput 80) (80, 24) [] Idle ""), NoCmd)
                                       update view subs)
            case r of
              Left e => die False ("llmchat needs a terminal: " ++ show e)
              Right _ => putStrLn "bye"
