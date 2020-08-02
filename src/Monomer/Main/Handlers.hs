{-# LANGUAGE FlexibleContexts #-}

module Monomer.Main.Handlers (
  HandlerStep,
  handleWidgetResult,
  handleSystemEvents,
  handleWidgetInit
) where

import Control.Concurrent.Async (async)
import Control.Lens (use, (.=))
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)
import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.IO.Class
import Data.Maybe
import Data.Sequence (Seq(..), (><))

import qualified Data.Sequence as Seq
import qualified SDL

import Monomer.Common.Geometry
import Monomer.Common.Tree (Path)
import Monomer.Event.Core
import Monomer.Event.Keyboard
import Monomer.Event.Types
import Monomer.Main.Types
import Monomer.Main.Util
import Monomer.Graphics.Renderer
import Monomer.Widget.Types
import Monomer.Widget.Util

type HandlerStep s e = (WidgetEnv s e, Seq e, WidgetInstance s e)

getTargetPath
  :: WidgetEnv s e
  -> Maybe Path
  -> Maybe Path
  -> Path
  -> SystemEvent
  -> WidgetInstance s e
  -> Maybe Path
getTargetPath wenv pressed overlay target event widgetRoot = case event of
    -- Keyboard
    KeyAction{}            -> pathEvent target
    TextInput _            -> pathEvent target
    -- Clipboard
    Clipboard _            -> pathEvent target
    -- Mouse/touch
    ButtonAction point _ _ -> pointEvent point
    Click point _          -> pointEvent point
    WheelScroll point _ _  -> pointEvent point
    Focus                  -> pathEvent target
    Blur                   -> pathEvent target
    Enter point            -> pointEvent point
    Move point             -> pointEvent point
    Leave oldPath _        -> pathEvent oldPath
  where
    startPath = fromMaybe rootPath overlay
    widget = _wiWidget widgetRoot
    pathEvent = Just
    pathFromPoint point = _widgetFind widget wenv startPath point widgetRoot
    pointEvent point = pressed <|> pathFromPoint point <|> overlay

handleSystemEvents
  :: (MonomerM s m)
  => Renderer m
  -> WidgetEnv s e
  -> [SystemEvent]
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleSystemEvents renderer wenv systemEvents widgetRoot = nextStep where
  reducer (currWctx, currEvents, currRoot) systemEvent = do
    focused <- use focused

    (wenv2, evts2, wroot2)
      <- handleSystemEvent renderer currWctx systemEvent focused currRoot
    return (wenv2, currEvents >< evts2, wroot2)
  nextStep = foldM reducer (wenv, Seq.empty, widgetRoot) systemEvents

handleSystemEvent
  :: (MonomerM s m)
  => Renderer m
  -> WidgetEnv s e
  -> SystemEvent
  -> Path
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleSystemEvent renderer wenv event currentTarget widgetRoot = do
  pressed <- use latestPressed
  overlay <- use activeOverlay

  case getTargetPath wenv pressed overlay currentTarget event widgetRoot of
    Nothing -> return (wenv, Seq.empty, widgetRoot)
    Just target -> do
      let widget = _wiWidget widgetRoot
      let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
      let evtResult = _widgetHandleEvent widget wenv target event widgetRoot
      let widgetResult = fromMaybe emptyResult evtResult
      let reqs = _wrRequests widgetResult
      let stopProcessing = isJust $ Seq.findIndexL isIgnoreParentEvents reqs

      handleWidgetResult renderer wenv widgetResult
        >>= handleFocusChange renderer event stopProcessing

handleWidgetInit
  :: (MonomerM s m)
  => Renderer m
  -> WidgetEnv s e
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleWidgetInit renderer wenv widgetRoot = do
  let widget = _wiWidget widgetRoot
  let widgetResult = _widgetInit widget wenv widgetRoot

  handleWidgetResult renderer wenv widgetResult

handleWidgetResult
  :: (MonomerM s m)
  => Renderer m
  -> WidgetEnv s e
  -> WidgetResult s e
  -> m (HandlerStep s e)
handleWidgetResult renderer wenv (WidgetResult reqs events evtRoot) = do
  let evtUpdates = getUpdateModelReqs reqs
  let evtModel = foldr (.) id evtUpdates (_weModel wenv)
  let evtWctx = wenv { _weModel = evtModel }

  handleNewWidgetTasks reqs

  handleFocusSet renderer reqs (evtWctx, events, evtRoot)
    >>= handleClipboardGet renderer reqs
    >>= handleClipboardSet renderer reqs
    >>= handleSendMessages renderer reqs
    >>= handleOverlaySet renderer reqs
    >>= handleOverlayReset renderer reqs
    >>= handleResize renderer reqs

handleFocusChange
  :: (MonomerM s m)
  => Renderer m
  -> SystemEvent
  -> Bool
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleFocusChange renderer systemEvent stopProcessing (wenv, events, widgetRoot)
  | focusChangeRequested = do
      oldFocus <- use focused
      (newWenv1, newEvents1, newRoot1)
        <- handleSystemEvent renderer wenv Blur oldFocus widgetRoot

      let newFocus = findNextFocusable newWenv1 oldFocus widgetRoot
      let tempWenv = newWenv1 {
        _weFocusedPath = newFocus
      }
      (newWenv2, newEvents2, newRoot2)
        <- handleSystemEvent renderer tempWenv Focus newFocus newRoot1

      focused .= newFocus

      return (newWenv2, events >< newEvents1 >< newEvents2, widgetRoot)
  | otherwise = return (wenv, events, widgetRoot)
  where
    focusChangeRequested = not stopProcessing && isKeyPressed systemEvent keyTab

handleFocusSet
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleFocusSet renderer reqs previousStep =
  case Seq.filter isSetFocus reqs of
    SetFocus newFocus :<| _ -> do
      focused .= newFocus

      return previousStep
    _ -> return previousStep

handleResize
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleResize renderer reqs previousStep =
  case Seq.filter isResize reqs of
    Resize :<| _ -> do
      windowSize <- use windowSize

      let (wenv, events, widgetRoot) = previousStep
      let newWidgetRoot = resizeWidget wenv windowSize widgetRoot

      return (wenv, events, newWidgetRoot)
    _ -> return previousStep

handleClipboardGet
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleClipboardGet renderer reqs previousStep = do
    hasText <- SDL.hasClipboardText
    contents <- if hasText
                  then fmap ClipboardText SDL.getClipboardText
                  else return ClipboardEmpty

    foldM (reducer contents) previousStep reqs
  where
    reducer contents (wenv, events, widgetRoot) (GetClipboard path) = do
      (newWenv2, newEvents2, newRoot2)
        <- handleSystemEvent renderer wenv (Clipboard contents) path widgetRoot

      return (newWenv2, events >< newEvents2, newRoot2)
    reducer contents previousStep _ = return previousStep

handleClipboardSet
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleClipboardSet renderer reqs previousStep =
  case Seq.filter isSetClipboard reqs of
    SetClipboard (ClipboardText text) :<| _ -> do
      SDL.setClipboardText text

      return previousStep
    _ -> return previousStep

handleOverlaySet
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleOverlaySet renderer reqs previousStep =
  case Seq.filter isSetOverlay reqs of
    SetOverlay path :<| _ -> do
      activeOverlay .= Just path

      return previousStep
    _ -> return previousStep

handleOverlayReset
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleOverlayReset renderer reqs previousStep =
  case Seq.filter isSetOverlay reqs of
    ResetOverlay :<| _ -> do
      activeOverlay .= Nothing

      return previousStep
    _ -> return previousStep

handleSendMessages
  :: (MonomerM s m)
  => Renderer m
  -> Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleSendMessages renderer reqs previousStep = nextStep where
  nextStep = foldM reducer previousStep reqs
  reducer previousStep (SendMessage path message) = do
    currentFocus <- use focused

    let (wenv, events, widgetRoot) = previousStep
    let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
    let widget = _wiWidget widgetRoot
    let msgResult = _widgetHandleMessage widget wenv path message widgetRoot
    let widgetResult = fromMaybe emptyResult msgResult

    (newWenv, newEvents, newWidgetRoot)
      <- handleWidgetResult renderer wenv widgetResult

    return (newWenv, events >< newEvents, newWidgetRoot)
  reducer previousStep _ = return previousStep

handleNewWidgetTasks :: (MonomerM s m) => Seq (WidgetRequest s) -> m ()
handleNewWidgetTasks reqs = do
  let taskHandlers = Seq.filter isTaskHandler reqs
  let producerHandlers = Seq.filter isProducerHandler reqs

  singleTasks <- forM taskHandlers $ \(RunTask path handler) -> do
    asyncTask <- liftIO $ async (liftIO handler)
    return $ WidgetTask path asyncTask

  producerTasks <- forM producerHandlers $ \(RunProducer path handler) -> do
    newChannel <- liftIO newTChanIO
    asyncTask <- liftIO $ async (liftIO $ handler (sendMessage newChannel))
    return $ WidgetProducer path newChannel asyncTask

  previousTasks <- use widgetTasks
  widgetTasks .= previousTasks >< singleTasks >< producerTasks

sendMessage :: TChan e -> e -> IO ()
sendMessage channel message = atomically $ writeTChan channel message
