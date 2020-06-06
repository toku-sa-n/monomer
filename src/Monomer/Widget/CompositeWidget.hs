{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE MultiWayIf #-}

module Monomer.Widget.CompositeWidget where

import Debug.Trace

import Data.Default
import Data.List (foldl')
import Data.Maybe
import Data.Sequence (Seq(..), (|>))
import Data.Typeable (Typeable, cast, typeOf)

import qualified Data.Sequence as Seq

import Monomer.Common.Geometry
import Monomer.Common.Tree
import Monomer.Event.Core
import Monomer.Event.Types
import Monomer.Graphics.Renderer
import Monomer.Widget.PathContext
import Monomer.Widget.Types
import Monomer.Widget.Util

type UIBuilderC s e m = s -> WidgetInstance s e m
type EventHandlerC s e ep = s -> e -> EventResponseC s e ep

data EventResponseC s e ep = StateC s
                           | TaskC s (IO (Maybe e))
                           | MessageC ep

data Composite s e ep m = Composite {
  _widgetTypeC :: WidgetType,
  _eventHandlerC :: EventHandlerC s e ep,
  _uiBuilderC :: UIBuilderC s e m,
  _sizeReqC :: Tree SizeReq
}

data CompositeState s e m = CompositeState {
  _compositeApp :: s,
  _compositeRoot :: WidgetInstance s e m
}

data CompositeTask = forall e . Typeable e => CompositeTask e

composite :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => WidgetType -> s -> EventHandlerC s e ep -> UIBuilderC s e m -> WidgetInstance sp ep m
composite widgetType app eventHandler uiBuilder = defaultWidgetInstance widgetType widget where
  widgetRoot = uiBuilder app
  composite = Composite widgetType eventHandler uiBuilder (singleNode def)
  state = CompositeState app widgetRoot
  widget = createComposite composite state

createComposite :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> Widget sp ep m
createComposite comp state = widget where
  CompositeState app widgetRoot = state
  widget = Widget {
    _widgetGetState = makeState state,
    _widgetMerge = compositeMerge comp state,
    _widgetNextFocusable = compositeNextFocusable state,
    _widgetFind = compositeFind state,
    _widgetHandleEvent = compositeHandleEvent comp state,
    _widgetHandleCustom = compositeHandleCustom comp state,
    _widgetPreferredSize = compositePreferredSize state,
    _widgetResize = compositeResize comp state,
    _widgetRender = compositeRender state
  }

compositeMerge :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> sp -> WidgetInstance sp ep m -> WidgetInstance sp ep m -> WidgetInstance sp ep m
compositeMerge comp state pApp newComposite oldComposite = newInstance where
  oldState = _widgetGetState (_instanceWidget oldComposite) pApp
  CompositeState oldApp oldRoot = fromMaybe state (useState oldState)
  -- The widgetRoot created on _composite_ has not yet been evaluated, so duplicate widget tree creation is avoided
  newRoot = _uiBuilderC comp oldApp
  widgetRoot = _widgetMerge (_instanceWidget newRoot) oldApp newRoot oldRoot
  newState = CompositeState oldApp widgetRoot
  newInstance = newComposite {
    _instanceWidget = createComposite comp newState
  }

compositeNextFocusable :: CompositeState s e m -> PathContext -> WidgetInstance sp ep m -> Maybe Path
compositeNextFocusable (CompositeState app widgetRoot) ctx widgetComposite = _widgetNextFocusable (_instanceWidget widgetRoot) ctx widgetRoot

compositeFind :: CompositeState s e m -> Point -> WidgetInstance sp ep m -> Maybe Path
compositeFind (CompositeState app widgetRoot) point widgetComposite = _widgetFind (_instanceWidget widgetRoot) point widgetRoot

compositeHandleEvent :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> PathContext -> SystemEvent -> sp -> WidgetInstance sp ep m -> Maybe (EventResult sp ep m)
compositeHandleEvent comp state ctx evt pApp widgetComposite = fmap processEvent result where
  CompositeState app widgetRoot = state
  processEvent = processEventResult comp state ctx widgetComposite
  result = _widgetHandleEvent (_instanceWidget widgetRoot) ctx evt app widgetRoot

processEventResult :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> PathContext -> WidgetInstance sp ep m -> EventResult s e m -> EventResult sp ep m
processEventResult comp state ctx widgetComposite (EventResult reqs evts evtsRoot) = EventResult newReqs messages newInstance where
  CompositeState app widgetRoot = state
  evtStates = getUpdateUserStates reqs
  evtApp = foldr (.) id evtStates app
  newReqs = convertRequests reqs <> convertTasksToRequests ctx tasks

  (newApp, tasks, messages) = reduceCompositeEvents (_eventHandlerC comp) evtApp evts
  builtRoot = _uiBuilderC comp newApp
  tempRoot = if | app /= newApp -> _widgetMerge (_instanceWidget builtRoot) newApp builtRoot evtsRoot
                | otherwise -> evtsRoot
  viewport = _instanceViewport widgetComposite
  renderArea = _instanceRenderArea widgetComposite
  newRoot = _widgetResize (_instanceWidget tempRoot) newApp viewport renderArea tempRoot (_sizeReqC comp)
  newState = CompositeState newApp newRoot
  newInstance = widgetComposite {
    _instanceWidget = createComposite comp newState
  }

reduceCompositeEvents :: EventHandlerC s e ep -> s -> Seq e -> (s, Seq (IO (Maybe e)), Seq ep)
reduceCompositeEvents appEventHandler app events = foldl' reducer (app, Seq.empty, Seq.empty) events where
  reducer (app, tasks, messages) event = case appEventHandler app event of
    StateC newApp -> (newApp, tasks, messages)
    TaskC newApp task -> (newApp, tasks |> task, messages)
    MessageC message -> (app, tasks, messages |> message)

convertTasksToRequests :: Typeable e => PathContext -> Seq (IO (Maybe e)) -> Seq (EventRequest sp)
convertTasksToRequests ctx reqs = flip fmap reqs $ \req -> RunCustom (_pathCurrent ctx) (fmap CompositeTask req)

-- | Custom Handling
compositeHandleCustom :: (Monad m, Eq s, Typeable i, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> PathContext -> i -> sp -> WidgetInstance sp ep m -> Maybe (EventResult sp ep m)
compositeHandleCustom comp state ctx arg app widgetComposite
  | isTargetReached ctx = case cast arg of
      Just (CompositeTask evt) -> case cast evt of
        Just (Just res) -> Just $ processEventResult comp state ctx widgetComposite evtResult where
          evtResult = EventResult Seq.empty (Seq.singleton res) (_compositeRoot state)
        _ -> Nothing
      Nothing -> Nothing
  | otherwise = fmap processEvent result where
      CompositeState app widgetRoot = state
      processEvent = processEventResult comp state ctx widgetComposite
      result = _widgetHandleCustom (_instanceWidget widgetRoot) ctx arg app widgetRoot

-- Preferred size
compositePreferredSize :: CompositeState s e m -> Renderer m -> sp -> WidgetInstance sp ep m -> Tree SizeReq
compositePreferredSize (CompositeState app widgetRoot) renderer _ _ = _widgetPreferredSize (_instanceWidget widgetRoot) renderer app widgetRoot

-- Resize
compositeResize :: (Monad m, Eq s, Typeable s, Typeable e, Typeable ep, Typeable m) => Composite s e ep m -> CompositeState s e m -> sp -> Rect -> Rect -> WidgetInstance sp ep m -> Tree SizeReq -> WidgetInstance sp ep m
compositeResize comp state _ viewport renderArea widgetComposite reqs = newInstance where
  CompositeState app widgetRoot = state
  newComp = comp { _sizeReqC = reqs }
  newRoot = _widgetResize (_instanceWidget widgetRoot) app viewport renderArea widgetRoot reqs
  newState = CompositeState app newRoot
  newInstance = widgetComposite {
    _instanceWidget = createComposite newComp newState,
    _instanceViewport = viewport,
    _instanceRenderArea = renderArea
  }

-- Render
compositeRender :: (Monad m) => CompositeState s e m -> Renderer m -> Timestamp -> PathContext -> sp -> WidgetInstance sp ep m -> m ()
compositeRender (CompositeState app widgetRoot) renderer ts ctx _ _ = _widgetRender (_instanceWidget widgetRoot) renderer ts ctx app widgetRoot