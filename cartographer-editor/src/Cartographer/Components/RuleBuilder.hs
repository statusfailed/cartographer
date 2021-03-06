{-# LANGUAGE OverloadedLists    #-}
{-# LANGUAGE OverloadedStrings  #-}
module Cartographer.Components.RuleBuilder where

import Miso

import Cartographer.Layout (Layout(..))
import qualified Cartographer.Proof as Proof
import Cartographer.Viewer.Types (Generator(..))

import qualified Cartographer.Layout as Layout
import qualified Cartographer.Editor as Editor

type Model = (Editor.Model, Editor.Model)

emptyModel :: Model
emptyModel = (Editor.emptyModel, Editor.emptyModel)

-- Left and Right are useful constructor names :)
type Action = Either Editor.Action Editor.Action

update :: Action -> Model -> Model
update (Left  a) (l, r) = (Editor.update a l, r)
update (Right a) (l, r) = (l, Editor.update a r)

-- TODO: add diagnostics about whether left and right are:
--    * complete
--    * have same dimensions
view :: [Generator] -> Model -> View Action
view gs (l, r) = div_ [ Miso.class_ "message is-info" ]
  [ div_ [ class_ "message-header" ]
    [ "Rule"
    , button_ [ class_ "delete" ] [] -- TODO: hook this up
    ]
  , div_ [ class_ "message-body" ]
    [ diagnostic (l, r)
    , div_ [ class_ "columns" ]
      [ col $ Left  <$> Editor.view gs l
      , col $ Right <$> Editor.view gs r
      ]
    ]
  ]
  where
    col = div_ [ class_ "column" ] . pure
    diagnostic m = case toRule m of
      Just _  -> div_ [] []
      Nothing -> invalidRule

    invalidRule = div_ [ class_ "notification is-warning" ]
      [ "incomplete rule! do your types match?" ]

fromRule :: Proof.Rule Generator -> Model
fromRule (Proof.Rule l r) = (Editor.fromLayout l, Editor.fromLayout r)

toRule :: Model -> Maybe (Proof.Rule Generator)
toRule (Editor.Model l _ _, Editor.Model r _ _) = Proof.rule l r
