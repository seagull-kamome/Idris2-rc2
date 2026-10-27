||| How a Markdown text looks: the style of every element, the marks that are
||| drawn (bullets, quote bars ...) and, for each kind of block, whether it can
||| be folded and whether it starts folded. A theme is a plain record: take
||| `defaultTheme` and change what is wanted. The marks are ASCII by default,
||| whose width is the same in every terminal.
|||
||| Copyright 2026, Hattori,Hiroki. All rights reserved.
||| This module was licensed by BSD3. see LICENSE file for detail.
module TermUI.Markdown.Theme

import Data.List
import TermUI.Len
import TermUI.Style

%default total

||| The kinds of block a theme tells apart; a heading by its level.
public export
data Kind
  = KHeading Nat
  | KParagraph
  | KCode
  | KQuote
  | KBullets
  | KNumbered
  | KRule
  | KStyled              -- paragraphs given by the program

||| Whether a kind of block can be folded, and how it starts. A heading folds
||| its section: the blocks up to the next heading of its level or a higher one.
public export
data Fold = NoFold | Open | Closed

public export
record MdTheme where
  constructor MkTheme
  paragraph : Style
  heading : Nat -> Style               -- by level, 1 to 6
  headingMark : Nat -> String          -- written before the text, by level
  emph, strong, strike : Style
  inlineCode : Style
  link : Style
  linkUrl : Style                      -- the address written after a link's text
  showUrl : Bool                       -- write it
  codeBlock : Style                    -- the whole block, its background included
  codeIndent : Len
  codeLabel : Style                    -- the language, on a line of its own above the code
  showLang : Bool
  quoteBar : String
  quoteBarStyle : Style
  quoteText : Style
  bullet : Nat -> String               -- by the depth of the list, 0 outermost
  number : Nat -> String
  markerStyle : Style                  -- of bullets and numbers
  rule : String                        -- repeated across the width
  ruleStyle : Style
  gap : Nat                            -- blank rows between blocks
  fold : Kind -> Fold
  openMark, closedMark : String        -- before the first line of a block that can be folded
  foldStyle : Style

||| Headings, code and quotes and lists can be folded, and start open.
public export
defaultTheme : MdTheme
defaultTheme = MkTheme
  plain  -- paragraph
  (\n => case n of
                      1 => withAttr Underline (withAttr Bold (fgColor cyan plain))
                      2 => withAttr Bold (fgColor cyan plain)
                      3 => withAttr Bold (fgColor yellow plain)
                      _ => withAttr Bold plain)  -- heading
  (\n => pack (replicate n '#') ++ " ")  -- headingMark
  (withAttr Italic plain)  -- emph
  (withAttr Bold plain)  -- strong
  (withAttr Strike plain)  -- strike
  (fgColor yellow plain)  -- inlineCode
  (withAttr Underline (fgColor blue plain))  -- link
  (withAttr Dim plain)  -- linkUrl
  True  -- showUrl
  (bgColor (Indexed 236) plain)  -- codeBlock
  1  -- codeIndent
  (withAttr Dim plain)  -- codeLabel
  True  -- showLang
  "| "  -- quoteBar
  (withAttr Dim plain)  -- quoteBarStyle
  plain  -- quoteText
  (\d => case d of
                     0 => "- "
                     1 => "+ "
                     _ => "* ")  -- bullet
  (\n => show n ++ ". ")  -- number
  (fgColor green plain)  -- markerStyle
  "-"  -- rule
  (withAttr Dim plain)  -- ruleStyle
  1  -- gap
  (\k => case k of
                   KParagraph => NoFold
                   KRule => NoFold
                   KStyled => NoFold
                   _ => Open)  -- fold
  "[-] "  -- openMark
  "[+] "  -- closedMark
  (withAttr Dim plain)  -- foldStyle
