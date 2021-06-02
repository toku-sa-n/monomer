{-|
Module      : Monomer.Widgets.Singles.Dial
Copyright   : (c) 2018 Francisco Vallarino
License     : BSD-3-Clause (see the LICENSE file)
Maintainer  : fjvallarino@gmail.com
Stability   : experimental
Portability : non-portable

Dial widget, used for interacting with numeric values. It allows changing the
value by keyboard arrows, dragging the mouse or using the wheel.

Similar in objective to Slider, but uses less space.

Configs:

- width: sets the max width/height of the dial.
- wheelRate: The rate at which wheel movement affects the number.
- dragRate: The rate at which drag movement affects the number.
- onFocus: event to raise when focus is received.
- onFocusReq: WidgetRequest to generate when focus is received.
- onBlur: event to raise when focus is lost.
- onBlurReq: WidgetRequest to generate when focus is lost.
- onChange: event to raise when the value changes.
- onChangeReq: WidgetRequest to generate when the value changes.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Monomer.Widgets.Singles.Dial (
  dial,
  dial_,
  dialV,
  dialV_
) where

import Control.Applicative ((<|>))
import Control.Lens (ALens', (&), (^.), (.~), (<>~))
import Control.Monad
import Data.Default
import Data.Maybe
import Data.Text (Text)
import Data.Typeable (Typeable)
import GHC.Generics

import qualified Data.Sequence as Seq

import Monomer.Widgets.Single

import qualified Monomer.Lens as L

type DialValue a = (Eq a, Show a, Real a, FromFractional a, Typeable a)

data DialCfg s e a = DialCfg {
  _dlcWidth :: Maybe Double,
  _dlcWheelRate :: Maybe Rational,
  _dlcDragRate :: Maybe Rational,
  _dlcOnFocus :: [Path -> e],
  _dlcOnFocusReq :: [WidgetRequest s e],
  _dlcOnBlur :: [Path -> e],
  _dlcOnBlurReq :: [WidgetRequest s e],
  _dlcOnChange :: [a -> e],
  _dlcOnChangeReq :: [a -> WidgetRequest s e]
}

instance Default (DialCfg s e a) where
  def = DialCfg {
    _dlcWidth = Nothing,
    _dlcWheelRate = Nothing,
    _dlcDragRate = Nothing,
    _dlcOnFocus = [],
    _dlcOnFocusReq = [],
    _dlcOnBlur = [],
    _dlcOnBlurReq = [],
    _dlcOnChange = [],
    _dlcOnChangeReq = []
  }

instance Semigroup (DialCfg s e a) where
  (<>) t1 t2 = DialCfg {
    _dlcWidth = _dlcWidth t2 <|> _dlcWidth t1,
    _dlcWheelRate = _dlcWheelRate t2 <|> _dlcWheelRate t1,
    _dlcDragRate = _dlcDragRate t2 <|> _dlcDragRate t1,
    _dlcOnFocus = _dlcOnFocus t1 <> _dlcOnFocus t2,
    _dlcOnFocusReq = _dlcOnFocusReq t1 <> _dlcOnFocusReq t2,
    _dlcOnBlur = _dlcOnBlur t1 <> _dlcOnBlur t2,
    _dlcOnBlurReq = _dlcOnBlurReq t1 <> _dlcOnBlurReq t2,
    _dlcOnChange = _dlcOnChange t1 <> _dlcOnChange t2,
    _dlcOnChangeReq = _dlcOnChangeReq t1 <> _dlcOnChangeReq t2
  }

instance Monoid (DialCfg s e a) where
  mempty = def

instance CmbWheelRate (DialCfg s e a) Rational where
  wheelRate rate = def {
    _dlcWheelRate = Just rate
  }

instance CmbDragRate (DialCfg s e a) Rational where
  dragRate rate = def {
    _dlcDragRate = Just rate
  }

instance CmbWidth (DialCfg s e a) where
  width w = def {
    _dlcWidth = Just w
  }

instance CmbOnFocus (DialCfg s e a) e Path where
  onFocus fn = def {
    _dlcOnFocus = [fn]
  }

instance CmbOnFocusReq (DialCfg s e a) s e where
  onFocusReq req = def {
    _dlcOnFocusReq = [req]
  }

instance CmbOnBlur (DialCfg s e a) e Path where
  onBlur fn = def {
    _dlcOnBlur = [fn]
  }

instance CmbOnBlurReq (DialCfg s e a) s e where
  onBlurReq req = def {
    _dlcOnBlurReq = [req]
  }

instance CmbOnChange (DialCfg s e a) a e where
  onChange fn = def {
    _dlcOnChange = [fn]
  }

instance CmbOnChangeReq (DialCfg s e a) s e a where
  onChangeReq req = def {
    _dlcOnChangeReq = [req]
  }

data DialState = DialState {
  _dlsMaxPos :: Integer,
  _dlsPos :: Integer
} deriving (Eq, Show, Generic)

-- | Creates a dial using the given lens, providing minimum and maximum values.
dial :: (DialValue a, WidgetEvent e) => ALens' s a -> a -> a -> WidgetNode s e
dial field minVal maxVal = dial_ field minVal maxVal def

{-|
Creates a dial using the given lens, providing minimum and maximum values.
Accepts config.
-}
dial_
  :: (DialValue a, WidgetEvent e)
  => ALens' s a
  -> a
  -> a
  -> [DialCfg s e a]
  -> WidgetNode s e
dial_ field minVal maxVal cfgs = dialD_ (WidgetLens field) minVal maxVal cfgs

{-|
Creates a dial using the given value and onChange event handler, providing
minimum and maximum values.
-}
dialV
  :: (DialValue a, WidgetEvent e) => a -> (a -> e) -> a -> a -> WidgetNode s e
dialV value handler minVal maxVal = dialV_ value handler minVal maxVal def

{-|
Creates a dial using the given value and onChange event handler, providing
minimum and maximum values.
Accepts config.
-}
dialV_
  :: (DialValue a, WidgetEvent e)
  => a
  -> (a -> e)
  -> a
  -> a
  -> [DialCfg s e a]
  -> WidgetNode s e
dialV_ value handler minVal maxVal configs = newNode where
  widgetData = WidgetValue value
  newConfigs = onChange handler : configs
  newNode = dialD_ widgetData minVal maxVal newConfigs

{-|
Creates a dial providing a WidgetData instance, minimum and maximum values and
config.
-}
dialD_
  :: (DialValue a, WidgetEvent e)
  => WidgetData s a
  -> a
  -> a
  -> [DialCfg s e a]
  -> WidgetNode s e
dialD_ widgetData minVal maxVal configs = dialNode where
  config = mconcat configs
  state = DialState 0 0
  widget = makeDial widgetData minVal maxVal config state
  dialNode = defaultWidgetNode "dial" widget
    & L.info . L.focusable .~ True

makeDial
  :: (DialValue a, WidgetEvent e)
  => WidgetData s a
  -> a
  -> a
  -> DialCfg s e a
  -> DialState
  -> Widget s e
makeDial field minVal maxVal config state = widget where
  widget = createSingle state def {
    singleGetBaseStyle = getBaseStyle,
    singleGetActiveStyle = getActiveStyle,
    singleInit = init,
    singleMerge = merge,
    singleFindByPoint = findByPoint,
    singleHandleEvent = handleEvent,
    singleGetSizeReq = getSizeReq,
    singleRender = render
  }

  dragRate
    | isJust (_dlcDragRate config) = fromJust (_dlcDragRate config)
    | otherwise = toRational (maxVal - minVal) / 1000

  getBaseStyle wenv node = Just style where
    style = collectTheme wenv L.dialStyle

  getActiveStyle wenv node = style where
    (_, dialArea) = getDialInfo wenv node config
    style = activeStyle_ (activeStyleConfig dialArea) wenv node

  init wenv node = resultNode resNode where
    newState = newStateFromModel wenv node state
    resNode = node
      & L.widget .~ makeDial field minVal maxVal config newState

  merge wenv newNode oldNode oldState = resultNode resNode where
    newState
      | isNodePressed wenv newNode = oldState
      | otherwise = newStateFromModel wenv newNode oldState
    resNode = newNode
      & L.widget .~ makeDial field minVal maxVal config newState

  findByPoint wenv node path point
    | isVisible && pointInEllipse point dialArea = Just wni
    | otherwise = Nothing
    where
      isVisible = node ^. L.info . L.visible
      wni = node ^. L.info
      (_, dialArea) = getDialInfo wenv node config

  handleEvent wenv node target evt = case evt of
    Focus prev -> handleFocusChange _dlcOnFocus _dlcOnFocusReq config prev node
    Blur next -> handleFocusChange _dlcOnBlur _dlcOnBlurReq config next node
    KeyAction mod code KeyPressed
      | isCtrl && isKeyUp code -> handleNewPos (pos + warpSpeed)
      | isCtrl && isKeyDown code -> handleNewPos (pos - warpSpeed)
      | isShiftPressed mod && isKeyUp code -> handleNewPos (pos + baseSpeed)
      | isShiftPressed mod && isKeyDown code -> handleNewPos (pos - baseSpeed)
      | isKeyUp code -> handleNewPos (pos + fastSpeed)
      | isKeyDown code -> handleNewPos (pos - fastSpeed)
      where
        DialState maxPos pos = state
        isCtrl = isShortCutControl wenv mod
        baseSpeed = max 1 $ round (fromIntegral maxPos / 1000)
        fastSpeed = max 1 $ round (fromIntegral maxPos / 100)
        warpSpeed = max 1 $ round (fromIntegral maxPos / 10)
        vPos pos = restrictValue 0 maxPos pos
        newResult newPos = addReqsEvts (resultNode newNode) newVal where
          newVal = valueFromPos minVal dragRate newPos
          newState = state { _dlsPos = newPos }
          newNode = node
            & L.widget .~ makeDial field minVal maxVal config newState
        handleNewPos newPos
          | vPos newPos /= pos = Just $ newResult (vPos newPos)
          | otherwise = Nothing
    Move point
      | isNodePressed wenv node -> Just result where
        (_, start) = fromJust $ wenv ^. L.mainBtnPress
        (_, newVal) = posFromPoint minVal maxVal state dragRate start point
        result = addReqsEvts (resultReqs node [RenderOnce]) newVal
    ButtonAction point btn ReleasedBtn clicks
      | clicks == 0 -> Just result where
        reqs = [RenderOnce]
        newState = newStateFromModel wenv node state
        newNode = node
          & L.widget .~ makeDial field minVal maxVal config newState
        result = resultReqs newNode reqs
    WheelScroll _ (Point _ wy) wheelDirection -> Just result where
      DialState maxPos pos = state
      wheelCfg = fromMaybe (theme ^. L.sliderWheelRate) (_dlcWheelRate config)
      wheelRate = fromRational wheelCfg
      tmpPos = pos + round (wy * wheelRate)
      newPos = restrictValue 0 maxPos tmpPos
      newVal = valueFromPos minVal dragRate newPos
      result = addReqsEvts (resultReqs node [RenderOnce]) newVal
    _ -> Nothing
    where
      theme = activeTheme wenv node
      (_, dialArea) = getDialInfo wenv node config
      path = node ^. L.info . L.path
      isSelectKey code = isKeyReturn code || isKeySpace code
      addReqsEvts result newVal = newResult where
        currVal = widgetDataGet (wenv ^. L.model) field
        evts = RaiseEvent <$> fmap ($ newVal) (_dlcOnChange config)
        reqs = widgetDataSet field newVal
          ++ fmap ($ newVal) (_dlcOnChangeReq config)
        newResult
          | currVal /= newVal = result
              & L.requests <>~ Seq.fromList (reqs <> evts)
          | otherwise = result

  getSizeReq wenv node = req where
    theme = activeTheme wenv node
    width = fromMaybe (theme ^. L.dialWidth) (_dlcWidth config)
    req = (fixedSize width, fixedSize width)

  render wenv node renderer = do
    drawArcBorder renderer dialArea start endSnd CW (Just sndColor) dialBW
    drawArcBorder renderer dialArea start endFg CW (Just fgColor) dialBW
    where
      (dialCenter, dialArea) = getDialInfo wenv node config
      DialState maxPos pos = newStateFromModel wenv node state
      posPct = fromIntegral pos / fromIntegral maxPos
      dialBW = max 1 (_rW dialArea * 0.15)
      style = getActiveStyle wenv node
      fgColor = styleFgColor style
      sndColor = styleSndColor style
      start = 90 + 45
      endFg = start + 270 * posPct
      endSnd = 45

  newStateFromModel wenv node oldState = newState where
    currVal = widgetDataGet (wenv ^. L.model) field
    newMaxPos = round (toRational (maxVal - minVal) / dragRate)
    newPos = round (toRational (currVal - minVal) / dragRate)
    newState = oldState {
      _dlsMaxPos = newMaxPos,
      _dlsPos = newPos
    }

posFromPoint
  :: DialValue a
  => a
  -> a
  -> DialState
  -> Rational
  -> Point
  -> Point
  -> (Integer, a)
posFromPoint minVal maxVal state dragRate stPoint point = (newPos, newVal) where
  DialState maxPos pos = state
  Point _ dy = subPoint stPoint point
  tmpPos = pos + round dy
  newPos = restrictValue 0 maxPos tmpPos
  newVal = valueFromPos minVal dragRate newPos

valueFromPos :: DialValue a => a -> Rational -> Integer -> a
valueFromPos minVal dragRate newPos = newVal where
  newVal = minVal + fromFractional (dragRate * fromIntegral newPos)

getDialInfo :: WidgetEnv s e -> WidgetNode s e -> DialCfg s e a -> (Point, Rect)
getDialInfo wenv node config = (dialCenter, dialArea) where
  theme = activeTheme wenv node
  style = activeStyle wenv node
  carea = getContentArea style node
  dialW = fromMaybe (theme ^. L.dialWidth) (_dlcWidth config)
  dialL = _rX carea + (_rW carea - dialW) / 2
  dialT = _rY carea + (_rH carea - dialW) / 2
  dialCenter = Point (dialL + dialW / 2) (dialT + dialW / 2)
  dialArea = Rect dialL dialT dialW dialW

activeStyleConfig :: Rect -> ActiveStyleCfg s e
activeStyleConfig dialArea = def
  & L.isHovered .~ isNodeHoveredEllipse_ dialArea
