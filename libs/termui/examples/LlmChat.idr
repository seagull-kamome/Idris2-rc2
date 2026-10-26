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
||| Usage: llmchat [--url URL] [--model NAME] [--system TEXT]
|||   --url     where the API is, `http://IPv4-or-localhost[:port]/v1`; the program
|||             adds `/chat/completions` (default http://127.0.0.1:1234/v1, or $LLM_URL)
|||   --model   the model name the server knows (default $LLM_MODEL)
|||   --system  a system prompt
||| The key, if the server wants one, is in $LLM_API_KEY.
|||
||| Build: idris2-rc2 --cg rc2 -p termui -p rc2base -p contrib -p network -o llmchat LlmChat.idr
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
import TermUI.Widget.LogView as L
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.StyledText
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
     ++ "  --url     http://IPv4-or-localhost[:port]/v1   (default http://127.0.0.1:1234/v1, or $LLM_URL)\n"
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
  = Edit A.Msg | Send | Resized Len Len | Scroll Sc.Msg
  | Opened (Either ApiError ChatStream)
  | Piece (Either ApiError (Maybe Delta))
  | Stop | Pause | Quit' | Done

record AppModel where
  constructor MkModel
  settings : Settings
  endpoint : Endpoint
  log : L.Model
  input : A.Model
  size : (Len, Len)               -- the columns and rows of the terminal
  history : List Message          -- what the model is sent, the last first
  phase : Phase
  reply : String                  -- what the model has said so far in this turn

bold : Color -> Style
bold c = withAttr Bold (fgColor c plain)

dim : Style
dim = withAttr Dim plain

-- A message: the name in colour, the text wrapped under it.
message : Color -> String -> String -> Para
message c who what =
  MkPara [spanOf (bold c) (who ++ "  ")] [spanOf plain (pack (replicate (length who + 2) ' '))]
         WrapWords (if what == "" then [] else [spanOf plain what])

note : String -> Para
note t = MkPara [] [] WrapWords [spanOf (fgColor red plain) t]

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
     , log $= L.resize (rows `monus` (3 + want)) cols } m

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
                 , log $= L.update ToEnd . L.append [message green "you" entered, message cyan "ai" ""] } m)
        in (m', RunTaskAs "chat" (Opened <$> chatStream m'.endpoint (request m')))
    _ => (m, NoCmd)
update (Opened (Left e)) m =
  case m.phase of
    Connecting => (finish ({ log $= L.append [note ("error: " ++ show e)] } m), NoCmd)
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
          let spans = (if d.reasoning == "" then [] else [spanOf dim d.reasoning])
                      ++ (if d.content == "" then [] else [spanOf plain d.content])
                      ++ (if d.finish == Just "length" then [spanOf (fgColor red plain) " [cut off: the length limit]"] else [])
          in ({ reply := m.reply ++ d.content, log $= L.extendLast spans } m, nextPiece cs)
        Right Nothing => (finish m, closing m.phase)
        Left e => (finish ({ log $= L.append [note ("error: " ++ show e)] } m), closing m.phase)
    _ => (m, NoCmd)
update Stop m =
  case m.phase of
    Idle => (m, NoCmd)
    p => (finish ({ log $= L.append [note "(stopped)"] } m), Batch [CancelTask "chat", closing p])
update (Resized c r) m = (layoutFor ({ size := (c, r) } m), NoCmd)
update (Scroll s) m = ({ log $= L.update s } m, NoCmd)
update Done m = (m, NoCmd)
update Pause m = (m, Suspend)
update Quit' m = (m, Quit)

status : AppModel -> String
status m =
  case m.phase of
    Idle => "Enter sends (Alt+Enter: new line), Esc stops a reply, Ctrl-Z suspends, Ctrl-C quits.   " ++ m.settings.model ++ " @ " ++ m.settings.url
    Connecting => "waiting for the model ..."
    Receiving _ => "the model is writing (Esc stops it) ..."

-- Enter sends, Alt+Enter is a line break, Page Up/Down scroll the log, the rest
-- is the editor's.
inputKeys : Input -> Maybe AppMsg
inputKeys (Press KEnter mods) = Just (if mods.alt || mods.shift then Edit A.Newline else Send)
inputKeys (Press KPageUp _) = Just (Scroll Sc.PageUp)
inputKeys (Press KPageDown _) = Just (Scroll Sc.PageDown)
inputKeys i = Edit <$> A.keyMsg i

view : AppModel -> Node AppMsg
view m =
  column []
    [ box [grow 1] [L.view m.log]
    , truncated dim (status m)
    , box [border Single] [focusable (\f => A.view f m.input) inputKeys]
    ]

subs : AppModel -> List (Sub AppMsg)
subs _ =
  [ MouseFocus
  , OnResize Resized
  , OnMouse (\e => Scroll <$> keyMsg (Mouse e))
  , OnInput (\i => case i of
                     Press KEscape _ => Just Stop
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
                     Press (KChar 'z') mods => if mods.ctrl then Just Pause else Nothing
                     _ => Scroll <$> keyMsg i)
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
        else case parseBase s.url of
          Left e => die True ("--url: " ++ e ++ "\n" ++ usage)
          Right _ => do
            let auth = pure (Right (maybe [] (\k => [("Authorization", "Bearer " ++ k)]) (nonEmpty key)))
                greeting = L.append [message cyan "ai" ("Hello! Say something to " ++ s.model ++ ".")] (L.empty 20 70)
            r <- runProgram (MkProgram (layoutFor (MkModel s (MkEndpoint s.url auth) greeting (newInput 80) (80, 24) [] Idle ""), NoCmd)
                                       update view subs)
            case r of
              Left e => die False ("llmchat needs a terminal: " ++ show e)
              Right _ => putStrLn "bye"
