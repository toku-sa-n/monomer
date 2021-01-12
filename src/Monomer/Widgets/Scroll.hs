{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}

module Monomer.Widgets.Scroll (
  ScrollCfg,
  ScrollMessage(..),
  scroll,
  scroll_,
  hscroll,
  hscroll_,
  vscroll,
  vscroll_,
  scrollWheelRate,
  scrollBarHoverColor,
  scrollBarColor,
  scrollThumbHoverColor,
  scrollThumbColor,
  scrollStyle,
  scrollBarWidth,
  scrollThumbWidth,
  scrollThumbRadius
) where

import Codec.Serialise
import Control.Applicative ((<|>))
import Control.Lens (ALens', (&), (^.), (.~), (^?!), cloneLens, ix)
import Control.Monad
import Data.Default
import Data.Maybe
import Data.Typeable (cast)
import GHC.Generics

import qualified Data.Sequence as Seq

import Monomer.Widgets.Container

import qualified Monomer.Lens as L

data ScrollType
  = ScrollH
  | ScrollV
  | ScrollBoth
  deriving (Eq, Show)

data ActiveBar
  = HBar
  | VBar
  deriving (Eq, Show, Generic, Serialise)

data ScrollCfg = ScrollCfg {
  _scScrollType :: Maybe ScrollType,
  _scWheelRate :: Maybe Double,
  _scBarColor :: Maybe Color,
  _scBarHoverColor :: Maybe Color,
  _scThumbColor :: Maybe Color,
  _scThumbHoverColor :: Maybe Color,
  _scStyle :: Maybe (ALens' ThemeState StyleState),
  _scBarWidth :: Maybe Double,
  _scThumbWidth :: Maybe Double,
  _scThumbRadius :: Maybe Double
}

instance Default ScrollCfg where
  def = ScrollCfg {
    _scScrollType = Nothing,
    _scWheelRate = Nothing,
    _scBarColor = Nothing,
    _scBarHoverColor = Nothing,
    _scThumbColor = Nothing,
    _scThumbHoverColor = Nothing,
    _scStyle = Nothing,
    _scBarWidth = Nothing,
    _scThumbWidth = Nothing,
    _scThumbRadius = Nothing
  }

instance Semigroup ScrollCfg where
  (<>) t1 t2 = ScrollCfg {
    _scScrollType = _scScrollType t2 <|> _scScrollType t1,
    _scWheelRate = _scWheelRate t2 <|> _scWheelRate t1,
    _scBarColor = _scBarColor t2 <|> _scBarColor t1,
    _scBarHoverColor = _scBarHoverColor t2 <|> _scBarHoverColor t1,
    _scThumbColor = _scThumbColor t2 <|> _scThumbColor t1,
    _scThumbHoverColor = _scThumbHoverColor t2 <|> _scThumbHoverColor t1,
    _scStyle = _scStyle t2 <|> _scStyle t1,
    _scBarWidth = _scBarWidth t2 <|> _scBarWidth t1,
    _scThumbWidth = _scThumbWidth t2 <|> _scThumbWidth t1,
    _scThumbRadius = _scThumbRadius t2 <|> _scThumbRadius t1
  }

instance Monoid ScrollCfg where
  mempty = def

data ScrollState = ScrollState {
  _sstDragging :: Maybe ActiveBar,
  _sstDeltaX :: !Double,
  _sstDeltaY :: !Double,
  _sstChildSize :: Size
} deriving (Eq, Show, Generic, Serialise)

newtype ScrollMessage
  = ScrollTo Rect

data ScrollContext = ScrollContext {
  hScrollRatio :: Double,
  vScrollRatio :: Double,
  hScrollRequired :: Bool,
  vScrollRequired :: Bool,
  hMouseInScroll :: Bool,
  vMouseInScroll :: Bool,
  hMouseInThumb :: Bool,
  vMouseInThumb :: Bool,
  hScrollRect :: Rect,
  vScrollRect :: Rect,
  hThumbRect :: Rect,
  vThumbRect :: Rect
}

instance Default ScrollState where
  def = ScrollState {
    _sstDragging = Nothing,
    _sstDeltaX = 0,
    _sstDeltaY = 0,
    _sstChildSize = def
  }

scrollType :: ScrollType -> ScrollCfg
scrollType st = def {
  _scScrollType = Just st
}

scrollWheelRate :: Double -> ScrollCfg
scrollWheelRate rate = def {
  _scWheelRate = Just rate
}

scrollBarColor :: Color -> ScrollCfg
scrollBarColor col = def {
  _scBarColor = Just col
}

scrollBarHoverColor :: Color -> ScrollCfg
scrollBarHoverColor col = def {
  _scBarHoverColor = Just col
}

scrollThumbColor :: Color -> ScrollCfg
scrollThumbColor col = def {
  _scThumbColor = Just col
}

scrollThumbHoverColor :: Color -> ScrollCfg
scrollThumbHoverColor col = def {
  _scThumbHoverColor = Just col
}

scrollBarWidth :: Double -> ScrollCfg
scrollBarWidth w = def {
  _scBarWidth = Just w
}

scrollThumbWidth :: Double -> ScrollCfg
scrollThumbWidth w = def {
  _scThumbWidth = Just w
}

scrollThumbRadius :: Double -> ScrollCfg
scrollThumbRadius r = def {
  _scThumbRadius = Just r
}

scrollStyle :: ALens' ThemeState StyleState -> ScrollCfg
scrollStyle style = def {
  _scStyle = Just style
}

scroll :: WidgetNode s e -> WidgetNode s e
scroll managedWidget = scroll_ managedWidget [def]

scroll_ :: WidgetNode s e -> [ScrollCfg] -> WidgetNode s e
scroll_ managed configs = makeNode (makeScroll config def) managed where
  config = mconcat configs

hscroll :: WidgetNode s e -> WidgetNode s e
hscroll managedWidget = hscroll_ managedWidget [def]

hscroll_ :: WidgetNode s e -> [ScrollCfg] -> WidgetNode s e
hscroll_ managed configs = makeNode (makeScroll config def) managed where
  config = mconcat (scrollType ScrollH : configs)

vscroll :: WidgetNode s e -> WidgetNode s e
vscroll managedWidget = vscroll_ managedWidget [def]

vscroll_ :: WidgetNode s e -> [ScrollCfg] -> WidgetNode s e
vscroll_ managed configs = makeNode (makeScroll config def) managed where
  config = mconcat (scrollType ScrollV : configs)

makeNode :: Widget s e -> WidgetNode s e -> WidgetNode s e
makeNode widget managedWidget = defaultWidgetNode "scroll" widget
  & L.info . L.focusable .~ False
  & L.children .~ Seq.singleton managedWidget

makeScroll :: ScrollCfg -> ScrollState -> Widget s e
makeScroll config state = widget where
  baseWidget = createContainer state def {
    containerGetBaseStyle = getBaseStyle,
    containerRestore = restore,
    containerHandleEvent = handleEvent,
    containerHandleMessage = handleMessage,
    containerGetSizeReq = getSizeReq
  }
  widget = baseWidget {
    widgetResize = scrollResize Nothing state,
    widgetRender = render
  }

  ScrollState dragging dx dy cs = state
  Size childWidth childHeight = cs

  getBaseStyle wenv node = _scStyle config >>= handler where
    handler lstyle = Just $ collectTheme wenv (cloneLens lstyle)

  restore wenv oldState oldNode node = resultWidget newNode where
    newNode = node
      & L.widget .~ makeScroll config oldState

  handleEvent wenv target evt node = case evt of
    ButtonAction point btn status _ -> result where
      leftPressed = status == PressedBtn && btn == wenv ^. L.mainButton
      btnReleased = status == ReleasedBtn && btn == wenv ^. L.mainButton
      isDragging = isJust $ _sstDragging state
      startDrag = leftPressed && not isDragging
      jumpScrollH = btnReleased && not isDragging && hMouseInScroll
      jumpScrollV = btnReleased && not isDragging && vMouseInScroll
      newState
        | startDrag && hMouseInThumb = state { _sstDragging = Just HBar }
        | startDrag && vMouseInThumb = state { _sstDragging = Just VBar }
        | jumpScrollH = updateScrollThumb state HBar point contentArea sctx
        | jumpScrollV = updateScrollThumb state VBar point contentArea sctx
        | btnReleased = state { _sstDragging = Nothing }
        | otherwise = state
      newNode = rebuildWidget wenv newState node
      handledResult = Just $ resultReqs newNode scrollReqs
      result
        | leftPressed && (hMouseInThumb || vMouseInThumb) = handledResult
        | btnReleased && (hMouseInScroll || vMouseInScroll) = handledResult
        | btnReleased && isDragging = handledResult
        | otherwise = Nothing
    Move point -> result where
      drag bar = updateScrollThumb state bar point contentArea sctx
      makeWidget state = rebuildWidget wenv state node
      makeResult state = resultReqs (makeWidget state) (RenderOnce : scrollReqs)
      result = fmap (makeResult . drag) dragging
    WheelScroll _ (Point wx wy) wheelDirection -> result where
      changedX = wx /= 0 && childWidth > cw
      changedY = wy /= 0 && childHeight > ch
      needsUpdate = changedX || changedY
      makeWidget state = rebuildWidget wenv state node
      makeResult state = resultReqs (makeWidget state) scrollReqs
      result
        | needsUpdate = Just $ makeResult newState
        | otherwise = Nothing
      stepX
        | wheelDirection == WheelNormal = -wheelRate * wx
        | otherwise = wheelRate * wx
      stepY
        | wheelDirection == WheelNormal = wheelRate * wy
        | otherwise = -wheelRate * wy
      newState = state {
        _sstDeltaX = scrollAxis (stepX + dx) childWidth cw,
        _sstDeltaY = scrollAxis (stepY + dy) childHeight ch
      }
    _ -> Nothing
    where
      theme = activeTheme wenv node
      style = scrollActiveStyle wenv node
      contentArea = getContentArea style node
      Rect cx cy cw ch = contentArea
      sctx@ScrollContext{..} = scrollStatus config wenv state node
      scrollReqs = [IgnoreChildrenEvents, IgnoreParentEvents]
      wheelRate = fromMaybe (theme ^. L.scrollWheelRate) (_scWheelRate config)

  scrollAxis reqDelta childLength vpLength
    | maxDelta == 0 = 0
    | reqDelta < 0 = max reqDelta (-maxDelta)
    | otherwise = min reqDelta 0
    where
      maxDelta = max 0 (childLength - vpLength)

  handleMessage wenv ctx message node = result where
    handleScrollMessage (ScrollTo rect) = scrollTo wenv node rect
    result = cast message >>= handleScrollMessage

  scrollTo wenv node rect = result where
    style = scrollActiveStyle wenv node
    contentArea = getContentArea style node
    Rect rx ry rw rh = rect
    Rect cx cy cw ch = contentArea
    diffL = cx - rx
    diffR = cx + cw - (rx + rw)
    diffT = cy - ry
    diffB = cy + ch - (ry + rh)
    stepX
      | rectInRectH rect contentArea = dx
      | abs diffL <= abs diffR = diffL + dx
      | otherwise = diffR + dx
    stepY
      | rectInRectV rect contentArea = dy
      | abs diffT <= abs diffB = diffT + dy
      | otherwise = diffB + dy
    newState = state {
      _sstDeltaX = scrollAxis stepX childWidth cw,
      _sstDeltaY = scrollAxis stepY childHeight ch
    }
    newNode = rebuildWidget wenv newState node
    result
      | rectInRect rect contentArea = Nothing
      | otherwise = Just $ resultWidget newNode

  updateScrollThumb state activeBar point contentArea sctx = newState where
    Point px py = point
    ScrollContext{..} = sctx
    Rect cx cy cw ch = contentArea
    hMid = _rW hThumbRect / 2
    vMid = _rH vThumbRect / 2
    hDelta = (cx - px + hMid) / hScrollRatio
    vDelta = (cy - py + vMid) / vScrollRatio
    newDeltaX
      | activeBar == HBar = scrollAxis hDelta childWidth cw
      | otherwise = dx
    newDeltaY
      | activeBar == VBar = scrollAxis vDelta childHeight ch
      | otherwise = dy
    newState = state {
      _sstDeltaX = newDeltaX,
      _sstDeltaY = newDeltaY
    }

  rebuildWidget wenv newState node = newNode where
    newWidget = makeScroll config newState
    tempNode = node & L.widget .~ newWidget
    vp = tempNode ^. L.info . L.viewport
    ra = tempNode ^. L.info . L.renderArea
    newNode = scrollResize (Just newWidget) newState wenv vp ra tempNode

  getSizeReq :: ContainerGetSizeReqHandler s e a
  getSizeReq wenv currState node children = sizeReq where
    style = scrollActiveStyle wenv node
    child = Seq.index children 0
    tw = sizeReqMax $ child ^. L.info . L.sizeReqW
    th = sizeReqMax $ child ^. L.info . L.sizeReqH
    Size w h = fromMaybe def (addOuterSize style (Size tw th))
    factor = 1

    sizeReq = (FlexSize w factor, FlexSize h factor)

  scrollResize uWidget state wenv viewport renderArea node = newNode where
    style = scrollActiveStyle wenv node
    scrollType = fromMaybe ScrollBoth (_scScrollType config)

    Rect cl ct cw ch = fromMaybe def (removeOuterBounds style renderArea)
    dx = _sstDeltaX state
    dy = _sstDeltaY state

    child = Seq.index (node ^. L.children) 0
    childWidth2 = sizeReqMax $ child ^. L.info . L.sizeReqW
    childHeight2 = sizeReqMax $ child ^. L.info . L.sizeReqH

    areaW
      | scrollType == ScrollV = cw
      | otherwise = max cw childWidth2
    areaH
      | scrollType == ScrollH = ch
      | otherwise = max ch childHeight2
    newDx = scrollAxis dx areaW cw
    newDy = scrollAxis dy areaH ch
    cRenderArea = Rect (cl + newDx) (ct + newDy) areaW areaH
    cViewport = fromMaybe def (intersectRects viewport cRenderArea)

    defWidget = makeScroll config $ state {
      _sstChildSize = Size areaW areaH
    }
    newWidget = fromMaybe defWidget uWidget
    cWidget = child ^. L.widget
    tempChild = widgetResize cWidget wenv viewport cRenderArea child
    newChild = tempChild
      & L.info . L.viewport .~ cViewport
      & L.info . L.renderArea .~ cRenderArea

    newNode = node
      & L.widget .~ newWidget
      & L.info . L.viewport .~ viewport
      & L.info . L.renderArea .~ renderArea
      & L.children .~ Seq.singleton newChild

  render renderer wenv node =
    drawInScissor renderer True viewport $
      drawStyledAction renderer renderArea style $ \_ -> do
        widgetRender (child ^. L.widget) renderer wenv child
        renderAfter renderer wenv node
    where
      style = scrollActiveStyle wenv node
      child = node ^. L.children ^?! ix 0
      viewport = node ^. L.info . L.viewport
      renderArea = node ^. L.info . L.renderArea

  renderAfter renderer wenv node = do
    when hScrollRequired $
      drawRect renderer hScrollRect barColorH Nothing

    when vScrollRequired $
      drawRect renderer vScrollRect barColorV Nothing

    when hScrollRequired $
      drawRect renderer hThumbRect thumbColorH thumbRadius

    when vScrollRequired $
      drawRect renderer vThumbRect thumbColorV thumbRadius
    where
      ScrollContext{..} = scrollStatus config wenv state node
      draggingH = _sstDragging state == Just HBar
      draggingV = _sstDragging state == Just VBar
      theme = wenv ^. L.theme
      athm = activeTheme wenv node
      tmpRad = fromMaybe (athm ^. L.scrollThumbRadius) (_scThumbRadius config)
      thumbRadius
        | tmpRad > 0 = Just (radius tmpRad)
        | otherwise = Nothing

      cfgBarBCol = _scBarColor config
      cfgBarHCol = _scBarHoverColor config
      cfgThumbBCol = _scThumbColor config
      cfgThumbHCol = _scThumbHoverColor config

      barBCol = cfgBarBCol <|> Just (theme ^. L.basic . L.scrollBarColor)
      barHCol = cfgBarHCol <|> Just (theme ^. L.hover . L.scrollBarColor)
      thumbBCol = cfgThumbBCol <|> Just (theme ^. L.basic . L.scrollThumbColor)
      thumbHCol = cfgThumbHCol <|> Just (theme ^. L.hover. L.scrollThumbColor)

      barColorH
        | hMouseInScroll = barHCol
        | otherwise = barBCol
      barColorV
        | vMouseInScroll = barHCol
        | otherwise = barBCol
      thumbColorH
        | hMouseInThumb || draggingH = thumbHCol
        | otherwise = thumbBCol
      thumbColorV
        | vMouseInThumb || draggingV = thumbHCol
        | otherwise = thumbBCol

scrollActiveStyle :: WidgetEnv s e -> WidgetNode s e -> StyleState
scrollActiveStyle wenv node
  | isFocused wenv child = focusedStyle wenv node
  | otherwise = activeStyle wenv node
  where
    child = node ^. L.children ^?! ix 0

scrollStatus
  :: ScrollCfg
  -> WidgetEnv s e
  -> ScrollState
  -> WidgetNode s e
  -> ScrollContext
scrollStatus config wenv scrollState node = ScrollContext{..} where
  ScrollState _ dx dy (Size childWidth childHeight) = scrollState
  mousePos = _ipsMousePos (_weInputStatus wenv)
  theme = activeTheme wenv node
  style = scrollActiveStyle wenv node
  contentArea = getContentArea style node
  barW = fromMaybe (theme ^. L.scrollBarWidth) (_scBarWidth config)
  thumbW = fromMaybe (theme ^. L.scrollThumbWidth) (_scThumbWidth config)
  caLeft = _rX contentArea
  caTop = _rY contentArea
  caWidth = _rW contentArea
  caHeight = _rH contentArea
  hScrollTop = caHeight - barW
  vScrollLeft = caWidth - barW
  hRatio = caWidth / childWidth
  vRatio = caHeight / childHeight
  hRatioR = (caWidth - barW) / childWidth
  vRatioR = (caHeight - barW) / childHeight
  (hScrollRatio, vScrollRatio)
    | hRatio < 1 && vRatio < 1 = (hRatioR, vRatioR)
    | otherwise = (hRatio, vRatio)
  hScrollRequired = hScrollRatio < 1
  vScrollRequired = vScrollRatio < 1
  hScrollRect = Rect {
    _rX = caLeft,
    _rY = caTop + hScrollTop,
    _rW = caWidth,
    _rH = barW
  }
  vScrollRect = Rect {
    _rX = caLeft + vScrollLeft,
    _rY = caTop,
    _rW = barW,
    _rH = caHeight
  }
  hThumbRect = Rect {
    _rX = caLeft - hScrollRatio * dx,
    _rY = caTop + hScrollTop + (barW - thumbW) / 2,
    _rW = hScrollRatio * caWidth,
    _rH = thumbW
  }
  vThumbRect = Rect {
    _rX = caLeft + vScrollLeft + (barW - thumbW) / 2,
    _rY = caTop - vScrollRatio * dy,
    _rW = thumbW,
    _rH = vScrollRatio * caHeight
  }
  hMouseInScroll = pointInRect mousePos hScrollRect
  vMouseInScroll = pointInRect mousePos vScrollRect
  hMouseInThumb = pointInRect mousePos hThumbRect
  vMouseInThumb = pointInRect mousePos vThumbRect
