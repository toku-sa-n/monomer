{-|
Module      : Monomer.Graphics.Text
Copyright   : (c) 2018 Francisco Vallarino
License     : BSD-3-Clause (see the LICENSE file)
Maintainer  : fjvallarino@gmail.com
Stability   : experimental
Portability : non-portable

Helper functions for calculating text size.
-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}

module Monomer.Graphics.Text (
  calcTextSize,
  calcTextSize_,
  calcTextRect,
  getTextLinesSize,
  fitTextToSize,
  fitTextToWidth,
  alignTextLines,
  moveTextLines,
  getGlyphsMin,
  getGlyphsMax
) where

import Control.Lens ((&), (^.), (^?), (+~), ix, non)
import Data.Default
import Data.List (foldl')
import Data.Maybe
import Data.Sequence (Seq(..), (<|), (|>))
import Data.Text (Text)

import qualified Data.Sequence as Seq
import qualified Data.Text as T

import Monomer.Common
import Monomer.Core.StyleTypes
import Monomer.Core.StyleUtil
import Monomer.Graphics.Types
import Monomer.Helper

import Monomer.Common.Lens as L
import Monomer.Graphics.Lens as L

type GlyphGroup = Seq GlyphPos

-- | Returns the size a given text an style will take.
calcTextSize
  :: FontManager   -- ^ The font manager.
  -> StyleState    -- ^ The style.
  -> Text          -- ^ The text to calculate.
  -> Size          -- ^ The calculated size.
calcTextSize fontMgr style !text = size where
  size = calcTextSize_ fontMgr style SingleLine KeepSpaces Nothing Nothing text

-- | Returns the size a given text an style will take.
calcTextSize_
  :: FontManager   -- ^ The font manager.
  -> StyleState    -- ^ The style.
  -> TextMode      -- ^ Single or multiline.
  -> TextTrim      -- ^ Whether to trim or keep spaces.
  -> Maybe Double  -- ^ Optional max width (needed for multiline).
  -> Maybe Int     -- ^ Optional max lines.
  -> Text          -- ^ The text to calculate.
  -> Size          -- ^ The calculated size.
calcTextSize_ fontMgr style mode trim mwidth mlines text = newSize where
  font = styleFont style
  fontSize = styleFontSize style
  !metrics = computeTextMetrics fontMgr font fontSize
  width = fromMaybe maxNumericValue mwidth
  textLinesW = fitTextToWidth fontMgr style width trim text
  textLines
    | mode == SingleLine = Seq.take 1 textLinesW
    | isJust mlines = Seq.take (fromJust mlines) textLinesW
    | otherwise = textLinesW
  newSize
    | not (Seq.null textLines) = getTextLinesSize textLines
    | otherwise = Size 0 (_txmLineH metrics)

-- | Returns the rect a text needs to be displayed completely.
calcTextRect
  :: FontManager  -- ^ The font manager.
  -> Rect         -- ^ The base rect. The result may be larger.
  -> Font         -- ^ The font to use.
  -> FontSize     -- ^ The font size.
  -> FontSpacing  -- ^ The font spacing.
  -> AlignTH      -- ^ The horizontal alignment.
  -> AlignTV      -- ^ The vertical alignment.
  -> Text         -- ^ The text to calculate.
  -> Rect         -- ^ The output rect.
calcTextRect fontMgr containerRect font fSize fSpc ha va text = textRect where
  Rect x y w h = containerRect
  Size tw _ = computeTextSize fontMgr font fSize fSpc text
  TextMetrics asc desc lineh lowerX = computeTextMetrics fontMgr font fSize
  tx | ha == ATLeft = x
     | ha == ATCenter = x + (w - tw) / 2
     | otherwise = x + (w - tw)
  {-
  This logic differs from alignTextLines, since it works from bottom to top, but
  the result is the same.
  -}
  ty | va == ATTop = y + asc
     | va == ATMiddle = y + h + desc - (h - lineh) / 2
     | va == ATAscender = y + h - (h - asc) / 2
     | va == ATLowerX = y + h - (h - lowerX) / 2
     | otherwise = y + h + desc

  textRect = Rect {
    _rX = tx,
    _rY = ty - lineh,
    _rW = tw,
    _rH = lineh
  }

{-|
Fits the given text to a determined size, splitting on multiple lines as needed.
Since the function returns glyphs that may be partially visible, the text can
overflow vertically or horizontally and a scissor is needed. The rectangles are
returned with zero offset (i.e., x = 0 and first line y = 0), and a translation
transform is needed when rendering.
-}
fitTextToSize
  :: FontManager   -- ^ The font manager.
  -> StyleState    -- ^ The style.
  -> TextOverflow  -- ^ Whether to clip or use ellipsis.
  -> TextMode      -- ^ Single or multiline.
  -> TextTrim      -- ^ Whether to trim or keep spaces.
  -> Maybe Int     -- ^ Optional max lines.
  -> Size          -- ^ The bounding size.
  -> Text          -- ^ The text to fit.
  -> Seq TextLine  -- ^ The fitted text lines.
fitTextToSize fontMgr style ovf mode trim mlines !size !text = newLines where
  Size cw ch = size
  font = styleFont style
  fontSize = styleFontSize style
  textMetrics = computeTextMetrics fontMgr font fontSize
  fitW
    | mode == MultiLine = cw
    | otherwise = maxNumericValue
  maxH = case mlines of
    Just maxLines -> min ch (fromIntegral maxLines * textMetrics ^. L.lineH)
    _ -> ch
  textLinesW = fitTextToWidth fontMgr style fitW trim text
  firstLine = Seq.take 1 textLinesW
  isMultiline = mode == MultiLine
  ellipsisReq = ovf == Ellipsis && getTextLinesSize firstLine ^. w > cw
  newLines
    | isMultiline = fitLinesToH fontMgr style ovf cw maxH textLinesW
    | ellipsisReq = addEllipsisToTextLine fontMgr style cw <$> firstLine
    | otherwise = clipTextLine fontMgr style trim cw <$> firstLine

-- | Fits a single line of text to the given width, potencially spliting into
-- | several lines.
fitTextToWidth
  :: FontManager   -- ^ The fontManager.
  -> StyleState    -- ^ The style.
  -> Double        -- ^ The maximum width.
  -> TextTrim      -- ^ Whether to trim or keep spaces.
  -> Text          -- ^ The text to calculate.
  -> Seq TextLine  -- ^ The fitted text lines.
fitTextToWidth fontMgr style width trim text = resultLines where
  font = styleFont style
  fSize = styleFontSize style
  fSpace = styleFontSpacing style
  !metrics = computeTextMetrics fontMgr font fSize
  lineH = _txmLineH metrics
  helper acc line = (cLines <> newLines, newTop) where
    (cLines, cTop) = acc
    newLines = fitLineToW fontMgr font fSize fSpace metrics cTop width trim line
    newTop = cTop + fromIntegral (Seq.length newLines) * lineH
  (resultLines, _) = foldl' helper (Empty, 0) (T.lines text)

-- | Aligns a Seq of TextLines to the given rect.
alignTextLines
  :: StyleState    -- ^ The style.
  -> Rect          -- ^ The bounding rect. Text may overflow.
  -> Seq TextLine  -- ^ The TextLines to align.
  -> Seq TextLine  -- ^ The aligned TextLines.
alignTextLines style parentRect textLines = newTextLines where
  Rect _ py _ ph = parentRect
  Size _ th = getTextLinesSize textLines
  TextMetrics asc _ lineH lowerX = (textLines ^? ix 0) ^. non def . L.metrics
  isSingle = length textLines == 1
  alignH = styleTextAlignH style
  alignV = styleTextAlignV style
  alignOffsetY = case alignV of
    ATTop -> 0
    ATAscender
      | isSingle -> (ph - asc) / 2
    ATLowerX
      | isSingle -> (ph - lowerX) / 2 - (asc - lowerX)
    ATBottom -> ph - th
    ATBaseline -> ph - th
    _ -> (ph - th) / 2 -- ATMiddle
  offsetY = py + alignOffsetY
  newTextLines = fmap (alignTextLine parentRect offsetY alignH) textLines

-- | Moves a Seq of TextLines by the given offset.
moveTextLines
  :: Point         -- ^ The offset.
  -> Seq TextLine  -- ^ The TextLines.
  -> Seq TextLine  -- ^ The displaced TextLines.
moveTextLines (Point offsetX offsetY) textLines = newTextLines where
  moveTextLine tl = tl
    & L.rect . L.x +~ offsetX
    & L.rect . L.y +~ offsetY
  newTextLines = fmap moveTextLine textLines

-- | Gets the minimum x a Seq of Glyphs will use.
getGlyphsMin :: Seq GlyphPos -> Double
getGlyphsMin Empty = 0
getGlyphsMin (g :<| gs) = _glpXMin g

-- | Gets the maximum x a Seq of Glyphs will use.
getGlyphsMax :: Seq GlyphPos -> Double
getGlyphsMax Empty = 0
getGlyphsMax (gs :|> g) = _glpXMax g

-- Helpers
alignTextLine :: Rect -> Double -> AlignTH -> TextLine -> TextLine
alignTextLine parentRect offsetY alignH textLine = newTextLine where
  Rect px _ pw _ = parentRect
  Rect tx ty tw th = _tlRect textLine
  alignOffsetX = case alignH of
    ATLeft -> 0
    ATCenter -> (pw - tw) / 2
    ATRight -> pw - tw
  offsetX = px + alignOffsetX
  newTextLine = textLine {
    _tlRect = Rect (tx + offsetX) (ty + offsetY) tw th
  }

fitLinesToH
  :: FontManager
  -> StyleState
  -> TextOverflow
  -> Double
  -> Double
  -> Seq TextLine
  -> Seq TextLine
fitLinesToH fontMgr style overflow w h Empty = Empty
fitLinesToH fontMgr style overflow w h (g1 :<| g2 :<| gs)
  | overflow == Ellipsis && h >= g1H + g2H = g1 :<| rest
  | overflow == Ellipsis && h >= g1H = Seq.singleton ellipsisG1
  | overflow == ClipText && h >= g1H = g1 :<| rest
  where
    g1H = _sH (_tlSize g1)
    g2H = _sH (_tlSize g2)
    newH = h - g1H
    rest = fitLinesToH fontMgr style overflow w newH (g2 :<| gs)
    ellipsisG1 = addEllipsisToTextLine fontMgr style w g1
fitLinesToH fontMgr style overflow w h (g :<| gs)
  | h > 0 = Seq.singleton newG
  | otherwise = Empty
  where
    gW = _sW (_tlSize g)
    newG
      | overflow == Ellipsis && w < gW = addEllipsisToTextLine fontMgr style w g
      | otherwise = g

fitLineToW
  :: FontManager
  -> Font
  -> FontSize
  -> FontSpacing
  -> TextMetrics
  -> Double
  -> Double
  -> TextTrim
  -> Text
  -> Seq TextLine
fitLineToW fontMgr font fSize fSpc metrics top width trim text = res where
  spaces = T.replicate 4 " "
  newText = T.replace "\t" spaces text
  !glyphs = computeGlyphsPos fontMgr font fSize fSpc newText
  -- Do not break line on trailing spaces, they are removed in the next step
  -- In the case of KeepSpaces, lines with only spaces (empty looking) are valid
  keepTailSpaces = trim == TrimSpaces
  groups = fitGroups (splitGroups glyphs) width keepTailSpaces
  resetGroups
    | trim == TrimSpaces = fmap (resetGlyphs . trimGlyphs) groups
    | otherwise = fmap resetGlyphs groups
  res
    | text /= "" = Seq.mapWithIndex (buildTextLine metrics top) resetGroups
    | otherwise = Seq.singleton (buildTextLine metrics top 0 Empty)

buildTextLine :: TextMetrics -> Double -> Int -> Seq GlyphPos -> TextLine
buildTextLine metrics top idx glyphs = textLine where
  lineH = _txmLineH metrics
  x = 0
  y = top + fromIntegral idx * lineH
  width = getGlyphsWidth glyphs
  height = lineH
  text = T.pack . reverse $ foldl' (\ac g -> _glpGlyph g : ac) [] glyphs
  textLine = TextLine {
    _tlText = text,
    _tlSize = Size width height,
    _tlRect = Rect x y width height,
    _tlGlyphs = glyphs,
    _tlMetrics = metrics
  }

addEllipsisToTextLine
  :: FontManager
  -> StyleState
  -> Double
  -> TextLine
  -> TextLine
addEllipsisToTextLine fontMgr style width textLine = newTextLine where
  TextLine text textSize textRect textGlyphs textMetrics = textLine
  Size tw th = textSize
  Size dw dh = calcTextSize fontMgr style "..."
  font = styleFont style
  fontSize = styleFontSize style
  fontSpacing = styleFontSpacing style
  targetW = width - tw
  dropHelper (idx, w) g
    | _glpW g + w <= dw = (idx + 1, _glpW g + w)
    | otherwise = (idx, w)
  (dropChars, _) = foldl' dropHelper (0, targetW) (Seq.reverse textGlyphs)
  newText = T.dropEnd dropChars text <> "..."
  !newGlyphs = computeGlyphsPos fontMgr font fontSize fontSpacing newText
  newW = getGlyphsWidth newGlyphs
  newTextLine = TextLine {
    _tlText = newText,
    _tlSize = textSize { _sW = newW },
    _tlRect = textRect { _rW = newW },
    _tlGlyphs = newGlyphs,
    _tlMetrics = textMetrics
  }

clipTextLine
  :: FontManager
  -> StyleState
  -> TextTrim
  -> Double
  -> TextLine
  -> TextLine
clipTextLine fontMgr style trim width textLine = newTextLine where
  TextLine text textSize textRect textGlyphs textMetrics = textLine
  Size tw th = textSize
  font = styleFont style
  fontSize = styleFontSize style
  fontSpacing = styleFontSpacing style
  takeHelper (idx, w) g
    | _glpW g + w <= width = (idx + 1, _glpW g + w)
    | otherwise = (idx, w)
  (takeChars, _) = foldl' takeHelper (0, 0) textGlyphs
  validGlyphs = Seq.takeWhileL (\g -> _glpXMax g <= width) textGlyphs
  newText
    | trim == KeepSpaces = T.take (length validGlyphs) text
    | otherwise = T.dropWhileEnd (== ' ') $ T.take (length validGlyphs) text
  !newGlyphs = computeGlyphsPos fontMgr font fontSize fontSpacing newText
  newW = getGlyphsWidth newGlyphs
  newTextLine = TextLine {
    _tlText = newText,
    _tlSize = textSize { _sW = newW },
    _tlRect = textRect { _rW = newW },
    _tlGlyphs = newGlyphs,
    _tlMetrics = textMetrics
  }

fitGroups :: Seq GlyphGroup -> Double -> Bool -> Seq GlyphGroup
fitGroups Empty _ _ = Empty
fitGroups (g :<| gs) !width !keepTailSpaces = currentLine <| extraLines where
  gW = getGlyphsWidth g
  gMax = getGlyphsMax g
  extraGroups = fitExtraGroups gs (width - gW) gMax keepTailSpaces
  (lineGroups, remainingGroups) = extraGroups
  currentLine = g <> lineGroups
  extraLines = fitGroups remainingGroups width keepTailSpaces

fitExtraGroups
  :: Seq GlyphGroup
  -> Double
  -> Double
  -> Bool
  -> (Seq GlyphPos, Seq GlyphGroup)
fitExtraGroups Empty _ _ _ = (Empty, Empty)
fitExtraGroups (g :<| gs) !width !prevGMax !keepTailSpaces
  | gW + wDiff <= width || keepSpace = (g <> newFit, newRest)
  | otherwise = (Empty, g :<| gs)
  where
    gW = getGlyphsWidth g
    gMin = getGlyphsMin g
    gMax = getGlyphsMax g
    wDiff = gMin - prevGMax
    remWidth = width - (gW + wDiff)
    keepSpace = keepTailSpaces && isSpaceGroup g
    (newFit, newRest) = fitExtraGroups gs remWidth gMax keepTailSpaces

getGlyphsWidth :: Seq GlyphPos -> Double
getGlyphsWidth glyphs = getGlyphsMax glyphs - getGlyphsMin glyphs

getTextLinesSize :: Seq TextLine -> Size
getTextLinesSize textLines = size where
  width = maximum (fmap (_sW . _tlSize) textLines)
  height = sum (fmap (_sH . _tlSize) textLines)
  size
    | Seq.null textLines = def
    | otherwise = Size width height

isSpaceGroup :: Seq GlyphPos -> Bool
isSpaceGroup Empty = False
isSpaceGroup (g :<| gs) = isSpace (_glpGlyph g)

splitGroups :: Seq GlyphPos -> Seq GlyphGroup
splitGroups Empty = Empty
splitGroups glyphs = group <| splitGroups rest where
  g :<| gs = glyphs
  groupWordFn = not . isWordDelimiter . _glpGlyph
  (group, rest)
    | isWordDelimiter (_glpGlyph g) = (Seq.singleton g, gs)
    | otherwise = Seq.spanl groupWordFn glyphs

resetGlyphs :: Seq GlyphPos -> Seq GlyphPos
resetGlyphs Empty = Empty
resetGlyphs gs@(g :<| _) = resetGlyphsPos gs (_glpXMin g)

resetGlyphsPos :: Seq GlyphPos -> Double -> Seq GlyphPos
resetGlyphsPos Empty _ = Empty
resetGlyphsPos (g :<| gs) offset = newG <| resetGlyphsPos gs offset where
  newG = g {
    _glpXMin = _glpXMin g - offset,
    _glpXMax = _glpXMax g - offset
  }

trimGlyphs :: Seq GlyphPos -> Seq GlyphPos
trimGlyphs glyphs = newGlyphs where
  isSpaceGlyph g = _glpGlyph g == ' '
  newGlyphs = Seq.dropWhileL isSpaceGlyph $ Seq.dropWhileR isSpaceGlyph glyphs

isWordDelimiter :: Char -> Bool
isWordDelimiter = (== ' ')

isSpace :: Char -> Bool
isSpace = (== ' ')
