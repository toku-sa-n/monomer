{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE TemplateHaskell #-}

module Monomer.Widgets.Singles.ColorPicker (
  colorPicker,
  colorPicker_,
  colorPickerV,
  colorPickerV_,
  colorPickerD_
) where

import Control.Applicative ((<|>))
import Control.Lens ((&), (^.), (.~), ALens', abbreviatedFields, makeLensesWith)
import Data.Default
import Data.Maybe
import Data.Text (Text)

import Monomer.Core
import Monomer.Core.Combinators

import Monomer.Widgets.Composite
import Monomer.Widgets.Containers.Box
import Monomer.Widgets.Containers.Stack
import Monomer.Widgets.Singles.Label
import Monomer.Widgets.Singles.NumericField
import Monomer.Widgets.Singles.Slider
import Monomer.Widgets.Singles.Spacer

import qualified Monomer.Lens as L

data ColorPickerCfg s e = ColorPickerCfg {
  _cpcShowAlpha :: Maybe Bool,
  _cpcOnFocus :: [e],
  _cpcOnFocusReq :: [WidgetRequest s e],
  _cpcOnBlur :: [e],
  _cpcOnBlurReq :: [WidgetRequest s e],
  _cpcOnChange :: [Color -> e],
  _cpcOnChangeReq :: [WidgetRequest s e]
}

instance Default (ColorPickerCfg s e) where
  def = ColorPickerCfg {
    _cpcShowAlpha = Nothing,
    _cpcOnFocus = [],
    _cpcOnFocusReq = [],
    _cpcOnBlur = [],
    _cpcOnBlurReq = [],
    _cpcOnChange = [],
    _cpcOnChangeReq = []
  }

instance Semigroup (ColorPickerCfg s e) where
  (<>) a1 a2 = def {
    _cpcShowAlpha = _cpcShowAlpha a2 <|> _cpcShowAlpha a1,
    _cpcOnFocus = _cpcOnFocus a1 <> _cpcOnFocus a2,
    _cpcOnFocusReq = _cpcOnFocusReq a1 <> _cpcOnFocusReq a2,
    _cpcOnBlur = _cpcOnBlur a1 <> _cpcOnBlur a2,
    _cpcOnBlurReq = _cpcOnBlurReq a1 <> _cpcOnBlurReq a2,
    _cpcOnChange = _cpcOnChange a1 <> _cpcOnChange a2,
    _cpcOnChangeReq = _cpcOnChangeReq a1 <> _cpcOnChangeReq a2
  }

instance Monoid (ColorPickerCfg s e) where
  mempty = def

instance CmbOnFocus (ColorPickerCfg s e) e where
  onFocus fn = def {
    _cpcOnFocus = [fn]
  }

instance CmbOnFocusReq (ColorPickerCfg s e) s e where
  onFocusReq req = def {
    _cpcOnFocusReq = [req]
  }

instance CmbOnBlur (ColorPickerCfg s e) e where
  onBlur fn = def {
    _cpcOnBlur = [fn]
  }

instance CmbOnBlurReq (ColorPickerCfg s e) s e where
  onBlurReq req = def {
    _cpcOnBlurReq = [req]
  }

instance CmbOnChange (ColorPickerCfg s e) Color e where
  onChange fn = def {
    _cpcOnChange = [fn]
  }

instance CmbOnChangeReq (ColorPickerCfg s e) s e where
  onChangeReq req = def {
    _cpcOnChangeReq = [req]
  }

colorPickerAlpha :: Bool -> ColorPickerCfg s e
colorPickerAlpha show = def {
  _cpcShowAlpha = Just show
}

data ColorPickerEvt
  = PickerFocus
  | PickerBlur
  | ColorChanged Int
  | AlphaChanged Double
  deriving (Eq, Show)

colorPicker
  :: (WidgetModel sp, WidgetEvent ep)
  => ALens' sp Color
  -> WidgetNode sp ep
colorPicker field = colorPicker_ field def

colorPicker_
  :: (WidgetModel sp, WidgetEvent ep)
  => ALens' sp Color
  -> [ColorPickerCfg sp ep]
  -> WidgetNode sp ep
colorPicker_ field configs = colorPickerD_ wlens configs [] where
  wlens = WidgetLens field

colorPickerV
  :: (WidgetModel sp, WidgetEvent ep)
  => Color
  -> (Color -> ep)
  -> WidgetNode sp ep
colorPickerV value handler = colorPickerV_ value handler def

colorPickerV_
  :: (WidgetModel sp, WidgetEvent ep)
  => Color
  -> (Color -> ep)
  -> [ColorPickerCfg sp ep]
  -> WidgetNode sp ep
colorPickerV_ value handler configs = colorPickerD_ wdata newCfgs [] where
  wdata = WidgetValue value
  newCfgs = onChange handler : configs

colorPickerD_
  :: (WidgetModel sp, WidgetEvent ep)
  => WidgetData sp Color
  -> [ColorPickerCfg sp ep]
  -> [CompositeCfg Color ColorPickerEvt sp ep]
  -> WidgetNode sp ep
colorPickerD_ wdata cfgs cmpCfgs = newNode where
  cfg = mconcat cfgs
  uiBuilder = buildUI cfg
  evtHandler = handleEvent cfg
  newNode = compositeD_ "colorPicker" wdata uiBuilder evtHandler cmpCfgs

buildUI
  :: ColorPickerCfg sp ep
  -> WidgetEnv Color ColorPickerEvt
  -> Color
  -> WidgetNode Color ColorPickerEvt
buildUI config wenv model = mainTree where
  showAlpha = fromMaybe False (_cpcShowAlpha config)
  colorSample = filler `style` [width 32, bgColor model]
  compRow lensCol evt lbl minV maxV = hstack [
      label lbl `style` [width 48],
      spacer_ [width 2],
      hslider_ lensCol minV maxV [onChange evt, onFocus PickerFocus, onBlur PickerBlur] `style` [paddingV 5],
      spacer_ [width 2],
      numericField_ lensCol [minValue minV, maxValue maxV, onChange evt, onFocus PickerFocus, onBlur PickerBlur]
        `style` [width 40, padding 0, textRight]
    ]
  colorRow lens lbl = compRow lens ColorChanged lbl 0 255
  alphaRow lens lbl = compRow lens AlphaChanged lbl 0 1
  mainTree = hstack_ [sizeReqUpdater clearExtra] [
      vstack [
        colorRow L.r "Red",
        spacer_ [height 2],
        colorRow L.g "Green",
        spacer_ [height 2],
        colorRow L.b "Blue",
        spacer_ [height 2] `visible` showAlpha,
        alphaRow L.a "Alpha" `visible` showAlpha
      ],
      spacer_ [width 2],
      box_ [alignTop] colorSample
    ] `style` [padding 0]

handleEvent
  :: (WidgetModel sp, WidgetEvent ep)
  => ColorPickerCfg sp ep
  -> WidgetEnv Color ColorPickerEvt
  -> WidgetNode Color ColorPickerEvt
  -> Color
  -> ColorPickerEvt
  -> [EventResponse Color ColorPickerEvt sp ep]
handleEvent cfg wenv node model evt = case evt of
  PickerFocus -> reportFocus
  PickerBlur -> reportBlur
  ColorChanged _ -> reportChange
  AlphaChanged _ -> reportChange
  where
    report evts reqs = (Report <$> evts) ++ (RequestParent <$> reqs)
    reportFocus
      | not (isNodeParentOfFocused wenv node) = []
      | otherwise = report (_cpcOnFocus cfg) (_cpcOnFocusReq cfg)
    reportBlur
      | isNodeParentOfFocused wenv node = []
      | otherwise = report (_cpcOnBlur cfg) (_cpcOnBlurReq cfg)
    reportChange = report (($ model) <$> _cpcOnChange cfg) (_cpcOnChangeReq cfg)