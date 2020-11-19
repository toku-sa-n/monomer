{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}

module Monomer.Main.Handlers (
  HandlerStep,
  handleWidgetResult,
  handleSystemEvents,
  handleResourcesInit,
  handleWidgetInit
) where

import Control.Concurrent.Async (async)
import Control.Lens ((&), (^.), (%~), (.=), at, non, use)
import Control.Monad.STM (atomically)
import Control.Concurrent.STM.TChan (TChan, newTChanIO, writeTChan)
import Control.Applicative ((<|>))
import Control.Monad
import Control.Monad.IO.Class
import Data.List (foldl')
import Data.Maybe
import Data.Sequence (Seq(..), (><), (|>))
import Data.Typeable (Typeable)
import SDL (($=))

import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified SDL
import qualified SDL.Raw.Enum as SDLE
import qualified SDL.Raw.Event as SDLE
import qualified SDL.Raw.Types as SDL

import Monomer.Core
import Monomer.Event
import Monomer.Main.Types
import Monomer.Main.Util

import qualified Monomer.Lens as L

type HandlerStep s e = (WidgetEnv s e, Seq e, WidgetInstance s e)

handleSystemEvents
  :: (MonomerM s m)
  => WidgetEnv s e
  -> [SystemEvent]
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleSystemEvents wenv systemEvents widgetRoot = nextStep where
  reducer (currWctx, currEvents, currRoot) evt = do
    focused <- use L.pathFocus

    (wenv2, evts2, wroot2) <- handleSystemEvent currWctx evt focused currRoot
    return (wenv2, currEvents >< evts2, wroot2)
  nextStep = foldM reducer (wenv, Seq.empty, widgetRoot) systemEvents

handleSystemEvent
  :: (MonomerM s m)
  => WidgetEnv s e
  -> SystemEvent
  -> Path
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleSystemEvent wenv event currentTarget widgetRoot = do
  pressed <- use L.pathPressed
  overlay <- use L.pathOverlay

  case getTargetPath wenv pressed overlay currentTarget event widgetRoot of
    Nothing -> return (wenv, Seq.empty, widgetRoot)
    Just target -> do
      let widget = _wiWidget widgetRoot
      let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
      let evtResult = widgetHandleEvent widget wenv target event widgetRoot
      let widgetResult = fromMaybe emptyResult evtResult

      handleWidgetResult wenv widgetResult {
        _wrRequests = addFocusReq event (_wrRequests widgetResult)
      }

handleResourcesInit :: MonomerM s m => m ()
handleResourcesInit = do
  cursors <- foldM insert Map.empty [toEnum 0 ..]
  L.cursorIcons .= cursors
  where
    insert map icon = do
      cursor <- SDLE.createSystemCursor (cursorToSDL icon)
      return $ Map.insert icon cursor map

handleWidgetInit
  :: (MonomerM s m)
  => WidgetEnv s e
  -> WidgetInstance s e
  -> m (HandlerStep s e)
handleWidgetInit wenv widgetRoot = do
  let widget = _wiWidget widgetRoot
  let widgetResult = widgetInit widget wenv widgetRoot

  handleWidgetResult wenv widgetResult

handleWidgetResult
  :: (MonomerM s m)
  => WidgetEnv s e
  -> WidgetResult s e
  -> m (HandlerStep s e)
handleWidgetResult wenv (WidgetResult reqs events evtRoot) =
  handleRequests reqs (wenv, events, evtRoot)
    >>= handleResize reqs

handleRequests
  :: (MonomerM s m)
  => Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleRequests reqs step = foldM handleRequest step reqs where
  handleRequest step req = case req of
    IgnoreParentEvents -> return step
    IgnoreChildrenEvents -> return step
    Resize -> return step
    MoveFocus dir -> handleMoveFocus dir step
    SetFocus path -> handleSetFocus path step
    GetClipboard path -> handleGetClipboard path step
    SetClipboard cdata -> handleSetClipboard cdata step
    StartTextInput rect -> handleStartTextInput rect step
    StopTextInput -> handleStopTextInput step
    SetOverlay path -> handleSetOverlay path step
    ResetOverlay -> handleResetOverlay step
    SetCursorIcon icon -> handleSetCursorIcon icon step
    UpdateWindow req -> handleUpdateWindow req step
    UpdateModel fn -> handleUpdateModel fn step
    SendMessage path msg -> handleSendMessage path msg step
    RunTask path handler -> handleRunTask path handler step
    RunProducer path handler -> handleRunProducer path handler step

handleResize
  :: (MonomerM s m)
  => Seq (WidgetRequest s)
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleResize reqs previousStep =
  case Seq.filter isResize reqs of
    Resize :<| _ -> do
      windowSize <- use L.windowSize

      let (wenv, events, widgetRoot) = previousStep
      let newWidgetRoot = resizeWidget wenv windowSize widgetRoot

      return (wenv, events, newWidgetRoot)
    _ -> return previousStep

handleMoveFocus
  :: (MonomerM s m) => FocusDirection -> HandlerStep s e -> m (HandlerStep s e)
handleMoveFocus direction  (wenv, events, root) = do
  oldFocus <- use L.pathFocus
  overlay <- use L.pathOverlay
  let wenv0 = wenv { _weFocusedPath = rootPath }
  (wenv1, events1, root1) <- handleSystemEvent wenv0 Blur oldFocus root

  let newFocus = findNextFocus wenv1 direction oldFocus overlay root1
  let tempWenv = wenv1 { _weFocusedPath = newFocus }

  L.pathFocus .= newFocus
  (wenv2, events2, root2) <- handleSystemEvent tempWenv Focus newFocus root1

  return (wenv2, events >< events1 >< events2, root2)

handleSetFocus
  :: (MonomerM s m) => Path -> HandlerStep s e -> m (HandlerStep s e)
handleSetFocus newFocus (wenv, events, root) =  do
  let wenv0 = wenv { _weFocusedPath = newFocus }

  oldFocus <- use L.pathFocus
  L.pathFocus .= newFocus

  (wenv1, events1, root1) <- handleSystemEvent wenv0 Blur oldFocus root
  (wenv2, events2, root2) <- handleSystemEvent wenv1 Focus newFocus root1

  return (wenv2, events >< events1 >< events2, root2)

handleGetClipboard
  :: (MonomerM s m) => Path -> HandlerStep s e -> m (HandlerStep s e)
handleGetClipboard path (wenv, evts, root) = do
  hasText <- SDL.hasClipboardText
  contents <- if hasText
                then fmap ClipboardText SDL.getClipboardText
                else return ClipboardEmpty

  (wenv2, evts2, root2) <- handleSystemEvent wenv (Clipboard contents) path root
  return (wenv2, evts >< evts2, root2)

handleSetClipboard
  :: (MonomerM s m) => ClipboardData -> HandlerStep s e -> m (HandlerStep s e)
handleSetClipboard (ClipboardText text) previousStep = do
  SDL.setClipboardText text
  return previousStep
handleSetClipboard _ previousStep = return previousStep

handleStartTextInput
  :: (MonomerM s m) => Rect -> HandlerStep s e -> m (HandlerStep s e)
handleStartTextInput (Rect x y w h) previousStep = do
  SDL.startTextInput (SDL.Rect (c x) (c y) (c w) (c h))
  return previousStep
  where
    c x = fromIntegral $ round x

handleStopTextInput :: (MonomerM s m) => HandlerStep s e -> m (HandlerStep s e)
handleStopTextInput previousStep = do
  SDL.stopTextInput
  return previousStep

handleSetOverlay
  :: (MonomerM s m) => Path -> HandlerStep s e -> m (HandlerStep s e)
handleSetOverlay path previousStep = do
  L.pathOverlay .= Just path
  return previousStep

handleResetOverlay :: (MonomerM s m) => HandlerStep s e -> m (HandlerStep s e)
handleResetOverlay previousStep = do
  L.pathOverlay .= Nothing
  return previousStep

handleSetCursorIcon
  :: (MonomerM s m) => CursorIcon -> HandlerStep s e -> m (HandlerStep s e)
handleSetCursorIcon icon previousStep = do
  L.currentCursor .= icon
  cursor <- (Map.! icon) <$> use L.cursorIcons
  SDLE.setCursor cursor

  return previousStep

handleUpdateWindow
  :: (MonomerM s m) => WindowRequest -> HandlerStep s e -> m (HandlerStep s e)
handleUpdateWindow windowRequest previousStep = do
  window <- use L.window
  case windowRequest of
    WindowTitle title -> SDL.windowTitle window $= title
    WindowFullScreen -> SDL.setWindowMode window SDL.FullscreenDesktop
    WindowMaximize -> SDL.setWindowMode window SDL.Maximized
    WindowMinimize -> SDL.setWindowMode window SDL.Minimized
    WindowRestore -> SDL.setWindowMode window SDL.Windowed
    WindowBringToFront -> SDL.raiseWindow window
  return previousStep

handleUpdateModel
  :: (MonomerM s m) => (s -> s) -> HandlerStep s e -> m (HandlerStep s e)
handleUpdateModel fn (wenv, evts, root) =
  return (wenv & L.model %~ fn, evts, root)

handleSendMessage
  :: forall s e m msg . (MonomerM s m, Typeable msg)
  => Path
  -> msg
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleSendMessage path message (wenv, events, widgetRoot) = do
  currentFocus <- use L.pathFocus

  let emptyResult = WidgetResult Seq.empty Seq.empty widgetRoot
  let widget = _wiWidget widgetRoot
  let msgResult = widgetHandleMessage widget wenv path message widgetRoot
  let widgetResult = fromMaybe emptyResult msgResult

  (newWenv, newEvents, newWidgetRoot)
    <- handleWidgetResult wenv widgetResult

  return (newWenv, events >< newEvents, newWidgetRoot)

handleRunTask
  :: forall s e m i . (MonomerM s m, Typeable i)
  => Path
  -> IO i
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleRunTask path handler previousStep = do
  asyncTask <- liftIO $ async (liftIO handler)

  previousTasks <- use L.widgetTasks
  L.widgetTasks .= previousTasks |> WidgetTask path asyncTask
  return previousStep

handleRunProducer
  :: forall s e m i . (MonomerM s m, Typeable i)
  => Path
  -> ((i -> IO ()) -> IO ())
  -> HandlerStep s e
  -> m (HandlerStep s e)
handleRunProducer path handler previousStep = do
  newChannel <- liftIO newTChanIO
  asyncTask <- liftIO $ async (liftIO $ handler (sendMessage newChannel))

  previousTasks <- use L.widgetTasks
  L.widgetTasks .= previousTasks |> WidgetProducer path newChannel asyncTask
  return previousStep

addFocusReq
  :: SystemEvent
  -> Seq (WidgetRequest s)
  -> Seq (WidgetRequest s)
addFocusReq (KeyAction mod code KeyPressed) reqs = newReqs where
  isTabPressed = isKeyTab code
  stopProcessing = isJust $ Seq.findIndexL isIgnoreParentEvents reqs
  focusReqExists = isJust $ Seq.findIndexL isFocusRequest reqs
  focusReqNeeded = isTabPressed && not stopProcessing && not focusReqExists
  direction
    | mod ^. L.leftShift = FocusBwd
    | otherwise = FocusFwd
  newReqs
    | focusReqNeeded = reqs |> MoveFocus direction
    | otherwise = reqs
addFocusReq _ reqs = reqs

sendMessage :: TChan e -> e -> IO ()
sendMessage channel message = atomically $ writeTChan channel message

isResize :: WidgetRequest s -> Bool
isResize Resize = True
isResize _ = False

cursorToSDL :: CursorIcon -> SDLE.SystemCursor
cursorToSDL CursorArrow = SDLE.SDL_SYSTEM_CURSOR_ARROW
cursorToSDL CursorHand = SDLE.SDL_SYSTEM_CURSOR_HAND
cursorToSDL CursorIBeam = SDLE.SDL_SYSTEM_CURSOR_IBEAM
cursorToSDL CursorInvalid = SDLE.SDL_SYSTEM_CURSOR_NO
cursorToSDL CursorSizeH = SDLE.SDL_SYSTEM_CURSOR_SIZEWE
cursorToSDL CursorSizeV = SDLE.SDL_SYSTEM_CURSOR_SIZENS
cursorToSDL CursorDiagTL = SDLE.SDL_SYSTEM_CURSOR_SIZENWSE
cursorToSDL CursorDiagTR = SDLE.SDL_SYSTEM_CURSOR_SIZENESW

isFocusRequest :: WidgetRequest s -> Bool
isFocusRequest MoveFocus{} = True
isFocusRequest SetFocus{} = True
isFocusRequest _ = False

isIgnoreParentEvents :: WidgetRequest s -> Bool
isIgnoreParentEvents IgnoreParentEvents = True
isIgnoreParentEvents _ = False
