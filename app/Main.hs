{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Debug.Trace

import Control.Concurrent (threadDelay)
import Control.Lens ((&), (^.), (.~), (%~))
import Data.Default
import TextShow

import System.Remote.Monitoring

import Monomer

import qualified Monomer.Lens as L

import KeysComposite
import TestComposite
import Types

main :: IO ()
main = do
  --forkServer "localhost" 28000

  let model = def
  let theme :: Theme = darkTheme
  --      & L.basic . L.fgColor .~ blue
  --      & L.hover . L.fgColor .~ white
  --      & L.focus . L.fgColor .~ white
  let config = [
        --windowSize (1280, 960),
        --windowSize (320, 240),
        useHdpi True,
        appTheme theme,
        appInitEvent InitApp,
        fontDef "Regular" "./assets/fonts/Roboto-Regular.ttf",
        fontDef "Bold" "./assets/fonts/Roboto-Bold.ttf",
        fontDef "Italic" "./assets/fonts/Roboto-Italic.ttf" ]

  simpleApp_ model handleAppEvent buildUI config
  --simpleApp model handleAppEvent buildUI

handleAppEvent model evt = case evt of
  IncButton -> Model (model & clickCount %~ (+1))
--  PrintMessage txt -> Model (model & showAlert .~ True)
  PrintMessage txt -> Task $ do
    print txt
    return Nothing
  CheckboxSt st -> Task $ do
    putStrLn $ "Checkbox is: " ++ show st
    return Nothing
--  RadioSt st -> Task $ do
--    putStrLn $ "Radio is: " ++ show st
--    return Nothing
  RadioSt st -> Model (model & fruit .~ st)
  ImageMsg msg -> Task $ do
    putStrLn $ "Image msg is: " ++ show msg
    return Nothing
  DropdownVal txt -> Task $ do
    putStrLn $ "Dropdown txt is: " ++ show txt
    return Nothing
  DropdownIdx idx txt -> Task $ do
    threadDelay 100
    putStrLn $ "Dropdown (idx, txt) is: " ++ show (idx,  txt)
    return Nothing
  ShowAlert -> Model (model & showAlert .~ True)
  CloseAlert -> Model (model & showAlert .~ False)
  ShowConfirm -> Model (model & showConfirm .~ True)
  AcceptConfirm -> Model (model & showConfirm .~ False)
  CancelConfirm -> Model (model & showConfirm .~ False)
  RunShortTask -> Task $ do
    putStrLn "Running!"
    return Nothing
  _ -> Model model

buildUI :: App -> WidgetInstance App AppEvent
buildUI model = trace "Creating UI" widgetTree where
  widgetTree = zstack [
      widgetTree3,
      alert "Message" CloseAlert `visible` model ^. showAlert,
      confirm "Message" AcceptConfirm CancelConfirm `visible` model ^. showConfirm
      --confirm "Message" AcceptConfirm CancelConfirm
      --widgetTree2,
      --widgetTree1
    ]
  widgetTree1 = vstack [
      --label (model ^. textField1) `style` [bgColor lightBlue, textLeft]
      alert "Message" RunShortTask
      --,
      --textField textField1 `style` [bgColor lightBlue, textLeft]
    ]
  widgetTree2 = textField textField1 `style` [bgColor lightBlue, textLeft]
  widgetTree3 = vstack [
      hstack [
        radioV (model ^. fruit) RadioSt Apple,
        radioV (model ^. fruit) RadioSt Orange,
        radioV (model ^. fruit) RadioSt Pear
      ] `key` "radio hstack" `style` [bgColor gray],
      hstack [
        button "Show Alert" ShowAlert,
        button "Show Confirm" ShowConfirm
      ],
      hgrid [
        vstack [
          label "jLabel 1" `style` [bgColor darkGray],
          label "Label 12" `style` [bgColor lightGray],
          label "Label 123" `style` [bgColor darkGray],
          label "Label 1234" `style` [bgColor lightGray]
        ] `style` [bgColor red],
        vstack [
          label "jLabel 1" `style` [bgColor lightGray, textBottom],
          label "Label 12" `style` [bgColor darkGray],
          label "Label 123" `style` [bgColor lightGray],
          label "Label 1234" `style` [bgColor darkGray]
        ] `style` [bgColor blue]
      ] `style` [bgColor green],
      label (model ^. textField1) `style` [bgColor lightBlue, textLeft],
      textField textField1 `style` [bgColor lightBlue, textLeft],
      hgrid [
        label_ "This is a really long label used to check what I did works fine" [textEllipsis],
        label "Jj label"
      ],
      hstack [
        scroll_ (
          scroll (image_ "assets/images/pecans.jpg" [fitFill] `style` [minWidth 200])
        ) []
        ,
        spacer_ [resizeFactor 1],
        image_ "https://picsum.photos/600/400" [fitFill, onLoadError ImageMsg]
      ],
      textDropdown_ textField1 items id [onChange DropdownVal, onChangeIdx DropdownIdx] `style` [bgColor lightBlue],
      button "Click me" (PrintMessage "Button clicked")
    ] `key` "main vstack" `style` [borderT 20 red, borderL 10 blue, borderR 10 green, borderB 10 gray, iradius 50] --, padding 20
  newLabel i = label ("New: " <> showt i) `style` [altColor i]
  altColor i = bgColor (if even i then gray else darkGray)
  labels = newLabel <$> [0..(model ^. clickCount - 1)]
  items = fmap showt [1..100::Int]
