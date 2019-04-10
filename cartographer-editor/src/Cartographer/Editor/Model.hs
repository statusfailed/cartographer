module Cartographer.Editor.Model where

import Control.Monad
import Control.Applicative

import Miso.String (MisoString)
import Data.Hypergraph
import Linear.V2 (V2(..))

import Cartographer.Layout (Layout(..))
import qualified Cartographer.Layout as Layout

import Cartographer.Viewer (Generator(..), ClickedPorts(..))
import qualified Cartographer.Viewer as Viewer

import Cartographer.Editor.Types as Editor

import Data.These

-- | Update the Editor model without side-effects
update :: Editor.Action -> Editor.Model -> Editor.Model
update action (Model layout actionState) = case action of
  ViewerAction va ->
    let (as, f) = updateActionState actionState va
    in  Model (f layout) as
  StartPlaceGenerator g -> Model layout (PlaceGenerator g)

-- | A state machine for handling inputs
-- TODO: this would be a billion times more readable with Lens.
updateActionState
  :: ActionState
  -> Viewer.Action
  -> (ActionState, Layout Generator -> Layout Generator)
updateActionState Done a = case a of
  Viewer.Action _ (Just (ClickedPorts _ t s)) ->
    case fromMaybes s t of
      Just x  -> (Connecting x, id)
      Nothing -> (Done, id)
  _ -> (Done,id)

updateActionState (Connecting these) a = case a of
  Viewer.Action _ (Just (ClickedPorts _ t s)) ->
    case fromMaybes s t of
      Just  x -> (Done, connectThesePorts these x)
      Nothing -> (Done, id)
  _ -> (Done, id)

updateActionState (PlaceGenerator g) a = case a of
  Viewer.Action pos _ ->
    (Done, insertSpacedCoordinates g pos)

-- | Decide which ports a user intended to connect.
-- Because a tile can have both an input and output port, we simply store both
-- when a tile is clicked.
-- We decide which ports to connect when the user clicks on a second tile, by
-- checking if it's to the left or right of the first click:
--    case right: the first click was a SOURCE port
--    case left:  the first click was a TARGET port.
connectThesePorts
  :: Layout.Generator sig
  => These (Port Source Open) (Port Target Open)
  -> These (Port Source Open) (Port Target Open)
  -> Layout sig
  -> Layout sig
connectThesePorts a b layout =
  maybe id (uncurry Layout.connectPorts) toPorts $ layout
  where
    toPorts = thisConnection layout a b <|> thatConnection layout a b

thisConnection
  :: Layout.Generator sig
  => Layout sig
  -> These (Port Source Open) (Port Target Open)
  -> These (Port Source Open) (Port Target Open)
  -> Maybe (Wire Open)
thisConnection layout this that = do
  s <- justHere this
  t <- justThere that
  positionedLeftOf layout s t

thatConnection
  :: Layout.Generator sig
  => Layout sig
  -> These (Port Source Open) (Port Target Open)
  -> These (Port Source Open) (Port Target Open)
  -> Maybe (Wire Open)
thatConnection layout = flip (thisConnection layout)

positionedLeftOf
  :: Layout.Generator sig
  => Layout sig
  -> Port Source Open
  -> Port Target Open
  -> Maybe (Wire Open)
positionedLeftOf layout s t = do
  -- make sure sx is left of tx
  V2 sx _ <- Layout.portPosition s layout
  V2 tx _ <- Layout.portPosition t layout
  guard (sx < tx)

  -- return the function to connect the two ports.
  return (s, t)


-- | Turned spaced coordinates into extended coordinates (see DESIGN.md)
--
-- TODO: this should probably go in Viewer, or ViewerAction should do it for
-- us.
spacedToExtended :: V2 Int -> V2 Int
spacedToExtended (V2 x y) = V2 (x `div` 2) y

-- | Insert into the Layout in spaced coordinates.
-- When inserting onto a "wires" column, a layer is first inserted into the
-- extended grid to the *right* of the wires column.
-- Otherwise, the generator is inserted into column clicked.
insertSpacedCoordinates
  :: Layout.Generator sig
  => sig -> V2 Int -> Layout sig -> Layout sig
insertSpacedCoordinates g v@(V2 0 _) = id -- TODO: still ignore left boundary?
insertSpacedCoordinates g v@(V2 x _) = snd . Layout.placeGenerator g v' . f
  where
    f = if odd x then Layout.insertLayer (Layout.Layer x') 1 else id
    v'@(V2 x' _) = spacedToExtended (v - V2 1 0)

-- | Try to create a 'These' from two maybes.
fromMaybes :: Maybe a -> Maybe b -> Maybe (These a b)
fromMaybes a b = case (a, b) of
  (Just x, Nothing) -> Just $ This x
  (Nothing, Just y) -> Just $ That y
  (Just x, Just y)  -> Just $ These x y
  _ -> Nothing

justHere (This x) = Just x
justHere (These x _) = Just x
justHere _ = Nothing

justThere (That y) = Just y
justThere (These _ y) = Just y
justThere _ = Nothing
