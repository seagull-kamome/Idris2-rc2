||| Chat with a language model that serves the OpenAI chat completions API (LM
||| Studio, llama.cpp's llama-server, Ollama ...): type a line, press Enter, and
||| the reply appears a piece at a time as the model writes it. The history is
||| sent with every question. The reply is read by a task of the program
||| (`Network.HTTP.Client.WebAPI.AI.OpenAIStream`), one piece per message, so
||| the terminal stays alive while the model thinks: scroll the log (Page
||| Up/Down, the wheel), resize the window, and stop
||| a reply with Esc. Ctrl-C quits.
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
import Data.Maybe
import Data.String
import Network.HTTP.Client.WebAPI.AI.OpenAI
import Network.HTTP.Client.WebAPI.AI.OpenAIStream
import Network.Socket.Data
import System
import System.File
import System.Posix.Errno
import TermUI.Input
import TermUI.Node
import TermUI.Program
import TermUI.Style
import TermUI.Widget.LogView as L
import TermUI.Widget.Scrolling as Sc
import TermUI.Widget.StyledText
import TermUI.Widget.TextInput as T

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
  = Edit T.Msg | Send | Resized Len Len | Scroll Sc.Msg
  | Opened (Either ApiError ChatStream)
  | Piece (Either ApiError (Maybe Delta))
  | Stop | Quit' | Done

record AppModel where
  constructor MkModel
  settings : Settings
  endpoint : Endpoint
  log : L.Model
  input : T.Model
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

-- Room for the log: all but the status line and the input with its border.
logRows : Len -> Len
logRows r = r `monus` 4

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
update (Edit e) m = ({ input $= T.update e } m, NoCmd)
update Send m =
  let entered = T.value m.input in
  case m.phase of
    Idle =>
      if trim entered == "" then (m, NoCmd)
      else
        let m' = { input := T.empty 60
                 , history := MkMessage User entered :: m.history
                 , phase := Connecting
                 , log $= L.update ToEnd . L.append [message green "you" entered, message cyan "ai" ""] } m
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
update (Resized c r) m = ({ log $= L.resize (logRows r) c } m, NoCmd)
update (Scroll s) m = ({ log $= L.update s } m, NoCmd)
update Done m = (m, NoCmd)
update Quit' m = (m, Quit)

status : AppModel -> String
status m =
  case m.phase of
    Idle => "Enter sends, Esc stops a reply, Ctrl-C quits.   " ++ m.settings.model ++ " @ " ++ m.settings.url
    Connecting => "waiting for the model ..."
    Receiving _ => "the model is writing (Esc stops it) ..."

view : AppModel -> Node AppMsg
view m =
  column []
    [ box [grow 1] [L.view m.log]
    , truncated dim (status m)
    , box [border Single] [T.field Edit (Just Send) m.input]
    ]

subs : AppModel -> List (Sub AppMsg)
subs _ =
  [ MouseFocus
  , OnResize Resized
  , OnMouse (\e => Scroll <$> keyMsg (Mouse e))
  , OnInput (\i => case i of
                     Press KEscape _ => Just Stop
                     Press (KChar 'c') mods => if mods.ctrl then Just Quit' else Nothing
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
            r <- runProgram (MkProgram (MkModel s (MkEndpoint s.url auth) greeting (T.empty 60) [] Idle "", NoCmd)
                                       update view subs)
            case r of
              Left e => die False ("llmchat needs a terminal: " ++ show e)
              Right _ => putStrLn "bye"
